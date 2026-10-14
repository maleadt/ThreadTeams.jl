# The worker pool.
#
# There is one sticky worker task per thread of the `:default` thread pool. Worker `k`
# runs on thread `tids[k]` and waits for commands in its own `WorkerState` (padded to
# avoid false sharing). A command is the index of the chunk to run, `0` means idle,
# `RUNNING` that the worker claimed its chunk and `STOP` asks the worker to exit.
#
# A parallel region is started by `dispatch!`:
#
# 1. The chunk function `f::F` is stored in a per-type `Base.RefValue{F}` slot owned by
#    the pool. Workers receive the slot, which is already heap-allocated, so the hand-off
#    does not allocate (no boxing of `f`).
# 2. The caller publishes the region (number of chunks, its dynamic scope and world age),
#    then gives workers chunks `2:n` by storing the chunk index into their command field,
#    in decreasing chunk order. The worker running on the caller's thread (if any) is
#    skipped, because the caller occupies that thread.
# 3. Sleeping workers are woken up (with their `Event`) in a binary tree: whoever claims
#    chunk `c` first wakes the workers of chunks `2c` and `2c + 1` if they sleep, so the
#    caller wakes at most two workers itself.
# 4. Workers run their chunk in the caller's dynamic scope (`ScopedValue`s, the logger)
#    and world age.
# 5. The caller runs chunk 1 itself. Then it "steals" every chunk that its worker has not
#    claimed yet (a compare-and-swap of the command from `chunk` to `0`; the worker claims
#    it with a swap to `RUNNING`) and runs it itself. This keeps the region from waiting
#    for a worker that is asleep or whose thread the OS does not schedule (oversubscribed
#    cores). Finally it waits until every worker it used is idle again, also when a chunk
#    threw.
#
# Only one parallel region can be active at a time. The `busy` flag is taken with a
# compare-and-swap. A loop nested in a region (started by a chunk) runs serially; a loop
# started concurrently by another task runs on ordinary tasks (`Threads.@spawn`) instead.

const STOP = -1
const RUNNING = -2

mutable struct WorkerState
    @atomic cmd::Int
    @atomic sleeping::Bool
    # Padding: keep the fields of different workers on different cache lines
    _pad::NTuple{14, Int}
end
WorkerState() = WorkerState(0, false, ntuple(_ -> 0, Val(14)))

mutable struct Pool
    # The current parallel region, written by the dispatcher before it hands out chunks:
    # `Base.RefValue{F}` holding the chunk function, the number of chunks, the worker that
    # is skipped, and the dispatcher's dynamic scope and world age
    @atomic job::Any
    @atomic nchunks::Int
    @atomic skip::Int
    @atomic scope::Any
    # the world age as a boxed `UInt`, reused while it does not change (see `run_job_in_scope`)
    @atomic world::Any
    const workers::Vector{WorkerState}
    const events::Vector{Base.Event}
    const tasks::Vector{Task}
    # `errs[k]`: `CapturedException` thrown by the chunk worker `k` ran, or `nothing`
    const errs::Vector{Any}
    # `tid2worker[tid]`: index of the worker running on thread `tid`, or `0`
    const tid2worker::Vector{Int}
    # One `Base.RefValue{F}` per chunk function type `F`, and one partials buffer per
    # result type of a reduction. Only accessed while holding `POOL.busy`.
    const slots::IdDict{Type, Any}
    const buffers::IdDict{Type, Any}
    # more Julia threads than CPUs available to the process: spinning workers then give
    # their CPU to other OS threads now and then
    const oversubscribed::Bool
end

# Global state. `busy` is held by the task running a parallel region (and by `shutdown!`);
# `pool` is only created, replaced or used while holding `busy`.
mutable struct PoolHolder
    @atomic busy::Bool
    # Task that holds `busy` (to detect `shutdown!` calls from inside a region)
    @atomic owner::Any
    @atomic pool::Union{Nothing, Pool}
end
const POOL = PoolHolder(false, nothing, nothing)

# Spin time of an idle worker before it goes to sleep, in nanoseconds
const SPIN_NS = Threads.Atomic{Int}(100_000)
# Number of active `parallel_phase`s; while > 0, idle workers do not go to sleep on time
const PHASE = Threads.Atomic{Int}(0)

"""
    ParkedWorkers.set_spin_time!(seconds::Real)

Set how long an idle worker busy-waits for the next parallel loop before it goes to
sleep. The default is `100e-6` (100 µs). Takes effect the next time a worker starts
waiting.

Longer spinning makes parallel loops that follow each other with short serial gaps cheaper
(waking up a sleeping worker costs about 10 µs), but idle workers keep their CPU busy for
that long after every loop. `0` makes workers go to sleep right away (lowest CPU use,
highest latency). To keep the workers spinning only during a part of the program, use
[`ParkedWorkers.parallel_phase`](@ref).

On CPUs with performance and efficiency cores (recent Intel CPUs, Apple silicon), spinning
cores take power and turbo headroom from the busy ones. LLVM's and GCC's OpenMP runtimes
do not spin by default on such CPUs; consider `set_spin_time!(0)` there.
"""
function set_spin_time!(seconds::Real)
    seconds >= 0 || throw(ArgumentError("spin time must be non-negative"))
    SPIN_NS[] = round(Int, seconds * 1e9)
    return seconds
end

"""
    ParkedWorkers.spin_time() -> Float64

Current spin time of idle workers in seconds, see [`set_spin_time!`](@ref).
"""
spin_time() = SPIN_NS[] / 1e9

"""
    ParkedWorkers.nworkers() -> Int

Maximum number of chunks a parallel loop is split into: the number of threads of the
`:default` thread pool (`Threads.nthreads(:default)`).
"""
nworkers() = Threads.threadpoolsize(:default)

@inline cpu_pause() = ccall(:jl_cpu_pause, Cvoid, ())

@inline function os_yield()
    @static if Sys.iswindows()
        ccall(:SwitchToThread, stdcall, Cint, ())
    else
        ccall(:sched_yield, Cint, ())
    end
    return nothing
end

# Does this thread have another task to run? Then an idle worker goes to sleep at once
# instead of spinning, so that the task gets the thread. (Uses scheduler internals; if they
# are missing, idle workers only go to sleep after the spin time.)
@inline function other_work()
    @static if isdefined(Base, :workqueue_for) && isdefined(Base, :Partr) &&
               isdefined(Base.Partr, :multiq_check_empty)
        return !isempty(Base.workqueue_for(Threads.threadid())) ||
               !Base.Partr.multiq_check_empty()
    else
        return false
    end
end

# More Julia threads than CPUs this process may run on (affinity mask), e.g. `-t N` on N
# cores with Julia ≥ 1.12, which adds an interactive thread
function is_oversubscribed()
    nt = Threads.threadpoolsize(:default) + Threads.threadpoolsize(:interactive)
    return nt > Int(ccall(:uv_available_parallelism, Cuint, ()))
end

# The dynamic scope of the caller, and a macro to run code in it. Julia ≥ 1.11 keeps
# `ScopedValue`s and the logger in the task's scope; on Julia 1.10, ScopedValues.jl and
# `with_logger` keep them in the task's `logstate`.
@static if isdefined(Core, :current_scope)
    @inline current_scope() = Core.current_scope()
    macro enter_scope(scope, ex)
        return Expr(:tryfinally, esc(ex), nothing, esc(scope))
    end
else
    @inline current_scope() = current_task().logstate
    macro enter_scope(scope, ex)
        return quote
            local ct = current_task()
            local old = ct.logstate
            ct.logstate = $(esc(scope))
            try
                $(esc(ex))
            finally
                ct.logstate = old
            end
        end
    end
end

@static if isdefined(Base, :tls_world_age)
    @inline world_age() = Base.tls_world_age()
else
    @inline world_age() = ccall(:jl_get_tls_world_age, UInt, ())
end

@inline generating_output() = ccall(:jl_generating_output, Cint, ()) != 0

# Called by the workers with `invoke_in_world` in the world age of the dispatcher (as for a
# task it would have spawned), so that chunk functions whose types were defined after the
# workers were started can be called.
function run_job(slot::Base.RefValue{F}, chunk::Int) where {F}
    slot[](chunk)
    return nothing
end

# Run chunk `chunk` of the current region in the dispatcher's dynamic scope and world age.
# The region is read from the pool here: passing the `Any`-typed job and scope as arguments
# can make the call dynamic, which boxes its arguments. The world age is stored boxed and
# passed to `Core._call_in_world` (what `invoke_in_world` calls) as is: `invoke_in_world`
# itself takes an unboxed `UInt` and boxes it again on every call on Julia 1.10 and 1.11.
function run_job_in_scope(pool::Pool, chunk::Int)
    slot = @atomic :monotonic pool.job
    scope = @atomic :monotonic pool.scope
    world = @atomic :monotonic pool.world
    @enter_scope scope Core._call_in_world(world, run_job, slot, chunk)
    return nothing
end

# Wait until `ws.cmd` is non-zero: spin for `SPIN_NS` nanoseconds (or while a
# `parallel_phase` is active), then sleep on `ev`. Go to sleep right away when another task
# could run on this thread.
function wait_for_command(ws::WorkerState, ev::Base.Event, oversubscribed::Bool)
    spins = 0
    t0 = time_ns()
    tyield = tevents = t0
    while true
        cmd = @atomic :acquire ws.cmd
        if cmd > 0
            # Claim the chunk; fails if the dispatcher stole it in the meantime
            (@atomicreplace ws.cmd cmd => RUNNING).success && return cmd
        elseif cmd == STOP
            return cmd
        end
        spins += 1
        if spins & 63 == 0
            now = time_ns()
            spun_out = now - t0 > SPIN_NS[]
            if (spun_out && PHASE[] == 0) || other_work()
                @atomic ws.sleeping = true
                # Re-check after announcing that we sleep: either we see the command
                # here, or the dispatcher sees `sleeping` and notifies `ev`.
                if (@atomic ws.cmd) <= 0
                    wait(ev)
                end
                @atomic ws.sleeping = false
                spins = 0
                t0 = tyield = tevents = time_ns()
                continue
            end
            if spun_out && now - tevents > 20_000
                # Spinning longer than usual (in a `parallel_phase`): run the libuv event
                # loop now and then (only does something on the thread that runs it, when
                # it is free), as the scheduler would do on an idle thread. Otherwise, with
                # a worker on every thread, timers and I/O would never complete.
                Base.process_events()
                tevents = now
            end
            if oversubscribed && now - tyield > 5_000
                # Let the OS run the other threads on this core now and then (only when
                # there are more threads than CPUs: on an idle machine this would only add
                # context switches)
                os_yield()
                tyield = now
            end
        end
        cpu_pause()
        GC.safepoint()
    end
end

# The code of a worker task; also used to recognize worker tasks
struct WorkerCode
    pool::Any
    k::Int
end
(w::WorkerCode)() = worker_loop(w.pool::Pool, w.k)

function worker_loop(pool::Pool, k::Int)
    ws = pool.workers[k]
    ev = pool.events[k]
    while true
        cmd = wait_for_command(ws, ev, pool.oversubscribed)
        cmd == STOP && break
        wake_children(pool, cmd, @atomic(:monotonic, pool.nchunks),
                      @atomic(:monotonic, pool.skip))
        try
            run_job_in_scope(pool, cmd)
        catch err
            pool.errs[k] = CapturedException(err, catch_backtrace())
        end
        @atomic :release ws.cmd = 0
    end
    @atomic :release ws.cmd = 0
    return nothing
end

function Pool()
    tids = Threads.threadpooltids(:default)
    nw = length(tids)
    tid2worker = zeros(Int, maximum(tids))
    for (k, tid) in enumerate(tids)
        tid2worker[tid] = k
    end
    pool = Pool(nothing, 0, 0, nothing, nothing, [WorkerState() for _ in 1:nw],
                [Base.Event(true) for _ in 1:nw], Task[], Any[nothing for _ in 1:nw],
                tid2worker, IdDict{Type, Any}(), IdDict{Type, Any}(), is_oversubscribed())
    for (k, tid) in enumerate(tids)
        task = Task(WorkerCode(pool, k))
        task.sticky = true
        ccall(:jl_set_task_tid, Cint, (Any, Cint), task, tid - 1)
        push!(pool.tasks, task)
        schedule(task)
    end
    return pool
end

# Is a parallel region active (in this task or any other)?
#
# This check is inlined into every parallel loop in front of the serial fallback loop, so
# it must only use relaxed (`:monotonic`) loads. LLVM's MemoryDependenceAnalysis treats any
# acquire (or stronger) load as a clobber of all memory, even for `!invariant.load` queries
# ("FIXME: This is overly conservative" in MemoryDependenceAnalysis.cpp). An acquire load
# here stops GVN from merging loads after it with loads before it (e.g., array sizes
# checked by the caller), so the serial loop would lose constant strides and other facts
# (Trixi.jl: +4 to +8% time in several kernels on Julia 1.13). A stale value is harmless:
# it only makes us try the pool (and fall back to serial in `acquire_pool`) or run one loop
# serially. Data is only published with acquire/release in the non-inlined `run_chunks`,
# `run_fold` and `dispatch!`.
@inline pool_busy() = @atomic :monotonic POOL.busy

# Is the current task running a chunk of a parallel region (as the dispatcher or as a
# worker)? Inlined in front of the serial loop as well: plain and relaxed loads only.
@inline function in_region()
    ct = current_task()
    (@atomic :monotonic POOL.owner) === ct && return true
    return isdefined(ct, :code) && ct.code isa WorkerCode
end

# Take the pool for a parallel region (starting it if needed); `nothing` if the loop has to
# run serially. Only called from non-inlined functions.
@inline function acquire_pool()
    generating_output() && return nothing
    (@atomicreplace POOL.busy false => true).success || return nothing
    @atomic :monotonic POOL.owner = current_task()
    pool = @atomic :acquire POOL.pool
    if pool === nothing
        pool = try
            new_pool()
        catch
            release_pool()
            rethrow()
        end
    end
    return pool
end

@noinline function new_pool()
    pool = Pool()
    @atomic :release POOL.pool = pool
    return pool
end

@inline function release_pool()
    @atomic :monotonic POOL.owner = nothing
    @atomic :release POOL.busy = false
    return nothing
end

@noinline function job_slot(pool::Pool, ::Type{F}) where {F}
    return get!(() -> Base.RefValue{F}(), pool.slots, F)::Base.RefValue{F}
end

@noinline function partials_buffer(pool::Pool, ::Type{T}, n::Int) where {T}
    buf = get!(() -> Vector{T}(undef, n), pool.buffers, T)::Vector{T}
    length(buf) < n && resize!(buf, n)
    return buf
end

# Spin until worker `k` is idle. Yields now and then, so that a worker (or a chunk that
# yields) sharing the thread of the waiting task can make progress.
@inline function wait_idle(pool::Pool, k::Int)
    ws = @inbounds pool.workers[k]
    spins = 0
    while (@atomic :acquire ws.cmd) != 0
        spins += 1
        if spins & 1023 == 0
            # Defensive: wake the worker if it went to sleep with a pending command
            @atomic(ws.sleeping) && notify(@inbounds pool.events[k])
            yield()
        else
            cpu_pause()
            GC.safepoint()
        end
    end
    return nothing
end

# Index of the worker that runs chunk `chunk` (≥ 2) when worker `skip` is not used
@inline worker_for_chunk(chunk, skip) = (k = chunk - 1; (skip != 0 && k >= skip) ? k + 1 : k)

# Wake the worker of chunk `chunk` if it sleeps with this chunk still pending
@inline function wake_chunk(pool::Pool, chunk::Int, skip::Int)
    k = worker_for_chunk(chunk, skip)
    ws = @inbounds pool.workers[k]
    if (@atomic ws.sleeping) && (@atomic ws.cmd) == chunk
        notify(@inbounds pool.events[k])
    end
    return nothing
end

# Called by whoever claims chunk `chunk` of `n`, before running it: wake the workers of
# chunks `2chunk` and `2chunk + 1` (a binary tree, so that waking `n` sleeping workers
# takes O(log n) steps). The dispatcher stores the commands in decreasing chunk order, so a
# child's command is stored before its parent's; with the sequentially consistent claim of
# the parent and loads here, either the child sees its command before it sleeps, or we see
# that it sleeps. (`wait_idle` also re-notifies sleeping workers with pending commands.)
@inline function wake_children(pool::Pool, chunk::Int, n::Int, skip::Int)
    c = 2chunk
    c <= n && wake_chunk(pool, c, skip)
    c + 1 <= n && wake_chunk(pool, c + 1, skip)
    return nothing
end

# Run `f(chunk)` for `chunk in 1:n` in parallel; the caller holds `POOL.busy`.
function dispatch!(pool::Pool, f::F, n::Int) where {F}
    slot = job_slot(pool, F)
    slot[] = f
    tid = Threads.threadid()
    skip = tid <= length(pool.tid2worker) ? @inbounds(pool.tid2worker[tid]) : 0
    # Published to the workers by the (sequentially consistent) stores of the commands
    @atomic :monotonic pool.job = slot
    @atomic :monotonic pool.nchunks = n
    @atomic :monotonic pool.skip = skip
    @atomic :monotonic pool.scope = current_scope()
    world = world_age()
    old = @atomic :monotonic pool.world
    # box the world age only when it changed
    (old isa UInt && old == world) || (@atomic :monotonic pool.world = world)
    # Decreasing chunk order: see `wake_children`
    for chunk in n:-1:2
        k = worker_for_chunk(chunk, skip)
        # A worker can still be busy if a previous region was interrupted
        wait_idle(pool, k)
        @inbounds pool.errs[k] = nothing
        # Sequentially consistent store (Dekker-style with the worker, which stores
        # `sleeping` and then loads `cmd`), see `wake_children`
        @atomic (@inbounds pool.workers[k]).cmd = chunk
    end
    # Chunk 1 is ours: wake the workers of chunks 2 and 3, they wake the others
    wake_children(pool, 1, n, skip)
    try
        f(1)
    catch
        # Cancel the chunks that were not started and wait for the others: never leave
        # workers running when returning from the region
        for chunk in 2:n
            k = worker_for_chunk(chunk, skip)
            @atomicreplace (@inbounds pool.workers[k]).cmd chunk => 0
        end
        wait_workers(pool, n, skip)
        rethrow()
    end
    # Run the chunks not claimed by their worker yet
    for chunk in 2:n
        k = worker_for_chunk(chunk, skip)
        if (@atomicreplace (@inbounds pool.workers[k]).cmd chunk => 0).success
            # We took over the chunk, and with it the wake-ups of its children
            wake_children(pool, chunk, n, skip)
            try
                f(chunk)
            catch err
                @inbounds pool.errs[k] = CapturedException(err, catch_backtrace())
            end
        end
    end
    wait_workers(pool, n, skip)
    for chunk in 2:n
        k = worker_for_chunk(chunk, skip)
        err = @inbounds pool.errs[k]
        if err !== nothing
            throw_worker_error(err::CapturedException)
        end
    end
    # Do not keep the scope alive
    @atomic :monotonic pool.scope = nothing
    return nothing
end

@inline function wait_workers(pool::Pool, n, skip)
    for chunk in 2:n
        wait_idle(pool, worker_for_chunk(chunk, skip))
    end
    return nothing
end

# Rethrow the original exception of a worker chunk. The worker's backtrace is kept on the
# exception stack (`current_exceptions()`), so it is shown as "caused by: ...".
@noinline function throw_worker_error(err::CapturedException)
    try
        throw(err)
    catch
        throw(err.ex)
    end
end

# `nothing`, or `:serial` / `:tasks` if the loop can not use the pool: serially when
# nested in a region (or during precompilation), on tasks when another task holds the pool
@inline function no_pool_mode()
    (generating_output() || in_region()) && return :serial
    return :tasks
end

# Run `f(chunk)` for `chunk in 1:n` on `Threads.@spawn`ed tasks (chunk 1 on the calling
# task), for loops started while another task runs a parallel region. Exceptions as for a
# region: the one of the lowest failing chunk is rethrown after all chunks finished.
@noinline function run_tasks(f::F, n::Int) where {F}
    tasks = Vector{Task}(undef, n - 1)
    for chunk in 2:n
        tasks[chunk - 1] = Threads.@spawn :default f($chunk)
    end
    err1 = nothing
    try
        f(1)
    catch err
        err1 = CapturedException(err, catch_backtrace())
    end
    for t in tasks
        Base._wait(t)
    end
    err1 === nothing || throw_worker_error(err1)
    for t in tasks
        istaskfailed(t) && throw_worker_error(CapturedException(t.result, t.backtrace))
    end
    return nothing
end

# Run `f(chunk)` for `chunk in 1:n`, in parallel if the pool is free, else serially (nested)
# or on tasks (another task holds the pool). `n` must not exceed `nworkers()`.
# Not inlined: the atomics in here must stay out of the caller (see `pool_busy`).
@noinline function run_chunks(f::F, n::Int) where {F}
    pool = acquire_pool()
    if pool === nothing
        if no_pool_mode() === :tasks
            run_tasks(f, n)
        else
            for chunk in 1:n
                f(chunk)
            end
        end
        return nothing
    end
    try
        dispatch!(pool, f, n)
    finally
        release_pool()
    end
    return nothing
end

struct StoreChunk{F, T}
    f::F
    buf::Vector{T}
end
@inline (s::StoreChunk)(chunk) = (@inbounds s.buf[chunk] = s.f(chunk); nothing)

# Compute `op(op(f(1), f(2)), ...)` over `1:n` with the `f(chunk)` evaluated in parallel
# (`n ≥ 2`). The partial results are combined in chunk order, so the result is
# deterministic for a given `n`.
# Not inlined: the atomics in here must stay out of the caller (see `pool_busy`).
@noinline function run_fold(f::F, op::Op, n::Int) where {F, Op}
    pool = acquire_pool()
    if pool === nothing
        if no_pool_mode() === :tasks
            T = Base.promote_op(f, Int)
            T === Union{} && (T = Any)
            buf = Vector{T}(undef, n)
            run_tasks(StoreChunk{F, T}(f, buf), n)
            acc = @inbounds buf[1]
            for chunk in 2:n
                acc = op(acc, @inbounds buf[chunk])
            end
            return acc
        end
        acc = f(1)
        for chunk in 2:n
            acc = op(acc, f(chunk))
        end
        return acc
    end
    try
        T = Base.promote_op(f, Int)
        T === Union{} && (T = Any)
        buf = partials_buffer(pool, T, n)
        dispatch!(pool, StoreChunk{F, T}(f, buf), n)
        acc = @inbounds buf[1]
        for chunk in 2:n
            acc = op(acc, @inbounds buf[chunk])
        end
        return acc
    finally
        release_pool()
    end
end

"""
    ParkedWorkers.shutdown!()

Stop all worker tasks and drop the pool, including the references it keeps to the last
chunk function of each type (and thereby to the arrays captured by it). Waits for a
parallel region running in another task to finish first. The next parallel loop starts
a new pool.

Throws an error when called from inside a parallel loop.
"""
function shutdown!()
    while !(@atomicreplace POOL.busy false => true).success
        # The region can not end while we wait in one of its chunks
        if @atomic(POOL.owner) === current_task() || in_worker()
            error("ParkedWorkers.shutdown! called from inside a parallel loop")
        end
        yield()
    end
    @atomic :monotonic POOL.owner = current_task()
    try
        pool = @atomic POOL.pool
        pool === nothing && return nothing
        @atomic POOL.pool = nothing
        for (k, ws) in enumerate(pool.workers)
            wait_idle(pool, k)
            @atomic ws.cmd = STOP
            notify(pool.events[k])
        end
        foreach(wait, pool.tasks)
        empty!(pool.slots)
        empty!(pool.buffers)
        @atomic pool.job = nothing
    finally
        release_pool()
    end
    return nothing
end

function in_worker()
    ct = current_task()
    return isdefined(ct, :code) && ct.code isa WorkerCode
end

"""
    ParkedWorkers.parallel_phase(f)

Call `f()` and return its result. While `f` runs, idle workers keep spinning instead of
going to sleep after [`spin_time()`](@ref ParkedWorkers.spin_time), and sleeping workers
are woken up at the start. Use it around a part of the program with many parallel loops
separated by serial work that takes longer than the spin time, so that the loops do not
pay for waking up the workers (about 10 µs each). Idle workers still go to sleep when
their thread has another task to run, but otherwise keep their CPU busy until `f`
returns.

Phases may be nested and may be active in several tasks at once.

```julia
ParkedWorkers.parallel_phase() do
    for step in 1:nsteps
        serial_part!(state)       # e.g. 1 ms
        @pfor for i in eachindex(u)
            ...
        end
    end
end
```
"""
function parallel_phase(f)
    Threads.atomic_add!(PHASE, 1)
    try
        if nworkers() > 1 && !generating_output()
            # Start the workers if needed, and wake up the sleeping ones
            pool = @atomic :acquire POOL.pool
            if pool === nothing && (@atomicreplace POOL.busy false => true).success
                try
                    pool = @atomic :acquire POOL.pool
                    pool === nothing && (pool = new_pool())
                finally
                    @atomic :release POOL.busy = false
                end
            end
            if pool !== nothing
                for (k, ws) in enumerate(pool.workers)
                    @atomic(ws.sleeping) && notify(pool.events[k])
                end
            end
        end
        return f()
    finally
        Threads.atomic_sub!(PHASE, 1)
    end
end
