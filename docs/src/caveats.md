# Trade-offs and caveats

**CPU use while idle.** After each loop, idle workers busy-wait for `spin_time()` (default
100 µs) before they sleep. The time counts from the end of the loop: a worker that finished
its chunk early keeps spinning while the loop waits for the other chunks, so that one late
chunk does not send the other workers to sleep (and make the next loop pay for waking them
up, which makes it late again). A worker goes to sleep right away when another task is ready
to run on its thread (or in the shared queue of the thread pool), but otherwise it keeps
its CPU core busy. With loops back to back, `top` shows all threads at 100%. When Julia
has more threads than the process has CPUs (e.g. `-t N` on N cores with Julia ≥ 1.12,
which adds an interactive thread), spinning workers also give their core to other OS
threads every 5 µs (`sched_yield`). They do not do that otherwise, since on an idle machine
it only adds context switches.
Other processes on the same cores are slowed down, and they slow down the team, although
stealing limits the damage. With one core of eight taken by another busy process, 16-element
loops cost about 0.9 µs with stealing and 90–600 µs without (`-t 8` on 8 cores). This is the
same trade-off as Polyester.jl. `ThreadTeams.set_spin_time!(0)` makes workers
sleep right away, at the cost of a wake-up (about 10 µs) per loop.
`ThreadTeams.shutdown!()` stops them completely. To combine a short (or zero) spin time
with fast loops in one part of a program, wrap that part in
`ThreadTeams.parallel_phase() do ... end` (like TBB's `parallel_phase`): idle workers then
keep spinning until it returns, also across serial parts longer than the spin time.

**Hybrid CPUs.** On CPUs with performance and efficiency cores (recent Intel CPUs, Apple
silicon), spinning cores take power and turbo headroom from the busy ones. LLVM's and GCC's
OpenMP runtimes do not spin by default on such CPUs. Consider `set_spin_time!(0)` together
with `parallel_phase` there. The default spin time is not changed automatically. Do not combine the team with another
spinning team on the same threads, e.g. Polyester-threaded code or multithreaded BLAS
inside the loop body.

**Long-running tasks on worker threads.** Workers are sticky to their threads. If another
task occupies a worker's thread without yielding, the calling task runs that worker's chunk
itself (see "Stealing"), and the loop does not wait for the task. A worker that the OS
deschedules *while* it runs a chunk still delays the loop.

**Automatic differentiation.** Parallel operations on the team can be differentiated with
Enzyme.jl, in forward and reverse mode, through a package extension that loads with EnzymeCore (so it loads with Enzyme).
Enzyme can not differentiate the team itself (atomics, long-lived tasks), so the extension
has rules for the two functions that run a region: they differentiate the loop body chunk
by chunk and run the derivative chunks on the team as well, with the same scheduler. In
reverse mode, the augmented forward pass of all chunks runs in parallel and keeps one tape
per chunk, then the reverse pass of all chunks runs in parallel. This is the scheme Enzyme
uses for `Threads.@threads`. With more than one thread, Enzyme updates shadow memory
atomically, so chunks may read the same data (stencils). Captured scalars (e.g. a
coefficient) get their derivatives too. Reductions (`tmapreduce`, `treduce`, `@tasks` with
`@set reducer`) are supported with a constant operator and a number or tuple of numbers as
the result, but not in batched mode. `tmap` and `tcollect` are not supported (their chunk
results are vectors) and throw; write the result into a preallocated array with `tmap!` or
`tforeach` instead. Other AD tools that work on the code of the loop
cannot differentiate through the team; use a serial version or `Threads.@threads` there.

**Captured variables (boxing).** The loop body becomes a closure (as with `Threads.@threads`).
If the enclosing function assigns a variable more than once (e.g. in both branches of an
`if`) and the loop body uses it, Julia captures it in a `Core.Box`. The loop is then
type-unstable and allocates, and assigning the variable in the body is a data race.
OhMyThreads' check applies to the team schedulers too: such a loop throws a
`BoxedVariableError` (opt out with `@allow_boxed_captures`). Assign such variables once (a
single destructuring assignment works) or move the loop into its own function.


**Bounds facts.** Code inside the closure does not see facts that the caller established
(e.g. array sizes from a `size` check), and the loop body is always called through the
closure, also when the loop runs serially. Some kernels can be slower per element than
in a plain serial loop.

**Other spinning pools.** Polyester.jl (e.g., through FastBroadcast.jl's `Threaded()` in
OrdinaryDiffEq.jl) and the team both pin spinning tasks to the same threads. They block each
other, and the calling task ends up running most chunks itself. In Trixi.jl, threaded RK
stage updates via Polyester together with the team made a time step about 5x slower than
serial stage updates.

**Other.** Precompilation always runs loops serially.
