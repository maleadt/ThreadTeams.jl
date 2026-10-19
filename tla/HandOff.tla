---------------------------- MODULE HandOff ----------------------------
(* The hand-off of one parallel region from the caller ("dispatcher", thread 0) to N
   persistent workers (threads 1..N; worker k runs chunk k + 1, the caller runs chunk 1),
   as in src/pool.jl: `dispatch!`, `wait_for_command`, `worker_loop`, `wake_children`,
   `wait_idle`, with the memory orderings of every atomic access as parameters.

   Memory model: a view-based operational model of release/acquire consistency with
   sequentially consistent fences (the "promise-free" fragment of the promising semantics,
   Kang et al. 2017; Kaiser et al. 2017). Every location holds a list of messages (the
   modification order, timestamps 1, 2, ...); every thread has a view: per location, the
   newest message it knows of. A load may read any message at or after the thread's view.
   A release store attaches the writer's view to the message, an acquire load joins the
   message's view into the reader's. An RMW reads the newest message; its message carries
   the view of the message it read (release sequences). An sc fence joins the thread's view
   with a global view and stores the result back. Sequentially consistent *accesses* are
   encoded in one of two ways (constant SCENC):
     "fence": sc store = release store + sc fence; sc load = acquire load;
              sc RMW = sc fence + acq_rel RMW + sc fence. This is how x86 implements them
              (xchg; mov; lock cmpxchg), a valid implementation of C11/Julia sc accesses,
              so it has at most the behaviours of C11.
     "weak":  sc store = release store, sc load = acquire load, sc RMW = acq_rel RMW,
              no fences: plain release/acquire consistency, which has at least the
              behaviours of C11 (sc accesses are at least as strong as rel/acq ones).
   A protocol property that holds under "weak" therefore holds under C11 for any
   compilation; one that fails under "fence" fails on x86. The explicit `atomic_fence()`
   of `dispatch!` is an sc fence under both encodings.

   Abstractions: the region data (`job`, `nchunks`, `skip`, `scope`, `world`) is one
   location `region`, written with the ordering of those stores (monotonic) before the
   commands; a worker running a chunk must read the current region (FreshRegion). The
   chunk's results and exceptions (`errs[k]`, the partials buffer) are one location `res_k`
   written by the worker before its final `cmd = 0`; the caller reads it after `wait_idle`
   (ResultsVisible). The `Event` of a worker is a flag with the notifier's view attached
   (its lock is a release/acquire pair). The caller runs chunk 1 and stolen chunks without
   memory accesses. One region; workers start spinning or asleep (all combinations). *)
EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS
    N,              \* number of workers
    TREE,           \* the wake-up tree: "binary" as in the code (chunk c wakes 2c and 2c + 1),
                    \* or "chain" (chunk c wakes c + 1), which needs only two workers for a
                    \* worker to wake another worker
    SLEEPERS,       \* the workers that may go to sleep (a subset of 1..N)
    MAXSLEEP,       \* how often a worker may go to sleep in the region (bounds the model)
    BACKUP,         \* `wait_idle` re-notifies a sleeping worker whose command is pending
    SCENC,          \* "fence" or "weak", see above
    \* orderings of the accesses: "rlx", "acq", "rel", "acqrel", "sc" ("none" for the fence)
    OrdRegion,      \* dispatch!:  the region data stores (`pool.job` etc.)
    OrdCmd,         \* dispatch!:  the command stores `ws.cmd = chunk`
    OrdFence,       \* dispatch!:  `Threads.atomic_fence()` after the command stores
    OrdWakeSlp,     \* wake_chunk: the load of `sleeping`
    OrdWakeCmd,     \* wake_chunk: the load of `cmd`
    OrdSteal,       \* dispatch!:  the load of `cmd` before stealing a chunk
    OrdStealCAS,    \* dispatch!:  the compare-and-swap `cmd: chunk => 0`
    OrdIdle,        \* wait_idle:  the load of `cmd`
    OrdBackup,      \* wait_idle:  the load of `sleeping` (re-notify)
    OrdSpin,        \* wait_for_command: the load of `cmd` in the spin loop
    OrdClaim,       \* wait_for_command: the compare-and-swap `cmd: chunk => RUNNING`
    OrdClaimFail,   \* wait_for_command: its failure ordering
    OrdSleep,       \* wait_for_command: the store `sleeping = true`
    OrdSleepCheck,  \* wait_for_command: the load of `cmd` after it
    OrdAwake,       \* wait_for_command: the store `sleeping = false`
    OrdDone         \* worker_loop: the store `cmd = 0` after the chunk

ASSUME N \in Nat /\ N >= 1
ASSUME TREE \in {"binary", "chain"}
ASSUME SLEEPERS \subseteq 1..N /\ MAXSLEEP \in Nat
ASSUME SCENC \in {"fence", "weak"}

RUNNING == -2
Workers == 1..N
Threads == 0..N                 \* 0 is the dispatcher
Chunks == 2..(N + 1)            \* chunk c belongs to worker c - 1
Wk(c) == c - 1
Children(c) == IF TREE = "binary" THEN {e \in Chunks : e \in {2 * c, 2 * c + 1}}
                                  ELSE {e \in Chunks : e = c + 1}

Loc(kind, k) == [kind |-> kind, k |-> k]
Region == Loc("region", 0)
Cmd(k) == Loc("cmd", k)
Slp(k) == Loc("slp", k)
Res(k) == Loc("res", k)
Locs == {Region} \cup {Cmd(k) : k \in Workers} \cup {Slp(k) : k \in Workers}
        \cup {Res(k) : k \in Workers}

Bot == [l \in Locs |-> 0]
Max(a, b) == IF a >= b THEN a ELSE b
Join(v, u) == [l \in Locs |-> Max(v[l], u[l])]

IsAcq(o) == o \in {"acq", "acqrel", "sc"}
IsRel(o) == o \in {"rel", "acqrel", "sc"}
\* sc fences that an sc access carries in the encoding: after a store or RMW, before an RMW
Fences(o) == IF o = "sc" /\ SCENC = "fence" THEN 1 ELSE 0

VARIABLES
    mem,    \* [Locs -> Seq([val, view])]: the messages of each location
    view,   \* [Threads -> [Locs -> Nat]]: the view of each thread
    scv,    \* [Locs -> Nat]: the view of the sc fences
    ev,     \* [Workers -> BOOLEAN]: the worker's Event is set
    evv,    \* [Workers -> view]: the view of the last notifier
    d,      \* the dispatcher: pc, c (chunk), k (worker), wq (chunks to wake), wc (chunk
            \*   being woken), ret (pc after waking), pend (fences)
    w,      \* [Workers -> worker]: pc, cmd (command read), wq, wc, pend, slept (times)
    runs,   \* [Chunks -> Nat]: how often each chunk has been run
    ranBy,  \* [Chunks -> -1..N]: who ran the chunk
    skipped \* [Chunks -> BOOLEAN]: wake_chunk saw the worker awake and did not notify it
vars == <<mem, view, scv, ev, evv, d, w, runs, ranBy, skipped>>

Newest(l) == Len(mem[l])
Readable(t, l) == {i \in 1..Newest(l) : i >= view[t][l]}
ViewAfterRead(t, l, i, o) ==
    IF IsAcq(o) THEN Join(view[t], mem[l][i].view) ELSE [view[t] EXCEPT ![l] = i]
NewMsg(t, l, val, o) ==
    LET ts == Newest(l) + 1
    IN [val |-> val, view |-> IF IsRel(o) THEN [view[t] EXCEPT ![l] = ts]
                                          ELSE [Bot EXCEPT ![l] = ts]]
Store(t, l, val, o) ==
    /\ mem' = [mem EXCEPT ![l] = Append(@, NewMsg(t, l, val, o))]
    /\ view' = [view EXCEPT ![t] = [@ EXCEPT ![l] = Newest(l) + 1]]
\* an RMW reads the newest message and writes right after it
RMWViews(t, l, o) ==
    LET m == mem[l][Newest(l)]
        ts == Newest(l) + 1
        tv == IF IsAcq(o) THEN Join(view[t], m.view) ELSE view[t]
        mv == IF IsRel(o) THEN Join(view[t], m.view) ELSE m.view
    IN [thread |-> [tv EXCEPT ![l] = ts], msg |-> [mv EXCEPT ![l] = ts]]
RMW(t, l, val, o) ==
    /\ mem' = [mem EXCEPT ![l] = Append(@, [val |-> val, view |-> RMWViews(t, l, o).msg])]
    /\ view' = [view EXCEPT ![t] = RMWViews(t, l, o).thread]
Fence(t) ==
    LET v == Join(view[t], scv)
    IN view' = [view EXCEPT ![t] = v] /\ scv' = v
Notify(t, k) ==
    /\ ev' = [ev EXCEPT ![k] = TRUE]
    /\ evv' = [evv EXCEPT ![k] = Join(@, view'[t])]

Init ==
    /\ \E asleep \in SUBSET SLEEPERS :
        /\ mem = [l \in Locs |->
                    IF l.kind = "slp" /\ l.k \in asleep
                    THEN <<[val |-> FALSE, view |-> [Bot EXCEPT ![l] = 1]],
                           [val |-> TRUE, view |-> [Bot EXCEPT ![l] = 2]]>>
                    ELSE <<[val |-> IF l.kind = "slp" THEN FALSE ELSE 0,
                            view |-> [Bot EXCEPT ![l] = 1]]>>]
        /\ view = [t \in Threads |-> [l \in Locs |->
                    IF l.kind = "slp" /\ l.k = t /\ t \in asleep THEN 2 ELSE 1]]
        \* the `sleeping = true` of an asleep worker was an sc store
        /\ scv = [l \in Locs |->
                    IF SCENC = "fence" /\ l.kind = "slp" /\ l.k \in asleep THEN 2 ELSE 1]
        /\ w = [k \in Workers |-> [pc |-> IF k \in asleep THEN "wait" ELSE "spin",
                                   cmd |-> 0, wq |-> {}, wc |-> 0, pend |-> 0,
                                   slept |-> IF k \in asleep THEN 1 ELSE 0]]
    /\ ev = [k \in Workers |-> FALSE]
    /\ evv = [k \in Workers |-> Bot]
    /\ d = [pc |-> "publish", c |-> 0, k |-> 0, wq |-> {}, wc |-> 0, ret |-> "", pend |-> 0]
    /\ runs = [c \in Chunks |-> 0]
    /\ ranBy = [c \in Chunks |-> -1]
    /\ skipped = [c \in Chunks |-> FALSE]

-----------------------------------------------------------------------------
(* The dispatcher *)

DFence ==
    /\ d.pend > 0
    /\ Fence(0)
    /\ d' = [d EXCEPT !.pend = @ - 1]
    /\ UNCHANGED <<mem, ev, evv, w, runs, ranBy, skipped>>

\* publish the region data
DPublish ==
    /\ d.pend = 0 /\ d.pc = "publish"
    /\ Store(0, Region, 1, OrdRegion)
    /\ d' = [d EXCEPT !.pc = "store", !.c = N + 1, !.pend = Fences(OrdRegion)]
    /\ UNCHANGED <<scv, ev, evv, w, runs, ranBy, skipped>>

\* store the commands in decreasing chunk order, then the fence
DStore ==
    /\ d.pend = 0 /\ d.pc = "store"
    /\ IF d.c >= 2
       THEN /\ Store(0, Cmd(Wk(d.c)), d.c, OrdCmd)
            /\ d' = [d EXCEPT !.c = @ - 1, !.pend = Fences(OrdCmd)]
            /\ UNCHANGED scv
       ELSE /\ IF OrdFence = "sc" THEN Fence(0) ELSE UNCHANGED <<view, scv>>
            /\ UNCHANGED mem
            /\ d' = [d EXCEPT !.pc = "wake", !.wq = Children(1), !.ret = "steal", !.c = N + 1]
    /\ UNCHANGED <<ev, evv, w, runs, ranBy, skipped>>

\* wake_children: for each chunk in wq, load `sleeping`, then `cmd`, then notify
DWake ==
    /\ d.pend = 0 /\ d.pc = "wake"
    /\ IF d.wq = {}
       THEN d' = [d EXCEPT !.pc = d.ret] /\ UNCHANGED <<view, skipped>>
       ELSE \E c \in d.wq : \E i \in Readable(0, Slp(Wk(c))) :
            /\ view' = [view EXCEPT ![0] = ViewAfterRead(0, Slp(Wk(c)), i, OrdWakeSlp)]
            /\ d' = [d EXCEPT !.wq = @ \ {c}, !.wc = c,
                              !.pc = IF mem[Slp(Wk(c))][i].val THEN "wakecmd" ELSE "wake"]
            /\ skipped' = [skipped EXCEPT ![c] = @ \/ ~mem[Slp(Wk(c))][i].val]
    /\ UNCHANGED <<mem, scv, ev, evv, w, runs, ranBy>>

DWakeCmd ==
    /\ d.pend = 0 /\ d.pc = "wakecmd"
    /\ \E i \in Readable(0, Cmd(Wk(d.wc))) :
        /\ view' = [view EXCEPT ![0] = ViewAfterRead(0, Cmd(Wk(d.wc)), i, OrdWakeCmd)]
        /\ IF mem[Cmd(Wk(d.wc))][i].val = d.wc THEN Notify(0, Wk(d.wc))
                                               ELSE UNCHANGED <<ev, evv>>
    /\ d' = [d EXCEPT !.pc = "wake"]
    /\ UNCHANGED <<mem, scv, w, runs, ranBy, skipped>>

\* after chunk 1: run the chunks that their workers have not claimed yet, in decreasing
\* order (the children of a chunk are stolen or claimed before it: no wake-ups)
DSteal ==
    /\ d.pend = 0 /\ d.pc = "steal"
    /\ IF d.c < 2
       THEN d' = [d EXCEPT !.pc = "idle", !.k = 1] /\ UNCHANGED view
       ELSE \E i \in Readable(0, Cmd(Wk(d.c))) :
            /\ view' = [view EXCEPT ![0] = ViewAfterRead(0, Cmd(Wk(d.c)), i, OrdSteal)]
            /\ IF mem[Cmd(Wk(d.c))][i].val = d.c
               THEN d' = [d EXCEPT !.pc = "stealcas", !.pend = Fences(OrdStealCAS)]
               ELSE d' = [d EXCEPT !.c = @ - 1]
    /\ UNCHANGED <<mem, scv, ev, evv, w, runs, ranBy, skipped>>

DStealCAS ==
    /\ d.pend = 0 /\ d.pc = "stealcas"
    /\ LET l == Cmd(Wk(d.c))
       IN IF mem[l][Newest(l)].val = d.c
          THEN /\ RMW(0, l, 0, OrdStealCAS)
               /\ runs' = [runs EXCEPT ![d.c] = @ + 1]
               /\ ranBy' = [ranBy EXCEPT ![d.c] = 0]
               /\ d' = [d EXCEPT !.pc = "steal", !.c = @ - 1, !.pend = Fences(OrdStealCAS)]
          ELSE /\ view' = [view EXCEPT ![0] = ViewAfterRead(0, l, Newest(l), "rlx")]
               /\ d' = [d EXCEPT !.pc = "steal", !.c = @ - 1, !.pend = Fences(OrdStealCAS)]
               /\ UNCHANGED <<mem, runs, ranBy, skipped>>
    /\ UNCHANGED <<scv, ev, evv, w, skipped>>

\* wait_idle for every worker, then read its results (no read step: ResultsVisible asks
\* whether a relaxed read could still return the old value)
DIdleRead(i) ==
    /\ view' = [view EXCEPT ![0] = ViewAfterRead(0, Cmd(d.k), i, OrdIdle)]
    /\ IF mem[Cmd(d.k)][i].val = 0 THEN d' = [d EXCEPT !.pc = "results"]
       ELSE IF BACKUP THEN d' = [d EXCEPT !.pc = "backup"]
       ELSE d' = d
DIdle ==
    /\ d.pend = 0 /\ d.pc = "idle"
    /\ IF d.k > N
       THEN d' = [d EXCEPT !.pc = "done"] /\ UNCHANGED view
       ELSE \E i \in Readable(0, Cmd(d.k)) : DIdleRead(i)
    /\ UNCHANGED <<mem, scv, ev, evv, w, runs, ranBy, skipped>>
DIdleLatest ==
    /\ d.pend = 0 /\ d.pc = "idle" /\ d.k <= N
    /\ DIdleRead(Newest(Cmd(d.k)))
    /\ UNCHANGED <<mem, scv, ev, evv, w, runs, ranBy, skipped>>

DBackupRead(i) ==
    /\ view' = [view EXCEPT ![0] = ViewAfterRead(0, Slp(d.k), i, OrdBackup)]
    /\ IF mem[Slp(d.k)][i].val THEN Notify(0, d.k) ELSE UNCHANGED <<ev, evv>>
    /\ d' = [d EXCEPT !.pc = "idle"]
DBackup ==
    /\ d.pend = 0 /\ d.pc = "backup"
    /\ \E i \in Readable(0, Slp(d.k)) : DBackupRead(i)
    /\ UNCHANGED <<mem, scv, w, runs, ranBy, skipped>>
DBackupLatest ==
    /\ d.pend = 0 /\ d.pc = "backup"
    /\ DBackupRead(Newest(Slp(d.k)))
    /\ UNCHANGED <<mem, scv, w, runs, ranBy, skipped>>

DResults ==
    /\ d.pend = 0 /\ d.pc = "results"
    /\ d' = [d EXCEPT !.pc = "idle", !.k = @ + 1]
    /\ UNCHANGED <<mem, view, scv, ev, evv, w, runs, ranBy, skipped>>

DAny == DFence \/ DPublish \/ DStore \/ DWake \/ DWakeCmd \/ DSteal \/ DStealCAS
        \/ DIdle \/ DBackup \/ DResults

-----------------------------------------------------------------------------
(* Worker k *)

WFence(k) ==
    /\ w[k].pend > 0
    /\ Fence(k)
    /\ w' = [w EXCEPT ![k].pend = @ - 1]
    /\ UNCHANGED <<mem, ev, evv, d, runs, ranBy, skipped>>

\* the spin loop of wait_for_command; after a command <= 0 the worker may decide to sleep
WSpinRead(k, i) ==
    LET v == mem[Cmd(k)][i].val
    IN /\ view' = [view EXCEPT ![k] = ViewAfterRead(k, Cmd(k), i, OrdSpin)]
       /\ IF v > 0
          THEN w' = [w EXCEPT ![k].pc = "claim", ![k].cmd = v, ![k].pend = Fences(OrdClaim)]
          ELSE \E next \in {"spin"} \cup
                    (IF k \in SLEEPERS /\ w[k].slept < MAXSLEEP THEN {"presleep"} ELSE {}) :
                w' = [w EXCEPT ![k].pc = next]
WSpin(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "spin"
    /\ \E i \in Readable(k, Cmd(k)) : WSpinRead(k, i)
    /\ UNCHANGED <<mem, scv, ev, evv, d, runs, ranBy, skipped>>
WSpinLatest(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "spin"
    /\ WSpinRead(k, Newest(Cmd(k)))
    /\ UNCHANGED <<mem, scv, ev, evv, d, runs, ranBy, skipped>>

\* claim the chunk: cmd: chunk => RUNNING; fails if the dispatcher stole it
WClaim(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "claim"
    /\ LET l == Cmd(k)
       IN IF mem[l][Newest(l)].val = w[k].cmd
          THEN /\ RMW(k, l, RUNNING, OrdClaim)
               /\ runs' = [runs EXCEPT ![w[k].cmd] = @ + 1]
               /\ ranBy' = [ranBy EXCEPT ![w[k].cmd] = k]
               /\ w' = [w EXCEPT ![k].pc = "wake", ![k].wq = Children(w[k].cmd),
                                 ![k].pend = Fences(OrdClaim)]
          ELSE /\ view' = [view EXCEPT ![k] = ViewAfterRead(k, l, Newest(l), OrdClaimFail)]
               /\ w' = [w EXCEPT ![k].pc = "spin", ![k].pend = Fences(OrdClaim)]
               /\ UNCHANGED <<mem, runs, ranBy, skipped>>
    /\ UNCHANGED <<scv, ev, evv, d, skipped>>

WWake(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "wake"
    /\ IF w[k].wq = {}
       THEN w' = [w EXCEPT ![k].pc = "write"] /\ UNCHANGED <<view, skipped>>
       ELSE \E c \in w[k].wq : \E i \in Readable(k, Slp(Wk(c))) :
            /\ view' = [view EXCEPT ![k] = ViewAfterRead(k, Slp(Wk(c)), i, OrdWakeSlp)]
            /\ w' = [w EXCEPT ![k].wq = @ \ {c}, ![k].wc = c,
                              ![k].pc = IF mem[Slp(Wk(c))][i].val THEN "wakecmd" ELSE "wake"]
            /\ skipped' = [skipped EXCEPT ![c] = @ \/ ~mem[Slp(Wk(c))][i].val]
    /\ UNCHANGED <<mem, scv, ev, evv, d, runs, ranBy>>

WWakeCmd(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "wakecmd"
    /\ \E i \in Readable(k, Cmd(Wk(w[k].wc))) :
        /\ view' = [view EXCEPT ![k] = ViewAfterRead(k, Cmd(Wk(w[k].wc)), i, OrdWakeCmd)]
        /\ IF mem[Cmd(Wk(w[k].wc))][i].val = w[k].wc THEN Notify(k, Wk(w[k].wc))
                                                     ELSE UNCHANGED <<ev, evv>>
    /\ w' = [w EXCEPT ![k].pc = "wake"]
    /\ UNCHANGED <<mem, scv, d, runs, ranBy, skipped>>

\* going to sleep: announce it, re-check the command, wait for the Event
WPreSleep(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "presleep"
    /\ Store(k, Slp(k), TRUE, OrdSleep)
    /\ w' = [w EXCEPT ![k].pc = "sleepcheck", ![k].pend = Fences(OrdSleep), ![k].slept = @ + 1]
    /\ UNCHANGED <<scv, ev, evv, d, runs, ranBy, skipped>>

WSleepCheck(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "sleepcheck"
    /\ \E i \in Readable(k, Cmd(k)) :
        /\ view' = [view EXCEPT ![k] = ViewAfterRead(k, Cmd(k), i, OrdSleepCheck)]
        /\ w' = [w EXCEPT ![k].pc = IF mem[Cmd(k)][i].val <= 0 THEN "wait" ELSE "wakeup"]
    /\ UNCHANGED <<mem, scv, ev, evv, d, runs, ranBy, skipped>>

WWait(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "wait"
    /\ ev[k]
    /\ ev' = [ev EXCEPT ![k] = FALSE]
    /\ view' = [view EXCEPT ![k] = Join(@, evv[k])]
    /\ w' = [w EXCEPT ![k].pc = "wakeup"]
    /\ UNCHANGED <<mem, scv, evv, d, runs, ranBy, skipped>>

WWakeup(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "wakeup"
    /\ Store(k, Slp(k), FALSE, OrdAwake)
    /\ w' = [w EXCEPT ![k].pc = "spin", ![k].pend = Fences(OrdAwake)]
    /\ UNCHANGED <<scv, ev, evv, d, runs, ranBy, skipped>>

\* run the chunk: (read the region data: no step, see FreshRegion), write the results,
\* report idle
WWrite(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "write"
    /\ Store(k, Res(k), w[k].cmd, "rlx")
    /\ w' = [w EXCEPT ![k].pc = "finish"]
    /\ UNCHANGED <<scv, ev, evv, d, runs, ranBy, skipped>>

WFinish(k) ==
    /\ w[k].pend = 0 /\ w[k].pc = "finish"
    /\ Store(k, Cmd(k), 0, OrdDone)
    /\ w' = [w EXCEPT ![k].pc = "spin", ![k].pend = Fences(OrdDone)]
    /\ UNCHANGED <<scv, ev, evv, d, runs, ranBy, skipped>>

WAny(k) == WFence(k) \/ WSpin(k) \/ WClaim(k) \/ WWake(k) \/ WWakeCmd(k) \/ WPreSleep(k)
           \/ WSleepCheck(k) \/ WWait(k) \/ WWakeup(k) \/ WWrite(k) \/ WFinish(k)

-----------------------------------------------------------------------------
Next == DAny \/ \E k \in Workers : WAny(k)

\* Every thread keeps running, and a load in a spin loop eventually reads the newest
\* message (stores become visible eventually; a stale value cannot be read forever)
Fairness ==
    /\ WF_vars(DAny)
    /\ SF_vars(DIdleLatest)
    /\ SF_vars(DBackupLatest)
    /\ \A k \in Workers : WF_vars(WAny(k)) /\ SF_vars(WSpinLatest(k))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties *)

\* every chunk runs at most once (the worker's claim and the dispatcher's steal exclude
\* each other), and exactly once by the end of the region
ExactlyOnce == \A c \in Chunks : runs[c] <= 1
AllRun == d.pc = "done" => \A c \in Chunks : runs[c] = 1

\* a worker runs its chunk with the region data of this region, not of an earlier one: a
\* monotonic load of the region data cannot return the old message
FreshRegion == \A k \in Workers : w[k].pc = "write" => view[k][Region] = Newest(Region)

\* after wait_idle, the dispatcher sees what the worker wrote while running the chunk
ResultsVisible ==
    d.pc = "results" /\ ranBy[d.k + 1] = d.k => view[0][Res(d.k)] = Newest(Res(d.k))

\* when the region ends, no worker is still running a chunk of it (a worker at "claim"
\* read a command that the dispatcher has stolen since; its compare-and-swap will fail)
NoWorkerLeftBehind ==
    d.pc = "done" => \A k \in Workers :
        w[k].pc \notin {"wake", "wakecmd", "write", "finish"}

\* The wake-up handshake (Dekker): a worker that goes to sleep after its command was stored
\* either sees the command before it waits, or its waker sees that it sleeps and notifies
\* it. Violated when a worker waits without a notification while its command is pending
\* and its waker has passed it by. The region still ends (Terminates): the dispatcher runs
\* the chunk itself. Checked without BACKUP, which would notify the worker later anyway.
WakeupDelivered ==
    \A k \in Workers :
        ~(/\ w[k].pc = "wait" /\ ~ev[k]
          /\ mem[Cmd(k)][Newest(Cmd(k))].val = k + 1
          /\ skipped[k + 1])

\* the region ends: no chunk waits forever (also with lost wake-ups: see WakeupDelivered)
Terminates == <>(d.pc = "done")

=============================================================================
