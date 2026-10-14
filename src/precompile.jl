# Precompilation of the parts of the team that do not depend on the loop body, so that
# the first parallel loop of a session does not pay for them (about 0.6 s of 0.9 s with
# Julia 1.12; what remains is the specialization on the loop body, as with OhMyThreads'
# own schedulers).
#
# Parallel loops run serially during precompilation (`generating_output`), so a workload
# alone never reaches the pool: the worker tasks, the command hand-off and the waiting
# loops are precompiled with explicit statements. The workload below compiles the entry
# points of OhMyThreads for the team schedulers, the `boxed_captures` generator, and the
# region functions (`run_fold`, `dispatch!`, ...) for sample loop bodies; inferring them
# also compiles the specializations of the compiler itself that they need (about 0.3 s
# per session otherwise). `run_tasks` is not specialized on the loop body, so one
# statement covers it.

precompile(run_tasks, (Any, Int))
precompile(Pool, ())
precompile(new_pool, ())
precompile(Tuple{WorkerCode})
precompile(worker_loop, (Pool, Int))
precompile(wait_for_command, (WorkerState, SleepFlag, Base.Event, Bool))
precompile(wait_idle, (Pool, Int))
precompile(is_oversubscribed, ())
precompile(shutdown!, ())
precompile(set_spin_time!, (Float64,))
precompile(spin_time, ())
precompile(nworkers, ())

if ccall(:jl_generating_output, Cint, ()) == 1
    let x = zeros(2), team = TeamScheduler(), greedy = GreedyTeamScheduler()
        tforeach(i -> (x[i] = 1.0), eachindex(x); scheduler = team)
        tmapreduce(abs2, +, x; scheduler = team)
        tmap(sqrt, x; scheduler = team)
        tforeach(i -> (x[i] = 1.0), eachindex(x); scheduler = greedy)
        tmapreduce(abs2, +, x; scheduler = greedy)
        @tasks for i in eachindex(x)
            @set scheduler = team
            x[i] = 2.0
        end
        parallel_phase(() -> nothing)
    end
end
