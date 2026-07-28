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
optional extension. The current module intentionally establishes only the load
boundary. Component extraction requires a tested public API target; until that
is available, the generic `ComponentMetadata` /
`expected_nullspace_modes` hooks remain the stable semantic boundary.

## Confirmed public API target

The first adapter should target PowerModels `0.21` using only its exported
`AbstractPowerModel`, `ids`, `ref`, `var`, and `nw_ids` interfaces. It should
obtain component identities and network/reference data through `ref`/`ids`,
and inspect formulation-owned JuMP variables through `var`; it must not reach
into `pm` fields or parse rendered variable names. The adapter must first
establish a tested mapping from those JuMP variables to MOI indices before
returning `ComponentMetadata` or expected modes to the generic core.
Formulation coverage (ACP, ACR, DC, and relaxations) remains an explicit
capability decision rather than a best-effort common implementation.

The implemented first slice is
`NLPDiagnostics.powermodels_component_metadata(pm)`. It enumerates buses,
branches, generators, loads, shunts, switches, storage, and DC lines across
networks through those public references, assigning stable `nw<ID>:<ID>`
component identities and per-unit unit labels. It intentionally returns no
variable/constraint scopes and no expected rank or gauge declaration yet.
When the extension is loaded, `component_metadata(pm)` delegates to this
adapter for a `PowerModels.AbstractPowerModel`.
Bus records additionally preserve `declared_reference_bus=true` when the
public `:ref_buses` reference set contains that bus. This is source-data
evidence only; it does not assert that the selected formulation includes an
angle-reference equation.
`NLPDiagnostics.powermodels_reference_bus_report(pm)` additionally reports
zero, one, or multiple declared references independently for each network.
It is a data-level diagnostic; it does not inspect the formulation's JuMP/MOI
constraints or classify a numerical nullspace.
