# Assembles one release archive per architecture:
#
#   libmpv-2.dll, its PDB, mpv.lib (import library for libmpv-2.dll), include/mpv/*.h
#   libEGL.dll, libGLESv2.dll and their PDBs (ANGLE)
#   licenses/            licence texts of mpv, FFmpeg, every static dependency, and ANGLE
#   ffmpeg-license.txt   the licence proof written by check-license.ps1
#   ffmpeg-config.h      FFmpeg's generated config.h
#   manifest.json        pinned sources, toolchain, meson options, SHA-256 of every file
#
# Run from the same Visual Studio developer shell as build-mpv.ps1 (dumpbin and lib are used).
param(
  [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Arch,
  [string]$WorkDir = (Join-Path $PSScriptRoot '..\work'),
  [string]$OutDir = (Join-Path $PSScriptRoot '..\dist')
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$versions = Get-Content (Join-Path $repoRoot 'versions.json') -Raw | ConvertFrom-Json
$abi = Get-Content (Join-Path $repoRoot 'player-abi.json') -Raw | ConvertFrom-Json
$WorkDir = Resolve-Path $WorkDir
$mpv = Join-Path $WorkDir 'mpv'
$build = Join-Path $mpv 'build'
$angle = Join-Path $WorkDir "angle-$Arch"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = Resolve-Path $OutDir

$name = "milutv-libmpv-$($versions.release)-$Arch"
$stage = Join-Path $WorkDir "stage\$name"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage, (Join-Path $stage 'include\mpv'), (Join-Path $stage 'licenses') | Out-Null

function Get-Exports([string]$Dll) {
  $out = dumpbin /nologo /exports $Dll
  foreach ($line in $out) {
    $m = [regex]::Match($line, '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)')
    if ($m.Success) { $m.Groups[1].Value }
  }
}

function Get-Dependents([string]$Dll) {
  $out = dumpbin /nologo /dependents $Dll
  foreach ($line in $out) {
    $m = [regex]::Match($line, '^\s+(\S+\.dll)\s*$', 'IgnoreCase')
    if ($m.Success) { $m.Groups[1].Value }
  }
}

# 1. libmpv. meson names it mpv-2.dll or libmpv-2.dll depending on the toolchain; the app loads
#    libmpv-2.dll, so that is the name we ship, with an import library made for that name.
$built = @(Get-ChildItem $build -Filter '*mpv-2.dll' | Where-Object { $_.Name -match '^(lib)?mpv-2\.dll$' })
if ($built.Count -ne 1) { throw "No single mpv-2.dll or libmpv-2.dll in $build." }
$built = $built[0]
Copy-Item $built.FullName (Join-Path $stage 'libmpv-2.dll')
$pdb = Join-Path $build ([IO.Path]::ChangeExtension($built.Name, '.pdb'))
if (-not (Test-Path $pdb)) { throw "No PDB next to $($built.Name): the Store package must carry libmpv symbols (#145)." }
# The PDB keeps its link-time name: debuggers and the Partner Center look it up by the name and
# GUID recorded in the DLL.
Copy-Item $pdb $stage

$exports = @(Get-Exports (Join-Path $stage 'libmpv-2.dll') | Where-Object { $_ -like 'mpv_*' })
$def = Join-Path $WorkDir "libmpv-2-$Arch.def"
@('LIBRARY libmpv-2.dll', 'EXPORTS') + ($exports | ForEach-Object { "    $_" }) | Set-Content $def
lib /nologo "/def:$def" "/out:$(Join-Path $stage 'mpv.lib')" "/machine:$Arch"
Remove-Item (Join-Path $stage 'mpv.exp') -ErrorAction SilentlyContinue

foreach ($header in 'client.h', 'render.h', 'render_gl.h', 'stream_cb.h') {
  Copy-Item (Join-Path $mpv "include\mpv\$header") (Join-Path $stage 'include\mpv')
}

# 2. ANGLE.
foreach ($file in Get-ChildItem (Join-Path $angle 'bin')) { Copy-Item $file.FullName $stage }

# 3. What the player component resolves by name must be exported.
foreach ($entry in $abi.PSObject.Properties | Where-Object { $_.Name -like '*.dll' }) {
  $have = @(Get-Exports (Join-Path $stage $entry.Name))
  $missing = @($entry.Value | Where-Object { $have -notcontains $_ })
  if ($missing.Count -gt 0) { throw "$($entry.Name) does not export: $($missing -join ', ')" }
}

# 4. No DLL may depend on anything but Windows and the MSVC runtime the app package already
#    declares. vulkan-1.dll is named because it can exist in System32 on one machine and not on
#    another (the trap of the zhongfly build).
$forbidden = @('vulkan-1.dll', 'libEGL.dll', 'libGLESv2.dll', 'zlib1.dll')
$system32 = Join-Path $env:SystemRoot 'System32'
foreach ($dll in Get-ChildItem $stage -Filter '*.dll') {
  foreach ($dep in Get-Dependents $dll.FullName) {
    if ($dll.Name -eq 'libEGL.dll' -and $dep -ieq 'libGLESv2.dll') { continue }
    $isRuntime = $dep -match '^(api-ms-win-|ext-ms-|vcruntime140|msvcp140)'
    $isSystem = Test-Path (Join-Path $system32 $dep)
    if (($forbidden -contains $dep) -or -not ($isRuntime -or $isSystem)) {
      throw "$($dll.Name) depends on $dep, which is neither Windows nor the MSVC runtime."
    }
  }
}

# 5. Licences: the LGPL text, then every licence file of mpv, of each subproject and of ANGLE.
Copy-Item (Join-Path $repoRoot 'COPYING.LGPL-2.1') (Join-Path $stage 'licenses')
function Copy-Licenses([string]$From, [string]$To) {
  New-Item -ItemType Directory -Force $To | Out-Null
  $files = @(Get-ChildItem $From -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|Copyright|NOTICE|AUTHORS)' })
  $files += @(Get-ChildItem (Join-Path $From 'docs') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(FTL|LICENSE|GPLv2)\.TXT$' })
  if ($files.Count -eq 0) { throw "No licence file found in $From." }
  foreach ($f in $files) { Copy-Item $f.FullName $To }
}
Copy-Licenses $mpv (Join-Path $stage 'licenses\mpv')
$subprojectDirs = Get-ChildItem (Join-Path $mpv 'subprojects') -Directory |
  Where-Object { $_.Name -notin 'packagecache', 'packagefiles' }
foreach ($dir in $subprojectDirs) { Copy-Licenses $dir.FullName (Join-Path $stage "licenses\$($dir.Name)") }
New-Item -ItemType Directory -Force (Join-Path $stage 'licenses\angle') | Out-Null
Copy-Item (Join-Path $angle 'LICENSE.ANGLE') (Join-Path $stage 'licenses\angle\LICENSE')

# 6. Licence proof (fails the build if FFmpeg or mpv is not LGPL v2.1+).
& (Join-Path $PSScriptRoot 'check-license.ps1') -BuildDir $build -Dll (Join-Path $stage 'libmpv-2.dll') `
  -OutFile (Join-Path $stage 'ffmpeg-license.txt') -FfmpegConfigCopy (Join-Path $stage 'ffmpeg-config.h')

# Safeer configuration gate output; runtime evidence is produced separately.
Copy-Item (Join-Path $build 'safeer-capabilities.json') $stage

# 7. Manifest.
$subprojectRevisions = [ordered]@{}
foreach ($dir in $subprojectDirs) {
  $rev = $null
  if (Test-Path (Join-Path $dir.FullName '.git')) { $rev = git -C $dir.FullName rev-parse HEAD }
  $subprojectRevisions[$dir.Name] = $rev
}
$files = [ordered]@{}
foreach ($f in Get-ChildItem $stage -Recurse -File | Sort-Object FullName) {
  $rel = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
  $files[$rel] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest = [ordered]@{
  release     = $versions.release
  arch        = $Arch
  builtAt     = (Get-Date).ToUniversalTime().ToString('o')
  sources     = $versions
  subprojects = $subprojectRevisions
  angle       = Get-Content (Join-Path $angle 'angle.json') -Raw | ConvertFrom-Json
  toolchain   = [ordered]@{
    # The runner image fixes the Visual Studio, SDK and clang versions (empty outside GitHub Actions).
    image = $env:ImageVersion
    clang = (clang --version | Select-Object -First 1)
    meson = (meson --version)
  }
  mesonArgs   = @(Get-Content (Join-Path $WorkDir "meson-args-$Arch.txt"))
  sha256      = $files
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $stage 'manifest.json') -Encoding utf8

$zip = Join-Path $OutDir "$name.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
Write-Output "Packaged $zip"
