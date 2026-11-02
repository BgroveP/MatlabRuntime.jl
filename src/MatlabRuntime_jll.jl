module MatlabRuntime_jll

using Downloads
using JSON
using Preferences
using Scratch

export install, uninstall, is_installed, installed_releases,
    mcr_root, mcr_version, runtime_lib_dir, mcr_env, with_runtime,
    download_url, container_tag, release_version, version_dir,
    find_system_runtime

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

Direct download URL of the MATLAB Runtime installer from MathWorks.

Two URL schemes exist, selected automatically by release:

- R2019a and newer: the current zipped installer,
  `.../<release>/Release/<update>/deployment_files/installer/complete/<platform>/MATLAB_Runtime_<release>_<platform>.zip`;
  `update = "0"` selects the base release, `"1"`, `"2"`, ... the update releases.
- R2013b .. R2018a: the legacy "MCR" installer scheme,
  `.../<release>/deployment_files/<release>/installers/<platform>/MCR_<release>_<platform>_installer.zip`
  (a `.exe` on Windows). Update installers do not exist for these releases,
  so `update` must be `"0"`.
"""
function download_url(; release = _release(), update = _update())
    platform = _platform()
    upd = string(update)
    if _release_index(string(release)) < _MODERN_INSTALLER_MIN
        upd == "0" || isempty(upd) ||
            error("Update installers do not exist for releases before R2019a; " *
                  "requested $(release) update $(upd).")
        ext = Sys.iswindows() ? "exe" : "zip"
        fname = "MCR_$(release)_$(platform)_installer.$(ext)"
        return "https://ssd.mathworks.com/supportfiles/downloads/$(release)/deployment_files/$(release)/installers/$(platform)/$(fname)"
    end
    fname = upd == "0" ?
        "MATLAB_Runtime_$(release)_$(platform).zip" :
        "MATLAB_Runtime_$(release)_Update_$(upd)_$(platform).zip"
    return "https://ssd.mathworks.com/supportfiles/downloads/$(release)/Release/$(upd)/deployment_files/installer/complete/$(platform)/$(fname)"
end

_scratch() = @get_scratch!("matlabruntime")
_installer_dir() = joinpath(_scratch(), "installer")
_runtime_dir(release, update) = joinpath(_scratch(), "runtime", "$(release)_$(string(update))")

#------------------------- Container backend ------------------------
# The official MATLAB Runtime container image
# (containers.mathworks.com/matlab-runtime:<tag>) contains a fully
# installed runtime under /opt/matlabruntime. Pulling the image layers
# directly over the OCI registry HTTP API and unpacking them requires no
# Docker/Singularity, no admin rights, and never runs the (fragile)
# MathWorks installer.

const _REGISTRY = "containers.mathworks.com"
const _REPO = "matlab-runtime"
const _AUTH_REALM = "https://containers-auth.mathworks.com/auth"
const _AUTH_SERVICE = "mathworksdockerregistry"
const _MANIFEST_ACCEPT = "application/vnd.oci.image.index.v1+json, " *
    "application/vnd.oci.image.manifest.v1+json, " *
    "application/vnd.docker.distribution.manifest.list.v2+json, " *
    "application/vnd.docker.distribution.manifest.v2+json"

"""
    release_version(release = _release()) -> String

MATLAB Runtime version string for a release name, using MATLAB's historical
version numbering:

- `R2023b` and newer: year-based, e.g. `"R2026b"` -> `"26.2"`
- `R2016a` .. `R2023a`: `9.x`, e.g. `"R2017a"` -> `"9.2"`, `"R2021a"` -> `"9.10"`
- `R2013a` .. `R2015b`: `8.x`, e.g. `"R2013b"` -> `"8.2"`

Note that a deployed binary only runs against the exact runtime version it
was compiled with, so this mapping matters when serving old applications.
"""
function release_version(release = _release())
    m = match(r"^R(\d{4})([ab])$", string(release))
    m === nothing && error("Invalid MATLAB release name \"$(release)\" " *
                           "(expected e.g. \"R2026b\")")
    year = parse(Int, m.captures[1])
    half = m.captures[2] == "a" ? 0 : 1
    if year > 2023 || (year == 2023 && half == 1)
        # year-based scheme, introduced with R2023b (23.2)
        return string(year % 100, ".", half == 0 ? 1 : 2)
    elseif year >= 2016
        # 9.x scheme: R2016a = 9.0 ... R2023a = 9.14
        return string("9.", (year - 2016) * 2 + half)
    elseif year >= 2013
        # 8.x scheme: R2013a = 8.1 ... R2015b = 8.6
        return string("8.", (year - 2013) * 2 + half + 1)
    end
    error("MATLAB releases before R2013a are not supported.")
end

"""
    version_dir(release = _release()) -> String

Name of the `v<version>` directory of a runtime installation for `release`,
matching what the MathWorks installer creates: the version string without
the dot, e.g. `"R2017a"` -> `"v92"`, `"R2021a"` -> `"v910"`,
`"R2026b"` -> `"v262"`.
"""
version_dir(release = _release()) = "v" * replace(release_version(release), "." => "")

"""Folder names a runtime tree could use for `release` (dotless and dotted)."""
_version_dir_candidates(release) =
    unique([version_dir(release), "v" * release_version(release)])

"""
    container_tag(; release = _release(), update = _update(), variant = "") -> String

Tag of the official MATLAB Runtime container image on
`containers.mathworks.com` for `(release, update)`, e.g. `("R2026b", "2")`
-> `"r2026b-update-2"`. `variant = "full"` selects the image that includes
the GPU libraries.
"""
function container_tag(; release = _release(), update = _update(), variant = "")
    tag = "r" * lowercase(string(release)[2:end])
    upd = string(update)
    tag = isempty(upd) || upd == "0" ? tag : tag * "-update-" * upd
    v = string(variant)
    return isempty(v) ? tag : tag * "-" * v
end

_container_arch() =
    Sys.ARCH === :x86_64 ? "amd64" :
    error("The MATLAB Runtime container image supports only x86_64 Linux.")

"""Anonymous pull token for the MathWorks container registry."""
function _container_token()
    url = "$(_AUTH_REALM)?service=$(_AUTH_SERVICE)&scope=repository:$(_REPO):pull"
    body = String(take!(Downloads.download(url, IOBuffer())))
    m = match(r"\"token\"\s*:\s*\"([^\"]+)\"", body)
    m === nothing && error("Could not obtain a container registry token: $(body)")
    return m.captures[1]
end

function _fetch_json(url, headers)
    return JSON.parse(String(take!(Downloads.download(url, IOBuffer(); headers))))
end

"""Image manifest for `tag`; resolves multi-arch indexes to the amd64 image."""
function _container_manifest(tag, token)
    url = "https://$(_REGISTRY)/v2/$(_REPO)/manifests/$(tag)"
    headers = ["Accept" => _MANIFEST_ACCEPT, "Authorization" => "Bearer $(token)"]
    manifest = _fetch_json(url, headers)
    if haskey(manifest, "manifests")
        arch = _container_arch()
        refs = [e for e in manifest["manifests"]
                if get(get(e, "platform", Dict()), "architecture", "") == arch]
        isempty(refs) && error("Container image $(tag) has no $(arch) build.")
        digest = refs[1]["digest"]
        manifest = _fetch_json("https://$(_REGISTRY)/v2/$(_REPO)/manifests/$(digest)", headers)
    end
    return manifest
end

function _download_blob(digest, dest; token)
    url = "https://$(_REGISTRY)/v2/$(_REPO)/blobs/$(digest)"
    Downloads.download(url, dest; headers = ["Authorization" => "Bearer $(token)"])
    return dest
end

"""
    _extract_container_layer(tgz, dest)

Extract one OCI image layer (a gzipped tar) into `dest`, then apply overlay
whiteouts (`.wh.*` entries deleting files from lower layers).
"""
function _extract_container_layer(tgz, dest)
    tar = something(Sys.which("tar"), Sys.which("bsdtar"))
    tar === nothing && error("Extracting container layers requires `tar` on PATH.")
    run(`$tar -xzf $(tgz) -C $(dest)`)
    # Collect whiteout entries first, then apply them: modifying the tree
    # while walkdir iterates it causes ENOENT errors.
    whiteouts = String[]
    try
        for (root, dirs, files) in walkdir(dest)
            for f in files
                startswith(f, ".wh.") && push!(whiteouts, joinpath(root, f))
            end
        end
    catch err
        # A dangling symlinked directory can make walkdir fail; whiteouts
        # are an edge case, so continue with what was collected.
        err isa IOError || rethrow()
    end
    for wh in whiteouts
        dir = dirname(wh)
        f = basename(wh)
        if f == ".wh..wh..opq"
            for e in readdir(dir)
                e == f && continue
                rm(joinpath(dir, e); recursive = true, force = true)
            end
        else
            rm(joinpath(dir, f[5:end]); recursive = true, force = true)
        end
        rm(wh; force = true)
    end
    return dest
end

"""
    _install_from_container(release, upd; variant, force, keep_installer) -> String

Install the MATLAB Runtime by pulling the official MathWorks container image
for `(release, upd)` and unpacking the already-installed runtime tree into the
package scratch space. No installer is executed and no admin rights are
required. Returns the runtime root (the directory containing `v<ver>`).
"""
function _install_from_container(release, upd; variant = "", force = false,
                                 keep_installer = false)
    tag = container_tag(; release, update = upd, variant)
    dest = _runtime_dir(release, upd)
    mkpath(dirname(dest))

    @info "Installing MATLAB Runtime $(release) (update $(upd)) from the MathWorks " *
          "container image (no installer is run)" tag dest
    token = _container_token()
    manifest = _container_manifest(tag, token)
    layers = get(manifest, "layers", nothing)
    (layers === nothing || isempty(layers)) &&
        error("Container manifest for $(tag) has no layers.")

    idir = joinpath(_installer_dir(), "container_$(tag)")
    mkpath(idir)
    rootfs = joinpath(idir, "rootfs")
    rm(rootfs; recursive = true, force = true)
    mkpath(rootfs)

    nonempty = [l for l in layers if l["size"] > 0]
    for (i, layer) in enumerate(nonempty)
        digest = layer["digest"]
        lname = "layer_$(i)_$(split(digest, ":")[end][1:12]).tgz"
        lpath = joinpath(idir, lname)
        if isfile(lpath) && filesize(lpath) == layer["size"]
            @info "Reusing previously downloaded container layer" lpath
        else
            @info "Downloading container layer $(i)/$(length(nonempty))" size_MB = layer["size"] ÷ 1048576
            try
                _download_blob(digest, lpath; token)
            catch
                # the anonymous token may have expired mid-download; retry once
                _download_blob(digest, lpath; token = _container_token())
            end
        end
        @info "Extracting container layer $(i)/$(length(nonempty))"
        _extract_container_layer(lpath, rootfs)
    end

    rt = joinpath(rootfs, "opt", "matlabruntime")
    isdir(rt) || error("Container image $(tag) has no /opt/matlabruntime directory.")
    vname = version_dir(release)  # e.g. v92, v262: the installer's convention
    if !isdir(joinpath(rt, vname))
        found = nothing
        for d in readdir(rt)
            isdir(joinpath(rt, d)) || continue
            if isdir(joinpath(rt, d, "runtime", _platform()))
                found = d
                break
            end
        end
        found === nothing && error("No runtime found in container image under $(rt).")
        mv(joinpath(rt, found), joinpath(rt, vname))
    end

    # Same scratch filesystem: this is a cheap rename.
    mv(rt, dest)
    _write_marker(dest, release, upd; source = "container")
    rm(rootfs; recursive = true, force = true)
    keep_installer || rm(idir; recursive = true, force = true)
    @info "MATLAB Runtime $(release) (update $(upd)) installed at $(dest)" tag
    return dest
end


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

function _write_marker(dest, release, update; source = "installer")
    open(joinpath(dest, MARKER), "w") do io
        println(io, "release=", release)
        println(io, "update=", update)
        println(io, "platform=", _platform())
        println(io, "source=", source)
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

"""Locate the installer entry point inside the extracted installer zip/dir."""
function _find_installer(dir)
    if !Sys.iswindows()
        cand = joinpath(dir, "install")
        isfile(cand) && return cand
        # legacy zips may nest one directory level deep
        for (root, dirs, files) in walkdir(dir)
            "install" in files && return joinpath(root, "install")
        end
        error("No installer entry point found in $(dir)")
    end
    for (root, dirs, files) in walkdir(dir)
        for f in files
            endswith(lowercase(f), ".exe") && return joinpath(root, f)
        end
    end
    error("No installer executable found in $(dir)")
end

"""
    _extraction_complete(dir) -> Bool

Whether `dir` contains a complete extracted installer: the entry-point
script/executable plus the per-architecture installer binary for the
current platform. Used to decide whether a previous extraction can be
reused instead of re-extracting the multi-GB archive.
"""
function _extraction_complete(dir)
    isdir(dir) || return false
    try
        _find_installer(dir)
    catch
        return false
    end
    Sys.iswindows() && return true
    archbin = joinpath(dirname(_find_installer(dir)), "bin", _platform())
    isdir(archbin) || return false
    return any(isfile(joinpath(archbin, f)) for f in
               ("MathWorksProductInstaller", "MATLABRuntimeInstaller",
                "install_unix", "install_unix_legacy", "MCRInstaller"))
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

"""Sort key for release ordering: R2017a -> 4034, R2017b -> 4035, ..."""
function _release_index(release)
    m = match(r"^R(\d{4})([ab])$", string(release))
    m === nothing && error("Invalid MATLAB release name \"$(release)\" " *
                           "(expected e.g. \"R2026b\")")
    return parse(Int, m.captures[1]) * 2 + (m.captures[2] == "b")
end

# MathWorks distribution boundaries, determined empirically:
# - the current installer download URLs serve R2019a and newer
# - the legacy MCR installer URLs serve R2013b .. R2018a
# - the container registry has images from R2021b onward
# Older releases are gone; a matching runtime tree must come from an
# existing installation (find_system_runtime / env override).
const _MODERN_INSTALLER_MIN = _release_index("R2019a")
const _LEGACY_INSTALLER_MIN = _release_index("R2013b")
const _CONTAINER_MIN = _release_index("R2021b")

"""Error thrown when MathWorks no longer distributes the requested release."""
function _undistributed_error(release)
    vd = try
        version_dir(release)
    catch
        ""  # releases before R2013a have no version mapping either
    end
    target = isempty(vd) ? "the release's v<ver> folder" : vd
    return ErrorException(
        "MATLAB Runtime $(release) is not distributed by MathWorks anymore: " *
        "installer downloads are available from R2013b onward and container images " *
        "from R2021b onward, and MATLAB-compiled binaries require the exact runtime " *
        "version they were built with. Point the package at an existing installation " *
        "instead: set $(ENV_ROOT) (or MCR_ROOT) to a runtime root containing " *
        "$(target), or use find_system_runtime(; release = \"$(release)\") " *
        "to locate a system-wide installation.")
end

"""
    install(; release = _release(), update = _update(), force = false,
             keep_installer = false, backend = _setting("BACKEND", "auto"),
             variant = _setting("VARIANT", "")) -> String

Install the MATLAB Runtime for `(release, update)` into the package scratch
space (`<depot>/scratchspaces/<uuid>/matlabruntime/runtime/<release>_<update>`)
and return the installation root (the directory that contains the `v<ver>`
runtime folder).

Backends (`MATLABRUNTIME_JLL_BACKEND` / the `backend` preference):

- `"container"` (default on Linux): pull the official MathWorks container
  image `containers.mathworks.com/matlab-runtime` and unpack the
  already-installed runtime. Pure HTTP + `tar`; no Docker/Singularity, no
  admin rights, and the MathWorks installer is never executed.
  `variant = "full"` selects the image variant that includes GPU libraries.
- `"installer"` (default on Windows, fallback on Linux): download the
  installer zip from MathWorks and run it silently.

`auto` picks `container` on Linux and `installer` on Windows, and falls back
to the installer if the container pull fails. On Windows the installer
manifest requires administrator privileges; if Julia is not running elevated
a single UAC consent prompt is shown.

Releases that MathWorks no longer distributes (installer downloads start at
R2013b, container images at R2021b) fail immediately with an error explaining
how to use an existing runtime tree via `MATLABRUNTIME_JLL_ROOT` or
`find_system_runtime`. For R2013b .. R2018a the installer backend downloads
the legacy MCR installer; update installers do not exist for those releases.

Installing takes several GB of disk space and several minutes.
"""
function install(; release = _release(), update = _update(), force = false,
                 keep_installer = false, backend = _setting("BACKEND", "auto"),
                 variant = _setting("VARIANT", ""))
    release = string(release)
    upd = string(update)
    _platform()  # validate the platform up front
    dest = _runtime_dir(release, upd)
    if !force && is_installed(release, upd)
        @info "MATLAB Runtime $(release) (update $(upd)) is already installed at $(dest)"
        return dest
    end

    b = lowercase(string(backend))
    idx = _release_index(release)
    container_possible = !Sys.iswindows() && idx >= _CONTAINER_MIN
    installer_possible = idx >= _LEGACY_INSTALLER_MIN

    if !container_possible && !installer_possible
        throw(_undistributed_error(release))
    end
    if b == "container" && !container_possible
        Sys.iswindows() &&
            error("The container backend is not available on Windows; use backend \"installer\".")
        installer_possible || throw(_undistributed_error(release))
        error("No container image exists for $(release) (images start at R2021b); " *
              "use backend \"installer\".")
    end

    if b in ("", "auto", "container") && container_possible
        try
            return _install_from_container(release, upd; variant, force, keep_installer)
        catch err
            b == "container" && rethrow()
            @warn "Container install failed; falling back to the MathWorks installer" exception = (err, catch_backtrace())
        end
    end
    return _install_from_installer(release, upd; force, keep_installer)
end

"""
    _install_from_installer(release, upd; force, keep_installer) -> String

Install the runtime the classic way: download the MATLAB Runtime installer
zip from MathWorks and run it silently. See [`install`](@ref) for the
public entry point.
"""
function _install_from_installer(release, upd; force = false, keep_installer = false)
    platform = _platform()
    dest = _runtime_dir(release, upd)

    url = download_url(; release, update = upd)
    @info "Downloading MATLAB Runtime installer for $(release) (update $(upd), $(platform))" url

    idir = _installer_dir()
    mkpath(idir)
    archive = joinpath(idir, basename(url))
    _ensure_downloaded(url, archive)

    mkpath(dirname(dest))
    installer = if Sys.iswindows() && endswith(lowercase(basename(url)), ".exe")
        # Legacy MCR installer (R2018a and earlier): a self-extracting exe
        # that IS the installer; run it directly, no extraction step.
        archive
    else
        exdir = joinpath(idir, "extracted_$(release)_$(upd)_$(platform)")
        if !force && _extraction_complete(exdir)
            @info "Reusing previously extracted installer" exdir
        else
            rm(exdir; recursive = true, force = true)
            @info "Extracting installer archive"
            _extract(archive, exdir)
        end
        if !Sys.iswindows()
            # The installer zip does not preserve executable bits; the installer
            # dies with exit code 42 when its helper binaries (e.g. silentlauncher)
            # cannot be executed. Mark all extracted files as executable.
            find = Sys.which("find")
            find === nothing || run(`$find $exdir -type f -exec chmod a+x "{}" +`)
        end
        _find_installer(exdir)
    end
    chmod(installer, 0o755)

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
        rm(archive; force = true)
        exdir = joinpath(idir, "extracted_$(release)_$(upd)_$(platform)")
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
    find_system_runtime(; release = nothing) -> Union{String, Nothing}

Look for an existing system-wide MATLAB Runtime installation in the usual
default locations. Returns the root directory (containing `v<ver>` folders),
or `nothing` if none is found.

When `release` is given (e.g. `"R2017a"`), only a root that actually contains
that release's runtime version directory (e.g. `v92`, matching both the
dotted and dotless naming conventions) is accepted. This is how to locate an
old runtime that MathWorks no longer distributes (R2018a and earlier are not
downloadable and have no container image).
"""
function find_system_runtime(; release = nothing)
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
        isdir(c) || continue
        if release === nothing
            isempty(_version_dirs(c)) || return c
        else
            any(isdir(joinpath(c, d)) for d in _version_dir_candidates(string(release))) &&
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
    sys = find_system_runtime(; release)
    sys === nothing && error(
        "MATLAB Runtime is not installed. Run `using MatlabRuntime_jll; MatlabRuntime_jll.install()` " *
        "or set $(ENV_ROOT) to an existing runtime root, or unset " *
        "MATLABRUNTIME_JLL_NO_AUTO_INSTALL to allow automatic installation.")
    @warn "No package-managed MATLAB Runtime found; using system installation." sys
    return sys
end

"""
    mcr_version(root = mcr_root()) -> String

Runtime version string of the (single) installed runtime under `root`,
e.g. `"26.2"` for R2026b or `"9.2"` for R2017a. For package-managed
installs the version is derived from the recorded release; otherwise it
is taken from the `v<ver>` folder name as-is (dotless for old runtimes,
e.g. `"92"` for a `v92` tree).
"""
function mcr_version(root = mcr_root())
    marker = joinpath(root, MARKER)
    if isfile(marker)
        try
            return release_version(_marker_field(root, "release"))
        catch
        end
    end
    dirs = _version_dirs(root)
    isempty(dirs) && error("No v<version> runtime directory found under $(root)")
    length(dirs) == 1 || @warn "Multiple runtime versions under $(root); using the first" dirs
    return replace(basename(first(dirs)), "v" => "")
end

"""
The `v<ver>` directory of the runtime installed under `root`. Uses the
directory that actually exists, so both dotless (`v92`) and dotted
(`v26.2`) conventions work, including for system-wide installations.
"""
function _version_dir_of(root)
    dirs = _version_dirs(root)
    isempty(dirs) && error("No v<version> runtime directory found under $(root)")
    length(dirs) == 1 || @warn "Multiple runtime versions under $(root); using the first" dirs
    return first(dirs)
end

"""
    runtime_lib_dir(root = mcr_root()) -> String

Directory that contains the MATLAB Runtime shared libraries
(`<root>/v<ver>/runtime/<arch>`), for users who need the raw DLL/SO path.
"""
function runtime_lib_dir(root = mcr_root())
    return joinpath(_version_dir_of(root), "runtime", _platform())
end

"""
    mcr_env(root = mcr_root()) -> Dict{String,String}

Environment variables required to execute binaries compiled with MATLAB
Compiler against the runtime at `root`:

- Windows: `PATH` including `runtime`, `bin` and `sys/os` library dirs,
- Linux: `LD_LIBRARY_PATH` with the same directories (plus `sys/opengl/lib`
  and `extern/bin` when present).

Use [`with_runtime`](@ref) to apply these to a command.
"""
function mcr_env(root = mcr_root())
    verdir = _version_dir_of(root)
    arch = _platform()
    subdirs = Sys.iswindows() ? ("runtime", "bin", "sys/os") :
              ("runtime", "bin", "sys/os", "sys/opengl/lib", "extern/bin")
    dirs = [joinpath(verdir, d, arch) for d in subdirs]
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
