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
