# MatlabRuntime_jll

A Julia `_jll`-style package that downloads and silently installs the
[MATLAB Runtime](https://www.mathworks.com/products/compiler/matlab-runtime.html)
so that other packages can execute binaries compiled with MATLAB Compiler,
without requiring a MATLAB installation.

Supported platforms: **Windows x64** (`win64`) and **Linux x64** (`glnxa64`).
macOS is intentionally not supported.

> **Note (Windows):** MathWorks' runtime installer (`setup.exe`) requires
> administrator privileges (`requireAdministrator` manifest). If Julia is
> not running elevated, `install()` triggers a single UAC consent prompt via
> PowerShell `Start-Process -Verb RunAs`; the installation itself is silent.
> If you decline the prompt, installation is aborted. Linux needs no
> elevation because the runtime installs into a user-writable directory.

## Usage

```julia
using MatlabRuntime_jll

# Downloads the MATLAB Runtime installer from MathWorks and installs it
# silently into the package scratch space. Multi-GB, several minutes.
MatlabRuntime_jll.install()

# Runtime root (directory containing v<ver> runtime folders):
MatlabRuntime_jll.mcr_root()

# Run a binary compiled against the runtime:
app = joinpath(pkgdir(MyApp), "bin", "myapp")
run(MatlabRuntime_jll.with_runtime(`$app arg1 arg2`))
```

`mcr_root()` automatically triggers `install()` the first time it is called,
so most dependent packages never need to call `install()` explicitly.

### Choosing a release

The default release is R2026b (base update). Dependent packages can pin a
release via their `Project.toml`:

```toml
[preferences."MatlabRuntime_jll"]
release = "R2024b"
update = "0"
```

or users can set the environment variables `MATLABRUNTIME_JLL_RELEASE` /
`MATLABRUNTIME_JLL_UPDATE`. `update = "0"` is the base release; `"1"`, `"2"`,
... select update releases (the installer URL and file name change accordingly).

### Environment variables

| Variable | Effect |
| --- | --- |
| `MATLABRUNTIME_JLL_ROOT` | Use this existing runtime root (directory containing `v<ver>` folders); skips all downloads. |
| `MATLABRUNTIME_JLL_RELEASE` / `MATLABRUNTIME_JLL_UPDATE` | Override the requested release/update. |
| `MATLABRUNTIME_JLL_NO_AUTO_INSTALL` | Set to `true` to disable automatic download+install from `mcr_root()`. |

### Where the runtime is installed

`~/.julia/scratchspaces/5c36b28e-dfcf-4811-ae13-b40b84046936/matlabruntime/runtime/<release>_<update>/v<ver>/`

Each release/update installs into its own subdirectory, so several runtime
versions can coexist. `MatlabRuntime_jll.uninstall()` removes one.
`Scratch.cleanup()` (or deleting the scratchspace dir) removes everything.

## API

| Function | Description |
| --- | --- |
| `install(; release, update, force, keep_installer)` | Download + silent install; returns the runtime root. |
| `uninstall(; release, update)` | Remove a scratch-space installation. |
| `is_installed([release, [update]])` | Whether the runtime is installed. |
| `installed_releases()` | List installed `(release, update)` pairs. |
| `download_url(; release, update)` | Direct MathWorks download URL for the installer zip. |
| `mcr_root()` | Installation root (contains `v<ver>`). Pass to `run_*.sh`/`run_*.bat` launchers. |
| `mcr_version([root])` | Runtime version string, e.g. `"26.2"`. |
| `runtime_lib_dir([root])` | Directory with the runtime shared libraries. |
| `mcr_env([root])` | `Dict` of env vars (`PATH` / `LD_LIBRARY_PATH`) needed by compiled binaries. |
| `with_runtime(cmd; root)` | A `Cmd` with those env vars applied, ready for `run`. |
| `find_system_runtime()` | Look for a system-wide MATLAB Runtime in default locations. |

## License note

Downloading the MATLAB Runtime implies acceptance of the MathWorks license.
The runtime itself is proprietary; this package only automates its
download and installation.
