module BenchmarkEnvironmentContracts
using Test
include("../benchmarks/check_benchmark_environment.jl")

@testset "Environment preflight requires loadability" begin
    missing = _package_record("Absent"; finder=_ -> nothing,
        loader=_ -> error("must not load an absent package"))
    @test !missing["available"] && !missing["loadable"]
    broken = _package_record("Broken"; finder=_ -> "/test/Broken.jl",
        loader=_ -> error("dependency ABI mismatch"))
    @test broken["available"] && !broken["loadable"]
    @test occursin("dependency ABI mismatch", broken["reason"])
    @test isnothing(broken["version"])
    @test_throws InterruptException _package_record("Interrupted";
        finder=_ -> "/test/Interrupted.jl", loader=_ -> throw(InterruptException()))
end
end
