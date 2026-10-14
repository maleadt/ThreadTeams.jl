# Per-loop overhead of a parallel loop with 64 trivial iterations: the pool (OhMyThreads'
# functions with the team schedulers) vs `Threads.@threads`, OhMyThreads' own schedulers,
# KernelAbstractions.jl's `foreach_index` on the `CPU` backend (and Polyester.jl's `@batch`
# if it is installed), over a `Vector` and over a `FixedSizeVector`.
#
#     julia --project=benchmark -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'
#     taskset -c 8-15 julia -t 8   --project=benchmark benchmark/overhead.jl
#     taskset -c 8-15 julia -t 8,0 --project=benchmark benchmark/overhead.jl
#
# Each Julia version keeps its own manifest, `benchmark/Manifest-vX.Y.toml`: Pkg writes to that
# file only if it exists, so `touch` it before the first `resolve` with a new version.
#
# Polyester is not a dependency; to include it, run in an environment that has it.
using ThreadTeams
using BenchmarkTools
using Printf
using OhMyThreads: OhMyThreads   # ThreadTeams re-exports its API
using KernelAbstractions: KernelAbstractions, CPU
using FixedSizeArrays: FixedSizeVector

const HAVE_POLYESTER = Base.find_package("Polyester") !== nothing
HAVE_POLYESTER && @eval using Polyester

const N = parse(Int, get(ENV, "OVERHEAD_N", "64"))

const TEAM = TeamScheduler()
f_tforeach_team(x) = tforeach(i -> (@inbounds x[i] += 1.0), eachindex(x); scheduler = TEAM)
f_tmapreduce_team(x) = tmapreduce(i -> (@inbounds x[i]), +, eachindex(x); scheduler = TEAM)
function f_tasks_team(x)
    @tasks for i in eachindex(x)
        @set scheduler = TEAM   # `:team` would cost a dynamic dispatch
        @inbounds x[i] += 1.0
    end
end
f_greedy(x) = tforeach(i -> (@inbounds x[i] += 1.0), eachindex(x); scheduler = GreedyTeamScheduler())
function f_static(x)
    Threads.@threads :static for i in eachindex(x)
        @inbounds x[i] += 1.0
    end
end
function f_dynamic(x)
    Threads.@threads :dynamic for i in eachindex(x)
        @inbounds x[i] += 1.0
    end
end
f_tforeach(x) = OhMyThreads.tforeach(i -> (@inbounds x[i] += 1.0), eachindex(x))
f_tforeach_static(x) =
    OhMyThreads.tforeach(i -> (@inbounds x[i] += 1.0), eachindex(x); scheduler = :static)
f_tmapreduce(x) = OhMyThreads.tmapreduce(i -> (@inbounds x[i]), +, eachindex(x))
function f_foreach_index(x)
    KernelAbstractions.foreach_index(i -> (@inbounds x[i] += 1.0), x)
    KernelAbstractions.synchronize(CPU())
end
function f_serial(x)
    for i in eachindex(x)
        @inbounds x[i] += 1.0
    end
end
if HAVE_POLYESTER
    @eval function f_batch(x)
        Polyester.@batch for i in eachindex(x)
            @inbounds x[i] += 1.0
        end
    end
end

fs = Any[("tforeach :team", f_tforeach_team), ("tmapreduce :team", f_tmapreduce_team),
         ("@tasks :team", f_tasks_team), ("tforeach :greedyteam", f_greedy),
         ("@threads :static", f_static), ("@threads :dynamic", f_dynamic),
         ("OMT tforeach", f_tforeach), ("OMT tforeach :static", f_tforeach_static),
         ("OMT tmapreduce", f_tmapreduce), ("KA foreach_index", f_foreach_index),
         ("serial loop", f_serial)]
HAVE_POLYESTER && insert!(fs, 5, ("Polyester @batch", f_batch))

# The same loops over a `FixedSizeVector` (FixedSizeArrays.jl): its length is a compile-time
# constant where the compiler can see it, which is closer to the `PtrArray` that Polyester
# converts arrays to than a `Vector` is
fs_fixed = Any[("tforeach :team, FSV", f_tforeach_team), ("tmapreduce :team, FSV", f_tmapreduce_team),
               ("@threads :dynamic, FSV", f_dynamic), ("OMT tforeach, FSV", f_tforeach),
               ("serial loop, FSV", f_serial)]
HAVE_POLYESTER && insert!(fs_fixed, 3, ("Polyester @batch, FSV", f_batch))

x = zeros(N)
xf = FixedSizeVector{Float64}(undef, N)
fill!(xf, 0.0)
println("Julia ", VERSION, ", threads ", Threads.nthreads(:default), ",",
        Threads.nthreads(:interactive), ", ", N, " iterations")
for (fns, arr) in ((fs, x), (fs_fixed, xf)), (name, f) in fns
    f(arr)
    b = @benchmark $f($arr) samples = 20000 evals = 1 seconds = 5
    @printf("%-26s min %8.2f µs  median %8.2f µs  allocs %3d  bytes %6d\n", name,
            minimum(b).time / 1e3, median(b).time / 1e3, b.allocs, b.memory)
end
