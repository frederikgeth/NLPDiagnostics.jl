# A research workflow

NLPDiagnostics is most useful as part of an experiment, rather than as a source
of a single health score. Write down the question before choosing the diagnostic.

## 1. State the phenomenon

Use a description that can be observed: “Ipopt terminates at restoration failure
from this start,” “the equality Jacobian has a small singular value at this
point,” or “two formulations produce different iteration histories.” Avoid
placing the proposed cause in the observation.

## 2. Preserve the experiment

Record at least:

- the model and data revision;
- Julia, package, solver, and linear-solver versions;
- solver options and tolerances;
- the exact evaluation point and its origin;
- coordinate and unit conventions; and
- unavailable measurements and failed runs.

For OPF work, also record network transformations, per-unit bases, component
status, formulation, reference choices, and the mapping between source records
and model entities.

The [experiment-record template](reference/experiment-record.md) provides a
copyable minimum schema for these fields.

## 3. Separate evidence from interpretation

Suppose a Jacobian has a local null direction concentrated on voltage angles.
That is numerical evidence at a point. “The angle reference is missing” is a
physical/modeling hypothesis. Test it against structural matching, reference
metadata, nearby points, and a controlled reference intervention.

## 4. Change one mechanism

A useful intervention makes a prediction. If the hypothesis is a missing angle
reference, adding one justified reference should remove the expected structural
freedom. If the hypothesis is a poor start, a physically justified alternative
start should remove the point-domain failure without changing the model.

Keep the baseline and intervention comparable. A coordinate-scaling experiment,
for example, should start from the same physical state and compare residuals in
the same physical coordinates.

## 5. Report negative and unavailable results

Retain cases where a diagnostic abstains, a backend is unavailable, or the
intervention contradicts the hypothesis. These are scientific results. They
bound the circumstances under which a finding is useful.

The package's historical benchmark records use stricter freeze and provenance
procedures. See the [research record](research/index.md) when designing a larger
campaign, but begin with this compact loop for exploratory work.
