module MatlabRuntime_jll

using Downloads
using Preferences
using Scratch

export install, uninstall, is_installed, installed_releases,
    mcr_root, mcr_version, runtime_lib_dir, mcr_env, with_runtime, download_url

const DEFAULT_RELEASE = "R2026b"
const DEFAULT_UPDATE = "0"
const ENV_ROOT = "MATLABRUNTIME_JLL_ROOT"
const MARKER = ".matlabruntime_jll"
const _PATHSEP = Sys.iswindows() ? ';' : ':'

"""
    _setting(key, default) -> String

Resolve a setting from the environment variable
`MATLABRUNTIME_JLL_<KEY>` (highest priority), then the package
preference `key`, then `default`.
"""
function _setting(key, default)
    env = get(ENV, "MATLABRUNTIME_JLL_$(key)", "")
    isempty(env) || return strip(env)
    return string(@load_preference(key, default))
end

_release() = _setting("RELEASE", DEFAULT_RELEASE)
_update() = _setting("UPDATE", DEFAULT_UPDATE)
_autoinstall() = !parse(Bool, lowercase(get(ENV, "MATLABRUNTIME_JLL_NO_AUTO_INSTALL", "false")))

"""
    _platform() -> String

MathWorks platform identifier for the current system.
Supports Windows x64 (`win64`) and Linux x64 (`glnxa64`) only;
macOS is intentionally not supported.
"""
function _platform()
    if Sys.iswindows()
        Sys.ARCH === :x86_64 && return "win64"
        error("MatlabRuntime_jll supports only 64-bit Windows.")
    elseif Sys.islinux()
        Sys.ARCH === :x86_64 && return "glnxa64"
        error("MatlabRuntime_jll supports only 64-bit Linux (x86_64).")
    end
    error("MatlabRuntime_jll does not support this operating system; " *
          "only Windows x64 and Linux x64 are supported.")
end

"""
    download_url(; release = _release(), update = _update()) -> String

Direct download URL of the MATLAB Runtime installer zip from MathWorks.
`update = "0"` selects the base release; `"1"`, `"2"`, ... select update releases.
"""
function download_url(; release = _release(), update = _update())
    platform = _platform()
    upd = string(update)
    fname = upd == "0" ?
        "MATLAB_Runtime_$(release)_$(platform).zip" :
        "MATLAB_Runtime_$(release)_Update_$(upd)_$(platform).zip"
    return "https://ssd.mathworks.com/supportfiles/downloads/$(release)/Release/$(upd)/deployment_files/installer/complete/$(platform)/$(fname)"
end

_scratch() = @get_scratch!("matlabruntime")
_installer_dir() = joinpath(_scratch(), "installer")
_runtime_dir(release, update) = joinpath(_scratch(), "runtime", "$(release)_$(string(update))")

"""Directory names of the installed runtime versions (`v<ver>`) under `root`."""
function _version_dirs(root)
    isdir(root) || return String[]
    pat = r"^v\d+(\.\d+)*$"
    return [joinpath(root, d) for d in readdir(root)
            if isdir(joinpath(root, d)) && occursin(pat, d)]
end

"""True if the scratch install of `(release, update)` is complete and usable."""
function is_installed(release = _release(), update = _update())
    dest = _runtime_dir(string(release), string(update))
    marker = joinpath(dest, MARKER)
    isfile(marker) || return false
    try
        if _marker_field(dest, "platform") != _platform()
            return false
        end
    catch
        return false
    end
    return !isempty(_version_dirs(dest))
end

"""All `(release, update)` pairs currently installed in the scratch space."""
function installed_releases()
    root = joinpath(_scratch(), "runtime")
    out = Tuple{String,String}[]
    isdir(root) || return out
    for d in readdir(root)
        isfile(joinpath(root, d, MARKER)) || continue
        parts = split(d, "_"; limit = 2)
        length(parts) == 2 && push!(out, (parts[1], parts[2]))
    end
    return out
end

function _marker_field(dest, key)
    for line in eachline(joinpath(dest, MARKER))
        k, v = split(line, "="; limit = 2)
        strip(k) == key && return strip(v)
    end
    error("Marker file for $(dest) has no field $(key)")
end

function _write_marker(dest, release, update)
    open(joinpath(dest, MARKER), "w") do io
        println(io, "release=", release)
        println(io, "update=", update)
        println(io, "platform=", _platform())
    end
end

"""
    _ensure_downloaded(url, zip)

Download `url` to `zip`, reusing an existing archive if its size matches the
`Content-Length` of the remote file (protects against re-downloading a
multi-GB installer after a failed/interrupted previous run).
"""
function _ensure_downloaded(url, zip)
    if isfile(zip)
        reusable = false
        expected = nothing
        try
            resp = Downloads.request(url; method = "HEAD")
            headers = Dict(lowercase(k) => v for (k, v) in resp.headers)
            expected = tryparse(Int, get(headers, "content-length", ""))
            reusable = resp.status == 200 && expected !== nothing &&
                       filesize(zip) == expected
        catch
            reusable = false
        end
        if reusable
            @info "Reusing previously downloaded installer archive" zip
            return zip
        end
        @info "Existing archive is incomplete or stale; downloading again" zip
    end
    Downloads.download(url, zip)
    return zip
end

function _extract(zip, dest)
    mkpath(dest)
    if Sys.iswindows()
        # Use the Windows built-in bsdtar (System32\tar.exe). Do NOT use
        # Sys.which("tar"): on machines with Git Bash on PATH that resolves to
        # GNU tar, which cannot read zip files and chokes on C:\ paths.
        tar = joinpath(get(ENV, "SystemRoot", "C:\\Windows"), "System32", "tar.exe")
        if isfile(tar)
            run(`$tar -xf $zip -C $dest`)
        else
            shell = something(Sys.which("pwsh"), Sys.which("powershell"))
            shell === nothing && error(
                "Extraction requires Windows 10 1803+ (tar.exe) or PowerShell.")
            run(`$shell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '$zip' -DestinationPath '$dest'"`)
        end
    else
        unzip = Sys.which("unzip")
        bsdtar = Sys.which("bsdtar")
        if unzip !== nothing
            run(`$unzip -q $zip -d $dest`)
        elseif bsdtar !== nothing
            run(`$bsdtar -xf $zip -C $dest`)
        else
            py = Sys.which("python3")
            py = py === nothing ? Sys.which("python") : py
            py !== nothing || error("Extraction requires `unzip`, `bsdtar`, or Python on PATH.")
            run(`$py -m zipfile -e $zip $dest`)
        end
    end
end

"""Locate the installer executable inside the extracted installer zip."""
function _find_installer(dir)
    Sys.iswindows() || return joinpath(dir, "install")
    for (root, dirs, files) in walkdir(dir)
        for f in files
            endswith(lowercase(f), ".exe") && return joinpath(root, f)
        end
    end
    error("No installer executable found in $(dir)")
end

"""Whether the current process has administrator privileges (Windows only)."""
_is_elevated() =
    Sys.iswindows() ? ccall((:IsUserAnAdmin, :shell32), stdcall, Cint, ()) != 0 : true

"""
    _run_installer(installer, dest) -> Nothing

Run the extracted MATLAB Runtime installer silently, installing into `dest`.

On Windows the installer manifest requires administrator privileges
(`requireAdministrator`). If the current process is not elevated, the
installer is launched through PowerShell `Start-Process -Verb RunAs`, which
shows a single UAC consent prompt; the installation itself is silent.
"""
function _run_installer(installer, dest)
    flags = `-mode silent -agreeToLicense yes -destinationFolder $(dest)`
    if Sys.iswindows() && !_is_elevated()
        @info "MATLAB Runtime installer requires administrator privileges on Windows." *
              " A UAC consent dialog will appear; please approve it." installer
        shell = something(Sys.which("pwsh"), Sys.which("powershell"))
        shell === nothing && error("PowerShell is required to elevate the MATLAB Runtime installer.")
        ps1 = tempname() * ".ps1"
        open(ps1, "w") do io
            println(io, "\$ErrorActionPreference = 'Stop'")
            println(io, "\$p = Start-Process -FilePath '$installer' " *
                        "-ArgumentList '-mode','silent','-agreeToLicense','yes'," *
                        "'-destinationFolder','\"$dest\"' -Verb RunAs -Wait -PassThru")
            println(io, "exit \$p.ExitCode")
        end
        try
            run(`$shell -NoProfile -ExecutionPolicy Bypass -File $(ps1)`)
        finally
            rm(ps1; force = true)
        end
        return
    end
    # Invoke by absolute path: a bare `install` would resolve to
    # coreutils /usr/bin/install on Linux instead of the MathWorks script.
    # The cd matters because the installer expects to find its payload
    # relative to its own directory.
    cd(dirname(installer)) do
        run(`$(abspath(installer)) $(flags)`)
    end
    return
end

"""
    install(; release = _release(), update = _update(), force = false,
             keep_installer = false) -> String

Download the MATLAB Runtime installer for `(release, update)` from MathWorks
and run it silently, installing into the package scratch space
(`<depot>/scratchspaces/<uuid>/matlabruntime/runtime/<release>_<update>`).

Returns the installation root (the directory that contains the `v<ver>`
runtime folder). Reuses an existing installation unless `force = true`.
The downloaded zip and extracted installer are deleted afterwards unless
`keep_installer = true`.

Installing takes several GB of disk space and several minutes.
"""
function install(; release = _release(), update = _update(), force = false,
                 keep_installer = false)
    release = string(release)
    upd = string(update)
    platform = _platform()
    dest = _runtime_dir(release, upd)
    if !force && is_installed(release, upd)
        @info "MATLAB Runtime $(release) (update $(upd)) is already installed at $(dest)"
        return dest
    end

    url = download_url(; release, update = upd)
    @info "Downloading MATLAB Runtime $(release) (update $(upd), $(platform))" *
          " from MathWorks. This is a multi-GB download and may take a long time." url

    idir = _installer_dir()
    mkpath(idir)
    zip = joinpath(idir, "MATLAB_Runtime_$(release)_$(upd)_$(platform).zip")
    _ensure_downloaded(url, zip)

    exdir = joinpath(idir, "extracted_$(release)_$(upd)_$(platform)")
    rm(exdir; recursive = true, force = true)
    @info "Extracting installer archive"
    _extract(zip, exdir)
    if !Sys.iswindows()
        # The installer zip does not preserve executable bits; the installer
        # dies with exit code 42 when its helper binaries (e.g. silentlauncher)
        # cannot be executed. Mark all extracted files as executable.
        find = Sys.which("find")
        find === nothing || run(`$find $exdir -type f -exec chmod a+x "{}" +`)
    end

    installer = _find_installer(exdir)
    chmod(installer, 0o755)

    mkpath(dirname(dest))
    @info "Running MATLAB Runtime installer silently; this can take several minutes" dest
    _run_installer(installer, dest)

    isempty(_version_dirs(dest)) &&
        error("MATLAB Runtime installer finished but no v<version> directory was created in $(dest). " *
              (Sys.islinux() ?
                "If the installer exited with code 42, required OS libraries are missing " *
                "(on a minimal/headless system install e.g. " *
                "`apt-get install libnss3 libnspr4 libxi6 libxtst6 libxext6 libx11-6 libxcb1`). " * string("The installer log is in /tmp/mathworks_\$(get(ENV, \"USER\", \"user\")).log. ") :
                "") *
              "The installer may have failed; check its output above.")
    _write_marker(dest, release, upd)

    if !keep_installer
        rm(zip; force = true)
        rm(exdir; recursive = true, force = true)
    end
    @info "MATLAB Runtime $(release) (update $(upd)) installed at $(dest)"
    return dest
end

"""
    uninstall(; release = _release(), update = _update())

Remove the scratch-space installation of `(release, update)`.
"""
function uninstall(; release = _release(), update = _update())
    dest = _runtime_dir(string(release), string(update))
    if isdir(dest)
        rm(dest; recursive = true, force = true)
        @info "Removed MATLAB Runtime installation at $(dest)"
    end
    return nothing
end

"""
    find_system_runtime() -> Union{String, Nothing}

Look for an existing system-wide MATLAB Runtime installation in the usual
default locations. Returns the root directory (containing `v<ver>` folders),
or `nothing` if none is found.
"""
function find_system_runtime()
    hint = get(ENV, ENV_ROOT, "")
    hint = isempty(hint) ? get(ENV, "MCR_ROOT", "") : hint
    candidates = String[]
    isempty(hint) || push!(candidates, hint)
    if Sys.iswindows()
        pf = get(ENV, "ProgramFiles", "C:\\Program Files")
        push!(candidates, joinpath(pf, "MATLAB", "MATLAB Runtime"))
    elseif Sys.islinux()
        push!(candidates, "/usr/local/MATLAB/MATLAB_Runtime",
                          "/opt/MATLAB/MATLAB_Runtime",
                          "/opt/MATLAB_Runtime")
    end
    for c in candidates
        if isdir(c) && !isempty(_version_dirs(c))
            return c
        end
    end
    return nothing
end

"""
    mcr_root(; release = _release(), update = _update(), autoinstall = _autoinstall()) -> String

Installation root of the MATLAB Runtime, i.e. the directory that contains
`v<ver>` runtime folders. This is also the path you pass to the `run_*.sh` /
`run_*.bat` launchers of compiled applications.

Resolution order:
1. the environment variable `MATLABRUNTIME_JLL_ROOT` (explicit root, wins always),
2. the package-managed installation of `(release, update)`,
3. an automatic download + silent install (unless `autoinstall = false`
   or `MATLABRUNTIME_JLL_NO_AUTO_INSTALL=true`),
4. a system-wide installation in the default locations (with a warning).

Throws an error if nothing is found and automatic installation is disabled.
"""
function mcr_root(; release = _release(), update = _update(), autoinstall = _autoinstall())
    explicit = get(ENV, ENV_ROOT, "")
    isempty(explicit) || return explicit
    if is_installed(release, update)
        return _runtime_dir(string(release), string(update))
    end
    if autoinstall
        return install(; release, update)
    end
    sys = find_system_runtime()
    sys === nothing && error(
        "MATLAB Runtime is not installed. Run `using MatlabRuntime_jll; MatlabRuntime_jll.install()` " *
        "or set $(ENV_ROOT) to an existing runtime root, or unset " *
        "MATLABRUNTIME_JLL_NO_AUTO_INSTALL to allow automatic installation.")
    @warn "No package-managed MATLAB Runtime found; using system installation. " *
          "Its version may not match the requested release $(release)." sys
    return sys
end

"""
    mcr_version(root = mcr_root()) -> String

Runtime version string of the (single) installed runtime under `root`,
e.g. `"26.2"` for R2026b. This corresponds to the `v<ver>` folder name.
"""
function mcr_version(root = mcr_root())
    dirs = _version_dirs(root)
    isempty(dirs) && error("No v<version> runtime directory found under $(root)")
    length(dirs) == 1 || @warn "Multiple runtime versions under $(root); using the first" dirs
    return replace(basename(first(dirs)), "v" => "")
end

"""
    runtime_lib_dir(root = mcr_root()) -> String

Directory that contains the MATLAB Runtime shared libraries
(`<root>/v<ver>/runtime/<arch>`), for users who need the raw DLL/SO path.
"""
function runtime_lib_dir(root = mcr_root())
    return joinpath(root, "v" * mcr_version(root), "runtime", _platform())
end

"""
    mcr_env(root = mcr_root()) -> Dict{String,String}

Environment variables required to execute binaries compiled with MATLAB
Compiler against the runtime at `root`:

- Windows: `PATH` including `runtime`, `bin` and `sys/os` library dirs,
- Linux: `LD_LIBRARY_PATH` with the same directories.

Use [`with_runtime`](@ref) to apply these to a command.
"""
function mcr_env(root = mcr_root())
    verdir = joinpath(root, "v" * mcr_version(root))
    arch = _platform()
    dirs = [joinpath(verdir, d, arch) for d in ("runtime", "bin", "sys/os")]
    filter!(isdir, dirs)
    isempty(dirs) && error("No runtime library directories found under $(verdir)")
    joined = join(dirs, _PATHSEP)
    if Sys.iswindows()
        return Dict("PATH" => joined)
    end
    return Dict("LD_LIBRARY_PATH" => joined)
end

"""
    with_runtime(cmd::Cmd; root = mcr_root()) -> Cmd

Wrap a command that was compiled against the MATLAB Runtime so that it can
find the runtime libraries, prepending the required environment variables
to the current environment:

```julia
run(MCR.with_runtime(`./my_compiled_app --flag`))
```
"""
function with_runtime(cmd::Cmd; root = mcr_root())
    env = copy(ENV)
    for (k, v) in mcr_env(root)
        prev = get(ENV, k, "")
        env[k] = isempty(prev) ? v : string(v, _PATHSEP, prev)
    end
    return setenv(cmd, env)
end

end # module
