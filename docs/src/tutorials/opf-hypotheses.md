# Tutorial: from NLP evidence to OPF hypotheses

Power-system models add physical meaning to generic NLP structure. This tutorial
uses a simplified angle block to show how to move from mathematical evidence to
an OPF hypothesis without overstating the result.

!!! note "Learning goals"
    After this tutorial, you can separate structural underdetermination from an
    OPF gauge interpretation, test a reference-angle hypothesis, and recognize
    redundant affine balance equations.

    **Prerequisites:** basic OPF angle notation. **Time:** about 15 minutes.
    **Artifact:** unreferenced, referenced, and redundant angle-block reports.

## One flow equation, no angle reference

Let a linearized branch relation impose ``\theta_1-\theta_2=0.5``. With two
angles and one equation, a common shift remains free.

```@example opf_hypotheses
using JuMP, NLPDiagnostics

unreferenced = Model()
@variable(unreferenced, theta[1:2])
@constraint(unreferenced, theta[1] - theta[2] == 0.5)

unreferenced_report = analyze(unreferenced)
unreferenced_codes = Set(finding.code for finding in unreferenced_report)
@assert :underdetermined_equality_partition in unreferenced_codes
nothing
```

The structural result says that the equality pattern does not determine every
free variable. Calling the freedom a global angle gauge additionally requires
knowledge that these coordinates are voltage angles and that no other model
part fixes the reference.

## Test the reference hypothesis

Add one justified reference and repeat the same analysis:

```@example opf_hypotheses
referenced = Model()
@variable(referenced, theta[1:2])
@constraint(referenced, theta[1] == 0)
@constraint(referenced, theta[1] - theta[2] == 0.5)

referenced_report = analyze(referenced)
referenced_codes = Set(finding.code for finding in referenced_report)
@assert :underdetermined_equality_partition ∉ referenced_codes
@assert :overdetermined_equality_partition ∉ referenced_codes
nothing
```

The intervention behaves as the gauge hypothesis predicts. In a full AC OPF,
also inspect island topology, reference metadata, active constraints, and the
local numerical nullspace. A reference in one island does not fix another.

## A second balance equation can be redundant

It is easy to mistake “more equations” for “more information.” Add the reverse
of the same relation:

```@example opf_hypotheses
@constraint(referenced, theta[2] - theta[1] == -0.5)
duplicate_report = analyze(referenced)
duplicate_codes = Set(finding.code for finding in duplicate_report)
@assert :proportional_affine_equality_constraints in duplicate_codes
@assert :overdetermined_equality_partition in duplicate_codes
print(text_report(duplicate_report))
```

Here the proportionality is a mathematical fact about the represented affine
equations. Whether the duplicate is an error depends on formulation intent. In
network models, paired component and nodal equations may look related while
representing different physical laws, coordinate maps, or sign conventions.

## Moving to an actual OPF study

For each real case, preserve:

- the network source and component-status revision;
- formulation and reference-bus policy;
- per-unit bases and source-to-model mapping;
- initialization provenance;
- solver options, termination status, and tolerances; and
- the exact point used for derivative or rank evidence.

The current end-to-end source/solver workflow is experimental and documented in
the repository's [Power diagnostics v2 record](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/docs/power_diagnostics_v2.md).
Its frozen synthetic evaluations are development evidence, not a claim of
operator usefulness or general OPF coverage.

## Exercise

Create two disconnected angle pairs, one equation per pair, and fix a reference
in only the first pair. Predict the structural finding before running the
analysis. Then add one reference in the second pair and compare the reports.

!!! tip "Hint"
    Use variables ``theta[1:4]`` with relations between 1–2 and 3–4. Treat each
    pair as a separate island and change only the reference policy.

!!! info "Expected observations"
    One reference removes the common shift in its own pair but leaves a free
    shift in the other. A reference in each pair removes both structural null
    directions. Calling the pairs electrical islands still depends on the
    source-to-model mapping, not the affine equations alone.
