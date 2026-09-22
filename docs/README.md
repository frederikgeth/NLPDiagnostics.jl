# Documentation structure and authoring guide

The published Documenter site is sourced from `docs/src/`. Markdown and JSON
files beside this README are detailed research records, generated evidence,
protocols, and historical ledgers. Keep them available for audit, but add them
to site navigation only when they serve a clear reader task.

## Build locally

From the repository root:

```sh
julia --project=docs -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'
julia --startup-file=no --project=docs docs/make.jl
```

Open `docs/build/index.html`. The build executes every Documenter `@example`
block and fails on example, cross-reference, or selected API-doc errors. The
generated `docs/Manifest.toml` and `docs/build/` directory are ignored. CI
resolves the documentation environment from `docs/Project.toml`.

The finding-code page is generated and checked during every build. After adding,
removing, or renaming a literal finding code, update it with:

```sh
julia --startup-file=no docs/generate_finding_reference.jl --write
```

## Choose the page type first

- A **tutorial** teaches through a complete, reproducible investigation. It
  should have a learning objective and a narrative sequence.
- A **how-to guide** answers one practical question for a reader who already
  understands the concepts.
- A **concept page** explains why the system behaves as it does and separates
  commonly confused claims.
- A **reference page** states API and data contracts precisely. It should be
  organized for lookup rather than read as a lesson.
- A **research record** preserves methods, evidence, negative results, and
  historical decisions. It need not become part of the learning path.

## Tutorial pattern

Use the same investigation loop across NLP and OPF examples:

1. State the question in observable terms.
2. Ask the reader to predict the result.
3. Build the smallest model that preserves the mechanism.
4. Inspect a typed finding and its evidence basis.
5. State what the result does and does not establish.
6. Change one justified mechanism.
7. Compare the result with the prediction.
8. End with an exercise that requires interpretation, not transcription.

Include a tempting but unsupported interpretation when it teaches an important
boundary. For example, compare a zero derivative at one point with a global
degree of freedom, or a domain-invalid start with model infeasibility.

## Executable examples

Prefer solver-free examples for static, structural, and explicit-point concepts.
They are faster and separate the diagnostic mechanism from solver behaviour.
Use a solver only when its behaviour is the subject of the lesson.

Every `@example` should assert its important scientific claim. Avoid asserting
the complete rendered report or an incidental finding count; both make teaching
examples brittle. Assert the relevant finding code, basis, scope, or disappearance
after an intervention. Finish blocks with `nothing` when their raw output would
distract from the lesson.

For numerical examples, record the point label and origin, tolerance/policy,
coordinate convention, and why the point is meaningful. For OPF examples, add
the network source, formulation, component status, reference policy, units or
per-unit bases, and source-to-model mapping as the example becomes realistic.

## Writing standard

- Introduce JuMP first; explain MOI when it clarifies the evidence or API boundary.
- Define a technical term where the reader first needs it.
- Put the conclusion immediately after the output that supports it.
- Distinguish source intent, represented model, evaluation point, and solver
  state explicitly.
- Link prerequisites to JuMP, MOI, or domain documentation instead of recreating
  a second manual.
- Keep experimental status and unavailable evidence visible without burying the
  main lesson in project history.
- Send deep calibration detail to the research record and summarize only the
  boundary a learner needs.

Before merging a new page, ask a reader from the intended audience to explain
the conclusion in their own words. If they cannot distinguish the observation
from the interpretation, revise the example before adding more detail.
