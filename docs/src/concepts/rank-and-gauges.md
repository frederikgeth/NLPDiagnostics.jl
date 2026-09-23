# Rank, structure, and gauges

Rank language is useful but easy to overinterpret. Keep three layers separate.

## Structural matching

Structural analysis asks whether the variable–equation incidence pattern could
support a matching. It ignores coefficient magnitudes. An underdetermined region
means some free variables cannot be matched to distinct equality rows in that
pattern. It does not identify a physical gauge by itself.

## Numerical rank

Numerical rank concerns a Jacobian at an explicit point under a stated tolerance
and scaling. A small singular value may reflect a true invariant, a derivative
that vanishes only at the chosen point, poor coordinate scaling, or numerical
error.

When the **rows** are dependent, `dependent_row_localization` can reduce a
bounded evaluated row scope to one set in which removing any row restores
independence under a fixed threshold. The [dependent-row
tutorial](../tutorials/dependent-rows.md) shows how to inspect the source
equations. Select equality and active rows explicitly when studying constraint
qualification; the default all-row scope has no activity interpretation.
The [OPF endpoint calibration](../tutorials/opf-dependent-rows.md) shows how
to make that selection from evaluated scalar-set evidence.

For example, the derivative of ``g(x)=x^2-1`` is zero at ``x=0``, even though the
equation has isolated feasible points at ``x=\pm1``. One-point rank loss is not a
global degree of freedom.

Useful checks include:

- repeat the estimate at independently justified nearby or solver-produced points;
- vary rank tolerance and scaling policy;
- compare independent dense and sparse backends where the size permits;
- inspect direct residuals of candidate null vectors; and
- compare with structural matching and declared expected modes.

## Physical gauges

A physical gauge is an invariance justified by domain semantics. In AC OPF, a
uniform angle shift may be expected within a connected island when no angle
reference is fixed. Establishing that interpretation requires component and
topology metadata, coordinate mappings, and reference policy in addition to a
numerical null direction.

The strongest investigation aligns several independent channels:

1. the structural pattern admits the freedom;
2. numerical nullspace evidence persists across relevant points and policies;
3. domain metadata declares the expected gauge direction; and
4. a controlled reference intervention removes the predicted freedom.

Disagreement between those channels is useful evidence. Preserve it rather than
forcing a single diagnosis.
