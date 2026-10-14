# After a loop, the team keeps no reference to the loop body, the arrays it captured or the
# partial results of a reduction
function loop_over_temporary()
    x = zeros(10^6)
    w = WeakRef(x)
    tforeach(i -> (@inbounds x[i] += 1.0), eachindex(x); scheduler = team)
    s = tmapreduce(i -> (@inbounds x[i]), +, eachindex(x); scheduler = team)
    v = tmapreduce(i -> fill(1.0, 1000), (a, b) -> a .+ b, 1:64; scheduler = team)
    return w, s, WeakRef(v)
end

@testset "no references after a loop" begin
    w, s, wv = loop_over_temporary()
    @test s == 10^6
    GC.gc(); GC.gc()
    @test w.value === nothing
    @test wv.value === nothing
    if NW > 1
        pool = @atomic ThreadTeams.POOL.pool
        @test all(isempty, values(pool.buffers))
        # the slots are undefined again, as a fresh `RefValue{F}()` is (except for isbits
        # chunk functions, which hold no references)
        @test all(slot -> isbitstype(eltype(slot)) || !isdefined(slot, :x), values(pool.slots))
        @test any(slot -> !isdefined(slot, :x), values(pool.slots))
    end
end
