# ThreadTeams.jl

[![CI](https://github.com/vchuravy/ThreadTeams.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/vchuravy/ThreadTeams.jl/actions/workflows/CI.yml)
[![docs dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://vchuravy.github.io/ThreadTeams.jl/dev)

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
allocates nothing after the first run of that loop, against 2–4 µs and about 3 KB for
`Threads.@threads` or OhMyThreads' default scheduler (see the [overhead](https://vchuravy.github.io/ThreadTeams.jl/dev/overhead/) page).

## Installation

The package is not registered yet:

```julia
pkg> add https://github.com/vchuravy/ThreadTeams.jl
```

It needs Julia 1.10 or newer and depends on OhMyThreads.jl 0.8.7.

## When to use it

- **Use it** for many small to medium parallel loops in a row, where the per-loop overhead
  of `Threads.@threads` (2–4 µs) is a
  noticeable part of the run time. A typical case is the right-hand side of a PDE solver,
  which runs 10–20 loops of a few µs each per call.
- **Use OhMyThreads' own schedulers** (`DynamicScheduler`, the default) for large loops,
  where a few µs per loop do not matter. Use them also when loop bodies are unbalanced
  beyond what `GreedyTeamScheduler` handles, when they yield (I/O, locks, `wait`), when you
  need composable task-based parallelism or `@barrier`. Switching is one keyword argument.
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

The [documentation](https://vchuravy.github.io/ThreadTeams.jl/dev) describes the design
(chunking, stealing, serial fallback, exceptions, dynamic scope, reductions), the measured
overheads and the trade-offs and caveats (CPU use while idle, hybrid CPUs, automatic
differentiation, captured variables).

## Development

The code is formatted with [Runic.jl](https://github.com/fredrikekre/Runic.jl)
(`julia -m Runic --inplace src test ext docs/make.jl benchmark`), which CI checks. A
pre-commit hook that checks the staged files is in `.githooks`; enable it with
`git config core.hooksPath .githooks`.

## License

MIT, see [LICENSE](LICENSE).

## AI Usage
This package was developed with Claude Code Opus 5.5 and Fable 5.1
