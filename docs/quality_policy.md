# Local quality policy

This policy defines the verification boundary used while the project remains
pre-release. It is intentionally local and read-only: it does not install
packages, invoke GitHub Actions, mutate manifests, or treat an unavailable
optional tool as a passing result.

The machine-readable source is
[`quality_policy.json`](quality_policy.json). Each check is classified as
`active` or `deferred`.

Active checks currently cover whitespace, the known local regression suite,
API/test/benchmark consolidation, and the read-only local quality baseline.
The baseline validates the policy itself, including that every expected check
has a status, that active checks have commands, and that deferred checks carry
an explicit reason.

Documentation-example execution, Aqua, and targeted JET checks are explicitly
deferred. They require reviewed environments and dependency policy before they
can be promoted to active checks. Their deferral is evidence about the current
verification boundary, not a quality or correctness result.

The local baseline is run with:

```text
julia --project=work/benchmark-environment --startup-file=no \
  benchmarks/check_local_quality.jl /tmp/nlpdiagnostics-local-quality.json
```
