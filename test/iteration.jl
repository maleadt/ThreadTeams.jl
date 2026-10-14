@testset "iteration spaces" begin
    for itr in (1:0, 1:1, 1:2, 1:(NW - 1), 1:NW, 1:(NW + 1), 0:10, -5:5, 3:1000,
                Base.OneTo(37), 1:3:100, 10:-1:1, UInt8(3):UInt8(40),
                CartesianIndices((3, 5)), [2, 4, 8, 16, 32], reshape(1:24, 4, 6),
                view(collect(1:50), 2:2:40))
        @test check_visits(itr)
    end
    # only arrays: OhMyThreads' functions do not take tuples
    @test_throws ArgumentError tforeach(identity, (1, :a, 3.0); scheduler = team)
end

@testset "results" begin
    x = zeros(1000)
    tforeach(i -> (x[i] = 2i), eachindex(x); scheduler = team)
    @test x == 2 .* (1:1000)
    y = zeros(Int, 11)
    tforeach(i -> (y[i + 1] = i^2), 0:10; scheduler = team)
    @test y == (0:10) .^ 2
    # destructuring
    w = zeros(10)
    tforeach(collect(enumerate(1.0:10.0)); scheduler = team) do (i, v)
        w[i] = v
    end
    @test w == 1.0:10.0
    @test tforeach(identity, 1:0; scheduler = team) === nothing
    # @tasks
    z = zeros(Int, 100)
    r = @tasks for i in 1:100
        @set scheduler = team
        z[i] = i
    end
    @test r === nothing
    @test z == 1:100
    # one element: the serial fallback runs the body once
    calls = Int[]
    tforeach(i -> push!(calls, i), 5:5; scheduler = team)
    @test calls == [5]
end
