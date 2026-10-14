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
