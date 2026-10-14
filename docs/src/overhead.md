# Overhead

Per-loop time for a loop with 64 trivial iterations (`x[i] += 1.0`), `benchmark/overhead.jl`,
pinned to 8 cores (`taskset -c 8-15`) of a Ryzen 9 5950X, Julia 1.12.7 and 1.13.1, `OPENBLAS_NUM_THREADS=1`. Polyester.jl 0.7.18 was
loaded from a separate environment for comparison (\* on 1.13 from an earlier run, with
0.7.19); OhMyThreads.jl 0.8.7 and KernelAbstractions.jl 0.10.0 (`foreach_index` on the
`CPU` backend, followed by `synchronize`) come from the benchmark environment. Values are
min / median in µs.

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

## Where the time goes

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
