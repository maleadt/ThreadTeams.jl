using Aqua

@testset "Aqua" begin
    # `from_symbol(::Val{:team})` extends OhMyThreads' scheduler lookup for our symbols
    Aqua.test_all(ThreadTeams; piracies = (treat_as_own = [OhMyThreads.Schedulers.from_symbol],))
end
