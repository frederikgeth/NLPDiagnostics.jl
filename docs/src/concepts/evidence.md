# Evidence and claims

NLPDiagnostics separates a measurement from its interpretation. This matters in
research because the same symptom can have several causes: restoration failure
may follow a domain-invalid start, contradictory data, poor scaling, a solver
defect, or a formulation mismatch.

## Evidence bases

| Basis | Typical question it can answer | Boundary |
|:--|:--|:--|
| Mathematical proof | Do supported represented constraints contradict each other? | Does not validate source intent or physical meaning |
| Structural proof | What does the variable–equation incidence pattern imply? | Ignores numerical coefficient magnitudes and physical semantics |
| Numerical observation | What happened at this explicit point and tolerance? | Local to that point, policy, coordinates, and numerical source |
| Physical expectation | What behaviour does declared domain metadata predict? | Depends on the authority and completeness of that metadata |
| Local inference | Which explanation fits nearby numerical evidence? | Does not establish a global property |
| Heuristic interpretation | Where is it useful to investigate next? | A lead, not a certificate |

Confidence and evidence basis answer different questions. High confidence in a
local numerical observation does not make the conclusion global. A mathematically
proved contradiction may still reflect a source-data transcription error rather
than the intended physical system.

## Three scopes that are often confused

**The source record** describes the intended system. **The represented model** is
what JuMP/MOI contains. **An evaluation point** is one coordinate vector supplied
to that model. A useful diagnostic report says which scope its evidence belongs
to.

For example:

- `log(x)` at `x = -1` is a point-domain failure;
- declared bounds `x <= -1` make the logarithm unsafe throughout the represented
  variable interval; and
- whether `x` was intended to be positive requires source or domain evidence.

## Unavailable is a result

Some questions require a derivative backend, complete start, solver callback,
component map, or physical unit declaration. When that evidence is missing, the
correct result is unavailable with a reason. Treating unavailable as “healthy”
would bias experiments toward whichever cases happen to expose more telemetry.

## Controlled intervention

An interpretation becomes more credible when it predicts a specific change.
For a suspected gauge, add one justified reference and check the structural and
numerical consequences. For suspected scaling, transform coordinates while
holding the physical point and problem constant. For a suspected bad start,
change only the start. Retain cases where the prediction fails.
