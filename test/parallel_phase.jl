@testset "parallel phase" begin
    x = ThreadTeams.parallel_phase() do
        x = zeros(64)
        for _ in 1:5
            sleep(0.002)   # longer than the spin time
            add_one!(x)
        end
        if NW > 1
            # idle workers keep spinning (except the one on our thread, which goes to
            # sleep when we become runnable again)
            pool = @atomic ThreadTeams.POOL.pool
            skip = get(pool.tid2worker, Threads.threadid(), 0)
            sleep(0.002)
            @test all(
                k -> k == skip || !(@atomic pool.sleepflags[k].sleeping),
                eachindex(pool.workers)
            )
        end
        ThreadTeams.parallel_phase(() -> add_one!(x))
    end
    @test all(==(6.0), x)
    @test ThreadTeams.PHASE[] == 0
    @test_throws ErrorException ThreadTeams.parallel_phase(() -> error("in phase"))
    @test ThreadTeams.PHASE[] == 0
    @test ThreadTeams.is_oversubscribed() isa Bool
end
