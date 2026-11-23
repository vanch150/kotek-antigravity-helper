#Requires -Version 5.1
param([string]$Version = '')
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
    $vf = Join-Path $Root 'version.txt'
    $Version = if (Test-Path -LiteralPath $vf) { ([string](Get-Content -LiteralPath $vf -TotalCount 1 -Encoding UTF8)).Trim() } else { '0.2.0' }
}
$OutZip = Join-Path (Split-Path -Parent $Root) ("kotek-antigravity-helper-v$($Version.TrimStart('v','V')).zip")
$Stage = Join-Path $env:TEMP ("kotek_agy_stage_" + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

try {
    foreach ($f in @('!_START_ANTIGRAVITY_HELPER.bat', 'antigravity_helper.ps1', 'signatures.json', 'version.txt', 'README.md', 'LICENSE')) {
        $src = Join-Path $Root $f
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $Stage $f) -Force
        }
    }
    if (Test-Path -LiteralPath $OutZip) { Remove-Item -LiteralPath $OutZip -Force }
    Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $OutZip -CompressionLevel Optimal
    Write-Host "[OK] Релизный архив собран: $OutZip" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
}
