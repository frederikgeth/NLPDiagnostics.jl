# PowerModels extension contract

`PowerModelsExt` must remain optional. The generic package continues to accept
only public MOI models and never infers electrical semantics from variable
names.

## Required plugin outputs

For a PowerModels model, the extension should implement:

- `component_metadata(model)`: one `ComponentMetadata` record per bus, branch,
  transformer, generator, load, shunt, switch, and port-bearing device;
- `expected_nullspace_modes(model, evaluation)`: declared reference and gauge
  directions in evaluation-point coordinate order; and
- plugin findings that attach physical interpretation only after generic
  structural/numerical evidence is available.

For multiconductor work, it should also implement `component_port_metadata(model)`:
one `ComponentPortMetadata` record per terminal-bearing device port, with
terminal/mode labels and an explicit connection matrix. The generic core does
not infer these maps from bus or variable names.
It may declare expected terminal- or mode-space hidden directions through
`component_port_nullspace_modes(model)`, which the generic core checks against
each supplied connection map before any network-level interpretation.
Network topology must be supplied explicitly through
`component_port_connections(model)` with `PortConnectionMetadata` maps; the
generic core will not infer port connections from component IDs or variable
labels.
The generic topology report can identify declared disconnected port islands,
but the extension must supply any electrical interpretation of those islands.

Component IDs must be stable within a component type. Metadata should include
device/bus identifiers, units, conductor or port labels, connection type, and
parameter-dependent expected rank where known.

Use the optional `variables` and `constraints` scopes when an expected rank is
expressed in model coordinates and equation rows. This allows the generic core
to reject stale references, duplicate scope entries, and ranks larger than a
declared coordinate or equation dimension; it does not yet infer port or
constitutive-equation semantics.

At an explicit point, the generic `analyze_component_ranks` helper compares a
declared expected rank to the aligned scoped Jacobian rank. A mismatch is only
an observed discrepancy: the extension remains responsible for distinguishing
an incorrect declaration, an operating-point singularity, and an expected
physical mode.

The generic core validates nonempty component identities and units, duplicate
type/ID pairs, and nonnegative expected ranks. Extension code should use the
`ComponentMetadata` constructor, but malformed direct records remain reported
as representational findings rather than being silently accepted.

## First implementation slice

Start with single-conductor AC formulations:

1. declare the global angle gauge when no angle reference is fixed;
2. detect one versus multiple declared reference buses;
3. attach per-unit voltage, power, and current metadata; and
4. compare declared angle-gauge span with observed Jacobian nullspace modes.

Only then extend to unbalanced and multiconductor ports. A multiconductor
component must declare terminal voltage/current maps and connection matrices;
bus-name heuristics are not an acceptable substitute.

## Dependency boundary

`PowerModels` is registered as a weak dependency and `PowerModelsExt` is an
optional extension. The implementation targets a deliberately small, tested
public API surface. Unsupported formulation coordinate families remain visible
as adapter-capability limits rather than being guessed from internal fields or
rendered variable names.

## Confirmed public API target

The first adapter should target PowerModels `0.21` using only its exported
`AbstractPowerModel`, `ids`, `ref`, `var`, and `nw_ids` interfaces. It should
obtain component identities and network/reference data through `ref`/`ids`,
and inspect formulation-owned JuMP variables through `var`; it must not reach
into `pm` fields or parse rendered variable names. The adapter must first
establish a tested mapping from those JuMP variables to MOI indices before
returning `ComponentMetadata` or expected modes to the generic core.
Network and component IDs are treated as opaque public values: report ordering
and dynamic metadata keys use their string representation, rather than
assuming integer identifiers.
Formulation coverage (ACP, ACR, DC, and relaxations) remains an explicit
capability decision rather than a best-effort common implementation.

The implemented first slice is
`NLPDiagnostics.powermodels_component_metadata(pm)`. It enumerates buses,
branches, generators, loads, shunts, switches, storage, and DC lines across
networks through those public references, assigning stable `nw<ID>:<ID>`
component identities and per-unit unit labels. It intentionally returns no
constraint scopes and no expected rank or gauge declaration yet. Where public
scalar `:va` entries exist, the corresponding bus record also carries that
single MOI variable scope and `scalar_angle_coordinate=va`; other coordinate
families remain deliberately unscoped.
The extension additionally returns matching `component_coordinate_semantics(pm)`
records with quantity `:angle`, polar representation, and radians units.
Those public `:va` coordinates also declare a nominal scale of one radian, so
the generic numerical stage can report unusually large nonzero angle
coordinates without inferring a scale from their unit label.
When the extension is loaded, `component_metadata(pm)` delegates to this
adapter for a `PowerModels.AbstractPowerModel`.
Bus records additionally preserve `declared_reference_bus=true` when the
public `:ref_buses` reference set contains that bus. This is source-data
evidence only; it does not assert that the selected formulation includes an
angle-reference equation.
`NLPDiagnostics.powermodels_reference_bus_report(pm)` additionally reports
zero, one, or multiple declared references independently for each network.
When PowerModels exposes public connected-component data, it also reports this
cardinality per island. It is a data-level diagnostic; it does not inspect the
formulation's JuMP/MOI constraints or classify a numerical nullspace.
Its metadata includes separate missing/multiple counts at network and island
scope, including the informational multiple-across-islands classification.

`NLPDiagnostics.powermodels_variable_indices(pm, key; network=nothing)` is
the tested-convention boundary for scalar formulation variables: it converts
public `var` entries to `MOI.VariableIndex` values through `JuMP.index` and
keys them by network/component ID. It intentionally omits container-valued
entries until their coordinate ordering is declared by a formulation adapter.
`NLPDiagnostics.powermodels_capability_report(pm)` makes this boundary
inspectable per network. In particular, it reports when public scalar `:va`
coordinates are absent, which means the generic scalar common-angle candidate
cannot be constructed for that network without a formulation-specific adapter.
`powermodels_jump_model(pm; key=:va)` recovers the owning JuMP model from
those public scalar entries, after checking that they all share one owner. It
is the safe handoff for running generic JuMP/MOI analysis; it never reads a
PowerModels internal model field.
The extension also defines `analyze(pm; owner_variable_key=:va)`: it runs the
generic analysis on that recovered JuMP model, adds counts for public
PowerModels component metadata, validates scoped public `:va` coordinates
against the recovered MOI backend, and appends adapter-capability and data-level
reference-bus reports. Angle-gauge candidates remain explicit opt-in inputs rather than an
automatic physical classification.
For the targeted numerical screen,
`powermodels_analyze_degeneracy(pm, point)` runs generic Jacobian-nullspace
analysis on the recovered MOI backend and includes missing-reference scalar
angle candidates by default. Set `include_angle_gauge_modes=false` to obtain
the bare generic screen, or pass additional `expected_modes` explicitly.
`powermodels_analyze_active_set(pm, point)` applies the same candidate policy
to the selected active Jacobian, distinguishing a locally tangent angle mode
from one removed by active constraints.
`powermodels_analyze_reduced_hessian_persistence(pm, snapshots)` supplies the
same optional candidates to cross-point flat-curvature persistence analysis;
the snapshots remain the sole source of second-order numerical evidence.
`powermodels_analyze_jacobian_rank_persistence(pm, points)` and
`powermodels_analyze_component_rank_persistence(pm, points)` provide the
analogous first-order cross-point screens. They evaluate only caller-supplied
points on the recovered backend, preserve the optional angle candidates as
expected-mode evidence, and do not reconstruct solver iterates or infer a
physical interpretation from persistent rank or nullspace geometry.

For a polar formulation whose scalar angle variables are publicly exposed as
`:va`, `powermodels_angle_gauge_modes(pm, evaluation)` creates one opt-in
common-angle candidate per unreferenced network island when public component
data is available (otherwise per unreferenced network). Pass these as
`expected_modes` to generic degeneracy or active-set analysis only after
confirming the formulation's coordinate semantics; a declared reference bus is
not treated as proof that an angle equation was created.
