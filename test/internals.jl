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

# The cache line of each hot atomic field lies within its (16-byte aligned) object, so
# that neither the other fields of the pool nor a neighbouring object share it
@testset "cache line padding" begin
    L = ThreadTeams.CACHE_LINE
    @test L == (Sys.ARCH === :aarch64 ? 128 : 64)
    for (T, field) in [
            (ThreadTeams.ChunkCounter, :next), (ThreadTeams.WorkerState, :cmd),
            (ThreadTeams.SleepFlag, :sleeping),
        ]
        off = Int(fieldoffset(T, findfirst(==(field), fieldnames(T))))
        for base in 0:16:(L - 16)   # every alignment of the object within a line
            start = base + off - (base + off) % L
            @test start >= base
            @test start + L <= base + sizeof(T)
        end
    end
end
