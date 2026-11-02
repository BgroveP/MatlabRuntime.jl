using Test
using MatlabRuntime_jll
using Downloads

const MCR = MatlabRuntime_jll

@testset "MatlabRuntime_jll" begin
    @testset "platform" begin
        @test MCR._platform() in ("win64", "glnxa64")
    end

    @testset "download_url" begin
        # default release/update
        url = MCR.download_url()
        if Sys.iswindows()
            @test url == "https://ssd.mathworks.com/supportfiles/downloads/$(MCR.DEFAULT_RELEASE)/Release/0/deployment_files/installer/complete/win64/MATLAB_Runtime_$(MCR.DEFAULT_RELEASE)_win64.zip"
        else
            @test url == "https://ssd.mathworks.com/supportfiles/downloads/$(MCR.DEFAULT_RELEASE)/Release/0/deployment_files/installer/complete/glnxa64/MATLAB_Runtime_$(MCR.DEFAULT_RELEASE)_glnxa64.zip"
        end
        # update releases append _Update_<n> to the file name
        url1 = MCR.download_url(; release = "R2020a", update = "5")
        @test occursin("/R2020a/Release/5/deployment_files/installer/complete/", url1)
        @test endswith(url1, "MATLAB_Runtime_R2020a_Update_5_" * MCR._platform() * ".zip")
    end

    @testset "download URL is reachable" begin
        resp = Downloads.request(MCR.download_url())
        @test resp.status == 200
    end

    @testset "version/env helpers against a fake runtime root" begin
        mktempdir() do root
            vdir = joinpath(root, "v26.2", "runtime", MCR._platform())
            bin = joinpath(root, "v26.2", "bin", MCR._platform())
            mkpath(vdir)
            mkpath(bin)
            @test MCR.mcr_version(root) == "26.2"
            @test MCR.runtime_lib_dir(root) == vdir
            env = MCR.mcr_env(root)
            if Sys.iswindows()
                @test haskey(env, "PATH")
                @test occursin(vdir, env["PATH"])
            else
                @test haskey(env, "LD_LIBRARY_PATH")
                @test occursin(vdir, env["LD_LIBRARY_PATH"])
            end
            cmd = MCR.with_runtime(`foo`; root)
            @test cmd isa Cmd
            envkey = Sys.iswindows() ? "PATH" : "LD_LIBRARY_PATH"
            envdict = Dict{String,String}()
            for entry in cmd.env
                if entry isa Pair
                    envdict[entry.first] = entry.second
                else
                    k, v = split(entry, "="; limit = 2)
                    envdict[k] = v
                end
            end
            @test occursin(vdir, get(envdict, envkey, ""))
        end
    end

    @testset "release/version mapping" begin
        @test MCR.release_version("R2026b") == "26.2"
        @test MCR.release_version("R2025a") == "25.1"
        @test MCR.release_version("R2020a") == "20.1"
        @test_throws ErrorException MCR.release_version("2026b")
        @test_throws ErrorException MCR.release_version("R2026c")
    end

    @testset "container_tag" begin
        @test MCR.container_tag() == "r2026b"
        @test MCR.container_tag(; release = "R2020a", update = "5") == "r2020a-update-5"
        @test MCR.container_tag(; release = "R2020a", update = 5, variant = "full") == "r2020a-update-5-full"
        @test MCR.container_tag(; update = "0", variant = "full") == "r2026b-full"
    end

    @testset "container registry" begin
        if Sys.islinux() && Sys.ARCH === :x86_64
            token = nothing
            try
                token = MCR._container_token()
            catch
            end
            if token !== nothing
                @test length(token) > 100
                m = MCR._container_manifest(MCR.container_tag(), token)
                @test haskey(m, "layers")
                @test !isempty(m["layers"])
                @test all(haskey(l, "digest") for l in m["layers"])
            else
                @warn "Skipping container registry test (registry unreachable)"
            end
        end
    end

    @testset "marker logic" begin
        mktempdir() do dest
            MCR._write_marker(dest, "R2999a", "0")
            @test MCR._marker_field(dest, "release") == "R2999a"
            @test MCR._marker_field(dest, "platform") == MCR._platform()
            @test MCR._marker_field(dest, "source") == "installer"
            MCR._write_marker(dest, "R2999a", "1"; source = "container")
            @test MCR._marker_field(dest, "source") == "container"
        end
    end

    @testset "system runtime detection" begin
        # The explicit root hint always wins
        withenv("MATLABRUNTIME_JLL_ROOT" => "some_fake_dir") do
            @test MCR.mcr_root() == "some_fake_dir"
        end
        # Not installed anywhere in this test environment
        withenv("MATLABRUNTIME_JLL_ROOT" => nothing, "MCR_ROOT" => nothing) do
            @test MCR.find_system_runtime() === nothing
        end
    end

    @testset "is_installed" begin
        # The requested default release is not installed in a fresh environment
        withenv("MATLABRUNTIME_JLL_RELEASE" => "R2999a") do
            @test !MCR.is_installed()
        end
    end
end
