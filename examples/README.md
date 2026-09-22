# Runnable research examples

These scripts mirror the longer Documenter tutorials and are intended as small
starting points for new experiments. Run them from the repository root with the
documentation environment:

```sh
julia --project=docs examples/numerical_rank_at_a_point.jl
julia --project=docs examples/controlled_opf_formulations.jl
```

The scripts assert their central numerical claims. They are teaching fixtures,
not benchmark evidence or validated network studies. Copy the experiment-record
template from `docs/src/assets/experiment-record.toml` before adapting them to a
new case, solver, formulation, or tolerance policy.
