@testset "schedulers" begin
    @testset "construction" begin
        @test PS() isa Scheduler
        @test GPS() isa Scheduler
        @test OhMyThreads.Schedulers.scheduler_from_symbol(:team) === PS()
        @test OhMyThreads.Schedulers.scheduler_from_symbol(:greedyteam; chunksize = 4) ===
            GPS(chunksize = 4)
        @test_throws ArgumentError PS(nchunks = 3)
        @test_throws ArgumentError PS(ntasks = 3)
        @test_throws ArgumentError GPS(split = :roundrobin)
        @test_throws ArgumentError GPS(nchunks = 2, chunksize = 3)
        @test_throws ArgumentError GPS(nchunks = -1)
        @test occursin("per thread", sprint(show, MIME"text/plain"(), PS()))
        @test occursin("fixed size (7)", sprint(show, MIME"text/plain"(), GPS(chunksize = 7)))
        @test ThreadTeams.nchunks(1:1000) == (NW == 1 ? 1 : NW)
        @test ThreadTeams.nchunks(1:1000, GPS()) == (NW == 1 ? 1 : 4NW)
        @test ThreadTeams.nchunks(1:1000, GPS(chunksize = 10)) == (NW == 1 ? 1 : 100)
        @test ThreadTeams.nchunks(1:1000, GPS(nchunks = 7)) == (NW == 1 ? 1 : 7)
        @test ThreadTeams.nchunks(1:3, GPS(nchunks = 7)) == (NW == 1 ? 1 : 3)
        @test ThreadTeams.nchunks(1:1000, GPS(chunksize = 1000)) == 1
        # the OhMyThreads API is re-exported
        @test tmap(identity, 1:3) == 1:3
        @test tmapreduce(identity, +, 1:10; scheduler = DynamicScheduler()) == 55
    end

    @testset "OhMyThreads functions" begin
        x = rand(1001)
        for sched in (PS(), GPS(), GPS(chunksize = 1), GPS(chunksize = 7), :team, :greedyteam)
            @test tmapreduce(abs2, +, x; scheduler = sched) ≈ sum(abs2, x)
            @test tmapreduce(string, *, 1:50; scheduler = sched) == join(1:50)
            @test treduce(+, 1:1000; scheduler = sched) == 500500
            @test tmapreduce(+, +, x, x; scheduler = sched) ≈ 2sum(x)
            @test tmapreduce(identity, +, Int[]; scheduler = sched, init = 0) == 0
            @test tmap(sqrt, x; scheduler = sched) == sqrt.(x)
            A = reshape(1.0:24.0, 4, 6)
            @test tmap(sqrt, A; scheduler = sched) == sqrt.(A)
            @test tmap(*, A, A; scheduler = sched) == A .* A
            y = similar(x)
            tmap!(sqrt, y, x; scheduler = sched)
            @test y == sqrt.(x)
            @test tcollect((i^2 for i in 1:100); scheduler = sched) == (1:100) .^ 2
            z = zeros(1000)
            tforeach(i -> (z[i] = i), eachindex(z); scheduler = sched)
            @test z == 1:1000
            # chunks input: the task index is the position of the chunk
            ic = index_chunks(x; n = 13)
            @test tmapreduce(r -> sum(view(x, r)), +, ic; scheduler = sched) ≈ sum(x)
            @test tmap(length, ic; scheduler = sched) == length.(collect(ic))
            @test tmap(WithTaskIndex((t, r) -> t), ic; scheduler = sched) == 1:13
            @test tmap(((i, r),) -> i, enumerate(ic); scheduler = sched) == 1:13
        end
        # unsupported inputs
        @test_throws ArgumentError tmapreduce(identity, +, (1, 2, 3); scheduler = PS())
        @test_throws ArgumentError tmapreduce(
            identity, +, index_chunks(x; n = 3), x;
            scheduler = PS()
        )
    end

    @testset "chunk ranges" begin
        for itr in (
                1:0, 1:1, 0:9, 3:1000, view(collect(1:50), 2:2:40), CartesianIndices((3, 5)),
                enumerate(index_chunks(1:100; n = 7)),
            )
            lin = firstindex(itr):lastindex(itr)
            @test ThreadTeams.chunk_range(itr, 1, 1) == lin
            for n in 1:min(9, length(itr))
                rs = [ThreadTeams.chunk_range(itr, c, n) for c in 1:n]
                @test reduce(vcat, rs) == lin
                @test all(r -> length(r) >= length(itr) ÷ n, rs)
            end
        end
    end

    @testset "task index" begin
        # the chunk index, every chunk once, chunks are contiguous
        for sched in (PS(), GPS(chunksize = 3)), itr in (1:0, 1:1, 1:100, 0:9, collect(10:10:500))
            n = ThreadTeams.nchunks(itr, sched)
            cs = tmap(WithTaskIndex((c, i) -> c), itr; scheduler = sched)
            @test issorted(cs)
            @test isempty(itr) || (cs[1] == 1 && cs[end] == n)
            @test [count(==(c), cs) for c in 1:n] ==
                [length(ThreadTeams.chunk_range(itr, c, n)) for c in 1:n]
        end
        # per-chunk buffers through the task index
        bufs = [Int[] for _ in 1:NW]
        tforeach(WithTaskIndex((c, i) -> push!(bufs[c], i)), 1:100; scheduler = team)
        @test sort(reduce(vcat, bufs)) == 1:100
        @test count(!isempty, bufs) == ThreadTeams.nchunks(1:100)
        # @task_index in @tasks
        ibufs = [zeros(Int, 100) for _ in 1:NW]
        @tasks for i in 1:100
            @set scheduler = PS()
            @local buf = ibufs[@task_index]
            buf[i] = i
        end
        @test sum(ibufs) == 1:100
    end

    @testset "@tasks" begin
        # @local: task-local values live in the persistent workers
        r = @tasks for i in 1:100
            @set scheduler = PS()
            @set reducer = +
            @local buf = zeros(2)
            buf[1] = i
            buf[1]
        end
        @test r == 5050.0
        v = @tasks for i in 1:10
            @set scheduler = GPS(chunksize = 2)
            @set collect = true
            i^2
        end
        @test v == (1:10) .^ 2
        # `ntasks` (needed by `@barrier`) is rejected
        @test_throws ArgumentError @tasks for i in 1:10
            @set scheduler = :team
            @set ntasks = 2
        end
    end
end
