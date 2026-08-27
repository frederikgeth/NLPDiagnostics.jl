# BMOPFTools voltage-start transfer API proposal

Status: draft for upstream review

This proposal removes the need for downstream code to reach into the staged
`ctx.vars` ledger when transferring a voltage state between BMOPFTools models.
It is intentionally additive: the existing native-start API remains unchanged,
and this document does not request that implementation details become public.

## Proposed surface

```julia
starts = opf_voltage_start_values(ctx; units = :SI)
report = set_opf_voltage_start_values!(ctx, starts; units = :SI)
```

`opf_voltage_start_values` returns a typed start-state record containing:

- rectangular voltage phasors keyed by `(bus, terminal)`;
- the declared `units` (`:SI` or `:working`);
- the coordinate convention and per-bus voltage bases used for conversion;
- grounded-terminal metadata, so omitted or fixed terminals are distinguishable
  from missing data.

`set_opf_voltage_start_values!` validates and applies finite phasors to the
existing JuMP voltage variables and returns a typed report with `applied_count`,
`skipped_count`, and structured validation errors. Unknown bus-terminal keys,
nonfinite values, invalid bases, and incompatible coordinate metadata must be
reported rather than silently accepted.

## Lifecycle and semantics

The read and write operations are valid after `build_opf_model` and before
`enforce_kcl!` or `optimize!`. They must only read coordinate metadata and set
JuMP start values; they must not add, remove, or mutate constraints, objective
terms, or solver options. `:SI` values are converted using the model's
per-bus voltage bases. `:working` values are applied without a second
conversion. Grounded terminals are preserved according to the model topology.

The transfer report should make partial application explicit. A caller can then
decide whether skipped values are acceptable without inferring success from a
solver status. The native `set_opf_start_values!(ctx)` behavior and return value
remain backward-compatible.

## Acceptance checks

An upstream implementation is ready for downstream adoption when it provides:

1. round-trip read/write checks for SI and working coordinates across uniform
   and nonuniform voltage bases;
2. explicit grounded-terminal and unknown-key behavior;
3. finite-value and invalid-base validation;
4. a lifecycle test showing no constraint or objective mutation;
5. additive API coverage with the existing native-start tests; and
6. a versioned report schema that downstream benchmarks can consume without
   accessing `ctx.vars`.

Until these checks pass in BMOPFTools, NLPDiagnostics retains the full-case
transfer benchmark as experimental evidence and keeps its internal ledger
access isolated to that benchmark.
