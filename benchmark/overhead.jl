# Per-loop overhead of a parallel loop with 64 trivial iterations:
# ParkedWorkers vs `Threads.@threads` (and Polyester.jl's `@batch` if it is installed).
#
#     julia --project=benchmark -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#     taskset -c 8-15 julia -t 8   --project=benchmark benchmark/overhead.jl
#     taskset -c 8-15 julia -t 8,0 --project=benchmark benchmark/overhead.jl
#
# Polyester is not a dependency; to include it, run in an environment that has it.
using ParkedWorkers
using BenchmarkTools
using Printf

const HAVE_POLYESTER = Base.find_package("Polyester") !== nothing
HAVE_POLYESTER && @eval using Polyester

const N = parse(Int, get(ENV, "OVERHEAD_N", "64"))

function f_pfor(x)
    @pfor for i in eachindex(x)
        @inbounds x[i] += 1.0
    end
end
f_pforeach(x) = pforeach(i -> (@inbounds x[i] += 1.0), eachindex(x))
function f_pfor_reduce(x)
    s = 0.0
    @pfor reduction = (+, s) for i in eachindex(x)
        @inbounds s += x[i]
    end
    return s
end
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

fs = Any[("@pfor", f_pfor), ("pforeach", f_pforeach), ("@pfor reduction", f_pfor_reduce),
         ("@threads :static", f_static), ("@threads :dynamic", f_dynamic),
         ("serial loop", f_serial)]
HAVE_POLYESTER && insert!(fs, 4, ("Polyester @batch", f_batch))

x = zeros(N)
println("Julia ", VERSION, ", threads ", Threads.nthreads(:default), ",",
        Threads.nthreads(:interactive), ", ", N, " iterations")
for (name, f) in fs
    f(x)
    b = @benchmark $f($x) samples = 20000 evals = 1 seconds = 5
    @printf("%-20s min %8.2f µs  median %8.2f µs  allocs %3d  bytes %6d\n", name,
            minimum(b).time / 1e3, median(b).time / 1e3, b.allocs, b.memory)
end
