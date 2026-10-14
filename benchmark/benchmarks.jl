# Benchmark suite for AirspeedVelocity.jl (`benchpkg`, see .github/workflows/Benchmark.yml):
# the per-loop cost of a loop with 64 trivial iterations on the team, against
# `Threads.@threads` and OhMyThreads' default scheduler. The absolute numbers depend
# strongly on the machine and on how many cores the Julia threads get (see the overhead
# page of the documentation); the suite is for comparing revisions on the same machine.
# `benchmark/overhead/overhead.jl` is the script behind the numbers in the documentation.
using BenchmarkTools
using ThreadTeams
using Enzyme

const SUITE = BenchmarkGroup()

const N = 64
const TEAM = TeamScheduler()

f_tforeach_team(x) = tforeach(i -> (@inbounds x[i] += 1.0), eachindex(x); scheduler = TEAM)
f_tmapreduce_team(x) = tmapreduce(i -> (@inbounds x[i]), +, eachindex(x); scheduler = TEAM)
function f_tasks_team(x)
    @tasks for i in eachindex(x)
        @set scheduler = TEAM
        @inbounds x[i] += 1.0
    end
    return
end
f_greedy(x) = tforeach(i -> (@inbounds x[i] += 1.0), eachindex(x); scheduler = GreedyTeamScheduler())
function f_threads_dynamic(x)
    Threads.@threads :dynamic for i in eachindex(x)
        @inbounds x[i] += 1.0
    end
    return
end
f_omt_dynamic(x) = tforeach(i -> (@inbounds x[i] += 1.0), eachindex(x))
function f_serial(x)
    for i in eachindex(x)
        @inbounds x[i] += 1.0
    end
    return
end

# One sample per loop (`evals = 1`): the cost of one loop is what matters, and the workers'
# spin time (100 µs) covers the gap between samples
for (name, f) in (
        ("tforeach team", f_tforeach_team), ("tmapreduce team", f_tmapreduce_team),
        ("@tasks team", f_tasks_team), ("tforeach greedy team", f_greedy),
        ("Threads.@threads :dynamic", f_threads_dynamic),
        ("OhMyThreads tforeach", f_omt_dynamic), ("serial loop", f_serial),
    )
    SUITE["overhead"][name] = @benchmarkable $f(x) setup = (x = zeros(N)) samples = 10_000 evals = 1 seconds = 3
end

# Loops with more work per iteration, where the hand-off is a smaller part
function f_work_team(x)
    tforeach(eachindex(x); scheduler = TEAM) do i
        @inbounds x[i] = sqrt(x[i] + 1.0) * 1.5
    end
    return
end
function f_work_serial(x)
    for i in eachindex(x)
        @inbounds x[i] = sqrt(x[i] + 1.0) * 1.5
    end
    return
end
for n in (1_000, 100_000)
    SUITE["work"]["tforeach team, $n"] = @benchmarkable f_work_team(x) setup = (x = zeros($n)) samples = 2_000 evals = 1 seconds = 3
    SUITE["work"]["serial, $n"] = @benchmarkable f_work_serial(x) setup = (x = zeros($n)) samples = 2_000 evals = 1 seconds = 3
end

# Automatic differentiation with Enzyme: the loop on the team (through the rules of the
# EnzymeCore extension, the derivative chunks run on the team too) against a serial loop
function ad_square_sum_team(x, a)
    y = similar(x)
    tforeach(i -> (y[i] = a * x[i]^2), eachindex(x); scheduler = TEAM)
    return sum(y)
end
function ad_square_sum_serial(x, a)
    y = similar(x)
    for i in eachindex(x)
        y[i] = a * x[i]^2
    end
    return sum(y)
end
ad_sum_of_squares_team(x) = tmapreduce(abs2, +, x; scheduler = TEAM)
for n in (1_000, 100_000)
    SUITE["ad"]["reverse tforeach team, $n"] = @benchmarkable Enzyme.gradient(Reverse, ad_square_sum_team, x, a) setup = (x = rand($n); a = 1.7) samples = 500 evals = 1 seconds = 5
    SUITE["ad"]["reverse serial loop, $n"] = @benchmarkable Enzyme.gradient(Reverse, ad_square_sum_serial, x, a) setup = (x = rand($n); a = 1.7) samples = 500 evals = 1 seconds = 5
    SUITE["ad"]["forward tforeach team, $n"] = @benchmarkable autodiff(Forward, ad_square_sum_team, Duplicated(x, dx), Const(a)) setup = (x = rand($n); dx = ones($n); a = 1.7) samples = 500 evals = 1 seconds = 5
    SUITE["ad"]["reverse tmapreduce team, $n"] = @benchmarkable Enzyme.gradient(Reverse, ad_sum_of_squares_team, x) setup = (x = rand($n)) samples = 500 evals = 1 seconds = 5
end
