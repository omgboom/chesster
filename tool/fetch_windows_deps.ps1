# Downloads the Windows engine binaries bundled next to chesster.exe into
# windows/deps/ (gitignored): Microsoft's onnxruntime.dll for Maia and the
# official Stockfish executable. Archives are checked against pinned SHA-256s.
#
# Usage (Windows PowerShell 5.1 or pwsh):  powershell -File tool/fetch_windows_deps.ps1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ortVersion = '1.24.3'
$ortUrl = "https://github.com/microsoft/onnxruntime/releases/download/v$ortVersion/onnxruntime-win-x64-$ortVersion.zip"
$ortSha256 = '4fbfb85d0e9de9bb6fb8a9866a7cb477cbad404d889b236931bf3f5d547e5f48'
$stockfishUrl = 'https://github.com/official-stockfish/Stockfish/releases/download/sf_19/stockfish-windows-x86-64-universal.zip'
$stockfishSha256 = '3c8bf1f9ea66a09350a40df4f632288285ac206d99f33ab5842c408fc30b48a7'

$root = Split-Path -Parent $PSScriptRoot
$deps = Join-Path $root 'windows\deps'
$licenses = Join-Path $deps 'licenses'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("chesster-deps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $deps, $licenses, $work | Out-Null

function Get-VerifiedArchive([string]$url, [string]$sha256, [string]$name) {
    $zip = Join-Path $work "$name.zip"
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    if ($actual -ne $sha256) { throw "SHA-256 mismatch for ${url}: $actual" }
    $out = Join-Path $work $name
    Expand-Archive -Path $zip -DestinationPath $out
    return $out
}

try {
    $ort = Get-VerifiedArchive $ortUrl $ortSha256 'ort'
    $ortDir = Join-Path $ort "onnxruntime-win-x64-$ortVersion"
    Copy-Item (Join-Path $ortDir 'lib\onnxruntime.dll') $deps -Force
    Copy-Item (Join-Path $ortDir 'LICENSE') (Join-Path $licenses 'onnxruntime-LICENSE.txt') -Force
    Copy-Item (Join-Path $ortDir 'ThirdPartyNotices.txt') (Join-Path $licenses 'onnxruntime-ThirdPartyNotices.txt') -Force

    $sf = Get-VerifiedArchive $stockfishUrl $stockfishSha256 'stockfish'
    $sfDir = Join-Path $sf 'stockfish'
    Copy-Item (Join-Path $sfDir 'stockfish-windows-x86-64-universal.exe') (Join-Path $deps 'stockfish.exe') -Force
    Copy-Item (Join-Path $sfDir 'Copying.txt') (Join-Path $licenses 'stockfish-COPYING.txt') -Force
    Copy-Item (Join-Path $sfDir 'AUTHORS') (Join-Path $licenses 'stockfish-AUTHORS.txt') -Force
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Get-ChildItem -Recurse $deps | Select-Object FullName, Length | Format-Table -AutoSize
