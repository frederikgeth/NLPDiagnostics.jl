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
- connection matrix and any expected hidden terminal or mode directions;
- quantity (`:voltage`, `:current`, `:power`, `:angle`, or `:generic`),
  representation, unit convention, and optional positive nominal scale; and
- terminal-to-MOI-variable coordinates where numerical comparison is intended.

Network links are declared by `PortConnectionMetadata` maps. The generic core
can assemble their terminal-coordinate nullspace, project connected-port modes
into MOI coordinates, and compare explicit candidates with local Jacobian,
active-set, and persistent reduced-Hessian evidence. It does not label a mode
as a neutral, common mode, delta circulation, or voltage-collapse mechanism.
Those are plugin-level physical classifications.
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
