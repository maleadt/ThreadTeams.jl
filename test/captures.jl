# Loops whose bodies capture boxed variables: OhMyThreads' check applies to the pool too
function boxed_write(x)
    found = false
    tforeach(eachindex(x); scheduler = team) do i
        x[i] > 0.5 && (found = true)
    end
    return found
end
function boxed_read(x)
    y = 1.0
    y = 2.0   # assigned twice: boxed, although the loop only reads it
    tforeach(i -> (x[i] = y), eachindex(x); scheduler = team)
    return x
end
function boxed_reduction(x)
    y = 1.0
    y = 2.0
    return tmapreduce(i -> y * x[i], +, eachindex(x); scheduler = team)
end
function unboxed(x)
    y = 1.0
    z = let
        y + 1.0
    end
    tforeach(i -> (x[i] = z), eachindex(x); scheduler = team)
    return x
end

@testset "boxed captures" begin
    x = rand(100)
    for f in (boxed_write, boxed_read, boxed_reduction)
        @test_throws OhMyThreads.Implementation.BoxedVariableError f(copy(x))
    end
    # opting out with OhMyThreads' macro (re-exported)
    @test (@allow_boxed_captures boxed_read(zeros(100))) == fill(2.0, 100)
    @test (@allow_boxed_captures boxed_reduction(ones(100))) == 200.0
    # no box, no error
    @test unboxed(zeros(10)) == fill(2.0, 10)
    # inputs of at most one element run serially in OhMyThreads and are not checked
    @test boxed_read(zeros(1)) == [2.0]
end
