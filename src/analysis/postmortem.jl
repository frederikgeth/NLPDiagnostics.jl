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
    elseif postmortem.termination in (:acceptable_solution, :feasible_point)
        push!(report, Finding(
            :solver_nonfinal_feasible_termination;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) reported termination $(postmortem.termination).",
            why_it_matters = "The solver reported a feasible or acceptable point, but this native status does not establish the requested optimality or tolerance criterion.",
            evidence = evidence,
            suggested_actions = ["Inspect recorded residuals, objective value, and solver tolerances before accepting the point as a final solution."],
        ))
    elseif postmortem.termination == :interrupted
        push!(report, Finding(
            :solver_interrupted;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "$(postmortem.solver) reported an interrupted run.",
            why_it_matters = "The solver did not select this as a mathematical or numerical termination; any final iterate must be interpreted as partial-run evidence.",
            evidence = evidence,
            suggested_actions = ["Inspect the stop source and retained final-point diagnostics before rerunning or changing the model."],
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
    elseif postmortem.termination == :diverging_iterates
        push!(report, Finding(
            :solver_diverging_iterates;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) reported diverging iterates.",
            why_it_matters = "This native termination records the solver's local trajectory interpretation; it does not prove an objective ray, physical instability, or global model failure.",
            evidence = evidence,
            suggested_actions = ["Inspect bounds, domain margins, scaling, and iteration residuals at captured points before classifying the divergence."],
        ))
    elseif postmortem.termination == :slow_progress
        push!(report, Finding(
            :solver_slow_progress;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) reported slow progress.",
            why_it_matters = "Slow progress is a local algorithmic outcome that can arise from scaling, flat directions, active-set degeneracy, or conservative step control.",
            evidence = evidence,
            suggested_actions = ["Compare row and column scaling, active-set rank, and reduced-Hessian evidence before changing solver tolerances."],
        ))
    elseif postmortem.termination in (:invalid_model, :invalid_option)
        push!(report, Finding(
            :solver_model_or_option_rejected;
            severity = SeverityError,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) reported termination $(postmortem.termination).",
            why_it_matters = "The solver rejected the supplied representation or an option before establishing an optimization conclusion. Its status does not by itself identify the offending model component.",
            evidence = evidence,
            suggested_actions = ["Inspect the retained raw status, solver option configuration, and MOI/JuMP model support before diagnosing mathematical feasibility."],
        ))
    elseif postmortem.termination == :memory_limit
        push!(report, Finding(
            :solver_memory_limit;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) stopped at a memory limit.",
            why_it_matters = "This is a resource termination, not evidence that the formulation is infeasible, degenerate, or mathematically ill-conditioned.",
            evidence = evidence,
            suggested_actions = ["Inspect model size, sparsity, derivative representation, and solver linear-algebra settings before changing the mathematical formulation."],
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
    elseif postmortem.termination in (:optimal, :locally_optimal)
        # A recognized successful status needs no generic warning. Its raw
        # status and residual evidence remain available in the report.
    else
        push!(report, Finding(
            :solver_unclassified_termination;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(postmortem.solver) reported unclassified termination $(postmortem.termination).",
            why_it_matters = "The normalized status is retained, but the generic core has no solver-independent interpretation for it. It must not be silently treated as success, infeasibility, or a numerical failure.",
            evidence = evidence,
            suggested_actions = [
                "Inspect the raw status and solver-specific documentation, then extend the optional adapter if this status has stable semantics.",
            ],
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
The generic scanner recognizes explicit restoration attempts and failures,
reported infeasibility or unboundedness, diverging-iterate markers, termination
limits, invalid-number markers, and a small set of numerical-failure phrases.
Solver extensions may later add richer structured parsers without changing
this raw-evidence boundary.
"""
function solver_log_observations(log::AbstractString)
    observations = SolverLogObservation[]
    for (line_number, line) in enumerate(eachline(IOBuffer(log)))
        normalized = lowercase(strip(line))
        isempty(normalized) && continue
        category = if occursin("restoration failed", normalized)
            :restoration_failed
        elseif occursin("restoration phase", normalized) ||
               occursin("restoration is called", normalized)
            :restoration_attempted
        elseif occursin("overflow", normalized)
            :overflow_marker
        elseif occursin("underflow", normalized)
            :underflow_marker
        elseif occursin("invalid number", normalized) ||
               occursin("nan", normalized) ||
               occursin("not a number", normalized)
            :invalid_number
        elseif occursin("unbounded", normalized)
            :reported_unboundedness
        elseif occursin("diverging", normalized) || occursin("diverged", normalized)
            :diverging_iterates
        elseif occursin("infeasib", normalized)
            :reported_infeasibility
        elseif occursin("maximum iterations", normalized) ||
               occursin("maximum number of iterations", normalized) ||
               occursin("iteration limit", normalized) ||
               occursin("time limit", normalized) ||
               occursin("maximum cpu time", normalized) ||
               occursin("maximum wall", normalized)
            :termination_limit
        elseif occursin("singular matrix", normalized) ||
               occursin("singular jacobian", normalized) ||
               occursin("rank deficient", normalized)
            :linear_system_singularity
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
    analyze_postmortem_log_consistency(postmortem, log;
                                       max_evidence_lines = 20,
                                       objective_agreement_factor = 100)

Compare a normalized final solver outcome with explicit raw-log failure markers.
This is a provenance screen, not a reconstruction of solver state: appended
logs and solver-specific status semantics can legitimately differ.
"""
function analyze_postmortem_log_consistency(
    postmortem::SolverPostmortem,
    log::AbstractString;
    max_evidence_lines::Integer = 20,
    objective_agreement_factor::Real = 100,
)
    max_evidence_lines > 0 || throw(ArgumentError("max_evidence_lines must be positive"))
    objective_agreement_factor > 1 || throw(
        ArgumentError("objective_agreement_factor must be greater than one"),
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "postmortem_log_consistency"
    report.metadata[:solver] = postmortem.solver
    report.metadata[:termination] = string(postmortem.termination)
    observations = solver_log_observations(log)
    report.metadata[:recognized_log_observation_count] = string(length(observations))
    successful_terminations = (:optimal, :locally_solved, :success)
    failure_categories = (
        :restoration_failed,
        :invalid_number,
        :numerical_failure,
        :reported_infeasibility,
        :reported_unboundedness,
        :diverging_iterates,
    )
    conflicting = [
        observation for observation in observations if observation.category in failure_categories
    ]
    report.metadata[:postmortem_log_conflicting_marker_count] = string(length(conflicting))
    if postmortem.termination in successful_terminations && !isempty(conflicting)
        categories = join(sort(unique(string(observation.category) for observation in conflicting)), ",")
        push!(report, Finding(:solver_postmortem_log_failure_marker_mismatch;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = HeuristicInterpretation, confidence = ConfidenceMedium,
            observation = "$(postmortem.solver) reports terminal status $(postmortem.termination), while the supplied log contains explicit failure marker(s): $categories.",
            why_it_matters = "The log may include an earlier restart, a recoverable phase, or solver-specific wording. The disagreement should be resolved before treating the final status and trace as one unambiguous run record.",
            evidence = vcat(
                [_postmortem_evidence(postmortem)],
                _solver_log_evidence(
                    postmortem.solver,
                    :postmortem_log_conflict,
                    conflicting,
                    Int(max_evidence_lines),
                ),
            ),
            suggested_actions = [
                "Verify log/run boundaries and solver status provenance before correlating final-point diagnostics with this trace.",
            ],
        ))
    end
    records = solver_iteration_records(log)
    report.metadata[:parsed_iteration_count] = string(length(records))
    if !isnothing(postmortem.iterations) && !isempty(records)
        final_segment = last(solver_iteration_segments(records))
        final_iteration = final_segment.final_iteration
        compatible = postmortem.iterations in (final_iteration, final_iteration + 1)
        report.metadata[:postmortem_iterations] = string(postmortem.iterations)
        report.metadata[:final_segment_iteration] = string(final_iteration)
        report.metadata[:postmortem_log_iteration_count_compatible] = string(compatible)
        if !compatible
            push!(report, Finding(:solver_postmortem_log_iteration_count_mismatch;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = HeuristicInterpretation, confidence = ConfidenceMedium,
                observation = "$(postmortem.solver) reports $(postmortem.iterations) iterations, while the final parsed log segment ends at printed iteration $final_iteration.",
                why_it_matters = "Solver counters can have different conventions, but neither the same count nor the common zero-based offset matches. The records may come from different runs or use different iteration semantics.",
                evidence = [
                    _postmortem_evidence(postmortem),
                    Evidence("Final parsed solver-log segment"; details = [
                        "final_segment_iteration" => final_iteration,
                        "parsed_iteration_count" => length(records),
                        "final_segment_start_line" => final_segment.start_line,
                        "final_segment_end_line" => final_segment.end_line,
                    ]),
                ],
                suggested_actions = [
                    "Verify whether the postmortem counter and printed iteration table describe the same solve and counting convention.",
                ],
            ))
        end
    end
    if !isnothing(postmortem.objective_value) && !isempty(records)
        final_logged_objective = last(records).objective
        reported_objective = postmortem.objective_value
        smaller = min(abs(reported_objective), abs(final_logged_objective))
        larger = max(abs(reported_objective), abs(final_logged_objective))
        compatible = !(larger > 0 &&
                       (smaller == 0 || larger / smaller > objective_agreement_factor))
        report.metadata[:postmortem_objective_value] = string(reported_objective)
        report.metadata[:final_logged_objective] = string(final_logged_objective)
        report.metadata[:postmortem_log_objective_compatible] = string(compatible)
        report.metadata[:objective_agreement_factor] = string(objective_agreement_factor)
        if !compatible
            push!(report, Finding(:solver_postmortem_log_objective_mismatch;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = HeuristicInterpretation, confidence = ConfidenceMedium,
                observation = "$(postmortem.solver) reports final objective $reported_objective, while the final parsed log row reports $final_logged_objective.",
                why_it_matters = "The printed value may be scaled, barrier-augmented, rounded, or from a differently timed point. A large discrepancy should be resolved before relating the postmortem to this trace.",
                evidence = [
                    _postmortem_evidence(postmortem),
                    Evidence("Final parsed solver-log row"; details = [
                        "line" => last(records).line,
                        "iteration" => last(records).iteration,
                        "logged_objective" => final_logged_objective,
                        "objective_agreement_factor" => objective_agreement_factor,
                    ]),
                ],
                suggested_actions = [
                    "Verify objective scaling, barrier or penalty conventions, and final-point timing before comparing these values.",
                ],
            ))
        end
    end
    return report
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
        elseif category == :restoration_attempted
            push!(report, Finding(
                :solver_log_restoration_attempted;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text reporting a restoration-phase attempt.",
                why_it_matters = "Restoration entry is a local solver event. It can motivate feasibility and domain checks, but does not by itself establish infeasibility or restoration failure.",
                evidence = evidence,
                suggested_actions = [
                    "Inspect nearby residual and step-trace evidence.",
                    "Compare the associated point with elastic feasibility and expression-domain diagnostics when available.",
                ],
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
        elseif category == :reported_unboundedness
            push!(report, Finding(
                :solver_log_reported_unboundedness;
                severity = SeverityWarning,
                domain = MathematicalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text mentioning unboundedness.",
                why_it_matters = "A solver message records its local termination interpretation; it does not prove a global objective ray or exclude a numerical or scaling failure.",
                evidence = evidence,
                suggested_actions = ["Compare with static objective-ray diagnostics, declared bounds, and final-point domain evidence."],
            ))
        elseif category == :diverging_iterates
            push!(report, Finding(
                :solver_log_diverging_iterates;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceMedium,
                observation = "$(solver) log contains $count_text reporting diverging iterates.",
                why_it_matters = "The raw marker establishes neither an objective ray nor a physical instability; it motivates checking bounds, domain margins, scaling, and residual traces.",
                evidence = evidence,
                suggested_actions = ["Inspect iteration residual trends, variable bound margins, and expression-domain fingerprints at captured iterates."],
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
        elseif category == :overflow_marker
            push!(report, Finding(
                :solver_log_overflow_marker;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text mentioning overflow.",
                why_it_matters = "The text records a floating-point range event, but does not identify the expression, precision, or scaling convention responsible.",
                evidence = evidence,
                suggested_actions = [
                    "Inspect exponential and power fingerprints at captured iterates.",
                    "Compare variable units, scaling, and numeric precision before attributing the event to a formulation error.",
                ],
            ))
        elseif category == :underflow_marker
            push!(report, Finding(
                :solver_log_underflow_marker;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text mentioning underflow.",
                why_it_matters = "Underflow can erase small values or derivative contributions, but the generic log text does not establish whether this changed the solver's mathematical conclusion.",
                evidence = evidence,
                suggested_actions = [
                    "Inspect small-scale expression fingerprints and derivative magnitudes at captured iterates.",
                    "Review scaling and tolerance semantics before treating small terms as negligible.",
                ],
            ))
        elseif category == :linear_system_singularity
            push!(report, Finding(
                :solver_log_linear_system_singularity;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "$(solver) log contains $count_text reporting a singular or rank-deficient linear system.",
                why_it_matters = "This records a solver linear-algebra event at a local state; it does not prove that the model Jacobian is globally or structurally singular.",
                evidence = evidence,
                suggested_actions = [
                    "Compare local Jacobian rank, nullspace, and active-set diagnostics at an explicitly captured point.",
                    "Inspect scaling-sensitive rank evidence before classifying the event as mathematical degeneracy.",
                ],
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
    solver_iteration_segments(records)

Split parsed rows in log order whenever a printed iteration number decreases.
The resulting boundaries preserve evidence about appended or restarted traces
without inferring why the solver restarted.
"""
function solver_iteration_segments(records::AbstractVector{SolverIterationRecord})
    isempty(records) && return SolverIterationSegment[]
    starts = Int[1]
    for position in 2:length(records)
        records[position].iteration < records[position - 1].iteration &&
            push!(starts, position)
    end
    segments = SolverIterationSegment[]
    for (segment_index, start) in enumerate(starts)
        stop = segment_index == length(starts) ? length(records) : starts[segment_index + 1] - 1
        rows = @view records[start:stop]
        push!(segments, SolverIterationSegment(
            first(rows).line,
            last(rows).line,
            length(rows),
            first(rows).iteration,
            last(rows).iteration,
            sort!(unique(record.format for record in rows); by = string),
            count(record -> record.phase == :annotated, rows),
        ))
    end
    return segments
end

"""
    solver_iteration_summary(records)

Summarize parsed solver iteration rows in log order. Returns `nothing` for an
empty trace because no initial or final row exists to summarize.
"""
function solver_iteration_summary(records::AbstractVector{SolverIterationRecord})
    isempty(records) && return nothing
    first_record = first(records)
    final_record = last(records)
    segments = solver_iteration_segments(records)
    return SolverIterationSummary(
        length(records),
        sort!(unique(record.format for record in records); by = string),
        first_record.iteration,
        final_record.iteration,
        first_record.primal_infeasibility,
        final_record.primal_infeasibility,
        minimum(record.primal_infeasibility for record in records),
        first_record.dual_infeasibility,
        final_record.dual_infeasibility,
        minimum(record.dual_infeasibility for record in records),
        count(record -> record.phase == :annotated, records),
        length(segments),
    )
end

"""
    analyze_solver_iterations(solver, log; residual_tolerance = 1e-6,
                              stagnation_window = 5,
                              stagnation_improvement_factor = 2)

Report parsed iteration-trace evidence without asserting that log columns are
identical across solvers. A final recorded residual above tolerance is a log
observation only; increasing and tail-stagnation residual patterns are
heuristic trace warnings.
"""
function analyze_solver_iterations(
    solver::AbstractString,
    log::AbstractString;
    residual_tolerance::Real = 1e-6,
    stagnation_window::Integer = 5,
    stagnation_improvement_factor::Real = 2,
    small_primal_step_threshold::Real = 1e-8,
    residual_imbalance_factor::Real = 100,
)
    tolerance = Float64(residual_tolerance)
    tolerance >= 0 || throw(ArgumentError("residual_tolerance must be nonnegative"))
    stagnation_window >= 3 ||
        throw(ArgumentError("stagnation_window must be at least three"))
    stagnation_improvement_factor > 1 ||
        throw(ArgumentError("stagnation_improvement_factor must exceed one"))
    small_primal_step_threshold >= 0 ||
        throw(ArgumentError("small_primal_step_threshold must be nonnegative"))
    residual_imbalance_factor > 1 ||
        throw(ArgumentError("residual_imbalance_factor must exceed one"))
    records = solver_iteration_records(log)
    report = DiagnosticReport()
    report.metadata[:stage] = "solver_iterations"
    report.metadata[:solver] = String(solver)
    report.metadata[:parsed_iteration_count] = string(length(records))
    summary = solver_iteration_summary(records)
    isnothing(summary) && return report
    report.metadata[:iteration_formats] = join(string.(summary.formats), ",")
    report.metadata[:first_parsed_iteration] = string(summary.first_iteration)
    report.metadata[:final_parsed_iteration] = string(summary.final_iteration)
    report.metadata[:minimum_logged_primal_infeasibility] =
        string(summary.minimum_primal_infeasibility)
    report.metadata[:minimum_logged_dual_infeasibility] =
        string(summary.minimum_dual_infeasibility)
    report.metadata[:annotated_iteration_row_count] = string(summary.annotated_row_count)
    report.metadata[:iteration_segment_count] = string(summary.segment_count)
    report.metadata[:stagnation_window] = string(stagnation_window)
    report.metadata[:stagnation_improvement_factor] =
        string(stagnation_improvement_factor)
    report.metadata[:small_primal_step_threshold] =
        string(small_primal_step_threshold)
    report.metadata[:residual_imbalance_factor] = string(residual_imbalance_factor)
    final = last(records)
    final_segment = last(solver_iteration_segments(records))
    final_segment_records = records[
        findfirst(record -> record.line == final_segment.start_line, records):end
    ]
    report.metadata[:final_segment_start_line] = string(final_segment.start_line)
    report.metadata[:final_segment_end_line] = string(final_segment.end_line)
    report.metadata[:final_segment_record_count] = string(length(final_segment_records))
    report.metadata[:final_segment_first_iteration] = string(final_segment.first_iteration)
    report.metadata[:final_segment_final_iteration] = string(final_segment.final_iteration)
    residuals = [
        max(record.primal_infeasibility, record.dual_infeasibility) for
        record in final_segment_records
    ]
    final_segment_annotated = count(
        record -> record.phase == :annotated,
        final_segment_records,
    )
    report.metadata[:final_segment_annotated_iteration_row_count] =
        string(final_segment_annotated)
    evidence = [Evidence(
        "Solver iteration log line $(final.line)";
        details = ["solver" => solver, "format" => final.format, "iteration" => final.iteration,
                   "line" => final.line, "text" => final.text,
                   "primal_infeasibility" => final.primal_infeasibility,
                   "dual_infeasibility" => final.dual_infeasibility,
                   "final_segment_start_line" => final_segment.start_line,
                   "final_segment_end_line" => final_segment.end_line],
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
    if final_segment_annotated > 0
        push!(report, Finding(:solver_iteration_annotated_rows;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The final parsed $(solver) trace segment contains $final_segment_annotated row(s) with a solver-specific iteration suffix annotation.",
            why_it_matters = "The parser preserves the annotation as trace evidence, but does not assign it a generic restoration, regularization, or failure meaning.",
            evidence = vcat(evidence, [Evidence("Final trace-segment suffix annotations"; details = [
                "annotated_row_count" => final_segment_annotated,
                "final_segment_row_count" => length(final_segment_records),
                "phases" => join(string.(unique(record.phase for record in final_segment_records)), ","),
            ])]),
            suggested_actions = [
                "Inspect the solver's documentation and surrounding raw log lines for the suffix meaning.",
                "Correlate the annotated rows with explicit captured points before interpreting their numerical state.",
            ],
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
    window_start = max(1, length(residuals) - stagnation_window + 1)
    tail_residuals = @view residuals[window_start:end]
    if length(tail_residuals) >= 3 && minimum(tail_residuals) > tolerance &&
       tail_residuals[1] / minimum(tail_residuals) < stagnation_improvement_factor
        push!(report, Finding(:solver_iteration_residual_stagnation;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = HeuristicInterpretation, confidence = ConfidenceMedium,
            observation = "The final parsed $(solver) trace segment shows less than a factor of $(stagnation_improvement_factor) residual improvement across its final $(length(tail_residuals)) rows, all above tolerance $tolerance.",
            why_it_matters = "This is a log-local progress heuristic, not a statement about convergence, feasibility, or the reason progress slowed.",
            evidence = vcat(evidence, [Evidence("Final trace-segment residual window"; details = [
                "window_row_count" => length(tail_residuals),
                "window_first_residual" => first(tail_residuals),
                "window_minimum_residual" => minimum(tail_residuals),
                "window_final_residual" => last(tail_residuals),
                "improvement_factor_threshold" => stagnation_improvement_factor,
                "residual_tolerance" => tolerance,
            ])]),
            suggested_actions = [
                "Compare the same rows with scaling, derivative-domain, and active-set diagnostics.",
                "Inspect solver-specific step acceptance and restoration text before assigning a cause.",
            ],
        ))
    end
    tail_steps = [record.primal_step for record in
                  final_segment_records[window_start:end]]
    if length(tail_steps) >= 3 && minimum(tail_residuals) > tolerance &&
       all(step -> step <= small_primal_step_threshold, tail_steps)
        push!(report, Finding(:solver_iteration_small_primal_steps;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = HeuristicInterpretation, confidence = ConfidenceMedium,
            observation = "The final parsed $(solver) trace segment has $(length(tail_steps)) consecutive logged primal steps at or below $small_primal_step_threshold while its residual remains above tolerance $tolerance.",
            why_it_matters = "Repeated small accepted primal steps with unresolved printed residuals can indicate a stalled search, but log column semantics and solver phases remain solver-specific.",
            evidence = vcat(evidence, [Evidence("Final trace-segment primal-step window"; details = [
                "window_row_count" => length(tail_steps),
                "maximum_primal_step" => maximum(tail_steps),
                "minimum_residual" => minimum(tail_residuals),
                "small_primal_step_threshold" => small_primal_step_threshold,
                "residual_tolerance" => tolerance,
            ])]),
            suggested_actions = [
                "Inspect line-search, restoration, and regularization messages around these rows.",
                "Compare domain margins, derivative magnitudes, and scaling at explicitly captured iterates.",
            ],
        ))
    end
    tail_primal = [record.primal_infeasibility for record in
                   final_segment_records[window_start:end]]
    tail_dual = [record.dual_infeasibility for record in
                 final_segment_records[window_start:end]]
    primal_dominant = length(tail_primal) >= 3 &&
                      all(primal > tolerance &&
                          primal / max(dual, eps(Float64)) >= residual_imbalance_factor
                          for (primal, dual) in zip(tail_primal, tail_dual))
    dual_dominant = length(tail_dual) >= 3 &&
                    all(dual > tolerance &&
                        dual / max(primal, eps(Float64)) >= residual_imbalance_factor
                        for (primal, dual) in zip(tail_primal, tail_dual))
    if primal_dominant || dual_dominant
        dominant = primal_dominant ? :primal : :dual
        dominant_values = primal_dominant ? tail_primal : tail_dual
        subordinate_values = primal_dominant ? tail_dual : tail_primal
        push!(report, Finding(:solver_iteration_residual_imbalance;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The final parsed $(solver) trace segment has $(length(dominant_values)) consecutive rows where logged $(dominant) infeasibility exceeds the other printed residual by at least a factor of $residual_imbalance_factor.",
            why_it_matters = "This is a trace observation that can help prioritize feasibility versus stationarity diagnostics, but log-column scaling and solver semantics prevent a generic causal interpretation.",
            evidence = vcat(evidence, [Evidence("Final trace-segment residual imbalance"; details = [
                "dominant_residual" => dominant,
                "window_row_count" => length(dominant_values),
                "minimum_dominant_residual" => minimum(dominant_values),
                "maximum_subordinate_residual" => maximum(subordinate_values),
                "imbalance_factor_threshold" => residual_imbalance_factor,
                "residual_tolerance" => tolerance,
            ])]),
            suggested_actions = [
                dominant == :primal ?
                "Inspect constraint feasibility, domain margins, and restoration evidence at captured iterates." :
                "Inspect derivative domains, stationarity scaling, and active-set rank evidence at captured iterates.",
                "Compare the printed columns with recomputed point diagnostics only after checking their scaling semantics.",
            ],
        ))
    end
    return report
end

"""
    bind_iteration_points(records, points)

Bind caller-provided points to parsed iterations; logs never create points.
Ordinary integer keys select every row with that printed iteration number. For
appended or restarted logs, use `(segment, iteration)` keys instead, where
segments are numbered by `solver_iteration_segments(records)`.
"""
function bind_iteration_points(
    records::AbstractVector{SolverIterationRecord},
    points::AbstractDict,
)
    all(key -> key isa Integer ||
               (key isa Tuple && length(key) == 2 &&
                key[1] isa Integer && key[2] isa Integer), keys(points)) ||
        throw(ArgumentError(
            "iteration-point keys must be integers or (segment, iteration) integer tuples",
        ))
    all(value -> value isa EvaluationPoint, values(points)) ||
        throw(ArgumentError("iteration-point values must be EvaluationPoint values"))
    segments = solver_iteration_segments(records)
    segment_by_line = Dict{Int,Int}()
    for (segment, range) in enumerate(segments)
        for line in range.start_line:range.end_line
            segment_by_line[line] = segment
        end
    end
    bindings = IterationPointBinding[]
    for record in records
        segment = get(segment_by_line, record.line, 1)
        key = (segment, record.iteration)
        if haskey(points, key)
            push!(bindings, IterationPointBinding(
                record, points[key], segment, :segment_iteration,
            ))
        elseif haskey(points, record.iteration)
            push!(bindings, IterationPointBinding(
                record, points[record.iteration], segment, :iteration,
            ))
        end
    end
    return bindings
end

"""Run point-local numerical diagnostics at explicitly bound solver iterations."""
function analyze_iteration_points(
    model::MOI.ModelLike,
    bindings::AbstractVector{<:IterationPointBinding};
    cache::EvaluationCache = EvaluationCache(),
    residual_agreement_factor::Real = 100,
    objective_agreement_factor::Real = 100,
    trace_trend_factor::Real = 10,
    objective_trace_tolerance::Real = sqrt(eps(Float64)),
    relative_step::Union{Nothing,Real} = nothing,
    kwargs...,
)
    residual_agreement_factor > 1 || throw(
        ArgumentError("residual_agreement_factor must be greater than one"),
    )
    objective_agreement_factor > 1 || throw(
        ArgumentError("objective_agreement_factor must be greater than one"),
    )
    trace_trend_factor > 1 || throw(ArgumentError("trace_trend_factor must be greater than one"))
    objective_trace_tolerance >= 0 ||
        throw(ArgumentError("objective_trace_tolerance must be nonnegative"))
    !isnothing(relative_step) && relative_step <= 0 &&
        throw(ArgumentError("relative_step must be positive when supplied"))
    report = DiagnosticReport()
    report.metadata[:stage] = "iteration_points"
    report.metadata[:bound_iteration_count] = string(length(bindings))
    report.metadata[:bound_iteration_relative_step] = isnothing(relative_step) ?
                                                     "type_default" : string(relative_step)
    report.metadata[:bound_iteration_segment_selector_count] = string(count(
        binding -> binding.selector == :segment_iteration, bindings,
    ))
    report.metadata[:bound_iteration_legacy_selector_count] = string(count(
        binding -> binding.selector == :iteration, bindings,
    ))
    legacy_segments_by_iteration = Dict{Int,Set{Int}}()
    for binding in bindings
        binding.selector == :iteration || continue
        push!(get!(legacy_segments_by_iteration, binding.record.iteration, Set{Int}()),
              binding.segment)
    end
    for (iteration, segments) in sort(collect(legacy_segments_by_iteration); by = first)
        length(segments) > 1 || continue
        push!(report, Finding(:solver_iteration_restart_binding_ambiguous;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "A legacy iteration-number point binding selects printed iteration $iteration in $(length(segments)) restarted log segments.",
            why_it_matters = "Repeated printed iteration numbers do not identify one solver run, so the same supplied point may be compared with unrelated log rows.",
            evidence = [Evidence("Ambiguous legacy iteration-point binding"; details = [
                "iteration" => iteration,
                "segments" => join(sort(collect(segments)), ","),
                "selector" => :iteration,
            ])],
            suggested_actions = [
                "Use (segment, iteration) keys with bind_iteration_points for restarted or appended logs.",
            ],
        ))
    end
    trace = Tuple{IterationPointBinding,Float64}[]
    objective_trace = Tuple{IterationPointBinding,Float64}[]
    segment_qualified_metadata = length(unique([
        (binding.segment, binding.record.iteration) for binding in bindings
    ])) < length(bindings) || any(binding -> binding.segment != 1, bindings)
    for binding in bindings
        evaluation = isnothing(relative_step) ?
                     evaluate_numerical(model, binding.point; cache = cache) :
                     evaluate_numerical(
            model, binding.point; cache = cache, relative_step = relative_step,
        )
        point_report = analyze_numerical(model, evaluation; kwargs...)
        append!(report.findings, point_report.findings)
        feasibility = constraint_feasibility_summary(model, evaluation)
        violations = [
            activity.feasibility_violation for activity in feasibility.activities if
            !isnothing(activity.feasibility_violation)
        ]
        scalar_violation = isempty(violations) ? 0.0 : Float64(maximum(violations))
        coupled = coupled_set_feasibility_summary(
            model,
            evaluation,
        )
        coupled_violations = [
            activity.feasibility_violation for activity in coupled.activities if
            !isnothing(activity.feasibility_violation)
        ]
        coupled_violation = isempty(coupled_violations) ? 0.0 :
                            Float64(maximum(coupled_violations))
        recomputed_primal = max(scalar_violation, coupled_violation)
        push!(trace, (binding, recomputed_primal))
        logged_primal = binding.record.primal_infeasibility
        smaller = min(logged_primal, recomputed_primal)
        larger = max(logged_primal, recomputed_primal)
        prefix = segment_qualified_metadata ?
                 "segment_$(binding.segment)_iteration_$(binding.record.iteration)" :
                 "iteration_$(binding.record.iteration)"
        report.metadata[Symbol(prefix * "_segment")] = string(binding.segment)
        report.metadata[Symbol(prefix * "_log_line")] = string(binding.record.line)
        report.metadata[Symbol(prefix * "_point_label")] = binding.point.label
        report.metadata[Symbol(prefix * "_logged_primal_infeasibility")] = string(logged_primal)
        report.metadata[Symbol(prefix * "_recomputed_total_violation")] = string(recomputed_primal)
        report.metadata[Symbol(prefix * "_recomputed_scalar_violation")] = string(scalar_violation)
        report.metadata[Symbol(prefix * "_recomputed_coupled_violation")] = string(coupled_violation)
        recomputed_objective = evaluation.objective_value
        objective_available = !isnothing(recomputed_objective) &&
                              !ismissing(recomputed_objective)
        report.metadata[Symbol(prefix * "_logged_objective")] =
            string(binding.record.objective)
        report.metadata[Symbol(prefix * "_recomputed_objective")] =
            objective_available ? string(recomputed_objective) : "unavailable"
        if larger > 0 && (smaller == 0 || larger / smaller > residual_agreement_factor)
            push!(report, Finding(:solver_iteration_primal_residual_mismatch;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = NumericalObservation, confidence = ConfidenceMedium,
                observation = "Iteration $(binding.record.iteration) records primal infeasibility $logged_primal, while generic scalar and coupled-set evaluation gives $recomputed_primal at supplied point \"$(binding.point.label)\".",
                why_it_matters = "These quantities can use different scaling, constraint representations, or coupled-set semantics; the mismatch is evidence to inspect, not a solver-error claim.",
                evidence = [Evidence("Bound iteration and recomputed feasibility";
                    details = ["iteration" => binding.record.iteration, "log_line" => binding.record.line,
                               "logged_primal_infeasibility" => logged_primal,
                               "recomputed_scalar_violation" => scalar_violation,
                               "recomputed_coupled_violation" => coupled_violation,
                               "recomputed_total_violation" => recomputed_primal,
                               "point_label" => binding.point.label],
                )],
                suggested_actions = ["Check solver scaling and coupled-set semantics before comparing residual magnitudes directly."],
            ))
        end
        if objective_available
            numeric_objective = Float64(recomputed_objective)
            push!(objective_trace, (binding, numeric_objective))
            smaller_objective = min(abs(binding.record.objective), abs(numeric_objective))
            larger_objective = max(abs(binding.record.objective), abs(numeric_objective))
            if larger_objective > 0 &&
               (smaller_objective == 0 ||
                larger_objective / smaller_objective > objective_agreement_factor)
                push!(report, Finding(:solver_iteration_objective_mismatch;
                    severity = SeverityInfo, domain = RepresentationalIssue,
                    basis = NumericalObservation, confidence = ConfidenceMedium,
                    observation = "Iteration $(binding.record.iteration) records objective $(binding.record.objective), while objective evaluation gives $numeric_objective at supplied point \"$(binding.point.label)\".",
                    why_it_matters = "A log objective can include barrier terms, scaling, or a differently timed iterate. The mismatch is evidence to inspect, not a solver-error claim.",
                    evidence = [Evidence("Bound iteration and recomputed objective";
                        details = ["iteration" => binding.record.iteration,
                                   "log_line" => binding.record.line,
                                   "logged_objective" => binding.record.objective,
                                   "recomputed_objective" => numeric_objective,
                                   "agreement_factor" => objective_agreement_factor,
                                   "point_label" => binding.point.label],
                    )],
                    suggested_actions = ["Check objective scaling, barrier or penalty reporting, and point-to-iteration alignment before comparing objective values directly."],
                ))
            end
        end
    end
    sort!(trace; by = item -> (
        item[1].segment, item[1].record.iteration, item[1].record.line,
    ))
    sort!(objective_trace; by = item -> (
        item[1].segment, item[1].record.iteration, item[1].record.line,
    ))
    trace_segments = sort(unique(item[1].segment for item in trace))
    objective_trace_segments = sort(unique(item[1].segment for item in objective_trace))
    report.metadata[:bound_iteration_segment_count] = string(length(trace_segments))
    report.metadata[:bound_iteration_multi_point_segment_count] = string(count(
        segment -> count(item -> item[1].segment == segment, trace) >= 2,
        trace_segments,
    ))
    for segment in trace_segments
        segment_trace = filter(item -> item[1].segment == segment, trace)
        length(segment_trace) >= 2 || continue
        first_binding, first_recomputed = first(segment_trace)
        final_binding, final_recomputed = last(segment_trace)
        first_logged = first_binding.record.primal_infeasibility
        final_logged = final_binding.record.primal_infeasibility
        log_improved = final_logged * trace_trend_factor < first_logged
        recomputed_worsened = final_recomputed >
                              max(first_recomputed * trace_trend_factor, 0.0)
        if log_improved && recomputed_worsened
            push!(report, Finding(:solver_iteration_trace_feasibility_disagreement;
                severity = SeverityWarning, domain = RepresentationalIssue,
                basis = HeuristicInterpretation, confidence = ConfidenceMedium,
                observation = "Within bound trace segment $segment, logged primal infeasibility decreases from $first_logged to $final_logged, while recomputed feasibility increases from $first_recomputed to $final_recomputed.",
                why_it_matters = "The supplied points and solver log may use different scaling, timing, or feasibility semantics; this trend disagreement needs inspection rather than attribution.",
                evidence = [Evidence("Bound iteration trace endpoints";
                    details = ["segment" => segment,
                               "first_iteration" => first_binding.record.iteration,
                               "final_iteration" => final_binding.record.iteration,
                               "first_logged_primal" => first_logged,
                               "final_logged_primal" => final_logged,
                               "first_recomputed_violation" => first_recomputed,
                               "final_recomputed_violation" => final_recomputed],
                )],
                suggested_actions = ["Verify point-to-iteration alignment and compare solver scaling with the model's constraint semantics."],
            ))
        end
    end
    if !isempty(objective_trace_segments)
        sense = MOI.get(model, MOI.ObjectiveSense())
        if sense != MOI.FEASIBILITY_SENSE
            for segment in objective_trace_segments
                segment_objective_trace = filter(
                    item -> item[1].segment == segment, objective_trace,
                )
                length(segment_objective_trace) >= 2 || continue
                first_binding, first_objective = first(segment_objective_trace)
                final_binding, final_objective = last(segment_objective_trace)
                orientation = sense == MOI.MAX_SENSE ? 1.0 : -1.0
                logged_progress = orientation * (
                    final_binding.record.objective - first_binding.record.objective
                )
                recomputed_progress = orientation * (final_objective - first_objective)
                if logged_progress > objective_trace_tolerance &&
                   recomputed_progress < -objective_trace_tolerance
                    push!(report, Finding(:solver_iteration_trace_objective_disagreement;
                        severity = SeverityWarning, domain = RepresentationalIssue,
                        basis = HeuristicInterpretation, confidence = ConfidenceMedium,
                        observation = "Within bound trace segment $segment, logged objective moves in the $(sense == MOI.MAX_SENSE ? "maximizing" : "minimizing") direction from $(first_binding.record.objective) to $(final_binding.record.objective), while the recomputed model objective moves oppositely from $first_objective to $final_objective.",
                        why_it_matters = "The log may report a scaled, barrier, penalty, or differently timed objective. This trace disagreement needs alignment inspection rather than solver attribution.",
                        evidence = [Evidence("Bound iteration objective trace endpoints";
                            details = ["segment" => segment,
                                       "objective_sense" => sense,
                                       "first_iteration" => first_binding.record.iteration,
                                       "final_iteration" => final_binding.record.iteration,
                                       "first_logged_objective" => first_binding.record.objective,
                                       "final_logged_objective" => final_binding.record.objective,
                                       "first_recomputed_objective" => first_objective,
                                       "final_recomputed_objective" => final_objective,
                                       "objective_trace_tolerance" => objective_trace_tolerance],
                        )],
                        suggested_actions = ["Verify objective reporting semantics and iteration-point alignment before comparing objective trends."],
                    ))
                end
            end
        end
    end
    return report
end
