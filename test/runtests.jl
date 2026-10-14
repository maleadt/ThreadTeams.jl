using ParkedWorkers
using ParkedWorkers: nworkers
using Test
using InteractiveUtils: code_llvm

const NW = nworkers()
@info "Testing ParkedWorkers" VERSION Threads.nthreads(:default) Threads.nthreads(:interactive)

# Count how often every element is visited
function visits(itr)
    counts = Dict{Any, Int}()
    lk = ReentrantLock()
    @pfor for x in itr
        lock(lk) do
            counts[x] = get(counts, x, 0) + 1
        end
    end
    return counts
end

function check_visits(itr)
    counts = visits(itr)
    expected = Dict{Any, Int}()
    for x in itr
        expected[x] = get(expected, x, 0) + 1
    end
    return counts == expected
end

# Allocation test helpers (functions, so that `@allocated` measures only the loop)
function add_one!(x)
    @pfor for i in eachindex(x)
        @inbounds x[i] += 1.0
    end
    return x
end
function psum(x)
    s = zero(eltype(x))
    @pfor reduction = (+, s) for i in eachindex(x)
        @inbounds s += x[i]
    end
    return s
end
add_one_f!(x) = pforeach(i -> (@inbounds x[i] += 1.0), eachindex(x))

# World age: chunks run in the world of the caller
pw_world_g(::Integer) = 1
function pw_world_h()
    r = zeros(Int, 64)
    @pfor for i in eachindex(r)
        r[i] = pw_world_g(i)
    end
    return r
end

myop(a, b) = a + 2b   # not associative, but used only with neutral 0 for testing syntax
struct MaxAbs end
(::MaxAbs)(a, b) = max(abs(a), abs(b))
ParkedWorkers.neutral(::MaxAbs, x) = zero(x)

@testset "ParkedWorkers" verbose = true begin
    @testset "iteration spaces" begin
        for itr in (1:0, 1:1, 1:2, 1:(NW - 1), 1:NW, 1:(NW + 1), 0:10, -5:5, 3:1000,
                    Base.OneTo(37), 1:3:100, 10:-1:1, UInt8(3):UInt8(40),
                    CartesianIndices((3, 5)), [2, 4, 8, 16, 32], (1, :a, 3.0, "x"),
                    reshape(1:24, 4, 6), view(collect(1:50), 2:2:40))
            @test check_visits(itr)
        end
    end

    @testset "chunk" begin
        for len in (0, 1, 2, 7, 64, 1001), n in 1:9
            r = 0:(len - 1)
            parts = [ParkedWorkers.chunk(r, c, n) for c in 1:n]
            @test reduce(vcat, collect.(parts)) == collect(r)
            n <= max(len, 1) && @test all(p -> length(p) >= len ÷ n, parts)
        end
        @test ParkedWorkers.chunk(Base.OneTo(10), 2, 2) == 6:10
        @test collect(ParkedWorkers.chunk((1, 2, 3, 4), 2, 2)) == [3, 4]
    end

    @testset "results" begin
        x = zeros(1000)
        @pfor for i in eachindex(x)
            x[i] = 2i
        end
        @test x == 2 .* (1:1000)
        y = zeros(Int, 11)
        @pfor for i in 0:10
            y[i + 1] = i^2
        end
        @test y == (0:10) .^ 2
        # `continue` works
        z = zeros(Int, 100)
        @pfor for i in 1:100
            isodd(i) && continue
            z[i] = 1
        end
        @test z == iseven.(1:100)
        # destructuring loop variable
        w = zeros(10)
        @pfor for (i, v) in collect(enumerate(1.0:10.0))
            w[i] = v
        end
        @test w == 1.0:10.0
        # function form
        a = zeros(Int, 77)
        pforeach(i -> (a[i] = i), eachindex(a))
        @test a == 1:77
        @test pforeach(identity, 1:0) === nothing
        # the macro returns `nothing`
        @test (@pfor for i in 1:10 end) === nothing
    end

    @testset "concurrent chunks run on distinct threads" begin
        # A chunk can run on the calling task when its worker did not pick it up in time,
        # but chunks that run at the same time never share a thread.
        tids = zeros(Int, NW)
        t0 = zeros(UInt64, NW)
        t1 = zeros(UInt64, NW)
        @pfor for c in 1:NW
            tids[c] = Threads.threadid()
            t0[c] = time_ns()
            while time_ns() - t0[c] < 1_000_000  # 1 ms
            end
            t1[c] = time_ns()
        end
        overlap(a, b) = t0[a] < t1[b] && t0[b] < t1[a]
        @test all(!(tids[a] == tids[b] && overlap(a, b)) for a in 1:NW, b in 1:NW if a != b)
    end

    @testset "reductions" begin
        x = collect(1:1000)
        s = 0
        @pfor reduction = (+, s) for i in eachindex(x)
            s += x[i]
        end
        @test s == sum(x)
        # the initial value is included
        s = 10
        @pfor reduction = (+, s) for i in 1:100
            s += i
        end
        @test s == 10 + 5050
        p = 1.0
        @pfor reduction = (*, p) for i in 1:20
            p *= i
        end
        @test p ≈ factorial(20)
        mx, mn = -Inf, Inf
        v = randn(503)
        @pfor reduction = ((max, mx), (min, mn)) for i in eachindex(v)
            mx = max(mx, v[i])
            mn = min(mn, v[i])
        end
        @test mx == maximum(v)
        @test mn == minimum(v)
        allpos, anyneg = true, false
        @pfor reduction = ((&, allpos), (|, anyneg)) for i in eachindex(v)
            allpos &= v[i] > -100
            anyneg |= v[i] < 0
        end
        @test allpos && anyneg
        bits = 0xff
        @pfor reduction = (&, bits) for i in 1:3
            bits &= 0xff
        end
        @test bits == 0xff
        xr = 0
        @pfor reduction = (xor, xr) for i in 1:100
            xr = xor(xr, i)
        end
        @test xr == reduce(xor, 1:100)
        # custom operators: explicit neutral element and `neutral` method
        c = 0.0
        @pfor reduction = ((a, b) -> a + b, c, 0.0) for i in 1:100
            c += i
        end
        @test c == 5050.0
        ma = 0.0
        @pfor reduction = (MaxAbs(), ma) for i in eachindex(v)
            ma = MaxAbs()(ma, v[i])
        end
        @test ma == maximum(abs, v)
        @test_throws ArgumentError ParkedWorkers.neutral(myop, 1)
        # the type of the variable can change in the loop
        t = 0
        @pfor reduction = (+, t) for i in 1:100
            t += 0.5
        end
        @test t === 50.0
        # empty range: the variable keeps its value
        e = 42
        @pfor reduction = (+, e) for i in 1:0
            e += i
        end
        @test e == 42
        # deterministic results
        f = rand(10_000)
        @test all(_ -> psum(f) == psum(f), 1:100)
        @test psum(f) ≈ sum(f)
    end

    @testset "reductions at top level" begin
        mod = Module()
        Core.eval(mod, :(using ParkedWorkers))
        include_string(mod, """
            s = 0
            @pfor reduction = (+, s) for i in 1:100
                s += i
            end
            """)
        @test mod.s == 5050
    end

    @testset "pmapreduce / preduce" begin
        x = rand(1001)
        @test pmapreduce(abs2, +, x) ≈ sum(abs2, x)
        @test pmapreduce(i -> x[i], max, eachindex(x)) == maximum(x)
        @test preduce(+, 1:1000) == 500500
        @test preduce(+, 1:0; init = 0) == 0
        @test preduce(*, (1, 2, 3, 4)) == 24
        @test preduce(+, [1]) == 1
        @test pmapreduce(identity, +, 1:10; init = 0.0) === 55.0
        @test pmapreduce(string, *, 1:12) == join(1:12)   # order is kept
        @test preduce(+, Int[]) == 0
        @test_throws Exception preduce(max, Int[])
    end

    @testset "exceptions" begin
        # one chunk throws: the exception of the first failing iteration in serial
        # order is rethrown after all chunks finished
        for bad in (1, 50, 100)
            done = zeros(Int, 100)
            err = try
                @pfor for i in 1:100
                    i == bad && throw(DomainError(i))
                    done[i] = 1
                end
                nothing
            catch e
                e
            end
            @test err == DomainError(bad)
            # everything a serial loop would have done before the error was done
            @test all(==(1), done[1:(bad - 1)])
        end
        # all chunks throw
        err = try
            @pfor for i in 1:100
                throw(ArgumentError("chunk starting at $i"))
            end
        catch e
            e
        end
        @test err == ArgumentError("chunk starting at 1")
        err = try
            pforeach(i -> i > 10 && error("bad $i"), 1:100)
        catch e
            e
        end
        @test err == ErrorException("bad 11")
        err = try
            preduce((a, b) -> b > 60 ? error("bad") : a + b, 1:100)
        catch e
            e
        end
        @test err isa ErrorException
        # the pool still works afterwards
        for _ in 1:100
            @test psum(collect(1:100)) == 5050
        end
        # backtrace of a worker chunk is kept
        if NW > 1
            excs = try
                @pfor for i in 1:100
                    i == 100 && error("last")
                end
            catch
                current_exceptions()
            end
            @test any(e -> e.exception isa CapturedException, excs)
        end
    end

    @testset "nested" begin
        m = zeros(Int, 20, 30)
        inner = zeros(Int, 20)
        @pfor for j in 1:20
            inner[j] = ParkedWorkers.nchunks(1:30)
            @pfor for i in 1:30
                m[j, i] = i + 100j
            end
        end
        @test m == [i + 100j for j in 1:20, i in 1:30]
        @test all(==(1), inner)
        s = 0
        @pfor reduction = (+, s) for j in 1:10
            t = 0
            @pfor reduction = (+, t) for i in 1:10
                t += i * j
            end
            s += t
        end
        @test s == 55 * 55
        @test pmapreduce(j -> pmapreduce(i -> i * j, +, 1:10), +, 1:10) == 55 * 55
    end

    @testset "concurrent tasks" begin
        ntasks = 8
        results = zeros(Int, ntasks)
        tasks = map(1:ntasks) do t
            Threads.@spawn begin
                ok = 0
                for _ in 1:2000
                    x = zeros(Int, 37 + t)
                    @pfor for i in eachindex(x)
                        x[i] = i
                    end
                    s = 0
                    @pfor reduction = (+, s) for i in eachindex(x)
                        s += x[i]
                    end
                    ok += (x == 1:(37 + t)) && s == sum(1:(37 + t))
                end
                ok
            end
        end
        results = fetch.(tasks)
        @test all(==(2000), results)
        # from the interactive thread pool, if there is one
        if Threads.nthreads(:interactive) > 0
            r = fetch(Threads.@spawn :interactive psum(collect(1.0:100.0)))
            @test r == 5050.0
        end
    end

    @testset "loops while another task runs one" begin
        # A loop started while another task holds the pool runs on spawned tasks
        if NW > 1
            started = Base.Event()
            release = Base.Event()
            holder = Threads.@spawn @pfor for i in 1:NW
                if i == 1
                    notify(started)
                    wait(release)
                end
            end
            wait(started)
            ct = current_task()
            tasks = Vector{Task}(undef, NW)
            @pfor for i in 1:NW
                tasks[i] = current_task()
            end
            @test tasks[1] === ct
            @test all(t -> t !== ct && !(t.code isa ParkedWorkers.WorkerCode), tasks[2:end])
            # exceptions: the one of the lowest failing chunk
            err = try
                @pfor for i in 1:NW
                    i >= 2 && error("chunk $i")
                end
                nothing
            catch e
                e
            end
            @test err == ErrorException("chunk 2")
            @test pmapreduce(identity, +, 1:100) == 5050
            s = 0
            @pfor reduction = (+, s) for i in 1:100
                s += i
            end
            @test s == 5050
            notify(release)
            wait(holder)
        end
    end

    @testset "dynamic scope and world age" begin
        r = zeros(Int, 64)
        if isdefined(Base, :ScopedValues)
            sv = Base.ScopedValues.ScopedValue(0)
            Base.ScopedValues.with(sv => 42) do
                @pfor for i in eachindex(r)
                    r[i] = sv[]
                end
            end
            @test all(==(42), r)
            pforeach(i -> (r[i] = sv[]), eachindex(r))
            @test all(==(0), r)
            @test Base.ScopedValues.with(() -> pmapreduce(_ -> sv[], +, 1:100), sv => 3) == 300
        end
        # the logger (in the task's scope on Julia ≥ 1.11, in its `logstate` on 1.10)
        logger = Base.CoreLogging.NullLogger()
        ok = zeros(Bool, 64)
        Base.CoreLogging.with_logger(logger) do
            @pfor for i in eachindex(ok)
                ok[i] = Base.CoreLogging.current_logger() === logger
            end
        end
        @test all(ok)
        @test Base.CoreLogging.current_logger() !== logger
        # world age
        @test all(==(1), pw_world_h())
        w = Base.get_world_counter()
        @eval pw_world_g(::Int) = 2   # a new, more specific method
        @test all(==(1), Base.invoke_in_world(w, pw_world_h))
        @test all(==(2), Base.invokelatest(pw_world_h))
    end

    @testset "parallel phase" begin
        x = ParkedWorkers.parallel_phase() do
            x = zeros(64)
            for _ in 1:5
                sleep(0.002)   # longer than the spin time
                add_one!(x)
            end
            if NW > 1
                # idle workers keep spinning (except the one on our thread, which goes to
                # sleep when we become runnable again)
                pool = @atomic ParkedWorkers.POOL.pool
                skip = get(pool.tid2worker, Threads.threadid(), 0)
                sleep(0.002)
                @test all(k -> k == skip || !(@atomic pool.workers[k].sleeping),
                          eachindex(pool.workers))
            end
            ParkedWorkers.parallel_phase(() -> add_one!(x))
        end
        @test all(==(6.0), x)
        @test ParkedWorkers.PHASE[] == 0
        @test_throws ErrorException ParkedWorkers.parallel_phase(() -> error("in phase"))
        @test ParkedWorkers.PHASE[] == 0
        @test ParkedWorkers.is_oversubscribed() isa Bool
    end

    @testset "blocked worker thread" begin
        # A task that does not yield occupies a worker's thread; the caller runs that
        # worker's chunk instead of waiting for the task to finish.
        if NW > 2
            add_one!(zeros(64))
            stop = Threads.Atomic{Bool}(false)
            blocker = Threads.@spawn begin
                t = time_ns()
                while !stop[] && time_ns() - t < 2_000_000_000
                end
            end
            while !istaskstarted(blocker)
                yield()
            end
            x = zeros(1000)
            elapsed = @elapsed for _ in 1:100
                add_one!(x)
            end
            stop[] = true
            wait(blocker)
            @test all(==(100.0), x)
            @test elapsed < 1.0
        end
    end

    @testset "spin time" begin
        old = ParkedWorkers.spin_time()
        @test old == 100e-6
        try
            ParkedWorkers.set_spin_time!(0)
            @test ParkedWorkers.spin_time() == 0
            x = zeros(100)
            for _ in 1:200
                add_one!(x)
                sleep(0.0005)   # workers sleep in between
            end
            @test all(==(200.0), x)
            # every shape of the wake-up tree
            for len in 2:(2NW + 1), _ in 1:5
                y = zeros(len)
                add_one!(y)
                @test all(==(1.0), y)
                @test psum(y) == len
                sleep(0.0002)
            end
            @test_throws ArgumentError ParkedWorkers.set_spin_time!(-1)
        finally
            ParkedWorkers.set_spin_time!(old)
        end
    end

    @testset "shutdown and restart" begin
        x = zeros(64)
        add_one!(x)
        ParkedWorkers.shutdown!()
        @test (@atomic ParkedWorkers.POOL.pool) === nothing
        ParkedWorkers.shutdown!()  # no-op
        add_one!(x)
        @test all(==(2.0), x)
        if NW > 1
            @test (@atomic ParkedWorkers.POOL.pool) !== nothing
            pool = @atomic ParkedWorkers.POOL.pool
            @test count(istaskdone, pool.tasks) == 0
            ParkedWorkers.shutdown!()
            @test all(istaskdone, pool.tasks)
            # from inside a parallel loop
            err = try
                @pfor for i in 1:NW
                    i == 1 && ParkedWorkers.shutdown!()
                end
            catch e
                e
            end
            @test err isa ErrorException
            # while another task runs loops
            t = Threads.@spawn for _ in 1:20_000
                add_one!(zeros(64))
            end
            for _ in 1:20
                ParkedWorkers.shutdown!()
                yield()
            end
            wait(t)
            @test psum(collect(1:100)) == 5050
        end
    end

    @testset "no acquire loads before the serial loop" begin
        # The checks inlined in front of the serial fallback loop must only use relaxed
        # loads: LLVM's MemDep treats acquire loads as clobbers, which keeps GVN from
        # merging loads (e.g., array sizes) across them. All stronger atomics belong in
        # the non-inlined `run_chunks` / `run_fold`.
        for (f, T) in ((add_one!, Tuple{Vector{Float64}}), (psum, Tuple{Vector{Float64}}),
                       (add_one_f!, Tuple{Vector{Float64}}))
            ir = sprint(io -> code_llvm(io, f, T; debuginfo = :none))
            @test !occursin(r"load atomic[^\n]*\b(acquire|seq_cst)\b", ir)
            @test !occursin(r"\b(cmpxchg|atomicrmw|fence)\b", ir)
            @test !occursin("jl_generating_output", ir)
        end
    end

    @testset "allocations" begin
        x = zeros(64)
        for _ in 1:10
            add_one!(x)
            psum(x)
            add_one_f!(x)
        end
        # minimum of a few tries: on Julia 1.10, `@allocated` also counts allocations of
        # other threads
        a1 = minimum(_ -> (@allocated add_one!(x)), 1:20)
        a2 = minimum(_ -> (@allocated psum(x)), 1:20)
        a3 = minimum(_ -> (@allocated add_one_f!(x)), 1:20)
        @info "allocations per loop" add_one! = a1 psum = a2 pforeach = a3
        @test a1 == 0
        @test a3 == 0
        # a reduction allocates 16 bytes on Julia 1.10 and 1.11, also when run serially
        @test a2 <= (VERSION >= v"1.12" ? 0 : 16)
    end

    @testset "stress" begin
        x = zeros(16)
        for _ in 1:50_000
            add_one!(x)
        end
        @test all(==(50_000.0), x)
        s = 0.0
        for k in 1:10_000
            s += psum(x)
        end
        @test s == 10_000 * 16 * 50_000.0
    end
end
