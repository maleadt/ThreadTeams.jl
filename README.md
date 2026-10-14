# ParkedWorkers.jl

[![CI](https://github.com/vchuravy/ParkedWorkers.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/vchuravy/ParkedWorkers.jl/actions/workflows/CI.yml)

A small pool of persistent ("parked") worker tasks for low-overhead parallel `for` loops,
built only on Base threads. It has no dependencies.

There is one sticky worker task per thread of the `:default` thread pool. A parallel loop
splits its range into one contiguous chunk per thread, runs chunk 1 on the calling task and
hands the other chunks to the workers. After a chunk, a worker spins for a short while
(100 µs by default) before it goes to sleep, so loops that follow each other closely do not
pay for creating, scheduling and waking up tasks. Starting a loop costs about 0.3–0.5 µs
and allocates nothing, against 2–4 µs and about 3 KB for `Threads.@threads`.

The pool started as the threading backend of a Trixi.jl prototype that removes Polyester.jl.

## When to use it

- **Use it** for many small to medium parallel loops in a row, where the per-loop overhead
  of `Threads.@threads` (2–4 µs, or about 100 µs with oversubscription, see below) is a
  noticeable part of the run time. A typical case is the right-hand side of a PDE solver,
  which runs 10–20 loops of a few µs each per call.
- **Use `Threads.@threads` / OhMyThreads.jl** for large loops, where a few µs per loop do
  not matter. Use them also when loop bodies are unbalanced or yield (I/O, locks, `wait`),
  when you need composable task-based parallelism, or when the code must be differentiable
  with Enzyme (see below).
- **Compared to Polyester.jl's `@batch`**: the same design (contiguous chunks, persistent
  spinning workers, nested loops run serially) at a slightly higher cost per loop (about
  0.1 µs). It is plain Julia on top of Base tasks: no LLVM-level threading runtime, no
  conversion of arrays to `PtrArray`s, exceptions are propagated, and the loop body is an
  ordinary closure.

## Usage

```julia
using ParkedWorkers   # start Julia with threads, e.g. `julia -t auto`

x = rand(10_000)
y = similar(x)

# a parallel for loop
@pfor for i in eachindex(x, y)
    y[i] = sqrt(x[i])
end

# reductions, with Polyester-compatible syntax
s = 0.0
m = -Inf
@pfor reduction = ((+, s), (max, m)) for i in eachindex(x)
    s += x[i]
    m = max(m, x[i])
end

# function forms
pforeach(i -> (y[i] = 2x[i]), eachindex(x))
pmapreduce(abs2, +, x)        # parallel mapreduce
preduce(max, x)               # parallel reduce
```

### API

| | |
|---|---|
| `@pfor for x in itr ... end` | parallel `for` loop |
| `@pfor reduction = (op, var) for ...` | with reductions; also `((op1, var1), (op2, var2))` and `(op, var, neutral)` |
| `pforeach(f, itr)` | `f(x)` for every element of `itr`, in parallel |
| `pmapreduce(f, op, itr; [init])` | parallel `mapreduce` |
| `preduce(op, itr; [init])` | parallel `reduce` |
| `ParkedWorkers.nworkers()` | maximum number of chunks, `Threads.nthreads(:default)` |
| `ParkedWorkers.nchunks(itr)` | number of chunks a loop over `itr` would use now (`1` = serial) |
| `ParkedWorkers.set_spin_time!(seconds)` / `spin_time()` | how long idle workers spin before they sleep (default 100 µs) |
| `ParkedWorkers.shutdown!()` | stop the workers; the next loop starts them again |
| `ParkedWorkers.neutral(op, x)` | neutral elements for `@pfor` reductions; add methods for custom operators |

`itr` can be an `AbstractUnitRange` (e.g. `eachindex(x)`, `0:10`), any `AbstractArray`
(e.g. `CartesianIndices`, a `StepRange`, or an array to loop over by value), or a collection
with `firstindex`, `lastindex` and `getindex` such as a `Tuple`.

### Semantics

- **Chunking.** `itr` is split into `min(nthreads(:default), length(itr))` contiguous chunks
  of nearly equal length. Chunk 1 runs on the calling task, chunk `c` on a worker.
- **Stealing.** When the calling task has finished chunk 1, it runs every chunk that its
  worker has not picked up yet (the worker is asleep, or the OS has not scheduled its
  thread). So a busy core or a sleeping worker does not stall the loop. Chunks that run at
  the same time always run on different threads, so `threadid()`-indexed scratch buffers
  are safe as long as the body does not yield. Do not assume that chunk `c` always runs on
  the same thread. Prefer buffers indexed by chunk where you can.
- **Serial fallback.** The loop runs as a plain serial loop when it would get a single chunk:
  one thread, zero or one element, during precompilation, and when the pool is busy. The pool
  is busy inside another parallel loop (nested loops) and while another task runs a parallel
  loop.
- **Thread safety.** Only one parallel region runs at a time. A loop started from another
  task while the pool is busy does **not** wait for the pool (no lock, no deadlock). It runs
  serially on its own task. Concurrent calls are always correct, but only one of them runs in
  parallel at a time. Loops may be started from any thread, including the interactive thread
  pool. The worker on the caller's own thread is then left out, since the caller occupies
  that thread.
- **Reductions.** Each chunk starts from the neutral element of `op`, and the chunk results
  are combined with the initial value in chunk order. So `op` must be associative. The result
  is deterministic for a given number of threads, but floating-point results can differ in
  the last digits from a serial loop. `+ * max min & | xor` are built in. For other
  operators, add a method to `ParkedWorkers.neutral` or write `reduction = (op, var, neutral)`.
- **Exceptions.** If chunks throw, the exception that a serial loop would have thrown (that of
  the first failing chunk) is rethrown after *all* running chunks have finished. The workers
  stay usable. Chunks that already started run to completion. If chunk 1 throws, chunks that
  no worker has started yet are skipped. Everything a serial loop would have done before the
  error is always done. A worker's backtrace is kept on the exception
  stack (`current_exceptions()`, shown as "caused by").
- **Lazy start, shutdown.** The workers start with the first parallel loop.
  `ParkedWorkers.shutdown!()` stops them, and the next loop starts them again.
- **No allocations.** Starting a loop allocates nothing. The chunk closure is stored in a
  typed slot that the pool reuses, and the reduction partials in a reused buffer. Tested
  with `@allocated` on Julia 1.11 to nightly. On Julia 1.10, `@pfor` and `pforeach` also
  allocate nothing, but `@pfor reduction = ...` allocates 16 bytes per loop.
- `break` and `return` in the loop body only end the current chunk. Do not use them.
  `continue` works.

## Overhead

Per-loop time for a loop with 64 trivial iterations (`x[i] += 1.0`), `benchmark/overhead.jl`,
pinned to 8 cores (`taskset -c 8-15`) of a Ryzen 9 5950X, Julia 1.12.7 and 1.13.1, `OPENBLAS_NUM_THREADS=1`. Polyester.jl 0.7.19 was
loaded from a separate environment for comparison. Values are min / median in µs.

**These numbers come from one shared machine, with other jobs running on the same cores.
Minima are more reliable than medians.**

| mechanism | 1.12 `-t 8` (8+1 interactive) | 1.12 `-t 8,0` | 1.13 `-t 8` | 1.13 `-t 8,0` | allocations per loop |
|---|---|---|---|---|---|
| `@pfor` | 0.17 / 0.54 | 0.28 / 0.49 | 0.27 / 0.49 | 0.18 / 0.50 | 0 |
| `pforeach` | 0.15 / 0.54 | 0.16 / 0.50 | 0.26 / 0.51 | 0.16 / 0.55 | 0 |
| `@pfor reduction = (+, s)` | 0.21 / 0.57 | 0.21 / 0.54 | 0.22 / 0.50 | 0.21 / 0.57 | 0 |
| Polyester `@batch` (v0.7.19) | 0.26 / 0.37 | 0.27 / 0.42 | 0.23 / 0.36 | 0.25 / 0.38 | 0 |
| `Threads.@threads :static` | 11.2 / **113** | 1.74 / 2.60 | 11.5 / **114** | 1.73 / 2.77 | 42 (2.9 KB) |
| `Threads.@threads :dynamic` | 2.59 / 3.90 | 2.36 / 3.83 | 2.35 / 3.66 | 2.33 / 3.75 | 42 (2.9 KB) |
| serial loop | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 | 0 |

Minima below Polyester's come from samples in which the calling task ran all chunks itself
(see "Stealing"), which is cheap for 64 trivial iterations.

- `-t 8` is the default since Julia 1.12: 8 default threads **plus one interactive thread**,
  so 9 threads share 8 cores. `Threads.@threads :static` then pays about the scheduler's
  sleep threshold (100 µs) per loop. Its sticky tasks must wait until the OS deschedules a
  thread that is spinning in the scheduler. `:dynamic` is not affected, and neither are the
  pool and Polyester. The worker tasks already run, and the caller (on the interactive
  thread) runs chunk 1 while one default thread stays unused.
- With `-t 8,0` (no interactive thread) `@threads :static` costs about 2–3 µs.
- Waking up workers that have gone to sleep costs about 10–15 µs, for the pool and for
  `@threads` alike. Raise the spin time when loops are separated by longer serial phases.

## Trade-offs and caveats

**CPU use while idle.** After each loop, idle workers busy-wait for `spin_time()` (default
100 µs) before they sleep. They yield to other tasks on their thread now and then, but they
keep their CPU core busy. With loops back to back, `top` shows all threads at 100%.
Other processes on the same cores are slowed down, and they slow down the pool, although
stealing limits the damage. With one core of eight taken by another busy process, 16-element
loops cost about 0.9 µs with stealing and 90–600 µs without (`-t 8` on 8 cores). This is the
same trade-off as Polyester.jl. `ParkedWorkers.set_spin_time!(0)` makes workers
sleep right away, at the cost of a wake-up (about 10 µs) per loop.
`ParkedWorkers.shutdown!()` stops them completely. Do not combine the pool with another
spinning pool on the same threads, e.g. Polyester-threaded code or multithreaded BLAS
inside the loop body.

**Long-running tasks on worker threads.** Workers are sticky to their threads. If another
task occupies a worker's thread without yielding, the calling task runs that worker's chunk
itself (see "Stealing"), and the loop does not wait for the task. A worker that the OS
deschedules *while* it runs a chunk still delays the loop.

**Automatic differentiation.** Enzyme.jl (and other AD tools that work on the code of the
loop) cannot differentiate through the pool. The hand-off goes through atomics,
`invokelatest` and long-lived tasks that the AD tool does not see. Differentiate a serial
version, or `Threads.@threads`, which Enzyme supports. A library using the pool should
offer a way to switch to `Threads.@threads` or to serial loops.

**Captured variables (boxing).** The loop body becomes a closure (as with `Threads.@threads`).
If the enclosing function assigns a variable more than once (e.g. in both branches of an
`if`) and the loop body uses it, Julia captures it in a `Core.Box`. The loop is then
type-unstable and allocates. Assign such variables once (a single destructuring assignment
works) or move the loop into its own function, and check hot loops with `@code_warntype`
or `@allocated`. Polyester's `@batch` passes the free variables as arguments and does not
have this problem. On Julia 1.10, a closure also stores a captured *type* (e.g., `T = eltype(x)` or
`MeshT = typeof(mesh)`) as a `DataType` field, so every call that passes it inside the loop
is a dynamic dispatch. Use `eltype(x)` / `typeof(mesh)` in the loop body instead.
Julia 1.11 and newer keep the type (`Type{T}`).

**Bounds facts.** Code inside the closure does not see facts that the caller established
(e.g. array sizes from a `size` check). Some kernels can be slower per element in parallel
chunks than in the serial loop that runs for a single chunk.

**Other spinning pools.** Polyester.jl (e.g., through FastBroadcast.jl's `Threaded()` in
OrdinaryDiffEq.jl) and the pool both pin spinning tasks to the same threads. They block each
other, and the calling task ends up running most chunks itself. In Trixi.jl, threaded RK
stage updates via Polyester together with the pool made a time step about 5x slower than
serial stage updates.

**Other.** The pool keeps a reference to the last chunk closure of each type (and the arrays
it captures) until `shutdown!()`. Precompilation always runs loops serially.

## License

MIT, see [LICENSE](LICENSE).
