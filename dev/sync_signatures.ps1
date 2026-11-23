#Requires -Version 5.1
param(
    [string]$UpstreamUrl = 'https://raw.githubusercontent.com/QNIX-Dev/eligibility-antigravity-patcher/main/manager.py',
    [string]$LocalManagerPy = ''
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$SigPath = Join-Path $Root 'signatures.json'

function Convert-PyRbToHex([string]$RawExpr) {
    $litMatches = [regex]::Matches($RawExpr, 'r?b"([^"]*)"')
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in $litMatches) { [void]$sb.Append($m.Groups[1].Value) }
    $s = $sb.ToString()
    $toks = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $s.Length) {
        if (($i + 4 -le $s.Length) -and ($s.Substring($i, 2) -eq '\x')) {
            $toks.Add($s.Substring($i + 2, 2).ToUpperInvariant())
            $i += 4
        } elseif ($s[$i] -eq '.') {
            $toks.Add('??')
            $i++
        } else {
            throw "Неподдерживаемый токен в Python-сигнатуре на позиции $i : $($s.Substring($i, [Math]::Min(10, $s.Length - $i)))"
        }
    }
    return ($toks -join ' ')
}

function Extract-GateX64([string]$Source, [string]$GateName) {
    $marker = "$GateName = Gate("
    $start = $Source.IndexOf($marker)
    if ($start -lt 0) { throw "Не найден $GateName в manager.py" }
    $openIdx = $Source.IndexOf('(', $start)
    $depth = 0
    $endIdx = -1
    for ($i = $openIdx; $i -lt $Source.Length; $i++) {
        if ($Source[$i] -eq '(') { $depth++ }
        elseif ($Source[$i] -eq ')') {
            $depth--
            if ($depth -eq 0) { $endIdx = $i; break }
        }
    }
    if ($endIdx -lt 0) { throw "Несбалансированные скобки в $GateName" }
    $inner = $Source.Substring($openIdx + 1, $endIdx - $openIdx - 1)
    $args = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    $inQ = $false
    for ($i = 0; $i -lt $inner.Length; $i++) {
        $ch = $inner[$i]
        if ($ch -eq '"') { $inQ = -not $inQ }
        if ($ch -eq ',' -and -not $inQ) {
            $args.Add($cur.ToString().Trim())
            [void]$cur.Clear()
        } else {
            [void]$cur.Append($ch)
        }
    }
    if ($cur.Length -gt 0) { $args.Add($cur.ToString().Trim()) }
    return [PSCustomObject]@{
        Find    = (Convert-PyRbToHex $args[0])
        Replace = (Convert-PyRbToHex $args[1])
    }
}

if (-not [string]::IsNullOrWhiteSpace($LocalManagerPy) -and (Test-Path -LiteralPath $LocalManagerPy)) {
    Write-Host "[*] Читаю локальный файл: $LocalManagerPy" -ForegroundColor Cyan
    $src = [System.IO.File]::ReadAllText($LocalManagerPy, [System.Text.Encoding]::UTF8)
} else {
    Write-Host "[*] Скачиваю свежий manager.py из QNIX-Dev/eligibility-antigravity-patcher..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'KotekSigSync/1.0')
    $src = $wc.DownloadString($UpstreamUrl)
}

$cli = Extract-GateX64 $src 'CLI_GATE_X64'
$mgr = Extract-GateX64 $src 'MANAGER_GATE_X64'

$ideReMatch   = [regex]::Match($src, 'IDE_RE\s*=\s*re\.compile\(rb"([^"]+)"\)')
$ideDoneMatch = [regex]::Match($src, 'IDE_DONE\s*=\s*b"([^"]+)"')
if (-not $ideReMatch.Success -or -not $ideDoneMatch.Success) {
    throw "Не найдены IDE_RE / IDE_DONE в manager.py"
}

$newObj = [ordered]@{
    schema_version = 2
    updated_at     = (Get-Date -Format 'yyyy-MM-dd')
    upstream       = 'QNIX-Dev/eligibility-antigravity-patcher'
    rules          = @(
        [ordered]@{
            id      = 'cli-eligibility-x64'
            target  = 'cli'
            type    = 'pe_hex'
            arch    = 'x64'
            enabled = $true
            desc    = 'CLI eligibility screen off (x64)'
            find    = $cli.Find
            replace = $cli.Replace
        },
        [ordered]@{
            id      = 'manager-eligibility-x64'
            target  = 'manager'
            type    = 'pe_hex'
            arch    = 'x64'
            enabled = $true
            desc    = 'Manager language_server hasValidAuth=true (x64)'
            find    = $mgr.Find
            replace = $mgr.Replace
        },
        [ordered]@{
            id      = 'extension-hub-x64'
            target  = 'extension'
            type    = 'pe_hex'
            arch    = 'x64'
            enabled = $true
            desc    = 'Extension agy --hub hasValidAuth=true (x64)'
            find    = $mgr.Find
            replace = $mgr.Replace
        },
        [ordered]@{
            id           = 'ide-eligibility-js'
            target       = 'ide'
            type         = 'js_regex'
            arch         = 'any'
            enabled      = $true
            desc         = 'IDE main.js isGoogleInternal=true'
            find         = $ideReMatch.Groups[1].Value
            replace      = '${1}true'
            done_literal = $ideDoneMatch.Groups[1].Value
        }
    )
}

$jsonOut = ($newObj | ConvertTo-Json -Depth 6) + "`r`n"
[System.IO.File]::WriteAllText($SigPath, $jsonOut, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[OK] signatures.json обновлён ($SigPath)" -ForegroundColor Green

if (Get-Command git -ErrorAction SilentlyContinue) {
    Push-Location $Root
    try {
        if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
            Write-Host ""
            & git diff -- signatures.json
            $ans = Read-Host "Закоммитить и запушить обновлённый signatures.json в GitHub? (y/N)"
            if ($ans.Trim().ToLowerInvariant() -eq 'y') {
                & git add signatures.json
                & git commit -m "chore: sync Antigravity signatures ($(Get-Date -Format 'yyyy-MM-dd'))"
                & git push
                Write-Host "[OK] Изменения отправлены на GitHub!" -ForegroundColor Green
            }
        }
    } finally {
        Pop-Location
    }
}
