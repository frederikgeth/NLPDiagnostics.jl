# Getting started

NLPDiagnostics supports Julia 1.10 and later. During the research-prototype
phase, install it from its repository together with JuMP:

```julia
using Pkg
Pkg.add(url = "https://github.com/frederikgeth/NLPDiagnostics.jl")
Pkg.add("JuMP")
```

For work on a local checkout, activate your experiment environment and develop
the package into it:

```julia
using Pkg
Pkg.activate("my-experiment")
Pkg.develop(path = "/path/to/NLPDiagnostics.jl")
Pkg.add("JuMP")
```

## A minimal analysis

```@example getting_started
using JuMP, NLPDiagnostics

model = Model()
@variable(model, x >= 0)
@constraint(model, x <= 2)

report = analyze(model)
@assert report isa DiagnosticReport
length(report)
```

`analyze` takes a read-only snapshot through public MOI interfaces. It does not
solve or modify the model. Display a concise terminal report:

```@example getting_started
print(text_report(report; minimum_severity = SeverityInfo))
```

For programmatic work, keep the typed records:

```@example getting_started
records = report_data(report)
@assert records["findings"] isa Vector
sort!(collect(keys(records)))
```

## Choose evidence deliberately

Calling `analyze(model)` uses model-wide static and structural evidence. To ask
questions about values, derivatives, rank, or conditioning, supply an explicit
point or request analysis of complete model starts. Those conclusions are local
to that point.

```@example getting_started
point = evaluation_point(model, [1.0]; label = "candidate A")
local_report = analyze(model; point = point)
@assert local_report.metadata[:evaluation_point_label] == "candidate A"
length(local_report)
```

Next, work through [Your first diagnosis](tutorials/first-diagnosis.md). If your
experiment uses solver output, record the solver, options, tolerances, model
revision, and point provenance alongside the diagnostic report.
