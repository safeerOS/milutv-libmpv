# Proves, from the build itself, that the libmpv DLL is LGPL v2.1 or later:
#   - FFmpeg's generated config.h has CONFIG_GPL 0, CONFIG_VERSION3 0, CONFIG_NONFREE 0 and
#     FFMPEG_LICENSE "LGPL version 2.1 or later";
#   - the DLL carries no GPL licence string (the LGPL one is usually dropped by the linker, since
#     mpv never calls avcodec_license());
#   - mpv was configured with gpl=false (build/config.h, HAVE_GPL 0).
# It also checks that the pieces the Windows player needs were compiled in: the d3d11-egl interop
# (zero-copy D3D11VA under ANGLE) and the d3d11vpp filter (GPU deinterlacing).
#
# Writes <OutFile> (ffmpeg-license.txt in the release), and throws on any failure.
param(
  [Parameter(Mandatory)][string]$BuildDir,
  [Parameter(Mandatory)][string]$Dll,
  [Parameter(Mandatory)][string]$OutFile,
  [string]$FfmpegConfigCopy
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Absolute: the config.h path printed in the proof is made relative to $BuildDir, and .NET file APIs
# resolve relative paths against the process directory, not PowerShell's current location.
$BuildDir = (Resolve-Path $BuildDir).Path.TrimEnd('\', '/')
$Dll = (Resolve-Path $Dll).Path

function Get-Define([string]$Text, [string]$Name) {
  $m = [regex]::Match($Text, "(?m)^#define $Name (.+?)\s*$")
  if (-not $m.Success) { return $null }
  return $m.Groups[1].Value
}

$failures = [System.Collections.Generic.List[string]]::new()

# FFmpeg's config.h is the one that defines FFMPEG_LICENSE.
$ffConfig = Get-ChildItem (Join-Path $BuildDir 'subprojects') -Recurse -Filter 'config.h' |
  Where-Object { (Get-Content $_.FullName -Raw) -match '#define FFMPEG_LICENSE ' } |
  Select-Object -First 1
if (-not $ffConfig) { throw "No FFmpeg config.h (with FFMPEG_LICENSE) under $BuildDir\subprojects." }
$ff = Get-Content $ffConfig.FullName -Raw

$expected = [ordered]@{
  CONFIG_GPL      = '0'
  CONFIG_VERSION3 = '0'
  CONFIG_NONFREE  = '0'
  FFMPEG_LICENSE  = '"LGPL version 2.1 or later"'
}
$found = [ordered]@{}
foreach ($name in $expected.Keys) {
  $value = Get-Define $ff $name
  $found[$name] = $value
  if ($value -ne $expected[$name]) {
    $failures.Add("FFmpeg $name is '$value', expected $($expected[$name]).")
  }
}
$configuration = Get-Define $ff 'FFMPEG_CONFIGURATION'

# mpv's own config.h.
$mpvConfigPath = Join-Path $BuildDir 'config.h'
$mpvGpl = $null
$mpvFeatures = $null
if (Test-Path $mpvConfigPath) {
  $mpvConfig = Get-Content $mpvConfigPath -Raw
  $mpvGpl = Get-Define $mpvConfig 'HAVE_GPL'
  if ($mpvGpl -ne '0') { $failures.Add("mpv HAVE_GPL is '$mpvGpl', expected 0.") }
  # FULLCONFIG lists every feature mpv was built with.
  $mpvFeatures = (Get-Define $mpvConfig 'FULLCONFIG') -replace '^"|"$', ''
  $featureList = @($mpvFeatures -split ' ')
  foreach ($f in 'gl', 'gl-win32', 'egl-angle', 'd3d-hwaccel', 'wasapi') {
    if ($featureList -notcontains $f) { $failures.Add("mpv was built without the '$f' feature.") }
  }
  foreach ($f in 'gpl', 'vulkan') {
    if ($featureList -contains $f) { $failures.Add("mpv was built with the '$f' feature.") }
  }
} else {
  $failures.Add("No mpv config.h at $mpvConfigPath.")
}

# The DLL itself.
$ascii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Dll))
$required = @('d3d11-egl', 'd3d11vpp')
foreach ($s in $required) {
  if (-not $ascii.Contains($s)) { $failures.Add("The DLL does not contain '$s'.") }
}
# mpv never calls avcodec_license(), so the linker usually drops FFMPEG_LICENSE: its absence proves
# nothing, config.h above is the proof. When present, it must be the LGPL one.
$lgplString = 'LGPL version 2.1 or later'
$lgplInDll = $ascii.Contains($lgplString)
$forbidden = @('GPL version 2 or later', 'GPL version 3 or later', 'LGPL version 3 or later', 'nonfree and unredistributable')
foreach ($s in $forbidden) {
  # None of these is a substring of 'LGPL version 2.1 or later'.
  if ($ascii.Contains($s)) { $failures.Add("The DLL contains '$s'.") }
}

$report = @(
  'FFmpeg licence, read from the build of this release'
  ''
  "config.h: $($ffConfig.FullName.Substring($BuildDir.Length).TrimStart('\', '/'))"
)
foreach ($name in $found.Keys) { $report += "  #define $name $($found[$name])" }
$report += @(
  ''
  "mpv config.h: #define HAVE_GPL $mpvGpl"
  "mpv features: $mpvFeatures"
  ''
  "Strings in $(Split-Path $Dll -Leaf): " + (($required | ForEach-Object { "'$_'" }) -join ', ') + ' present; ' +
    (($forbidden | ForEach-Object { "'$_'" }) -join ', ') + ' absent; ' +
    "'$lgplString' " + $(if ($lgplInDll) { 'present.' } else { 'not linked in (mpv does not call avcodec_license()).' })
  ''
  'FFMPEG_CONFIGURATION (the meson options FFmpeg was configured with):'
  $configuration
)
if ($failures.Count -gt 0) {
  $report += @('', 'FAILED:') + ($failures | ForEach-Object { "  $_" })
}
$report | Set-Content -Path $OutFile -Encoding utf8
if ($FfmpegConfigCopy) { Copy-Item $ffConfig.FullName $FfmpegConfigCopy }
Get-Content $OutFile

if ($failures.Count -gt 0) {
  throw "Licence check failed:`n$($failures -join "`n")"
}
