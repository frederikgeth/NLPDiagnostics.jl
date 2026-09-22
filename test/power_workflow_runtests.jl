# Self-contained workflow lane: checked-in inputs, no saved work/ artifacts.
using Test
@testset "Power workflow" begin
    include("power_repair_physics.jl")
    include("capacity_preflight_contracts.jl")
    mktempdir() do directory
        withenv("NLPDIAGNOSTICS_TEST_OUTPUT_ROOT" => directory) do
            include("power_mathematical_contracts.jl")
        end
    end
    include("power_diagnostics_v2_contracts.jl")
    include("power_diagnostics_cli_contracts.jl")
end
