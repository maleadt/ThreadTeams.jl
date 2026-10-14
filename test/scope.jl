@testset "dynamic scope and world age" begin
    r = zeros(Int, 64)
    if isdefined(Base, :ScopedValues)
        sv = Base.ScopedValues.ScopedValue(0)
        Base.ScopedValues.with(sv => 42) do
            tforeach(i -> (r[i] = sv[]), eachindex(r); scheduler = team)
        end
        @test all(==(42), r)
        tforeach(i -> (r[i] = sv[]), eachindex(r); scheduler = team)
        @test all(==(0), r)
        @test Base.ScopedValues.with(() -> tmapreduce(_ -> sv[], +, 1:100; scheduler = team), sv => 3) == 300
    end
    # the logger (in the task's scope on Julia ≥ 1.11, in its `logstate` on 1.10)
    logger = Base.CoreLogging.NullLogger()
    ok = zeros(Bool, 64)
    Base.CoreLogging.with_logger(logger) do
        tforeach(eachindex(ok); scheduler = team) do i
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
