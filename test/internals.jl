# The scheduler internals that idle workers use to go to sleep when another task is ready
# (`other_work`). They are guarded with `isdefined`, so nothing fails when they move; this
# test tells when that happens on a supported release.
@testset "scheduler internals" begin
    if VERSION < v"1.14-"
        @test isdefined(Base, :workqueue_for)
        @test isdefined(Base, :Partr) && isdefined(Base.Partr, :multiq_check_empty)
        @test ThreadTeams.other_work() isa Bool
    end
end
