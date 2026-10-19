@testset "exceptions" begin
    # one chunk throws: the exception of the first failing iteration in serial
    # order is rethrown after all chunks finished
    for bad in (1, 50, 100)
        done = zeros(Int, 100)
        err = try
            tforeach(1:100; scheduler = team) do i
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
        tforeach(i -> throw(ArgumentError("chunk starting at $i")), 1:100; scheduler = team)
    catch e
        e
    end
    @test err == ArgumentError("chunk starting at 1")
    err = try
        tforeach(i -> i > 10 && error("bad $i"), 1:100; scheduler = team)
    catch e
        e
    end
    @test err == ErrorException("bad 11")
    err = try
        treduce((a, b) -> b > 60 ? error("bad") : a + b, 1:100; scheduler = team)
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
            tforeach(i -> i == 100 && error("last"), 1:100; scheduler = team)
        catch
            current_exceptions()
        end
        @test any(e -> e.exception isa CapturedException, excs)
    end
end

@testset "exception thrown into a waiting worker" begin
    if NW > 1
        old = ThreadTeams.spin_time()
        ThreadTeams.set_spin_time!(0)
        @test psum(collect(1:100)) == 5050
        pool = @atomic ThreadTeams.POOL.pool
        k = NW
        @test timedwait(() -> (@atomic pool.sleepflags[k].sleeping), 10) === :ok
        # An interrupt on the worker's thread before it read its command (here `STOP`,
        # not notified) must not erase the command
        @atomic pool.workers[k].cmd = ThreadTeams.STOP
        schedule(pool.tasks[k], InterruptException(); error = true)
        @test timedwait(() -> istaskdone(pool.tasks[k]), 10) === :ok
        ThreadTeams.shutdown!()
        ThreadTeams.set_spin_time!(old)
        @test psum(collect(1:100)) == 5050
    end
end
