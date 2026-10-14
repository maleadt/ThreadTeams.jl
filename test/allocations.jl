@testset "allocations" begin
    x = zeros(64)
    fs = (add_one!, psum, add_one_tasks!, add_one_greedy!, psum_greedy)
    for _ in 1:10, f in fs
        f(x)
    end
    # minimum of a few tries: on Julia 1.10, `@allocated` also counts allocations of
    # other threads
    allocs = map(f -> minimum(_ -> (@allocated f(x)), 1:20), fs)
    @info "allocations per loop" tforeach = allocs[1] tmapreduce = allocs[2] tasks = allocs[3] greedy = allocs[4] greedy_reduce = allocs[5]
    @test allocs[1] == 0
    @test allocs[3] == 0
    @test allocs[4] == 0
    # a reduction allocates 16 bytes on Julia 1.10 and 1.11, also when run serially
    @test allocs[2] <= (VERSION >= v"1.12" ? 0 : 16)
    @test allocs[5] <= (VERSION >= v"1.12" ? 0 : 16)
end
