@testset "shutdown and restart" begin
    x = zeros(64)
    add_one!(x)
    ThreadTeams.shutdown!()
    @test (@atomic ThreadTeams.POOL.pool) === nothing
    ThreadTeams.shutdown!()  # no-op
    add_one!(x)
    @test all(==(2.0), x)
    if NW > 1
        @test (@atomic ThreadTeams.POOL.pool) !== nothing
        pool = @atomic ThreadTeams.POOL.pool
        @test count(istaskdone, pool.tasks) == 0
        ThreadTeams.shutdown!()
        @test all(istaskdone, pool.tasks)
        # from inside a parallel loop
        err = try
            tforeach(i -> i == 1 && ThreadTeams.shutdown!(), 1:NW; scheduler = team)
        catch e
            e
        end
        @test err isa ErrorException
        # from a loop that runs on spawned tasks because another task holds the team, which
        # may be waiting for this loop
        gate = Base.Event()
        holder = Threads.@spawn tforeach(i -> i == 1 && wait(gate), 1:NW; scheduler = team)
        while !(@atomic ThreadTeams.POOL.busy)
            yield()
        end
        r = Threads.@spawn try
            tforeach(i -> i == 1 && ThreadTeams.shutdown!(), 1:NW; scheduler = team)
        catch e
            e
        end
        timedwait(() -> istaskdone(r), 10)
        notify(gate)
        wait(holder)
        @test fetch(r) isa ErrorException
        # while another task runs loops
        t = Threads.@spawn for _ in 1:20_000
            add_one!(zeros(64))
        end
        for _ in 1:20
            ThreadTeams.shutdown!()
            yield()
        end
        wait(t)
        @test psum(collect(1:100)) == 5050
    end
end
