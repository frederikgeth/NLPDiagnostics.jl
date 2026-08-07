"""Return a deterministic textual representation for fingerprint inputs."""
function _fingerprint_show(value)
    io = IOBuffer()
    show(io, MIME("text/plain"), value)
    return String(take!(io))
end

_fingerprint_index_value(index) = hasproperty(index, :value) ? getproperty(index, :value) : repr(index)

function _sha256_fingerprint(parts::AbstractVector{<:AbstractString})
    payload = join(parts, "\n")
    return bytes2hex(SHA.sha256(codeunits(payload)))
end

"""Return a stable digest of the copied public MOI model description."""
function model_fingerprint(model::MOI.ModelLike)
    model_snapshot = snapshot(model)
    parts = String["NLPDiagnostics:model-fingerprint:v1"]
    push!(parts, "model_name=" * something(model_snapshot.model_name, ""))
    for variable in sort!(copy(model_snapshot.variables); by = item -> item.index.value)
        push!(parts, "variable=$(variable.index.value)|name=$(something(variable.name, ""))")
    end
    constraints = sort!(copy(model_snapshot.constraints); by = item -> (
        string(typeof(item.function_value)),
        string(typeof(item.set_value)),
        _fingerprint_index_value(item.index),
        _fingerprint_show(item.function_value),
        _fingerprint_show(item.set_value),
    ))
    for constraint in constraints
        push!(parts, join([
            "constraint",
            string(typeof(constraint.function_value)),
            string(typeof(constraint.set_value)),
            string(_fingerprint_index_value(constraint.index)),
            something(constraint.name, ""),
            _fingerprint_show(constraint.function_value),
            _fingerprint_show(constraint.set_value),
        ], "|"))
    end
    if isnothing(model_snapshot.objective)
        push!(parts, "objective=<none>")
    else
        objective = model_snapshot.objective
        push!(parts, join([
            "objective",
            string(objective.sense),
            _fingerprint_show(objective.function_value),
        ], "|"))
    end
    append!(parts, "opaque_source=" .* sort!(copy(model_snapshot.opaque_sources)))
    return _sha256_fingerprint(parts)
end

"""Return a stable digest of one explicit evaluation point and its provenance."""
function evaluation_point_fingerprint(point::EvaluationPoint)
    parts = String[
        "NLPDiagnostics:evaluation-point-fingerprint:v1",
        "label=$(point.label)",
        "kind=$(point.provenance.kind)",
        "source=$(point.provenance.source)",
        "complete=$(point.provenance.complete)",
    ]
    for (variable, value) in zip(point.variables, point.values)
        push!(parts, "coordinate=$(variable.value)|value=$(_fingerprint_show(value))")
    end
    for (key, value) in sort!(collect(point.provenance.metadata); by = first)
        push!(parts, "provenance_metadata=$key|$value")
    end
    return _sha256_fingerprint(parts)
end

"""Return a stable digest of evaluator capabilities and derivative paths."""
function evaluation_source_fingerprint(evaluation::NumericalEvaluation)
    parts = String["NLPDiagnostics:evaluation-source-fingerprint:v1"]
    for capability in sort!(copy(evaluation.capabilities); by = item -> (
        string(item.source), item.identifier,
    ))
        push!(parts, join([
            "capability",
            string(capability.source),
            capability.identifier,
            string(capability.objective_values),
            string(capability.constraint_values),
            join(string.(sort!(copy(capability.available_features); by = string)), ","),
            join(string.(sort!(copy(capability.requested_features); by = string)), ","),
        ], "|"))
    end
    push!(parts, "objective_gradient_method=$(evaluation.objective_gradient_method)")
    for (row, method) in enumerate(evaluation.jacobian_row_methods)
        push!(parts, "jacobian_row_method=$row|$method")
    end
    for failure in evaluation.failures
        push!(parts, join([
            "failure",
            string(failure.stage),
            string(failure.source),
            _fingerprint_show(failure.affected),
            failure.exception_type,
            failure.message,
        ], "|"))
    end
    return _sha256_fingerprint(parts)
end
