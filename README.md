> Safeer development patch: see SAFEER-BUILD.md. Not yet Windows-build validated.

# milutv-libmpv

LGPL builds of [libmpv](https://mpv.io) for Windows x64 and arm64, with [ANGLE](https://chromium.googlesource.com/angle/angle), as used by the MiluTV Windows app.

This repository is both the build and the publication the GNU LGPL asks for: the recipe, the pinned
sources and the scripts that produce every released DLL are here, and each release carries the
complete corresponding source.

## Licence

- `libmpv-2.dll` is distributed under the **GNU Lesser General Public License v2.1 or later**
  ([COPYING.LGPL-2.1](COPYING.LGPL-2.1)). mpv is built with `-Dgpl=false`; FFmpeg is built without
  `gpl`, `version3` or `nonfree`, so it stays LGPL v2.1 or later. Every other library linked into the
  DLL is under a compatible licence: libplacebo and FriBidi (LGPL-2.1), libass (ISC), FreeType
  (FreeType License), HarfBuzz (MIT-style), zlib (zlib License). Their licence texts are in the
  `licenses/` folder of each archive.
- `libEGL.dll` and `libGLESv2.dll` are ANGLE, under the BSD-3-Clause licence.
- The scripts of this repository are under the LGPL v2.1 or later as well.

Every release proves its FFmpeg licence from the build itself: `ffmpeg-license-<arch>.txt` quotes
FFmpeg's generated `config.h` (`CONFIG_GPL 0`, `CONFIG_VERSION3 0`, `CONFIG_NONFREE 0`,
`FFMPEG_LICENSE "LGPL version 2.1 or later"`), mpv's `HAVE_GPL 0` and feature list, and the full
FFmpeg configuration. The build fails instead of publishing if any of it says otherwise
(`scripts/check-license.ps1`).

## What a release holds

| File | Content |
|---|---|
| `milutv-libmpv-<release>-x64.zip`, `…-arm64.zip` | `libmpv-2.dll` and its PDB, `mpv.lib` (import library for `libmpv-2.dll`), `include/mpv/*.h`, `libEGL.dll`, `libGLESv2.dll` and their PDBs, `licenses/`, `ffmpeg-license.txt`, `ffmpeg-config.h`, `manifest.json` (pinned sources, toolchain, meson options, SHA-256 of every file) |
| `milutv-libmpv-<release>-sources.tar.gz` | The complete corresponding source: mpv and every meson subproject as built, the ANGLE sources and vcpkg port, and this recipe |
| `ffmpeg-license-x64.txt`, `ffmpeg-license-arm64.txt` | The licence proof of each architecture |
| `angle-x64.json`, `angle-arm64.json` | The ANGLE each architecture was built with: mode, pinned commit (`pinned` mode only), vcpkg port version and the version string read back from `libGLESv2.dll` |
| `SHA256SUMS` | SHA-256 of every file above |

A release is named `mpv-<mpv commit>-ff<FFmpeg version>-r<n>`, for example `mpv-f9850ee-ff9.0.1-r1`.
`r<n>` changes when only the recipe changes.

## Recipe

The build follows the `win32` job of mpv's own CI (`.github/workflows/build.yml` and
`ci/build-win32.ps1` in mpv-player/mpv), changed for an LGPL `libmpv`:

- **Toolchain:** clang in MSVC ABI (`*-pc-windows-msvc`), `lld-link`, `llvm-rc`, meson with every
  subproject in `forcefallback` mode, from a Visual Studio developer shell whose host and target
  architecture are the same. Runners: `windows-2025-vs2026` (x64) and `windows-11-arm` (arm64),
  native builds on both.
- **mpv:** `-Dlibmpv=true -Dcplayer=false -Dgpl=false`, one shared library with FFmpeg, libplacebo,
  libass, FreeType, HarfBuzz, FriBidi and zlib linked in statically. OpenGL render API on Windows
  (`gl-win32`), ANGLE headers for the `d3d11-egl` interop (zero-copy D3D11VA decoding under ANGLE),
  `d3d-hwaccel` (D3D11VA and the `d3d11vpp` deinterlacing filter), WASAPI audio. No Vulkan, no D3D11
  render API, no shader compiler, no scripting. One change to mpv's source, made by
  `scripts/build-mpv.ps1`: the D3D11 frames `mp_update_av_hw_frames_pool` allocates get
  `D3D11_BIND_RENDER_TARGET` under `d3d-hwaccel` as well as under the disabled D3D11 render API,
  since `d3d11vpp` draws into them (without it the filter fails at its first frame and nothing is
  deinterlaced).
- **FFmpeg:** its meson port (`gstreamer/meson-ports/ffmpeg`), `gpl`, `version3` and `nonfree`
  disabled, TLS through Windows' Schannel (no OpenSSL, GnuTLS or mbedTLS), D3D11VA hardware
  acceleration, and an allow-list of the decoders, parsers, demuxers and protocols IPTV streams use
  ([ffmpeg-components.json](ffmpeg-components.json)). Encoders, muxers and devices are disabled;
  filters and bitstream filters stay whole, minus the GPL ones.
- **ANGLE:** built by vcpkg (`scripts/build-angle.ps1`), from the vcpkg port re-pointed at the ANGLE
  commit pinned in `versions.json` (`angle.mode: "pinned"`), recent enough for zero-copy decoding.
  `angle.mode: "port"` builds the port as vcpkg ships it instead.
- **Checks before packaging:** a single DLL comes out; it exports every entry point the MiluTV
  player resolves ([player-abi.json](player-abi.json)); no DLL depends on anything but Windows and
  the MSVC runtime (in particular not on `vulkan-1.dll`); the licence check above.
- **MSVC runtime (Safeer):** the package ships the toolchain's own `msvcp140.dll`, `vcruntime140.dll`
  and `vcruntime140_1.dll` in `runtime/` (versions in `manifest.json` → `runtime`, licence note in
  `licenses/msvc-runtime/`). The consuming app must load them app-locally before any other C++ DLL:
  ANGLE and libplacebo built with STL 14.5x crash (0xc0000005 in MSVCP140) on a machine whose
  System32 carries an older runtime such as 14.32. `scripts/check-dll-deps.py --dir <package>`
  verifies the bundle; `scripts/smoke-safeer-player.py --runtime-dir <package>/runtime` preloads it.

Every version is pinned in [versions.json](versions.json) and `subprojects/*.wrap` (WrapDB wraps with
their source hashes). The FFmpeg, libplacebo and libass wraps are generated from `versions.json`.

## Building

On GitHub: run the `build` workflow by hand to get both archives as workflow artifacts, or push a
tag equal to `release` in `versions.json` to build and publish a release.

Locally, on Windows with Visual Studio 2026 and its "C++ Clang Compiler for Windows" component,
Python, `pip install meson ninja`, and NASM for x64, in PowerShell 7:

```powershell
./scripts/build-angle.ps1 -Arch x64
# In a developer shell: Enter-VsDevShell ... -DevCmdArguments "-arch=x64 -host_arch=x64"
$env:CC='clang'; $env:CXX='clang++'; $env:CC_LD='lld-link'; $env:CXX_LD='lld-link'; $env:WINDRES='llvm-rc'
./scripts/build-mpv.ps1 -Arch x64 -AngleInclude work/angle-x64/include
./scripts/package.ps1 -Arch x64
./scripts/pack-sources.ps1
```

Outputs land in `dist/`. `./scripts/test-check-license.ps1` tests the licence check alone.

## Updating

1. Change the pins in `versions.json` (and, for a WrapDB dependency, its `subprojects/*.wrap`,
   downloaded from `https://wrapdb.mesonbuild.com/v2/<name>_<version>/<name>.wrap`).
2. Set `release` to the new name, then run the workflow by hand until it passes.
3. Tag the commit with that name and push the tag.

Rebuild for any FFmpeg security fix that touches demuxing or network protocols: the DLL parses
untrusted network streams.

## Where the recipe is maintained

The recipe is edited in the MiluTV repository, folder `native/milutv-libmpv`, next to the app that
consumes it, and published here unchanged with `git subtree push --prefix native/milutv-libmpv`.
This repository's history is that folder's history.
