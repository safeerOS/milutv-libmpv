# Builds an LGPL libmpv DLL with FFmpeg and every other dependency linked in statically, following
# the recipe of mpv's own win32 CI (ci/build-win32.ps1): clang in MSVC ABI, lld-link, meson with
# subprojects in forcefallback mode, FFmpeg through its meson port.
#
# Run it from a Visual Studio developer shell whose host and target architecture are both $Arch
# (the workflow enters it), with CC=clang, CXX=clang++, CC_LD=CXX_LD=lld-link, WINDRES=llvm-rc.
param(
  [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Arch,
  [Parameter(Mandatory)][string]$AngleInclude,
  [string]$WorkDir = (Join-Path $PSScriptRoot '..\work')
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$versions = Get-Content (Join-Path $repoRoot 'versions.json') -Raw | ConvertFrom-Json
$components = Get-Content (Join-Path $repoRoot 'ffmpeg-components.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$WorkDir = Resolve-Path $WorkDir
$AngleInclude = Resolve-Path $AngleInclude

# 1. mpv at the pinned commit.
$mpv = Join-Path $WorkDir 'mpv'
if (-not (Test-Path (Join-Path $mpv '.git'))) {
  git init --quiet $mpv
  git -C $mpv remote add origin $versions.mpv.repository
}
git -C $mpv fetch --quiet --depth 1 origin $versions.mpv.commit
git -C $mpv checkout --quiet --force FETCH_HEAD

# 1b. The render target of d3d11vpp (MiluTV #161). mp_update_av_hw_frames_pool gives the D3D11 frames
#     it allocates D3D11_BIND_RENDER_TARGET under HAVE_D3D11 only, the D3D11 render API, which this
#     build disables (-Dd3d11=disabled). vf_d3d11vpp (d3d-hwaccel) draws into those frames: without the
#     flag, CreateVideoProcessorOutputView fails at the first frame, mpv disables the deinterlacer and
#     plays the fields woven. The flag belongs to d3d-hwaccel, which compiles hwcontext_d3d11va.
$pool = Join-Path $mpv 'video\mp_image_pool.c'
$source = [IO.File]::ReadAllText($pool)
$guard = [regex]'(?m)^#if HAVE_D3D11\r?$'
if ($guard.Matches($source).Count -ne 2) {
  throw "video/mp_image_pool.c no longer has the two '#if HAVE_D3D11' guards of the d3d11vpp fix: check the fix against this mpv commit."
}
[IO.File]::WriteAllText($pool, $guard.Replace($source, '#if HAVE_D3D11 || HAVE_D3D_HWACCEL'))

# 2. Subprojects: the wrapdb wraps committed in subprojects/ (their versions must match
#    versions.json), and git wraps generated from versions.json. Top-level wraps win over the ones
#    nested subprojects carry, so these pins are the versions actually built.
$subprojects = Join-Path $mpv 'subprojects'
New-Item -ItemType Directory -Force $subprojects | Out-Null
foreach ($entry in $versions.wrapdb.PSObject.Properties) {
  $wrap = Join-Path $repoRoot "subprojects\$($entry.Name).wrap"
  $declared = (Select-String -Path $wrap -Pattern '^wrapdb_version = (.+)$').Matches[0].Groups[1].Value
  if ($declared -ne $entry.Value) {
    throw "subprojects/$($entry.Name).wrap is $declared but versions.json says $($entry.Value)."
  }
  Copy-Item $wrap $subprojects -Force
}
function Write-GitWrap([string]$Name, [string]$Url, [string]$Revision, [string[]]$Provide) {
  $content = @(
    '[wrap-git]'
    "url = $Url"
    "revision = $Revision"
    'depth = 1'
    'clone-recursive = true'
  )
  if ($Provide) { $content += @('', '[provide]') + $Provide }
  Set-Content -Path (Join-Path $subprojects "$Name.wrap") -Value $content
}
Write-GitWrap 'ffmpeg' $versions.ffmpeg.repository $versions.ffmpeg.commit @(
  'dependency_names = libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample, libswscale'
)
Write-GitWrap 'libplacebo' $versions.libplacebo.repository $versions.libplacebo.tag @()
Write-GitWrap 'libass' $versions.libass.repository $versions.libass.tag @()

# dav1d 1.5.4 ne klice meson.override_dependency('dav1d'); zato [provide] z imenom spremenljivke
# (src/meson.build: dav1d_dep = declare_dependency(...)), sicer FFmpeg odvisnosti 'dav1d' ne najde.
Write-GitWrap 'dav1d' $versions.dav1d.repository $versions.dav1d.commit @(
  'dav1d = dav1d_dep'
)

# 3. FFmpeg allow-list (see ffmpeg-components.json).
$ffmpegArgs = @()
$groups = [ordered]@{ decoder ='decoders'; encoder = 'encoders'; parser = 'parsers'; demuxer = 'demuxers'; protocol = 'protocols'; hwaccel = 'hwaccels' }
foreach ($kind in $groups.Keys) {
  $ffmpegArgs += "-Dffmpeg:$($groups[$kind])=disabled"
  foreach ($name in $components.$kind) { $ffmpegArgs += "-Dffmpeg:${name}_$kind=enabled" }
}
foreach ($group in $components.disabledGroups) { $ffmpegArgs += "-Dffmpeg:$group=disabled" }

# 4. Configure. One DLL for mpv, every dependency static inside it.
$build = Join-Path $mpv 'build'
Remove-Item -Recurse -Force $build -ErrorAction SilentlyContinue
$mesonArgs = @(
  'setup', $build, $mpv,
  '--wrap-mode=forcefallback',
  '--buildtype=release', '-Ddebug=true', '-Db_ndebug=true',
  '-Ddefault_library=shared',
  '-Dffmpeg:default_library=static', '-Dlibass:default_library=static', '-Dlibplacebo:default_library=static',
  '-Dfreetype2:default_library=static', '-Dharfbuzz:default_library=static',
  '-Dfribidi:default_library=static', '-Dzlib:default_library=static',
  # libass looks libpng up for its test programs only (disabled), but forcefallback builds it anyway:
  # static, so that no png16-16.dll comes out next to mpv.
  '-Dlibpng:default_library=static',
  '-Ddav1d:default_library=static', '-Ddav1d:enable_tools=false',
  '-Ddav1d:enable_tests=false', '-Ddav1d:enable_examples=false',
  '-Ddav1d:enable_docs=false', '-Ddav1d:enable_asm=true',
  '-Dlibxml2:default_library=static', '-Dlibxml2:python=disabled',
  '-Dlibxml2:docs=disabled', '-Dlibxml2:iconv=disabled',
  '-Dlibxml2:icu=disabled', '-Dlibxml2:readline=disabled',
  '-Dlibxml2:history=disabled', '-Dlibxml2:modules=disabled',
  # A list literal (meson never splits a c_args string on commas); forward slashes, no escapes.
  "-Dc_args=['-I$($AngleInclude.Replace('\', '/'))']",

  # mpv: libmpv only, LGPL, OpenGL render API with the ANGLE interop and D3D11VA decoding.
  '-Dlibmpv=true', '-Dcplayer=false', '-Dtests=false', '-Dgpl=false',
  '-Dgl=enabled', '-Dgl-win32=enabled', '-Degl-angle=enabled',
  '-Degl-angle-lib=disabled', '-Dgl-dxinterop=disabled',
  # egl-angle-win32 (mpv's own windowed ANGLE context, ANGLE loaded at run time) is the switch that
  # compiles video/out/gpu/d3d11_helpers.c, which vf_d3d11vpp.c (d3d-hwaccel) needs.
  '-Degl-angle-win32=enabled',
  '-Dd3d-hwaccel=enabled', '-Dd3d9-hwaccel=disabled', '-Dgl-dxinterop-d3d9=disabled',
  '-Dwasapi=enabled', '-Dwin32-smtc=enabled',
  '-Dd3d11=disabled', '-Dshaderc=disabled', '-Dspirv-cross=disabled',
  '-Dvulkan=disabled', '-Damf=disabled', '-Dcuda-hwaccel=disabled', '-Dcuda-interop=disabled',
  '-Dvaapi=disabled', '-Dvaapi-win32=disabled',
  '-Dlua=disabled', '-Djavascript=disabled', '-Dcplugins=disabled', '-Dsubrandr=disabled',
  '-Dlibcurl=disabled', '-Dlibarchive=disabled', '-Dlibbluray=disabled', '-Dlibavdevice=disabled',
  '-Djpeg=disabled', '-Dlcms2=disabled', '-Duchardet=disabled', '-Dzimg=disabled',
  '-Drubberband=disabled', '-Dvapoursynth=disabled', '-Diconv=disabled',
  '-Dsdl2-audio=disabled', '-Dsdl2-video=disabled', '-Dsdl2-gamepad=disabled', '-Dopenal=disabled',
  '-Dsixel=disabled', '-Dcaca=disabled', '-Ddirect3d=disabled',

  # libplacebo: OpenGL backend only, no shader compiler, no Vulkan.
  '-Dlibplacebo:opengl=enabled', '-Dlibplacebo:vulkan=disabled', '-Dlibplacebo:d3d11=disabled',
  '-Dlibplacebo:glslang=disabled', '-Dlibplacebo:shaderc=disabled', '-Dlibplacebo:lcms=disabled',
  '-Dlibplacebo:dovi=disabled', '-Dlibplacebo:libdovi=disabled', '-Dlibplacebo:xxhash=disabled',
  '-Dlibplacebo:unwind=disabled', '-Dlibplacebo:demos=false', '-Dlibplacebo:tests=false',

  # libass: DirectWrite font provider, no fontconfig.
  '-Dlibass:directwrite=enabled', '-Dlibass:fontconfig=disabled', '-Dlibass:coretext=disabled',
  '-Dlibass:libunibreak=disabled', '-Dlibass:test=disabled', '-Dlibass:compare=disabled',
  '-Dlibass:profile=disabled', '-Dlibass:fuzz=disabled', '-Dlibass:checkasm=disabled',

  # FreeType under its FTL licence; no PNG, bzip2 or Brotli fonts.
  '-Dfreetype2:png=disabled', '-Dfreetype2:bzip2=disabled', '-Dfreetype2:brotli=disabled',
  '-Dfreetype2:harfbuzz=disabled',
  '-Dharfbuzz:freetype=enabled', '-Dharfbuzz:glib=disabled', '-Dharfbuzz:icu=disabled',
  '-Dharfbuzz:cairo=disabled', '-Dharfbuzz:tests=disabled',
  '-Dfribidi:docs=false', '-Dfribidi:bin=false', '-Dfribidi:tests=false',

  # FFmpeg: LGPL v2.1 or later (no gpl, no version3, no nonfree), Schannel TLS, D3D11VA only.
  '-Dffmpeg:gpl=disabled', '-Dffmpeg:version3=disabled', '-Dffmpeg:nonfree=disabled',
  '-Dffmpeg:programs=disabled', '-Dffmpeg:tests=disabled',
  '-Dffmpeg:avdevice=disabled', '-Dffmpeg:postproc=disabled',
  '-Dffmpeg:libdav1d=enabled', '-Dffmpeg:libxml2=enabled',
  '-Dffmpeg:network=enabled', '-Dffmpeg:schannel=enabled',
  '-Dffmpeg:openssl=disabled', '-Dffmpeg:gnutls=disabled', '-Dffmpeg:mbedtls=disabled',
  '-Dffmpeg:d3d11va=enabled', '-Dffmpeg:d3d12va=disabled', '-Dffmpeg:dxva2=disabled',
  '-Dffmpeg:mediafoundation=disabled', '-Dffmpeg:vulkan=disabled', '-Dffmpeg:amf=disabled',
  '-Dffmpeg:cuda=disabled', '-Dffmpeg:nvdec=disabled', '-Dffmpeg:nvenc=disabled',
  '-Dffmpeg:libmfx=disabled', '-Dffmpeg:vaapi=disabled', '-Dffmpeg:opencl=disabled',
  '-Dffmpeg:sdl2=disabled', '-Dffmpeg:iconv=disabled', '-Dffmpeg:bzlib=disabled',
  '-Dffmpeg:lzma=disabled', '-Dffmpeg:zlib=enabled'
) + $ffmpegArgs

# Kept for the manifest and the release notes: this is the exact recipe.
$mesonArgs | Set-Content (Join-Path $WorkDir "meson-args-$Arch.txt")

meson @mesonArgs
meson compile -C $build
python (Join-Path $PSScriptRoot 'check-safeer-capabilities.py') --build $build
if ($LASTEXITCODE -ne 0) { throw "Safeer capability configuration check failed." }

# 5. Exactly one DLL must come out: mpv, with FFmpeg and the rest inside.
$dlls = @(Get-ChildItem $build -Recurse -Filter '*.dll' | Where-Object { $_.Name -notmatch '^(libEGL|libGLESv2)\.dll$' })
$mpvDll = @($dlls | Where-Object { $_.Name -match '^(lib)?mpv-2\.dll$' })
if ($mpvDll.Count -ne 1) { throw "Expected one mpv-2.dll or libmpv-2.dll, found: $($dlls.Name -join ', ')" }
$others = @($dlls | Where-Object { $_.FullName -ne $mpvDll[0].FullName })
# Safeer: libxml2 gradi brezpogojen testni modul testdso.dll (meson.build: shared_module, brez opcije).
# Ni odvisnost in ni povezan v mpv (libxml2 sama je staticna: default_library=static), zato ga tu
# izvzamemo - a SAMO iz mape podprojekta libxml2. Vsaka druga DLL je se vedno napaka.
$others = @($others | Where-Object { -not ($_.Name -ieq 'testdso.dll' -and $_.FullName -match '[\\/]subprojects[\\/]libxml2[\\/]') })
if ($others.Count -gt 0) {
  throw "A dependency was built as a DLL instead of being linked into mpv: $($others.Name -join ', ')"
}
Write-Output "Built $($mpvDll[0].FullName)"
