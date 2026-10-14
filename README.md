# ThreadTeams.jl

[![CI](https://github.com/vchuravy/ThreadTeams.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/vchuravy/ThreadTeams.jl/actions/workflows/CI.yml)
[![docs dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://vchuravy.github.io/ParkedWorkers.jl/dev)

A team of persistent worker tasks, one per thread, that runs
[OhMyThreads.jl](https://github.com/JuliaFolds2/OhMyThreads.jl)'s parallel functions with
low per-loop overhead. The package re-exports the OhMyThreads.jl API (`tforeach`,
`tmapreduce`, `tmap`, `@tasks`, ...) and adds two schedulers that run on the team,
`TeamScheduler` (`:team`) and `GreedyTeamScheduler` (`:greedyteam`). It is plain Julia on
top of Base tasks.

There is one sticky worker task per thread of the `:default` thread pool. A parallel loop
splits its range into one contiguous chunk per thread, runs chunk 1 on the calling task and
hands the other chunks to the workers. After a loop, idle workers spin for a short while
(100 µs by default) before they go to sleep, so loops that follow each other closely do not
pay for creating, scheduling and waking up tasks. Starting a loop costs about 0.35 µs and
allocates nothing, against 2–4 µs and about 3 KB for `Threads.@threads` or OhMyThreads'
default scheduler (see [Overhead](#overhead)).

The team started as the threading backend of a Trixi.jl prototype that removes Polyester.jl.

## Installation

The package is not registered yet:

```julia
pkg> add https://github.com/vchuravy/ThreadTeams.jl
```

It needs Julia 1.10 or newer and depends on OhMyThreads.jl 0.8.7.

## When to use it

- **Use it** for many small to medium parallel loops in a row, where the per-loop overhead
  of `Threads.@threads` (2–4 µs, or about 100 µs with oversubscription, see below) is a
  noticeable part of the run time. A typical case is the right-hand side of a PDE solver,
  which runs 10–20 loops of a few µs each per call.
- **Use OhMyThreads' own schedulers** (`DynamicScheduler`, the default) for large loops,
  where a few µs per loop do not matter. Use them also when loop bodies are unbalanced
  beyond what `GreedyTeamScheduler` handles, when they yield (I/O, locks, `wait`), when you
  need composable task-based parallelism or `@barrier`, or when the code must be
  differentiable with Enzyme (see below). Switching is one keyword argument.
- **Compared to Polyester.jl's `@batch`**: the same design (contiguous chunks, persistent
  spinning workers, nested loops run serially) at a slightly higher cost per loop (about
  0.1 µs). No LLVM-level threading runtime, no conversion of arrays to `PtrArray`s,
  exceptions are propagated, and the loop body is an ordinary closure.

## Usage

```julia
using ThreadTeams   # re-exports OhMyThreads.jl; start Julia with threads, e.g. `julia -t auto`

x = rand(10_000)
y = similar(x)

# OhMyThreads' functions and macros, with a team scheduler
const team = TeamScheduler()
tforeach(eachindex(x); scheduler = team) do i
    y[i] = sqrt(x[i])
end
tmapreduce(abs2, +, x; scheduler = team)                         # parallel mapreduce
tmap(sqrt, x; scheduler = GreedyTeamScheduler(chunksize = 256))  # load balancing
@tasks for i in eachindex(x)
    @set scheduler = team
    y[i] = 2x[i]
end
s, m = @tasks for i in eachindex(x)                                 # reductions
    @set scheduler = team
    @set reducer = (a, b) -> (a[1] + b[1], max(a[2], b[2]))
    (x[i], x[i])
end
```

### API

| | |
|---|---|
| `TeamScheduler()`, `scheduler = :team` | OhMyThreads scheduler: one contiguous chunk per thread, run by the team |
| `GreedyTeamScheduler(; nchunks, chunksize)`, `scheduler = :greedyteam` | more chunks than threads, taken by the caller and the workers as they become free |
| `ThreadTeams.nworkers()` | maximum number of chunks, `Threads.nthreads(:default)` |
| `ThreadTeams.nchunks(itr, [scheduler])` | number of chunks a loop over `itr` would use now (`1` = serial) |
| `ThreadTeams.set_spin_time!(seconds)` / `spin_time()` | how long idle workers spin after a loop before they sleep (default 100 µs) |
| `ThreadTeams.parallel_phase(f)` | run `f()` with idle workers spinning until it returns (no sleep between loops) |
| `ThreadTeams.shutdown!()` | stop the workers; the next loop starts them again |

Everything else (`tforeach`, `tmapreduce`, `treduce`, `tmap`, `tmap!`, `tcollect`, `@tasks`,
`@set`, `@local`, `@task_index`, `@allow_boxed_captures`, `chunks`, `index_chunks`, the other
schedulers, ...) is OhMyThreads.jl, re-exported. The inputs of the team schedulers are
`AbstractArray`s (e.g. `eachindex(x)`, `1:n`, `CartesianIndices`, a `StepRange`, or an array
to loop over by value) and `chunks`/`index_chunks` objects.

### Semantics

- **Chunking.** With `TeamScheduler`, `itr` is split into `min(nthreads(:default), length(itr))`
  contiguous chunks of nearly equal length (with ChunkSplitters.jl, as OhMyThreads does).
  Chunk 1 runs on the calling task, chunk `c` on a worker. `GreedyTeamScheduler` splits
  into `nchunks` chunks (default `4 * nworkers()`) or chunks of `chunksize` elements; the
  caller and the workers take them from a shared counter until none are left.
- **Stealing.** When the calling task has finished chunk 1, it runs every chunk that its
  worker has not picked up yet (the worker is asleep, or the OS has not scheduled its
  thread). So a busy core or a sleeping worker does not stall the loop. Chunks that run at
  the same time always run on different threads, so `threadid()`-indexed scratch buffers
  are safe as long as the body does not yield. Do not assume that chunk `c` always runs on
  the same thread. Prefer buffers indexed by the task index (`@task_index`,
  `OhMyThreads.WithTaskIndex`), which is the chunk index.
- **Serial fallback.** The loop runs serially when it would get a single chunk: one thread,
  zero or one element, during precompilation, and inside another parallel loop on the team
  (nested loops). OhMyThreads' own schedulers nested in a team loop are not affected.
- **Thread safety.** Only one parallel region runs on the team at a time. A loop started
  from another task while the team is busy does **not** wait for the team (no lock, no
  deadlock). It runs its chunks on `Threads.@spawn`ed tasks instead (chunk 1 on the calling
  task), with the same exception semantics, like `Threads.@threads :dynamic` would. Loops
  may be started from any thread, including the interactive thread pool. The worker on the
  caller's own thread is then left out, since the caller occupies that thread.
- **Dynamic scope and world age.** Chunks run in the dynamic scope of the caller
  (`ScopedValue`s and the logger set with `with_logger`) and in its world age, as the tasks
  of `Threads.@spawn` would. `current_task()` and `task_local_storage()` are those of the
  worker (or of the calling task). Task-local values (`@local`, `TaskLocalValue`) live in
  the worker tasks, which persist: they are initialized once per worker and reused across
  loops.
- **Reductions.** Each chunk is reduced with `mapreduce`, and the chunk results are combined
  in chunk order, also with the greedy scheduler. So `op` must be associative, but not
  commutative. The result is deterministic for a given number of chunks, but floating-point
  results can differ in the last digits from a serial loop. `init`, if given, is used once
  per chunk, so it must be a neutral element of `op`.
- **Exceptions.** If chunks throw, the exception that a serial loop would have thrown (that of
  the first failing chunk) is rethrown after *all* running chunks have finished. The workers
  stay usable. Chunks that already started run to completion. If chunk 1 throws, chunks that
  no worker has started yet are skipped. Everything a serial loop would have done before the
  error is always done. A worker's backtrace is kept on the exception
  stack (`current_exceptions()`, shown as "caused by").
- **Lazy start, shutdown.** The workers start with the first parallel loop.
  `ThreadTeams.shutdown!()` stops them, and the next loop starts them again.
- **Waking up.** Sleeping workers are woken in a binary tree: whoever takes chunk `c` wakes
  the workers of chunks `2c` and `2c + 1`. The caller wakes at most two workers itself, so
  waking all workers takes O(log n) steps on its critical path instead of n.
- **No allocations.** Starting a loop allocates nothing. The chunk closure is stored in a
  typed slot that the team reuses, and the reduction partials in a reused buffer. Tested
  with `@allocated` on Julia 1.10 to nightly. On Julia 1.10 and 1.11, reductions allocate
  16 bytes per loop (also when they run serially).
- **Barriers.** `@barrier` (`OhMyThreads.Experimental`) needs a fixed number of tasks that
  run at the same time. The team does not promise that (see "Stealing"), so the team
  schedulers reject `ntasks`, which `@barrier` requires. Use `DynamicScheduler` for such loops.

## Overhead

Per-loop time for a loop with 64 trivial iterations (`x[i] += 1.0`), `benchmark/overhead.jl`,
pinned to 8 cores (`taskset -c 8-15`) of a Ryzen 9 5950X, Julia 1.12.7 and 1.13.1, `OPENBLAS_NUM_THREADS=1`. Polyester.jl 0.7.18 was
loaded from a separate environment for comparison (\* on 1.13 from an earlier run, with
0.7.19); OhMyThreads.jl 0.8.7 and KernelAbstractions.jl 0.10.0 (`foreach_index` on the
`CPU` backend, followed by `synchronize`) and FixedSizeArrays.jl 1.4.2 come from the
benchmark environment. Values are min / median in µs.

**These numbers come from one shared machine, with other jobs running on the same cores.
Minima are more reliable than medians.**

| mechanism | 1.12 `-t 8` (8+1 interactive) | 1.12 `-t 8,0` | 1.13 `-t 8` | 1.13 `-t 8,0` | allocations per loop |
|---|---|---|---|---|---|
| `tforeach`, `scheduler = TeamScheduler()` | 0.33 / 0.38 | 0.36 / 0.45 | 0.35 / 0.42 | 0.37 / 0.43 | 0 |
| `tmapreduce`, `scheduler = TeamScheduler()` | 0.36 / 0.46 | 0.35 / 0.42 | 0.37 / 0.45 | 0.35 / 0.45 | 0 |
| `@tasks` with `@set scheduler = TeamScheduler()` | 0.33 / 0.40 | 0.36 / 0.44 | 0.34 / 0.40 | 0.37 / 0.44 | 0 |
| `tforeach`, `scheduler = GreedyTeamScheduler()` (32 chunks) | 0.95 / 1.48 | 0.88 / 1.47 | 0.74 / 0.93 | 0.74 / 0.94 | 0 |
| Polyester `@batch` (v0.7.18) | 0.24 / 0.37 | 0.24 / 0.40 | 0.23 / 0.35* | 0.24 / 0.37* | 0 |
| `Threads.@threads :static` | 10.72 / **113** | 2.13 / 2.60 | 11.21 / **113** | 1.70 / 2.65 | 42 (2.9 KB) |
| `Threads.@threads :dynamic` | 2.36 / 3.87 | 2.40 / 3.80 | 2.18 / 3.77 | 2.27 / 3.54 | 42 (2.9 KB) |
| OhMyThreads `tforeach` (v0.8.7, `DynamicScheduler`) | 4.30 / 5.23 | 4.22 / 5.15 | 3.43 / 4.50 | 3.44 / 4.43 | 66–68 (3.6 KB) |
| OhMyThreads `tforeach`, `scheduler = :static` | 16.88 / **117** | 4.78 / 5.19 | 12.95 / **116** | 4.33 / 4.72 | 67–69 (3.6 KB) |
| OhMyThreads `tmapreduce(+)` | 3.99 / 4.95 | 4.03 / 4.90 | 3.32 / 4.30 | 3.39 / 4.36 | 64–66 (3.6 KB) |
| KernelAbstractions `foreach_index` (v0.10.0) | 3.08 / 3.91 | 3.00 / 3.99 | 3.30 / 5.91 | 3.16 / 3.83 | 5 (96 B) |
| serial loop | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 | 0 |
| `tforeach`, `TeamScheduler()`, `FixedSizeVector` | 0.36 / 0.42 | 0.35 / 0.42 | 0.36 / 0.43 | 0.37 / 0.44 | 0 |
| `tmapreduce`, `TeamScheduler()`, `FixedSizeVector` | 0.36 / 0.45 | 0.33 / 0.44 | 0.39 / 0.47 | 0.38 / 0.46 | 0 |
| Polyester `@batch`, `FixedSizeVector` | 0.23 / 0.38 | 0.26 / 0.39 |  |  | 0 |
| `Threads.@threads :dynamic`, `FixedSizeVector` | 2.56 / 3.98 | 2.38 / 3.74 | 2.31 / 3.77 | 2.31 / 3.64 | 42 (3.0 KB) |
| OhMyThreads `tforeach`, `FixedSizeVector` | 4.18 / 5.14 | 4.27 / 5.14 | 3.33 / 4.51 | 3.32 / 4.48 | 66–68 (3.8 KB) |
| serial loop, `FixedSizeVector` | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 | 0 |

- The `FixedSizeVector` rows (FixedSizeArrays.jl) check whether the array type matters, since
  Polyester converts arrays to `PtrArray`s: it does not at this size. The loop body runs on a
  view of the input, and the per-loop cost is the hand-off, not array metadata.
- Pass the scheduler as an object. A symbol (`scheduler = :team`, `@set scheduler = :team`)
  is resolved by OhMyThreads with a dynamic dispatch, which costs about 0.3 µs and 64 bytes
  per loop.
- `GreedyTeamScheduler()` splits the 64 iterations into 32 chunks (4 per thread) that are
  handed out one by one, hence the higher cost; with `chunksize` or `nchunks` set to match
  the loop, it costs about as much as the static schedule.
- `-t 8` is the default since Julia 1.12: 8 default threads **plus one interactive thread**,
  so 9 threads share 8 cores. `Threads.@threads :static` then pays about the scheduler's
  sleep threshold (100 µs) per loop. Its sticky tasks must wait until the OS deschedules a
  thread that is spinning in the scheduler. `:dynamic` is not affected, and neither are the
  team and Polyester. The worker tasks already run, and the caller (on the interactive
  thread) runs chunk 1 while one default thread stays unused.
- OhMyThreads' `:static` scheduler also uses sticky tasks and has the same problem with `-t 8`.
- KernelAbstractions 0.10 runs `CPU` kernels through POCL (`CPU()` is a `POCLBackend()`), so
  `foreach_index` compiles the body as a kernel. A launch costs about as much as a `@threads`
  loop, but it allocates much less.
- With `-t 8,0` (no interactive thread) `@threads :static` costs about 2–3 µs.
- Waking up workers that have gone to sleep costs about 10–15 µs, for the team and for
  `@threads` alike. Raise the spin time when loops are separated by longer serial phases.

### Where the time goes

Hardware counters per loop on the calling thread (`benchmark/counters.jl`, LinuxPerf.jl,
same loop and machine as above, Julia 1.12, `-t 8`):

| | cycles | instructions | L1d misses | last-level cache misses |
|---|---|---|---|---|
| `tforeach`, `TeamScheduler()` | 1650–2000 | 1700–1750 | 25–32 | 15–17 |
| `tmapreduce`, `TeamScheduler()` | 1900–2050 | 1800–1840 | 31–35 | 16–18 |
| Polyester `@batch` | 1560–1760 | 500 | 35–40 | 16–19 |
| serial loop | 16 | 70 | 0 | 0 |

(Ranges over four runs; the spread comes from other jobs on the machine.)

The cache misses are the hand-off: every worker's command field is a cache line that moves
between the calling thread's core and the worker's core. A `perf` profile of the calling
thread puts more than half of its time into that hand-off (storing the commands, checking
afterwards which chunks the workers have not taken, and waiting for the last worker). The
two `IdDict` lookups (chunk function slot, partials buffer) cost about 1%; OhMyThreads'
entry (`tmapreduce` keyword handling, the scheduler object) and `mapreduce` over the first
chunk account for the remaining instructions, which is where the team executes about three
times as many instructions as Polyester at a similar cycle count.

Two details keep the hand-off cheap: the command stores are release stores followed by one
fence rather than sequentially consistent stores (an `xchg` per store would wait for each
cache line in turn, where plain stores overlap in the store buffer), and the check for
untaken chunks loads before it compare-and-swaps (a failed compare-and-swap would still take
the line away from the worker, which then has to take it back). Together they removed about
a quarter of the calling thread's cycles.

## Trade-offs and caveats

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

**Automatic differentiation.** Enzyme.jl (and other AD tools that work on the code of the
loop) cannot differentiate through the team itself. The hand-off goes through atomics,
`invokelatest` and long-lived tasks that the AD tool does not see. Enzyme rules that
differentiate the loop chunk by chunk and run the derivative chunks on the team are on the
branch `vc/enzyme-rules` (written for the previous loop API, not merged yet). Until then,
differentiate a serial version or `Threads.@threads`, which Enzyme supports; a library
using the team should offer a way to switch to `Threads.@threads` or to serial loops.

**Captured variables (boxing).** The loop body becomes a closure (as with `Threads.@threads`).
If the enclosing function assigns a variable more than once (e.g. in both branches of an
`if`) and the loop body uses it, Julia captures it in a `Core.Box`. The loop is then
type-unstable and allocates, and assigning the variable in the body is a data race.
OhMyThreads' check applies to the team schedulers too: such a loop throws a
`BoxedVariableError` (opt out with `@allow_boxed_captures`). Assign such variables once (a
single destructuring assignment works) or move the loop into its own function. Polyester's
`@batch` passes the free variables as arguments and does not have this problem. On Julia
1.10, a closure also stores a captured *type* (e.g., `T = eltype(x)` or
`MeshT = typeof(mesh)`) as a `DataType` field, so every call that passes it inside the loop
is a dynamic dispatch. Use `eltype(x)` / `typeof(mesh)` in the loop body instead.
Julia 1.11 and newer keep the type (`Type{T}`).

**Bounds facts.** Code inside the closure does not see facts that the caller established
(e.g. array sizes from a `size` check), and the loop body is always called through the
closure, also when the loop runs serially. Some kernels can be slower per element than
in a plain serial loop.

**Other spinning pools.** Polyester.jl (e.g., through FastBroadcast.jl's `Threaded()` in
OrdinaryDiffEq.jl) and the team both pin spinning tasks to the same threads. They block each
other, and the calling task ends up running most chunks itself. In Trixi.jl, threaded RK
stage updates via Polyester together with the team made a time step about 5x slower than
serial stage updates.

**Other.** The team keeps a reference to the last chunk closure of each type (and the arrays
it captures) until `shutdown!()`. Precompilation always runs loops serially.

## License

MIT, see [LICENSE](LICENSE).
