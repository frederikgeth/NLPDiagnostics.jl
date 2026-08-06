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
  representation, unit convention, and optional positive nominal scale; and
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
When a port declares `nominal_scale`, the generic numerical stage compares it
only through an explicit map row containing one terminal coordinate. Mixed
terminal-coordinate maps or absent maps remain an unavailable generic scale projection and
require a plugin-supplied transformed-scale rule rather than a guessed scalar
scale. Mixed maps are also flagged during static metadata validation, before a
numerical point is available.
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
