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
