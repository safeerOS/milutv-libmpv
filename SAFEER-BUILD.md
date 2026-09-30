# Safeer libmpv: AV1, DASH and snapshots

Status: source patch, NOT a compiled Windows release. Based on jmonsellier/milutv-libmpv
commit a36a682b06531c7b56fbe1260de88fab4152f65a. No DLL is included.

## Kaj je pripravljeno

- dav1d 1.5.4: verified peeled tag commit 54706fc6bc0cdecab7e9593974a4039cc038fca7.
- libxml2 2.15.4: source archive SHA256 verified against the Meson wrap.
- AV1 software decoding, DASH, Matroska/WebM, PNG and MJPEG encoding enabled.
- Existing MPEG-4 decoder retained. Existing ANGLE rendering retained; Vulkan stays disabled.
- Static dependency builds; no new runtime DLL deliberately added.
- Configuration check fails the build if required FFmpeg features are missing.
- Windows playback probe with AV1 forcing, playback progress and PNG capture.
- Existing packaging collects new dependency licenses and source trees automatically;
  versions.json records pins and the package includes safeer-capabilities.json.

## Uporaba popravka v obstoječem klonu

Save local changes first. Run `git apply --check safeer-libmpv.patch` then
`git apply safeer-libmpv.patch` at the repository root. If check fails, reconcile
changes; do not reset or overwrite your existing work. The full patched recipe
is also provided in recipe/ for comparison or a fresh working directory.

## Gradnja Windows x64

Use the upstream environment: Visual Studio 2026 C++ Clang, Windows SDK, PowerShell 7,
Python, Meson 1.12.1, Ninja, NASM and git. The existing build.yml configures these.
In a developer shell targeting x64:

```powershell
$env:CC='clang'
$env:CXX='clang++'
$env:CC_LD='lld-link'
$env:CXX_LD='lld-link'
$env:WINDRES='llvm-rc'
./scripts/build-angle.ps1 -Arch x64
./scripts/build-mpv.ps1 -Arch x64 -AngleInclude work/angle-x64/include
./scripts/package.ps1 -Arch x64
./scripts/pack-sources.ps1
```

The existing build workflow can run manually. It builds x64 and ARM64 by default.
For the first experiment limit the matrix to x64 if desired. Do not push a release
tag until runtime tests pass: the upstream tag workflow publishes releases.
The output naming remains milutv-libmpv-safeer-av1-dash-snapshot-r1-x64 to minimize
changes to packaging. A Safeer branding rename can be a separate change.

## Windows test, Python 3.14 x64

Extract the resulting package into one directory retaining all three DLLs and licenses.
Use python-mpv 1.0.8. Tests load the DLL in --dll-dir; no system mpv or VLC required.
Use trusted samples longer than 20 seconds. A real window will appear.

```powershell
py -3.14 -m pip install python-mpv==1.0.8
py -3.14 scripts/smoke-safeer-player.py --dll-dir C:\SafeerTest\mpv --source C:\SafeerTest\av1.mp4 --av1 --png C:\SafeerTest\av1-frame.png --report C:\SafeerTest\av1-report.json
py -3.14 scripts/smoke-safeer-player.py --dll-dir C:\SafeerTest\mpv --source C:\SafeerTest\av1.webm --av1 --report C:\SafeerTest\webm-report.json
py -3.14 scripts/smoke-safeer-player.py --dll-dir C:\SafeerTest\mpv --source "https://YOUR-TEST-SERVER/manifest.mpd" --report C:\SafeerTest\dash-report.json
```

Replace YOUR-TEST-SERVER with an actual authorized DASH source. Test H.264, HEVC,
VP9 and MPEG-4 Part 2 similarly. The probe deliberately disables hardware decoding
to isolate software capability. Later test hwdec=auto separately. Keep any diagnostic
logs with authentication URLs private.

Success requires video visible, audio audible, increasing timestamps, valid PNG,
and actual AV1 decoder use. Inspect the generated image, not only its header.
The probe checks progress and PNG structure but cannot judge visual correctness.

## Remaining release gates

- Windows compilation and linking have NOT been run in the authoring environment.
- No actual playback, HDR or GPU validation has been run for this patch.
- Inspect package licenses and source archive before distribution; this is not a full legal audit.
- Verify HTTP headers/cookies, redirects, seeking, reconnects and long playback separately.
- Test Qt embedding, overlays, subtitles, full screen, resize and repeated close/open.
- Confirm HDR-to-SDR and real HDR output independently on appropriate hardware.
- Check clean Windows runtime dependencies, including MSVC runtime and all ANGLE DLLs.
- D3D11VA is a decode path; it is not proof of HDR output support.

## Verification completed here

Pinned sources/options inspected, libxml2 archive hash checked, Python scripts compile,
capability gate exercised with synthetic passing and failing headers, patch applicability
checked against the clean upstream commit. These checks do not replace the Windows build.
