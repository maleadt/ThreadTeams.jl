using Documenter
using ThreadTeams

makedocs(;
    sitename = "ThreadTeams.jl",
    modules = [ThreadTeams],
    authors = "Valentin Churavy",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://vchuravy.github.io/ThreadTeams.jl",
        edit_link = "main",
    ),
    pages = ["Home" => "index.md", "API" => "api.md"],
    checkdocs = :exports,
    warnonly = [:missing_docs],
)

deploydocs(; repo = "github.com/vchuravy/ThreadTeams.jl.git", push_preview = true)
