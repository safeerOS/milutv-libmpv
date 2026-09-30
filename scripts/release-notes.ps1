# Writes the release notes from versions.json and the licence proofs produced by the build.
param(
  [Parameter(Mandatory)][string]$Dist,
  [Parameter(Mandatory)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$v = Get-Content (Join-Path $repoRoot 'versions.json') -Raw | ConvertFrom-Json

$lines = @(
  "libmpv $($v.release) for Windows x64 and arm64, under the GNU LGPL v2.1 or later, with ANGLE (BSD-3-Clause)."
  ''
  '| Component | Version |'
  '|---|---|'
  "| mpv | [``$($v.mpv.commit.Substring(0, 10))``]($($v.mpv.repository)/commit/$($v.mpv.commit)) |"
  "| FFmpeg | $($v.ffmpeg.version), meson port ``$($v.ffmpeg.branch)`` @ ``$($v.ffmpeg.commit.Substring(0, 10))`` |"
  "| libplacebo | $($v.libplacebo.tag) |"
  "| libass | $($v.libass.tag) |"
  "| dav1d | $($v.dav1d.version) [``$($v.dav1d.commit.Substring(0, 10))``]($($v.dav1d.repository -replace '\.git$', '')/commit/$($v.dav1d.commit)) (AV1, BSD-2-Clause) |"
)
foreach ($p in $v.wrapdb.PSObject.Properties) { $lines += "| $($p.Name) | $($p.Value) (WrapDB) |" }
# ANGLE as built, from the angle-<arch>.json that build-angle.ps1 wrote: angle.commit and
# angle.revision only hold in "pinned" mode; in "port" mode vcpkg built the port's own ANGLE.
$vcpkgRef = "built by vcpkg @ ``$($v.vcpkg.commit.Substring(0, 10))``"
$builds = @(Get-ChildItem $Dist -Filter 'angle-*.json' | Sort-Object Name)
if ($builds.Count -eq 0) { throw "No angle-<arch>.json in ${Dist}: cannot state which ANGLE was built." }
foreach ($file in $builds) {
  $arch = $file.BaseName -replace '^angle-', ''
  $a = Get-Content $file.FullName -Raw | ConvertFrom-Json
  if ($a.mode -ne $v.angle.mode) { throw "$($file.Name) was built in '$($a.mode)' mode, versions.json says '$($v.angle.mode)'." }
  $built = if ($a.versionString) { "``$($a.versionString)``" } else { 'version string not found in libGLESv2.dll' }
  if ($a.mode -eq 'pinned') {
    $lines += "| ANGLE ($arch) | pinned ``$($v.angle.commit.Substring(0, 12))``, revision $($v.angle.revision) ($built), $vcpkgRef |"
  } else {
    $lines += "| ANGLE ($arch) | vcpkg port $($a.portVersion) ($built), $vcpkgRef |"
  }
}
$lines += @(
  ''
  'Each `milutv-libmpv-*-<arch>.zip` holds `libmpv-2.dll` and its PDB, `mpv.lib`, the libmpv headers,'
  '`libEGL.dll` and `libGLESv2.dll` with their PDBs, the licences of every component, FFmpeg''s'
  'generated `config.h` and a `manifest.json` with the SHA-256 of every file.'
  '`milutv-libmpv-*-sources.tar.gz` is the complete corresponding source and the recipe that built it.'
  ''
  '## FFmpeg licence, as built'
  ''
)
foreach ($proof in Get-ChildItem $Dist -Filter 'ffmpeg-license-*.txt' | Sort-Object Name) {
  $arch = $proof.BaseName -replace '^ffmpeg-license-', ''
  $defines = Select-String -Path $proof.FullName -Pattern '#define (CONFIG_GPL|CONFIG_VERSION3|CONFIG_NONFREE|FFMPEG_LICENSE|HAVE_GPL) ' |
    ForEach-Object { $_.Line.Trim() }
  $lines += @("**$arch**", '', '```c') + $defines + @('```', '')
}
$lines += 'The full FFmpeg configuration of each architecture is in `ffmpeg-license-<arch>.txt`.'
$lines | Set-Content -Path $OutFile -Encoding utf8
Get-Content $OutFile
