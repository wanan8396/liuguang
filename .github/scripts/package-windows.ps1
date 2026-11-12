[CmdletBinding()]
param(
    [string]$ReleaseDirectory = 'build/windows/x64/runner/Release',
    [string]$OutputDirectory = 'artifacts/windows'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$required = @(
    'liuguang.exe',
    'flutter_windows.dll',
    'flutter_inappwebview_windows_plugin.dll',
    'quickjs_c_bridge.dll',
    'msvcp140.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'data/icudtl.dat',
    'data/app.so',
    'data/flutter_assets'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $release $relative))) {
        throw "Incomplete Windows release bundle: missing $relative"
    }
}
if (@(Get-ChildItem -LiteralPath $release -Filter '*mpv*.dll' -File).Count -eq 0) {
    throw 'Incomplete Windows release bundle: media_kit mpv DLL missing'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$bundleName = 'liuguang-windows-x64'
$stage = Join-Path $output $bundleName
$archive = Join-Path $output "$bundleName.zip"
if (Test-Path -LiteralPath $stage) {
    throw "Staging path already exists: $stage"
}

try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    Get-ChildItem -LiteralPath $release -Force | Copy-Item -Destination $stage -Recurse -Force
    Copy-Item -LiteralPath 'LICENSE', 'THIRD_PARTY_NOTICES' -Destination $stage
    Copy-Item -LiteralPath 'third_party/flutter_js/LICENSE' -Destination (Join-Path $stage 'flutter_js-LICENSE.txt')
    Copy-Item -LiteralPath 'docs/PLATFORMS.md' -Destination (Join-Path $stage 'PLATFORMS.md')
    $commit = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { 'local-unrecorded' }
    $flutter = if ($env:FLUTTER_VERSION) { $env:FLUTTER_VERSION } else { 'see toolchain output' }
    @"
commit=$commit
platform=windows-x64
mode=release
flutter=$flutter
signing=unsigned-no-authenticode
real-source-playback=not-tested
Run liuguang.exe with every bundled DLL and the data directory kept beside it.
Microsoft runtime DLLs are redistributed under the applicable Visual Studio terms.
"@ | Set-Content -LiteralPath (Join-Path $stage 'BUILD.txt') -Encoding utf8

    $digests = Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
    }
    $digests | Set-Content -LiteralPath (Join-Path $stage 'SHA256SUMS.txt') -Encoding ascii
    Copy-Item -LiteralPath (Join-Path $stage 'BUILD.txt') -Destination $output
    Compress-Archive -LiteralPath $stage -DestinationPath $archive -CompressionLevel Optimal -Force
    '{0}  {1}.zip' -f (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant(), $bundleName |
        Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ascii
    Write-Output "Packaged complete Windows release: $archive"
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
