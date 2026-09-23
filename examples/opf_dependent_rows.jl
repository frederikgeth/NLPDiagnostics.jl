using Ipopt
using JuMP
using NLPDiagnostics
using NLPDiagnostics.Advanced
using PowerModels
using SHA

import MathOptInterface as MOI

const CASE3_SOLVER_OPTIONS = Dict(
    "print_level" => 0,
    "sb" => "yes",
    "tol" => 1.0e-8,
    "max_iter" => 500,
)
const CASE3_SOURCE_SHA256 =
    "d2173e913ab554dd4fe6cfdcf17bcc5d3f882b769bcdfc37470cb273f0df507b"

function run_case3_dependent_rows()
    case_path = joinpath(pkgdir(NLPDiagnostics), "test", "fixtures",
        "power_repair_case3.m")
    license_path = replace(case_path, ".m" => ".LICENSE")
    @assert isfile(case_path) && isfile(license_path)
    source_sha256 = bytes2hex(sha256(read(case_path)))
    @assert source_sha256 == CASE3_SOURCE_SHA256
    PowerModels.silence()
    data = PowerModels.parse_file(case_path)
    pm = PowerModels.instantiate_model(deepcopy(data),
        PowerModels.ACPPowerModel, PowerModels.build_opf)
    model = pm.model
    set_optimizer(model, optimizer_with_attributes(Ipopt.Optimizer,
        CASE3_SOLVER_OPTIONS...))
    optimize!(model)
    termination = termination_status(model)
    primal = primal_status(model)
    @assert termination in (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
    @assert primal == MOI.FEASIBLE_POINT

    endpoint = analyze_solver_result(model; label = "case3 Ipopt endpoint")
    @assert endpoint.point !== nothing
    evaluation = evaluate_numerical(model, endpoint.point)
    activity = constraint_feasibility_summary(model, evaluation;
        feasibility_tolerance = 1.0e-6,
        active_tolerance = 1.0e-6)
    equality_rows = [record.row for record in activity.activities
        if record.classification == :equality]
    active_rows = [record.row for record in activity.activities
        if record.classification in
            (:equality, :active_lower, :active_upper, :active_lower_upper)]
    @assert !isempty(equality_rows)
    @assert length(active_rows) <= 128

    function localize(rows, tolerance, provenance)
        return dependent_row_localization(evaluation; rows,
            scaling = :none, relative_tolerance = 0.0,
            absolute_tolerance = tolerance,
            max_rows = 128, provenance)
    end
    equality = localize(equality_rows, 1.0e-8, :case3_equality_scope)
    active = localize(active_rows, 1.0e-8, :case3_active_scope)
    active_tight = localize(active_rows, 1.0e-10,
        :case3_active_tighter_threshold)
    @assert equality.available && active.available && active_tight.available

    return (; model, source_sha256, termination, primal, endpoint, evaluation,
        activity, equality_rows, active_rows, equality, active, active_tight,
        solver_options = copy(CASE3_SOLVER_OPTIONS))
end

if abspath(PROGRAM_FILE) == @__FILE__
    case = run_case3_dependent_rows()
    localized = [case.activity.activities[row] for row in case.active.rows]
    println((source_sha256 = case.source_sha256,
        point = case.endpoint.point.label,
        activity_complete = case.activity.complete,
        violations = count(record -> record.classification == :violated,
            case.activity.activities),
        equality_rows = length(case.equality_rows),
        active_rows = length(case.active_rows),
        equality_rank = case.equality.selected_rank,
        active_rank = case.active.selected_rank,
        localized_rows = case.active.rows,
        variable_names = [name(VariableRef(case.model,
            MOI.VariableIndex(record.source.index))) for record in localized],
        localized_sets = [(record.source.function_type,
            record.source.set_type, record.source.index,
            record.lower, record.upper) for record in localized],
        tight_rows = case.active_tight.rows))
end
