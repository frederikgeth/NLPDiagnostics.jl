# Engineer review study — prepared, not run

Status: no incident records or participants are currently available. No reviewers
have been contacted. This document is a preparation package, not a preregistered
completed study or evidence of repair benefit. Freeze the filled protocol and
incident manifest before enrolling reviewers or showing any diagnostic reports.

## Question

Does access to the diagnostic report improve correct fault localization compared
with the same model inputs and ordinary solver logs, without increasing incorrect
confident diagnoses or unsafe/unnecessary proposed changes?

## Incident preparation

Recruit documented power-system modeling incidents with permission to use their
records. Each must have a contemporaneous source record, original failing model,
solver/environment version, investigation history, and independently supported
resolution. Separate domain truth from what each tool could observe. Include
solvable controls, out-of-scope components, unit/provenance faults, and topology or
capacity faults. Do not select incidents because the report already succeeds.

A curator who does not review reports prepares two packages with the same evidence:
A contains the model inputs, relevant source records, and solver logs; B adds the
frozen diagnostic report. Both must expose the same source records, so an apparent
benefit is not merely access to extra data. Hash all materials and record omissions.
Keep the adjudication key separate from reviewer packages. Remove confidential
identifiers without changing the numerical failure; document any transformation.

Before the study, freeze the code, report options/tolerances, incident inclusion
rules, order assignment, time limit, rubric, and all exclusions. Run a separate
practice incident for usability, excluded from scored results. Do not retune the
software or change scoring after seeing study outcomes.

## Pilot assignment

Begin with a feasibility pilot, for example six eligible incidents and four
engineers. This is a recruitment target, not a powered efficacy design. Do not
claim statistical power or generalize a small convenience sample to operators.
If fewer participants or incidents are available, report the actual sample and
explain limitations rather than silently replacing the design.

Use a balanced assignment so each incident is assessed under both A and B by
different engineers. Each engineer sees each incident only once to prevent recall
of its answer. Balance condition order and spread incident difficulty across
reviewers; a coordinator creates and freezes the assignment before sessions.
Log condition assignment and presentation order. Record reviewer experience but
avoid using identity as an explanatory result in public reports.

Allow 20 minutes per incident after the practice task; freeze any changed limit
before scored sessions. Participants may inspect the supplied materials and propose
changes, but this study does not authorize modifications to operational systems.
Record start, first submitted diagnosis, final submission, and any interruption.
Do not coach reviewers toward the ground truth.

## Outcomes and adjudication

Primary outcome: correct fault localization at the final submission, scored against
an incident-specific key written before reports are shown. Require the affected
component/input/equation and a defensible causal explanation. A generic infeasible
status or an unrelated alert is not localization. Controls require an appropriately
limited no-fault or inconclusive conclusion, not invented defects.

Record separately:

- Elapsed time to a correct submitted localization. Unsolved/time-limited tasks
  remain censored failures; do not average only successful tasks.
- Whether the proposed change addresses the documented cause, is unnecessary, or
  introduces an error. No automated application of repairs is part of this pilot.
- Confidence (0–100), incorrect confident conclusions, and useful abstentions.
- Whether unavailable/not-run/source-mismatch outcomes were correctly interpreted.
- Missing evidence, report ambiguities, and reviewer requests for information.

Two domain adjudicators independently score responses against the frozen key
without condition labels where practicable. Record disagreements and resolve them
with an explicit written rationale; do not erase initial scores. Reviewers cannot
adjudicate their own answers. If the sample cannot support two independent
adjudicators, disclose that limitation.

## Analysis and decision

Report per-incident and per-reviewer outcomes and denominators for both conditions,
including unsupported cases, incomplete sessions, and exclusions. Do not treat
multiple reviews of the same incident as independent incident discoveries. Show
raw paired incident comparisons and time-limit outcomes. A small pilot is for
finding usability and study-design problems; defer efficacy claims and formal
power calculations until there are actual observations and a defined larger study.

Predeclared qualitative stop conditions: report wording leads reviewers to confuse
point violation with model infeasibility, source mismatch with a proved conversion
bug, or verified tolerance compliance with operational safety. Record those failures
and revise the report only as a new version for a subsequent study. Passing a
synthetic acceptance gate does not override these usability failures.

Publish a results document only after data collection. It must state recruitment,
actual sample, exclusions, failures, adjudication disagreements, and confidentiality
constraints. Until then, the study status remains **not run**.
