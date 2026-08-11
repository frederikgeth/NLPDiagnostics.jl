# Multiconductor extension contract

Multiconductor diagnostics are built around ports, not bus names. A plugin must
declare each terminal-bearing component port with `ComponentPortMetadata`, then
separately declare `PortCoordinateSemantics` and a `PortCoordinateMap` before
the generic core can compare physical terminal modes with model-coordinate
Jacobian evidence.

For model coordinates that belong to a component but not to a terminal map
(for example a bus angle, internal state, or controller coordinate), use
`ComponentCoordinateSemantics`. When the plugin also supplies
`ComponentMetadata` with a variable scope, the generic core checks that one
matching component scope covers that declaration. This validates metadata
coherence only; it does not establish physical observability.

If a coordinate is intentionally shared by several components, every
`ComponentCoordinateSemantics` declaration must use the same quantity,
representation, and units. The generic core flags conflicting declarations
before attempting to use them for scaling or tolerance interpretation.

The same rule applies across terminal maps: if `PortCoordinateMap` records
connect multiple port declarations to one MOI variable, their
`PortCoordinateSemantics` must agree. A mismatch is a metadata conflict, not a
claim that either electrical convention is incorrect.
For simple explicit maps, the generic core also compares the map-adjusted
nominal scales of shared model coordinates; incompatible effective scales are
reported before point-local scale evidence is used.

Mapped terminal semantics must also agree with any
`ComponentCoordinateSemantics` on the same MOI variable. If a terminal and a
component use different representations, declare the transformation explicitly
instead of attaching contradictory labels to one coordinate.

For each port, the plugin should specify:

- terminal labels and mode labels;
- connection matrix and any expected hidden terminal or mode directions, with
  an optional stable `PortNullspaceMode` name when the plugin needs to retain
  its own physical identifier; and
- quantity (`:voltage`, `:current`, `:power`, `:angle`, or `:generic`),
  representation, unit convention, and optional positive nominal scale;
- optional ordered `PortTerminalCoordinateSemantics` entries carrying a
  terminal label, plugin-defined role, per-terminal nominal scale, and an
  explicit expected value plus absolute tolerance; and
- terminal-to-MOI-variable coordinates where numerical comparison is intended.

Optionally declare `PortNullspaceModeSemantics` for a named mode. Its category
is deliberately opaque to the generic core: it is validated as provenance and
preserved in evidence, but only the domain plugin may interpret it physically.

Network links are declared by `PortConnectionMetadata` maps. The generic core
can assemble their terminal-coordinate nullspace, project connected-port modes
into MOI coordinates, and compare explicit candidates with local Jacobian,
active-set, and persistent reduced-Hessian evidence. It does not label a mode
as a neutral, common mode, delta circulation, or voltage-collapse mechanism.
Those are plugin-level physical classifications.
If projected component and topology candidates are linearly dependent, the
core retains every declaration for provenance but reports their independent
model-coordinate span. Candidate count is therefore never an expected-nullity
claim. `port_expected_nullspace_summary` exposes the same candidate matrix,
coordinate scope, rank, and tolerance to plugins and downstream tooling; the
same independent-rank context is retained by generic degeneracy, active-set,
and reduced-Hessian persistence reports.
When a port declares `nominal_scale`, or an ordered terminal entry declares its
own scale, the generic numerical stage compares it only through an explicit map
row containing one terminal coordinate. An ordered per-terminal declaration
overrides the port-wide scale, including with `nothing`: this is how a plugin
states that a floating neutral must not inherit a phase-voltage scale. The
ordered declaration count must equal the coordinate-map column count. Mixed
terminal-coordinate maps or absent maps remain an unavailable generic scale
projection and require a plugin-supplied transformed-scale rule rather than a
guessed scalar scale. Mixed maps and dimension mismatches are also flagged
during static metadata validation, before a numerical point is available.

An expected coordinate value is never inferred from `role`. A plugin must
declare both the value and its absolute tolerance. The generic core then checks
the mapped value at the explicit evaluation point and reports a separate
`component_port_expected_coordinate_value_mismatch`; it does not turn that
local observation into a feasibility or grounding proof.

The BMOPFTools voltage adapter now uses this contract. Energized phase
terminals receive the 1 p.u. coordinate scale, explicitly grounded terminals
receive a zero reference with a model-coordinate tolerance, and ungrounded
neutral terminals deliberately receive neither. The balanced-delta false
positive that motivated this change is therefore removed by physical terminal
metadata, not by variable-name parsing or a generic near-zero exception.
For the same direct rows, the map-adjusted port scale must agree with any
component-coordinate nominal scale on the mapped MOI variable. Supplying a
scale on only one side is likewise reported as an incomplete shared-coordinate
scaling convention.
At an evaluation point, compatible declarations that imply the same effective
model-coordinate scale are consolidated into one scale finding with all port
identities retained as evidence.

The scalar PowerModels `:va` bridge is intentionally not a multiconductor port
adapter: it exposes angle coordinates, not terminal voltage phasors. A future
adapter must declare voltage/current coordinates explicitly for each supported
formulation before using this contract.

The BMOPFTools staged adapter now supplies the first concrete attachment slice:
bus voltage ports plus explicit component-to-bus ports for loads, generators,
voltage sources, shunts, capacitors, IBRs, switches, and line endpoints. Each
attachment has a terminal-to-model-variable map, rectangular voltage
semantics, and a finite embedding matrix into the owning bus terminal order.
These are shared-coordinate declarations only. They do not assert equality of
the two endpoints of a line or transformer, and they do not manufacture
constitutive equations. Use `bmopf_terminal_port_connections(context)` to
inspect the attachment maps and `bmopf_terminal_port_report(context)` to see
skipped or unmapped endpoints. Transformer winding attachments (including
fixed- and n-winding records) are included in this slice. Rectangular
terminal-current ports are available through
`bmopf_terminal_current_port_metadata(context)`, with matching coordinate maps,
unit semantics, and a non-mutating coverage report. Device current ports retain
only the conductor coordinates that BMOPFTools actually registers; an omitted
neutral current is therefore represented as a shorter declared port rather than
reported as a false missing coordinate. Conservative physical component-mode
declarations are now available through
`bmopf_terminal_port_nullspace_modes(context)` and their semantic labels through
`bmopf_terminal_port_nullspace_mode_semantics(context)`. The current slice
declares explicit-neutral WYE and DELTA common-mode expectations only where the
network metadata supports them; grounding, vector-group maps, KCL, and compiled
equations may remove those directions. Use
`bmopf_terminal_port_nullspace_mode_report(context)` for declaration evidence,
or opt into comparison with a numerical Jacobian using
`bmopf_analyze_opf(...; include_port_physical_modes = true)`. Constitutive
current maps remain the next adapter slice.

The generic core also now carries `PortConstitutiveMap`. This is intentionally
separate from `PortConnectionMetadata`: it records labeled linear equations
over one or more named ports and is never interpreted as a network equality.
The BMOPFTools adapter exposes device WYE/DELTA terminal-to-coil incidence,
fixed-transformer ideal winding coupling (with ratio/tap and vector-group
metadata), and n-winding per-winding coil incidence through
`bmopf_terminal_constitutive_maps(context)`. Use
`bmopf_terminal_constitutive_map_report(context)` to validate dimensions,
finite coefficients, and map identities before using these maps in a physical
or numerical analysis. Declared transformer vector-group labels, delta
orientation, and phase shifts are retained as metadata. A nonzero phase shift
is reported explicitly as unrepresented by the current separated real/imaginary
map, so it cannot be mistaken for a complete complex transformer equation.
Fixed-transformer phase-aware maps are available through
`bmopf_terminal_complex_constitutive_maps(context)`. They use a real block
matrix over real and imaginary terminal ports and apply the declared phase
rotation; the scalar maps remain available for compatibility and structural
incidence analysis.

Declared component/bus attachments can be assembled into a structural graph
with `bmopf_terminal_port_assembly(context)`. Its connected components are
evidence about the port declarations only; disconnected groups are not
automatically classified as physical islands or errors.

The first current-side constitutive contract is also available through
`bmopf_passive_network_current_maps(context)`. It wraps BMOPFTools' public
passive Ybus as `I = YV` in SI units and records node ordering, nonzero count,
and exact structural rank. Nonlinear device current laws and p.u. conversion
are intentionally separate: the report flags a p.u./SI mismatch rather than
silently rescaling coefficients. Passing `basis=:model` applies public bus
voltage/current bases to produce p.u.-to-p.u. coefficients when every node is
covered; otherwise the conversion is reported as unavailable.

Current-law fingerprints provide the first static nonlinear-device boundary:
they preserve public load-model names, dispatch/control metadata, terminal
scope, differentiability status, and singularity risk. They are metadata
evidence, not reconstructed equations. Exact equations remain plugin-owned,
but a public control profile can still support a conservative family
classification without pretending that its derivative implementation has been
recovered.

The public BMOPFTools IBR profile metadata now refines that boundary: constant
power-factor, voltage-droop, power-sharing, and box-dispatch families retain
their declared topology and control-profile evidence. Generator fingerprints
retain the bilinear voltage/current power equation. These classifications are
structural metadata evidence; exact control-law derivatives remain an optional
domain-extension responsibility.

The operating-point layer is exposed through
`bmopf_current_law_operating_point_probes(context, source)` and its report
counterpart. A source can be an explicit staged `EvaluationPoint` (including a
synthetic zero probe or a completed BMOPFTools start) or a saved result
dictionary. Public load equations are evaluated at each declared terminal
pair; the adapter records voltage/current magnitude, a guarded local current
Jacobian estimate, derivative conditioning, and domain status. Zero voltage and
non-finite derivatives are observations attached to that point, not proof that
the complete network is infeasible. Generator and IBR records additionally use
the public bilinear voltage/current-to-power equations when their current
coordinates are present, retaining observed power and saved-result residuals.
Public Volt-var/Volt-watt profiles now receive an exact profile-level
softplus/ReLU-sum fingerprint (normalized output, local slope, breakpoint
distance, and smoothing width) using the same stable semantics as BMOPFTools.
The adapter also resolves the declared monitored-voltage quantity (`PG`, `PN`,
or `PP`) and per-phase/average aggregation from public bus coordinates,
including the legacy record-level aggregation override. Each probe records
whether this was exact monitor coverage or a terminal-pair proxy, so averaged
and phase-to-phase semantics are inspectable rather than inferred. If `s_max`,
`p_max`, or `p_avail` supplies the declared device base, the probe also records
the base-scaled Volt-var equality residual and Volt-watt cap violation.

Typed controller observations are available through
`bmopf_controller_curve_operating_point_observations(context, source)` and can
be serialized with `controller_curve_operating_point_observation_data`.

Across several explicitly supplied snapshots,
`bmopf_current_law_operating_point_persistence(context, sources)` aligns the
same component and terminal pair and reports status transitions, derivative
scale changes, and conditioning changes. This comparison preserves partial
coverage and unavailable plugin-owned laws; it is local numerical evidence,
not a global conditioning theorem.

Captured solver primal iterates can be passed through
`bmopf_current_law_operating_point_trace(context, trace)`. Selection is
explicit (phase filtering and an optional point budget), and every returned
probe retains its callback iteration label. A metric-only trace is not promoted
to a coordinate point: the helper reports the missing-primal coverage boundary
instead of reconstructing values from solver logs. For MadNLP this boundary is
also available as the explicit `madnlp_primal_capture_capability()` report.

The BMOPF smoke campaign now invokes `bmopf_analyze_opf(...;
include_port_physical_modes = true)` for every selected fixture. Its serialized
`physical_mode_analysis` is summarized as an explicit expected-versus-observed
mode boundary. With dense analysis disabled, only plugin-declared terminal
modes are reported; no local numerical comparison is claimed. With an explicit
small dense budget, rank/nullspace evidence is admitted, but coordinate
alignment failures remain warnings until terminal maps can be projected onto
the free model-coordinate scope. The generic degeneracy report now quantifies
partial alignment (aligned versus dropped mode components and their norm
fraction) before retaining the stronger unaligned finding, so fixed-coordinate
restrictions are distinguishable from stale or missing maps.

For larger fixtures, the smoke runner can request a sparse iterative
right-nullspace probe with `NLPDIAGNOSTICS_BMOPF_ITERATIVE_RIGHT_PROBE_DIMENSION`
and `NLPDIAGNOSTICS_BMOPF_ITERATIVE_RIGHT_PROBE_ITERATIONS`. The probe uses
Jacobian products rather than dense rank/SVD and is summarized separately from
physical-mode comparisons. Availability, convergence, residual candidates, and
failure reasons are retained; a non-converged or candidate result is never
promoted to a rank or gauge claim.

Two probe campaigns can be compared with
`benchmarks/compare_bmopf_multiconductor_probes.jl`. The comparison requires
matching fixture coverage, environment fingerprints, and probe dimensions,
then retains per-fixture convergence and residual deltas. It is intended for
budget sensitivity studies (for example, 30 versus 200 iterations), not for
turning iterative-probe behavior into a solver or model-quality score.

Source-schema warnings are retained at fixture level and normalized into
fixture-, field-, scope-, and message-frequency maps by
`benchmarks/summarize_bmopf_multiconductor_smoke.jl`. This makes repeated
OpenDSS-to-BMOPF information loss visible (for example, load `kv`, `phases`,
and voltage-limit fields) without treating dropped metadata as a numerical
failure. Campaign validation carries the same maps into its finding evidence.
The summary also classifies each dropped field as representational,
device-semantic, physical/operating-point, or unknown and exposes
`readiness["physical_metadata_complete"]`. A successful import with dropped
physical fields therefore remains usable for structural and numerical
observations, but is blocked from being treated as a complete physical
diagnosis.
The aggregate report also exposes a source-field policy crosswalk with an
explicit status and remediation action for every observed dropped field. This
is the handoff point for a future PowerIO/BMOPFTools adapter: fields must move
from `unsupported_*` to an explicit component or provenance contract before
the physical readiness gate can close.
The smoke runner also copies each selected `.dss` deck into its output
directory and records its digest and size. This makes schema-loss remediation
reproducible even if the upstream fixture tree changes later.
