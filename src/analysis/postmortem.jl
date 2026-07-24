"""One registered solver-specific postmortem adapter."""
struct SolverPostmortemAdapter
    name::Symbol
    matches::Function
    build::Function
end

const _SOLVER_POSTMORTEM_ADAPTERS = SolverPostmortemAdapter[]

"""
    register_solver_postmortem_adapter!(name, matches, build)

Internal extension hook for solver adapters. `matches(model)` must be a
read-only predicate, and `build(model)` must return a `SolverPostmortem`.
Registering a name again replaces that adapter, allowing extension reloads in
interactive development without accumulating duplicate candidates.
"""
function register_solver_postmortem_adapter!(
    name::Symbol,
    matches::Function,
    build::Function,
)
    filter!(adapter -> adapter.name != name, _SOLVER_POSTMORTEM_ADAPTERS)
    push!(_SOLVER_POSTMORTEM_ADAPTERS, SolverPostmortemAdapter(name, matches, build))
    return nothing
end

"""
    solver_postmortem(model)

Create a solver-specific `SolverPostmortem` from a completed optimizer model.
Optional solver extensions register a type-safe runtime predicate because some
solver MOI optimizer types are themselves defined in package extensions. The
generic core deliberately does not guess solver semantics from standard MOI
status codes alone.
"""
function solver_postmortem(model::MOI.AbstractOptimizer)
    for adapter in _SOLVER_POSTMORTEM_ADAPTERS
        adapter.matches(model) && return adapter.build(model)
    end
    throw(ArgumentError(
        "NLPDiagnostics has no postmortem adapter for optimizer $(typeof(model)). " *
        "Load a supported solver extension first.",
    ))
end

function _postmortem_evidence(postmortem::SolverPostmortem)
    return Evidence(
        "Solver postmortem record";
        details = [
            "solver" => postmortem.solver,
            "termination" => postmortem.termination,
            "raw_status" => postmortem.raw_status,
            "iterations" => postmortem.iterations,
            "objective_value" => postmortem.objective_value,
            "primal_residual" => postmortem.primal_residual,
            "dual_residual" => postmortem.dual_residual,
            "complementarity" => postmortem.complementarity,
            "restoration_attempted" => postmortem.restoration_attempted,
            "restoration_succeeded" => postmortem.restoration_succeeded,
        ],
    )
end

"""
    analyze_postmortem(postmortem; residual_tolerance = 1e-6)

Interpret a normalized solver postmortem without assuming the solver's status
is a mathematical proof. Solver-specific extensions are responsible for
constructing the record and retaining their native raw status.
"""
function analyze_postmortem(
    postmortem::SolverPostmortem;
    residual_tolerance::Real = 1.0e-6,
)
    tolerance = Float64(residual_tolerance)
    tolerance >= 0 || throw(ArgumentError("residual_tolerance must be nonnegative"))
    report = DiagnosticReport()
    report.metadata[:stage] = "postmortem"
    report.metadata[:solver] = postmortem.solver
    report.metadata[:termination] = string(postmortem.termination)
    evidence = [_postmortem_evidence(postmortem)]
    if postmortem.termination in (:infeasible, :locally_infeasible)
        push!(report, Finding(
            :solver_reported_infeasibility;
            severity = SeverityWarning,
            domain = MathematicalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) reported termination $(postmortem.termination).",
            why_it_matters = "The solver's feasibility search did not produce an acceptable point, but its status alone does not prove global model infeasibility.",
            evidence = evidence,
            suggested_actions = ["Run elastic feasibility and initialization diagnostics before concluding the model is infeasible."],
        ))
    elseif postmortem.termination in (:iteration_limit, :time_limit)
        push!(report, Finding(
            :solver_termination_limit;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "$(postmortem.solver) stopped at $(postmortem.termination).",
            why_it_matters = "The final iterate may still contain useful diagnostic evidence, but termination did not establish the requested convergence criterion.",
            evidence = evidence,
            suggested_actions = ["Inspect residual trends, scaling, and the final active set before increasing limits."],
        ))
    elseif postmortem.termination in (:numerical_failure, :invalid_number, :restoration_failed)
        push!(report, Finding(
            :solver_numerical_failure;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) reported numerical termination $(postmortem.termination).",
            why_it_matters = "Derivative-domain failures, scaling, degeneracy, or unstable evaluation may have interrupted the algorithm.",
            evidence = evidence,
            suggested_actions = ["Compare the final point with domain, derivative, scaling, and degeneracy diagnostics."],
        ))
    end
    if postmortem.restoration_attempted && postmortem.restoration_succeeded === false
        push!(report, Finding(
            :solver_restoration_unsuccessful;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) attempted restoration without reporting success.",
            why_it_matters = "The run encountered feasibility difficulty; restoration failure is a useful local clue, not an IIS certificate.",
            evidence = evidence,
            suggested_actions = ["Inspect violated constraints and try an elastic feasibility diagnostic."],
        ))
    end
    for (label, value) in (
        :primal => postmortem.primal_residual,
        :dual => postmortem.dual_residual,
        :complementarity => postmortem.complementarity,
    )
        isnothing(value) || value <= tolerance || push!(report, Finding(
            :large_solver_residual;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The recorded $(label) residual is $value, above tolerance $tolerance.",
            why_it_matters = "The final solver iterate does not meet this recorded residual scale.",
            evidence = evidence,
            suggested_actions = ["Compare residual units and solver tolerances with model scaling."],
        ))
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""
    solver_log_observations(log)

Extract deliberately conservative line-level markers from raw solver log text.
The generic scanner recognizes only explicit restoration failures, reported
infeasibility, termination limits, invalid-number markers, and a small set of
numerical-failure phrases. Solver extensions may later add richer structured
parsers without changing this raw-evidence boundary.
"""
function solver_log_observations(log::AbstractString)
    observations = SolverLogObservation[]
    for (line_number, line) in enumerate(eachline(IOBuffer(log)))
        normalized = lowercase(strip(line))
        isempty(normalized) && continue
        category = if occursin("restoration failed", normalized)
            :restoration_failed
        elseif occursin("invalid number", normalized) ||
               occursin("nan", normalized) ||
               occursin("not a number", normalized) ||
               occursin("overflow", normalized) ||
               occursin("underflow", normalized)
            :invalid_number
        elseif occursin("infeasible", normalized)
            :reported_infeasibility
        elseif occursin("maximum iterations", normalized) ||
               occursin("iteration limit", normalized) ||
               occursin("time limit", normalized) ||
               occursin("maximum cpu time", normalized) ||
               occursin("maximum wall", normalized)
            :termination_limit
        elseif occursin("error in step", normalized) ||
               occursin("factorization failed", normalized) ||
               occursin("singular matrix", normalized) ||
               occursin("division by zero", normalized)
            :numerical_failure
        else
            nothing
        end
        isnothing(category) || push!(
            observations,
            SolverLogObservation(line_number, category, String(line)),
        )
    end
    return observations
end

function _solver_log_evidence(
    solver::AbstractString,
    category::Symbol,
    observations::Vector{SolverLogObservation},
    max_evidence_lines::Int,
)
    retained = first(observations, min(length(observations), max_evidence_lines))
    return [
        Evidence(
            "Solver log line $(observation.line)";
            details = [
                "solver" => solver,
                "category" => category,
                "line" => observation.line,
                "text" => observation.text,
            ],
        ) for observation in retained
    ]
end

"""
    analyze_solver_log(solver, log; max_evidence_lines = 20)

Turn explicit raw-log markers into evidence-first findings. The scanner does
not parse iteration tables or infer residuals. Findings describe what text was
observed in a log and never upgrade a solver message to a feasibility,
optimality, or physical certificate.
"""
function analyze_solver_log(
    solver::AbstractString,
    log::AbstractString;
    max_evidence_lines::Integer = 20,
)
    max_evidence_lines > 0 ||
        throw(ArgumentError("max_evidence_lines must be positive"))
    grouped = Dict{Symbol,Vector{SolverLogObservation}}()
    for observation in solver_log_observations(log)
        push!(get!(grouped, observation.category, SolverLogObservation[]), observation)
    end
    report = DiagnosticReport()
    report.metadata[:stage] = "solver_log"
    report.metadata[:solver] = String(solver)
    report.metadata[:recognized_log_observation_count] = string(
        sum(length, values(grouped)),
    )
    for category in sort!(collect(keys(grouped)); by = string)
        observations = grouped[category]
        evidence = _solver_log_evidence(
            solver,
            category,
            observations,
            Int(max_evidence_lines),
        )
        count_text = "$(length(observations)) matching log line(s)"
        if category == :restoration_failed
            push!(report, Finding(
                :solver_log_restoration_failure;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text reporting restoration failure.",
                why_it_matters = "Restoration difficulty is a local solver observation, not an IIS or infeasibility certificate.",
                evidence = evidence,
                suggested_actions = ["Inspect the final point and run elastic feasibility diagnostics."],
            ))
        elseif category == :reported_infeasibility
            push!(report, Finding(
                :solver_log_reported_infeasibility;
                severity = SeverityWarning,
                domain = MathematicalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text mentioning infeasibility.",
                why_it_matters = "A solver log message records its local search outcome; it does not prove global model infeasibility.",
                evidence = evidence,
                suggested_actions = ["Compare with initialization, domain, and elastic feasibility diagnostics."],
            ))
        elseif category == :termination_limit
            push!(report, Finding(
                :solver_log_termination_limit;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text indicating a termination limit.",
                why_it_matters = "The run ended before the requested convergence criterion was established.",
                evidence = evidence,
                suggested_actions = ["Inspect residual trends and scaling before increasing solver limits."],
            ))
        elseif category == :invalid_number
            push!(report, Finding(
                :solver_log_invalid_number;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text indicating invalid or unstable numerical evaluation.",
                why_it_matters = "The logged text may reflect a value or derivative domain failure, overflow, or another evaluation instability.",
                evidence = evidence,
                suggested_actions = ["Evaluate expression and derivative-domain diagnostics at the implicated iterate."],
            ))
        elseif category == :numerical_failure
            push!(report, Finding(
                :solver_log_numerical_failure;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceMedium,
                observation = "$(solver) log contains $count_text indicating numerical failure.",
                why_it_matters = "The precise cause is not determined by this generic text marker alone.",
                evidence = evidence,
                suggested_actions = ["Compare domain, derivative, scaling, and degeneracy evidence at the final point."],
            ))
        end
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function _log_float(token)
    return tryparse(Float64, replace(token, 'D' => 'E', 'd' => 'e'))
end

function _iteration_token(token)
    matched = match(r"^(\d+)([A-Za-z]*)$", token)
    isnothing(matched) && return nothing
    phase = isempty(matched.captures[2]) ? :regular : :annotated
    return parse(Int, matched.captures[1]), phase
end

"""
    solver_iteration_records(log)

Parse complete rows beneath the documented Ipopt or MadNLP iteration headers.
Rows with missing or nonnumeric required fields are kept out rather than being
partially guessed. `phase == :annotated` records suffixes such as Ipopt's
restoration-row marker; the suffix meaning remains solver-specific.
"""
function solver_iteration_records(log::AbstractString)
    records = SolverIterationRecord[]
    format = nothing
    for (line_number, line) in enumerate(eachline(IOBuffer(log)))
        normalized = lowercase(strip(line))
        if occursin("iter", normalized) && occursin("objective", normalized) &&
           occursin("inf_pr", normalized) && occursin("inf_du", normalized)
            format = occursin("||d||", normalized) ? :ipopt :
                     occursin("inf_compl", normalized) ? :madnlp : nothing
            continue
        end
        isnothing(format) && continue
        fields = split(strip(line))
        length(fields) >= 9 || continue
        token = _iteration_token(fields[1])
        isnothing(token) && continue
        iteration, phase = token
        objective, primal, dual = _log_float.(fields[2:4])
        any(isnothing, (objective, primal, dual)) && continue
        if format == :ipopt
            primal_step = _log_float(fields[9])
            isnothing(primal_step) && continue
            push!(records, SolverIterationRecord(
                :ipopt, line_number, iteration, phase, objective, primal, dual,
                nothing, primal_step, String(line),
            ))
        else
            complementarity = _log_float(fields[5])
            primal_step = _log_float(fields[8])
            any(isnothing, (complementarity, primal_step)) && continue
            push!(records, SolverIterationRecord(
                :madnlp, line_number, iteration, phase, objective, primal, dual,
                complementarity, primal_step, String(line),
            ))
        end
    end
    return records
end

"""
    analyze_solver_iterations(solver, log; residual_tolerance = 1e-6)

Report parsed iteration-trace evidence without asserting that log columns are
identical across solvers. A final recorded residual above tolerance is a log
observation only; an increasing final residual is a heuristic trace warning.
"""
function analyze_solver_iterations(
    solver::AbstractString,
    log::AbstractString;
    residual_tolerance::Real = 1e-6,
)
    tolerance = Float64(residual_tolerance)
    tolerance >= 0 || throw(ArgumentError("residual_tolerance must be nonnegative"))
    records = solver_iteration_records(log)
    report = DiagnosticReport()
    report.metadata[:stage] = "solver_iterations"
    report.metadata[:solver] = String(solver)
    report.metadata[:parsed_iteration_count] = string(length(records))
    isempty(records) && return report
    final = last(records)
    residuals = [max(record.primal_infeasibility, record.dual_infeasibility) for record in records]
    evidence = [Evidence(
        "Solver iteration log line $(final.line)";
        details = ["solver" => solver, "format" => final.format, "iteration" => final.iteration,
                   "line" => final.line, "text" => final.text,
                   "primal_infeasibility" => final.primal_infeasibility,
                   "dual_infeasibility" => final.dual_infeasibility],
    )]
    if residuals[end] > tolerance
        push!(report, Finding(:solver_iteration_large_final_residual;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The final parsed $(solver) iteration row has residual $((residuals[end])) above tolerance $tolerance.",
            why_it_matters = "This is a recorded log column, not an independently verified KKT residual.",
            evidence = evidence,
            suggested_actions = ["Compare the final point with numerical and active-set diagnostics."],
        ))
    end
    if length(records) >= 3 && residuals[end] > tolerance && residuals[end] > 10 * minimum(residuals)
        push!(report, Finding(:solver_iteration_residual_regression;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = HeuristicInterpretation, confidence = ConfidenceMedium,
            observation = "The final parsed residual exceeds the trace minimum by more than a factor of ten.",
            why_it_matters = "This may indicate late-iteration instability or a phase change, but the generic parser cannot establish its cause.",
            evidence = evidence,
            suggested_actions = ["Inspect the surrounding solver log and compare scaling and domain evidence."],
        ))
    end
    return report
end
