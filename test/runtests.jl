const ROOT = normpath(joinpath(@__DIR__, ".."))
const PACKAGE_ORDER = ["MCPClient", "LLMProviders", "LLMOAuth", "Agentif", "LLMTools", "Claw"]
const PACKAGE_TESTS = Dict(
    name => joinpath(ROOT, name, "test", "runtests.jl") for name in PACKAGE_ORDER
)

function selected_packages(args)
    isempty(args) && return PACKAGE_ORDER
    unknown = filter(name -> !haskey(PACKAGE_TESTS, name), args)
    isempty(unknown) || error("Unknown package test target(s): $(join(unknown, ", "))")
    return args
end

function run_package_tests(name::String)
    script = PACKAGE_TESTS[name]
    println("==> Running $(name) tests")
    base_cmd = Cmd(vcat(collect(Base.julia_cmd().exec), ["--project=$(ROOT)", "--startup-file=no", script]))
    cmd = Cmd(base_cmd; dir = ROOT)
    run(cmd)
    println("==> $(name) tests passed")
    return nothing
end

for name in selected_packages(ARGS)
    run_package_tests(name)
end

println("All requested package tests passed.")
