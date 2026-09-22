# Prior art and shared terminology

NLPDiagnostics builds on a substantial body of model-debugging work. The
[JuMP model-debugging initiative](https://github.com/jump-dev/JuMP.jl/issues/3664)
is the clearest statement of the shared problem: help users find formulation
mistakes and numerical risks, and explain the evidence instead of silently
rewriting the model. We use its idea list as a standing roadmap input.

This page records the projects that directly influence the package's language
and design. A reference means that the project supplied an idea, term, or useful
comparison point. It does not imply API compatibility, identical algorithms, or
endorsement by its authors.

## Terminology we share

| Term | Meaning in NLPDiagnostics | Prior art and relationship |
|:--|:--|:--|
| **Summary statistics** | Counts, represented function/set types, provenance, and a deterministic public-model fingerprint. | The [JuMP initiative](https://github.com/jump-dev/JuMP.jl/issues/3664) proposes these as the first model sanity check. `model_summary` provides the compact read-only front door. |
| **Coefficient analysis** | Static coefficient ranges and density when those quantities exist; **Jacobian scaling** for derivatives evaluated at a named point. | The initiative points to [SDDP.jl's numerical-stability report](https://github.com/odow/SDDP.jl/blob/9e88c6ba2a7dacc0f842b9be3f8073acfd55073e/src/print.jl#L191-L384), which reports matrix, objective, bound, and right-hand-side ranges. We keep those static ranges distinct from point-local nonlinear derivative scales. |
| **Initial-point analysis** | Completeness, bound feasibility, domain safety, finite values, and derivative availability at an explicitly labelled point. | [DegeneracyHunter.jl](https://github.com/adowling2/DegeneracyHunter.jl) uses “initial point analysis” for uninitialized variables, bound violations, and infeasible equations. NLPDiagnostics adds typed point provenance and explicit claim boundaries. |
| **Degeneracy** | Local active-set or equality-Jacobian dependence under a recorded point and tolerance policy. | [DegeneracyHunter.jl](https://github.com/adowling2/DegeneracyHunter.jl) introduced an algorithm for finding **irreducible degenerate sets (IDS)**. `dependent_row_localization` now checks every one-row deletion under a fixed numerical threshold and reports one inclusion-minimal row set. We still qualify it as point-local and numerical; a nullspace or dependent partition alone is not called an IDS. |
| **Incidence graph** | The bipartite variable-constraint graph derived from represented support. | [MathProgIncidence.jl](https://github.com/lanl-ansi/MathProgIncidence.jl) and [Pyomo's incidence analysis](https://pyomo.readthedocs.io/en/stable/explanation/analysis/incidence/overview.html) motivate the graph, matching, structural-rank, and Dulmage–Mendelsohn vocabulary. |
| **Reduced infeasible subsystem** | A solver conflict or elastic subset that is smaller than the original scope, with its method and minimality limits retained. | The initiative cites [Python-MIP's conflict tools](https://github.com/coin-or/python-mip/blob/6044fc8f0414d71430e94b8a08573b695dc35b5a/mip/conflict.py#L15). We use “irreducible infeasible subsystem” or **IIS** only when irreducibility has been established. |
| **Dual feasibility report** | Sign feasibility, stationarity, complementarity, and applicable objective-consistency checks, each with its coordinate and tolerance policy. | The initiative points to [HiGHS.jl issue #223](https://github.com/jump-dev/HiGHS.jl/issues/223) for checking solver-reported objective values against re-evaluation. `objective_consistency_summary` adds this front door and reports a gap only for a tolerance-qualified continuous scalar affine primal-dual pair. |
| **Convexity counterexample** | Domain-valid points that numerically disprove a convexity claim over the tested segment. | The initiative cites [CVXPY Analyzer's convexity checker](https://github.com/cvxpy/cvxpyanalyzer/blob/master/analyzer/convexity_checker.py). NLPDiagnostics currently provides local Hessian inertia; a reproducible counterexample campaign remains planned. |
| **Hessian structure** | Declared or method-generated candidate sparsity, evaluated numerical nonzeros, density, and reformulation implications, reported separately. | [MathOptInterface issue #2527](https://github.com/jump-dev/MathOptInterface.jl/issues/2527) documents why declared nonlinear Hessian sparsity can include entries that evaluate to zero. `hessian_density_summary` preserves this distinction and labels dense finite-difference candidates separately. |
| **MIP solution refiner** | Outside the current continuous NLP/OPF mission. | The initiative links a [solution-refinement presentation](https://youtu.be/rKcdF4Fgl-g?feature=shared&t=2535). We retain the idea in the roadmap so any future scope change starts from the cited prior art. |
| **Solver trace** | Ordered solver callback or parsed-log observations with metric coordinate semantics and optional explicitly captured points. | Solver telemetry is evidence about one algorithm run. It is paired with independently evaluated model or physical residuals without assuming the numeric columns share coordinates. |

## Coverage of the JuMP initiative

The current package covers 12 of the initiative's 13 idea families at least
partially. Eleven are strong parts of the implementation, one has meaningful
support with a clear missing front door, and the MIP solution refiner is outside
the present NLP/OPF scope.

| Idea family | Current coverage | Remaining work |
|:--|:--|:--|
| Summary statistics | Strong | `model_summary` groups represented function/set types, records counts and fingerprint provenance, and states that portable instantiated-bridge provenance is unavailable. |
| Coefficient analysis | Strong | `coefficient_profile` reports static linear/quadratic objective and constraint ranges, bounds, normalized RHS values, density, and opaque coverage beside point-local derivative scaling. |
| Degeneracy | Strong | Bounded fixed-threshold deletion now localizes one irreducible numerical dependent row set; broader coverage and cross-point calibration remain open. |
| Incidence analysis | Strong | Continue calibration and improve explanations of structural versus numerical rank. |
| Bounds given as constraints | Strong | `bound_expressed_as_constraint` isolates exact one-variable affine rows, reports the equivalent bound, and preserves the distinction between feasible-set equivalence and row/dual semantics. |
| Variables absent from constraints | Strong | Retain objective-only and genuinely disconnected distinctions. |
| Starting-point analysis | Strong | Keep point provenance and completion policy visible. |
| Domain analysis | Strong | Extend operator coverage while preserving proven/possible/local distinctions. |
| Convexity analysis | Partial | Add seeded, domain-valid counterexample campaigns; retain local Hessian screens. |
| Reduced infeasible subsystem | Strong | Distinguish solver conflicts, elastic reductions, minimum-cardinality searches, and verified irreducibility. |
| Dual feasibility report | Strong | `objective_consistency_summary` compares the public solver objective with independent endpoint evaluation and makes unsupported nonlinear gaps explicitly unavailable. |
| Hessian analysis | Strong | `hessian_density_summary` reports lower-triangular and symmetric structural/numerical density, tolerance, derivative provenance, duplicate combination, and coverage limits. |
| MIP solution refiner | Outside scope | Revisit only if the package deliberately expands beyond continuous NLP/OPF diagnostics. |

The detailed implementation order and acceptance conditions live in the
[development roadmap](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/docs/roadmap.md).

## Citation guidance

When work uses these ideas, cite the originating project or paper as well as
NLPDiagnostics. In particular:

- cite Dowling and Biegler's *Degeneracy Hunter: An Algorithm for Determining
  Irreducible Sets of Degenerate Constraints in Mathematical Programs* when
  making IDS claims; the bibliographic details and paper links are maintained
  in the [DegeneracyHunter.jl README](https://github.com/adowling2/DegeneracyHunter.jl#degeneracy-hunter-algorithms);
- cite MathProgIncidence.jl or Pyomo incidence analysis when their graph and
  Dulmage–Mendelsohn methods directly inform an experiment;
- cite the exact SDDP.jl source revision when reproducing its coefficient-range
  presentation; and
- cite the JuMP issue when referring to the broader educational linting
  initiative or its idea taxonomy.

NLPDiagnostics reports should still name the exact algorithm, point, tolerance,
and implementation revision used. Shared terminology makes results easier to
compare; it does not make different numerical policies equivalent.
