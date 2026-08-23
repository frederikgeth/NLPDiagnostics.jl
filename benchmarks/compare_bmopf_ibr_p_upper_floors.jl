#!/usr/bin/env julia

"""Compare committed 30-bus and real-99-bus IBR upper floor summaries."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const DEFAULT_30BUS = joinpath(ROOT, "docs", "bmopf_30bus_endpoint_kkt_comparison_summary.json")
const DEFAULT_30BUS_GEOMETRY = joinpath(ROOT, "docs", "bmopf_30bus_ibr_p_upper_geometry_summary.json")
const DEFAULT_99BUS = joinpath(ROOT, "docs", "real_99bus_phase_only_campaign_summary.json")

function read_path(name, default)
    path = abspath(get(ENV, name, default))
    isfile(path) || error("summary file does not exist: $path")
    return path, read_summary(path; root = "/")
end

path_30bus, summary_30bus = read_path("NLPDIAGNOSTICS_30BUS_KKT_SUMMARY", DEFAULT_30BUS)
path_geometry, geometry_30bus = read_path("NLPDIAGNOSTICS_30BUS_GEOMETRY_SUMMARY", DEFAULT_30BUS_GEOMETRY)
path_99bus, summary_99bus = read_path("NLPDIAGNOSTICS_99BUS_CAMPAIGN_SUMMARY", DEFAULT_99BUS)

model_30bus = Float64[
    Float64(get(case, "endpoint_ibr_p_upper_row_residual", NaN))
    for case in get(summary_30bus, "cases", Any[])
]
physical_30bus = Float64[
    Float64(get(case, "target_physical_violation_max", NaN))
    for case in get(geometry_30bus, "cases", Any[])
]
model_99bus = Float64.(get(
    get(summary_99bus, "summary", Dict()),
    "ibr_p_upper_native_model_residual_floor",
    Any[],
))
physical_99bus = Float64.(get(
    get(summary_99bus, "summary", Dict()),
    "strict_physical_endpoint_max_violation_range",
    Any[],
))
all(isfinite, vcat(model_30bus, physical_30bus, model_99bus, physical_99bus)) ||
    error("floor summaries must be finite")

result = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-ibr-p-upper-cross-fixture-summary-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "thirty_bus_summary" => relpath(path_30bus, ROOT),
        "thirty_bus_geometry" => relpath(path_geometry, ROOT),
        "ninety_nine_bus_summary" => relpath(path_99bus, ROOT),
        "common_row_family" => "ibr_p_upper",
        "common_declared_physical_scale" => 1.0e6,
    ),
    "fixtures" => Dict(
        "30bus" => Dict(
            "snapshot_count" => length(model_30bus),
            "model_coordinate_residual_range" => [minimum(model_30bus), maximum(model_30bus)],
            "physical_violation_range" => [minimum(physical_30bus), maximum(physical_30bus)],
            "strict_kkt_acceptance_count" => count(
                get(case, "physical_kkt_acceptance_passed", false) === true
                for case in get(summary_30bus, "cases", Any[])
            ),
            "variable_count" => 704,
        ),
        "99bus" => Dict(
            "snapshot_count" => get(get(summary_99bus, "source", Dict()), "selected_snapshot_count", nothing),
            "model_coordinate_residual_range" => [minimum(model_99bus), maximum(model_99bus)],
            "physical_violation_range" => [minimum(physical_99bus), maximum(physical_99bus)],
            "strict_kkt_acceptance_count" => get(get(summary_99bus, "summary", Dict()), "reference_physical_solver_kkt_acceptance_count", nothing),
            "variable_count" => 1968,
        ),
    ),
    "comparison" => Dict(
        "model_floor_ranges_overlap" => max(minimum(model_30bus), minimum(model_99bus)) <= min(maximum(model_30bus), maximum(model_99bus)),
        "physical_violation_ranges_overlap" => max(minimum(physical_30bus), minimum(physical_99bus)) <= min(maximum(physical_30bus), maximum(physical_99bus)),
        "interpretation" => "The 30-bus and real-99-bus summaries report the same 1e6 declared physical scale and overlapping approximately 1e-8 model-coordinate and 1e-2 physical endpoint ranges for ibr_p_upper. This is cross-fixture scale evidence, not proof that the same mechanism or solver cause is present.",
        "qualification" => "The fixtures have different model sizes, endpoint contracts, and campaign histories. The comparison does not combine KKT acceptance counts into a common qualification or establish global convergence behavior.",
    ),
)
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_IBR_CROSS_FIXTURE_OUTPUT",
    joinpath(ROOT, "work", "bmopf-ibr-p-upper-cross-fixture-summary.json"),
))
write_json(output, result)
println("wrote cross-fixture IBR upper summary to $output")
