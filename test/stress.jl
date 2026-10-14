@testset "stress" begin
    x = zeros(16)
    for _ in 1:50_000
        add_one!(x)
    end
    @test all(==(50_000.0), x)
    s = 0.0
    for k in 1:10_000
        s += psum(x)
    end
    @test s == 10_000 * 16 * 50_000.0
end
