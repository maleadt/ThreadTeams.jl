"""
    ParkedWorkers

A small pool of persistent ("parked") worker tasks for low-overhead parallel `for` loops
on top of Base threads.

There is one sticky worker task per thread of the `:default` thread pool. A parallel
loop splits its range into one contiguous chunk per thread, runs chunk 1 on the calling
task and hands the other chunks to workers. After finishing a chunk, a worker spins for a
short while (see [`set_spin_time!`](@ref)) before it goes to sleep, so that back-to-back
loops do not pay for task creation, scheduling and wake-up.

Public API: [`@pfor`](@ref), [`pforeach`](@ref), [`pmapreduce`](@ref), [`preduce`](@ref),
[`ParkedWorkers.nworkers`](@ref), [`ParkedWorkers.set_spin_time!`](@ref),
[`ParkedWorkers.spin_time`](@ref), [`ParkedWorkers.parallel_phase`](@ref),
[`ParkedWorkers.shutdown!`](@ref),
[`ParkedWorkers.neutral`](@ref).
"""
module ParkedWorkers

export @pfor, pforeach, pmapreduce, preduce

include("pool.jl")
include("loops.jl")

end # module
