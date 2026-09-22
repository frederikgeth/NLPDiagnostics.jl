using Documenter
using Ipopt
using JuMP
using NLPDiagnostics
using PowerModels

include("generate_finding_reference.jl")
FindingReference.check()

DocMeta.setdocmeta!(
    NLPDiagnostics,
    :DocTestSetup,
    :(using NLPDiagnostics);
    recursive = true,
)

makedocs(
    modules = [NLPDiagnostics],
    authors = "NLPDiagnostics contributors",
    sitename = "NLPDiagnostics.jl",
    clean = true,
    doctest = true,
    checkdocs = :none,
    warnonly = false,
    format = Documenter.HTML(
        canonical = "https://frederikgeth.github.io/NLPDiagnostics.jl/stable/",
        edit_link = "main",
        prettyurls = get(ENV, "CI", "false") == "true",
        assets = ["assets/custom.css"],
    ),
    pages = [
        "Home" => "index.md",
        "Start here" => [
            "Getting started" => "getting-started.md",
            "A research workflow" => "research-workflow.md",
            "Reading a report" => "how-to/reading-reports.md",
            "Diagnostic playbook" => "how-to/diagnostic-playbook.md",
        ],
        "Tutorials" => [
            "Your first diagnosis" => "tutorials/first-diagnosis.md",
            "Model failure or bad start?" => "tutorials/initialization.md",
            "From NLP evidence to OPF hypotheses" => "tutorials/opf-hypotheses.md",
            "A reproducible three-bus OPF investigation" => "tutorials/three-bus-opf.md",
        ],
        "Concepts" => [
            "Evidence and claims" => "concepts/evidence.md",
            "Rank, structure, and gauges" => "concepts/rank-and-gauges.md",
            "Glossary and notation" => "concepts/glossary.md",
        ],
        "Reference" => [
            "Core API" => "reference/api.md",
            "Finding codes" => "reference/finding-codes.md",
            "Experiment record" => "reference/experiment-record.md",
            "Scope and limitations" => "reference/limitations.md",
        ],
        "Research record" => "research/index.md",
    ],
)

if get(ENV, "GITHUB_ACTIONS", "false") == "true" &&
   get(ENV, "DOCUMENTER_DEPLOY", "false") == "true"
    deploydocs(
        repo = "github.com/frederikgeth/NLPDiagnostics.jl.git",
        devbranch = "main",
        push_preview = true,
    )
end
