#Requires -Version 5.1
param(
    [ValidateSet('menu', 'status', 'patch', 'restore', 'close')]
    [string]$Action = 'menu',
    [ValidateSet('all', 'ide', 'cli', 'manager', 'extension')]
    [string]$Target = 'all',
    [string]$SignaturesPath = '',
    [string]$SignaturesUrl = 'https://raw.githubusercontent.com/vanch150/kotek-antigravity-helper/main/signatures.json',
    [switch]$Offline,
    [switch]$ForceClose,
    [string]$CustomPath = ''
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Stop'

$script:HelperRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($SignaturesPath)) {
    $SignaturesPath = Join-Path $script:HelperRoot 'signatures.json'
}

function Write-Info([string]$Msg) { Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Msg)  { Write-Host "[X] $Msg" -ForegroundColor Red }

# Fast native C# 5 PE executable-section scanner (zero external dependencies, scans 100 MB in <50 ms)
if (-not ('KotekAgyPeScanner' -as [type])) {
    $csCode = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

public static class KotekAgyPeScanner
{
    public sealed class ScanResult
    {
        public string Status;
        public int Offset;
        public string Arch;
        public string Error;
    }

    private static string GetArch(ushort machine)
    {
        if (machine == 0x8664) return "x64";
        if (machine == 0xAA64) return "arm64";
        if (machine == 0x014C) return "x86";
        return "other";
    }

    private static void ParseHex(string hex, out byte[] bytes, out bool[] mask)
    {
        string[] parts = hex.Trim().Split(new char[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        bytes = new byte[parts.Length];
        mask = new bool[parts.Length];
        for (int i = 0; i < parts.Length; i++)
        {
            if (parts[i] == "??" || parts[i] == "?")
            {
                bytes[i] = 0;
                mask[i] = false;
            }
            else
            {
                bytes[i] = Convert.ToByte(parts[i], 16);
                mask[i] = true;
            }
        }
    }

    private static int FindInRange(byte[] data, int start, int length, byte[] pat, bool[] mask, List<int> hits)
    {
        int patLen = pat.Length;
        if (patLen == 0 || length < patLen) return 0;
        int end = start + length - patLen;
        int anchorIdx = -1;
        for (int k = 0; k < patLen; k++)
        {
            if (mask[k]) { anchorIdx = k; break; }
        }
        if (anchorIdx < 0) return 0;
        byte anchorByte = pat[anchorIdx];

        int pos = start + anchorIdx;
        int maxAnchor = end + anchorIdx;
        while (pos <= maxAnchor)
        {
            int found = Array.IndexOf(data, anchorByte, pos, maxAnchor - pos + 1);
            if (found < 0) break;
            int cand = found - anchorIdx;
            bool ok = true;
            for (int j = 0; j < patLen; j++)
            {
                if (mask[j] && data[cand + j] != pat[j]) { ok = false; break; }
            }
            if (ok)
            {
                hits.Add(cand);
                if (hits.Count > 1) return hits.Count;
            }
            pos = found + 1;
        }
        return hits.Count;
    }

    public static string Sha256(string path)
    {
        using (SHA256 sha = SHA256.Create())
        using (FileStream fs = File.OpenRead(path))
        {
            byte[] h = sha.ComputeHash(fs);
            return BitConverter.ToString(h).Replace("-", "").ToLowerInvariant();
        }
    }

    public static ScanResult InspectOrPatch(string filePath, string backupPath, string findHex, string replaceHex, string expectedArch, bool dryRun)
    {
        ScanResult res = new ScanResult();
        res.Offset = -1;
        try
        {
            byte[] data = File.ReadAllBytes(filePath);
            if (data.Length < 0x40 || data[0] != 0x4D || data[1] != 0x5A)
            {
                res.Status = "not_pe";
                return res;
            }
            int peOff = BitConverter.ToInt32(data, 0x3C);
            if (peOff <= 0 || peOff + 24 > data.Length || data[peOff] != 0x50 || data[peOff + 1] != 0x45 || data[peOff + 2] != 0 || data[peOff + 3] != 0)
            {
                res.Status = "not_pe";
                return res;
            }
            ushort machine = BitConverter.ToUInt16(data, peOff + 4);
            res.Arch = GetArch(machine);
            if (!string.IsNullOrEmpty(expectedArch) && expectedArch != "any" && res.Arch != expectedArch)
            {
                res.Status = "arch_mismatch";
                return res;
            }

            ushort numSec = BitConverter.ToUInt16(data, peOff + 6);
            ushort optSize = BitConverter.ToUInt16(data, peOff + 20);
            int secTable = peOff + 24 + optSize;

            byte[] findBytes, repBytes;
            bool[] findMask, repMask;
            ParseHex(findHex, out findBytes, out findMask);
            ParseHex(replaceHex, out repBytes, out repMask);
            if (findBytes.Length != repBytes.Length || findBytes.Length == 0)
            {
                res.Status = "error";
                res.Error = "Length mismatch between find and replace patterns";
                return res;
            }

            List<int> origHits = new List<int>();
            List<int> doneHits = new List<int>();
            for (int i = 0; i < numSec; i++)
            {
                int off = secTable + i * 40;
                if (off + 40 > data.Length) break;
                uint rawSize = BitConverter.ToUInt32(data, off + 16);
                uint rawPtr = BitConverter.ToUInt32(data, off + 20);
                uint chars = BitConverter.ToUInt32(data, off + 36);
                if ((chars & 0x20000000u) != 0 && rawSize > 0 && (long)rawPtr + (long)rawSize <= data.Length)
                {
                    FindInRange(data, (int)rawPtr, (int)rawSize, findBytes, findMask, origHits);
                    FindInRange(data, (int)rawPtr, (int)rawSize, repBytes, repMask, doneHits);
                }
            }

            if (origHits.Count > 1 || doneHits.Count > 1 || (origHits.Count > 0 && doneHits.Count > 0))
            {
                res.Status = "ambiguous";
                return res;
            }
            if (origHits.Count == 0 && doneHits.Count == 1)
            {
                res.Status = "already_patched";
                res.Offset = doneHits[0];
                return res;
            }
            if (origHits.Count == 0)
            {
                res.Status = "no_match";
                return res;
            }

            int pos = origHits[0];
            res.Offset = pos;
            if (dryRun)
            {
                res.Status = "ready";
                return res;
            }

            if (!File.Exists(backupPath))
            {
                File.Copy(filePath, backupPath, true);
                if (Sha256(filePath) != Sha256(backupPath))
                {
                    res.Status = "error";
                    res.Error = "Backup SHA-256 verification failed";
                    return res;
                }
            }

            for (int j = 0; j < repBytes.Length; j++)
            {
                if (repMask[j]) data[pos + j] = repBytes[j];
            }

            try
            {
                File.WriteAllBytes(filePath, data);
                byte[] verify = File.ReadAllBytes(filePath);
                for (int j = 0; j < repBytes.Length; j++)
                {
                    if (repMask[j] && verify[pos + j] != repBytes[j])
                    {
                        throw new IOException("Post-write verification mismatch at byte " + j);
                    }
                }
                res.Status = "patched";
                return res;
            }
            catch (Exception ex)
            {
                try { File.Copy(backupPath, filePath, true); } catch { }
                res.Status = "error";
                res.Error = ex.Message;
                return res;
            }
        }
        catch (Exception ex)
        {
            res.Status = "error";
            res.Error = ex.Message;
            return res;
        }
    }
}
'@
    Add-Type -TypeDefinition $csCode -Language CSharp
}

function Sync-RemoteSignatures([string]$Url, [string]$LocalPath) {
    if ($Offline -or [string]::IsNullOrWhiteSpace($Url)) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add('User-Agent', 'KotekAntigravityHelper/0.2')
        $raw = $wc.DownloadString($Url)
        $parsed = $raw | ConvertFrom-Json
        if ($null -ne $parsed -and $null -ne $parsed.rules -and @($parsed.rules).Count -gt 0) {
            [System.IO.File]::WriteAllText($LocalPath, $raw, (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok "Сигнатуры обновлены с GitHub (обновлено: $($parsed.updated_at))"
        }
    } catch {
        Write-Info "Использую локальный signatures.json (онлайн-проверка пропущена)"
    }
}

function Test-AntigravityProcessesRunning {
    $patterns = @('Antigravity*', 'agy', 'language_server*')
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        foreach ($pat in $patterns) {
            if ($p.ProcessName -like $pat) {
                $found.Add("$($p.ProcessName) (PID $($p.Id))")
                break
            }
        }
    }
    return $found.ToArray()
}

function Stop-AntigravityProcesses {
    $softProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Antigravity*' })
    foreach ($p in $softProcs) {
        try {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                [void]$p.CloseMainWindow()
            }
        } catch {}
    }
    if ($softProcs.Count -gt 0) {
        for ($w = 0; $w -lt 15; $w++) {
            $stillAg = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Antigravity*' })
            if ($stillAg.Count -eq 0) { break }
            Start-Sleep -Milliseconds 200
        }
    }
    $patterns = @('Antigravity*', 'agy', 'language_server*')
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        foreach ($pat in $patterns) {
            if ($p.ProcessName -like $pat) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
                break
            }
        }
    }
    Start-Sleep -Milliseconds 250
    $left = @(Test-AntigravityProcessesRunning)
    if ($left.Count -eq 0) {
        Write-Ok "Все процессы Antigravity закрыты."
        return $true
    }
    Write-Warn "Не удалось закрыть некоторые процессы: $($left -join ', ')"
    return $false
}

function Find-AntigravityLauncherExe {
    $roots = @(Get-AntigravitySearchRoots)
    $exeNames = @('Antigravity.exe', 'Antigravity IDE.exe')
    foreach ($r in $roots) {
        foreach ($en in $exeNames) {
            $p1 = Join-Path $r $en
            if (Test-Path -LiteralPath $p1 -PathType Leaf) { return [System.IO.Path]::GetFullPath($p1) }
        }
        foreach ($sub in (Get-ChildItem -LiteralPath $r -Directory -Filter '*Antigravity*' -ErrorAction SilentlyContinue)) {
            foreach ($en in $exeNames) {
                $p2 = Join-Path $sub.FullName $en
                if (Test-Path -LiteralPath $p2 -PathType Leaf) { return [System.IO.Path]::GetFullPath($p2) }
                $p3 = Join-Path $sub.FullName ("current\$en")
                if (Test-Path -LiteralPath $p3 -PathType Leaf) { return [System.IO.Path]::GetFullPath($p3) }
            }
        }
    }
    foreach ($regRoot in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        foreach ($item in (Get-ItemProperty -Path $regRoot -ErrorAction SilentlyContinue)) {
            if ($item.DisplayName -and ($item.DisplayName -match '(?i)Antigravity') -and $item.DisplayIcon) {
                $ic = ([string]$item.DisplayIcon).Split(',')[0].Trim().Trim('"')
                if ($ic -match '(?i)Antigravity.*\.exe$' -and (Test-Path -LiteralPath $ic -PathType Leaf)) {
                    return [System.IO.Path]::GetFullPath($ic)
                }
            }
        }
    }
    return ''
}

function Get-AntigravitySearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($cand in @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        $env:LOCALAPPDATA,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        (Join-Path $env:USERPROFILE 'scoop\apps')
    )) {
        if ($cand -and (Test-Path -LiteralPath $cand -PathType Container)) { $roots.Add($cand) }
    }
    foreach ($regRoot in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        foreach ($item in (Get-ItemProperty -Path $regRoot -ErrorAction SilentlyContinue)) {
            if ($item.DisplayName -and ($item.DisplayName -match '(?i)Antigravity')) {
                if ($item.InstallLocation -and (Test-Path -LiteralPath $item.InstallLocation -PathType Container)) {
                    $roots.Add($item.InstallLocation)
                }
            }
        }
    }
    return @($roots | Select-Object -Unique)
}

function Find-AntigravityTargets([string]$FilterTarget = 'all', [string]$OverridePath = '') {
    $results = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    function Add-Target([string]$Kind, [string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        $full = [System.IO.Path]::GetFullPath($Path)
        $key = "$Kind|$($full.ToLowerInvariant())"
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $results.Add([PSCustomObject]@{
            Kind   = $Kind
            Path   = $full
            Backup = ($full + '.agybak')
            HasBak = (Test-Path -LiteralPath ($full + '.agybak') -PathType Leaf)
        })
    }

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $k = if ($FilterTarget -eq 'all') { 'cli' } else { $FilterTarget }
        Add-Target $k $OverridePath
        return $results.ToArray()
    }

    $roots = @(Get-AntigravitySearchRoots)

    if ($FilterTarget -in @('all', 'cli')) {
        foreach ($cmdName in @('agy.exe', 'antigravity.exe')) {
            $cmd = Get-Command $cmdName -ErrorAction SilentlyContinue
            if ($null -ne $cmd -and $cmd.Source) { Add-Target 'cli' $cmd.Source }
        }
        foreach ($r in $roots) {
            foreach ($pat in @('agy\bin\agy.exe', 'agy\*\bin\agy.exe', 'agy*\agy.exe')) {
                foreach ($f in (Get-ChildItem -Path (Join-Path $r $pat) -File -ErrorAction SilentlyContinue)) {
                    Add-Target 'cli' $f.FullName
                }
            }
        }
    }

    if ($FilterTarget -in @('all', 'extension')) {
        Add-Target 'extension' (Join-Path $env:USERPROFILE '.gemini\bin\agy.exe')
    }

    if ($FilterTarget -in @('all', 'manager')) {
        foreach ($r in $roots) {
            Add-Target 'manager' (Join-Path $r 'resources\bin\language_server.exe')
            foreach ($sub in (Get-ChildItem -LiteralPath $r -Directory -Filter '*Antigravity*' -ErrorAction SilentlyContinue)) {
                Add-Target 'manager' (Join-Path $sub.FullName 'resources\bin\language_server.exe')
                Add-Target 'manager' (Join-Path $sub.FullName 'current\resources\bin\language_server.exe')
            }
        }
    }

    if ($FilterTarget -in @('all', 'ide')) {
        foreach ($r in $roots) {
            Add-Target 'ide' (Join-Path $r 'resources\app\out\main.js')
            foreach ($sub in (Get-ChildItem -LiteralPath $r -Directory -Filter '*Antigravity*' -ErrorAction SilentlyContinue)) {
                Add-Target 'ide' (Join-Path $sub.FullName 'resources\app\out\main.js')
                Add-Target 'ide' (Join-Path $sub.FullName 'current\resources\app\out\main.js')
            }
        }
    }

    return $results.ToArray()
}

function Clear-IdeJsCache {
    $bases = @(
        (Join-Path $env:APPDATA 'Antigravity IDE'),
        (Join-Path $env:USERPROFILE 'scoop\persist\antigravity-ide\data\user-data')
    )
    foreach ($b in $bases) {
        foreach ($sub in @('CachedData', 'Code Cache\js')) {
            $p = Join-Path $b $sub
            if (Test-Path -LiteralPath $p -PathType Container) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-JsRegexPatch([string]$FilePath, [string]$BackupPath, $Rule, [bool]$DryRun) {
    $txt = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $origMatches = [regex]::Matches($txt, $Rule.find)
    $doneMatches = [regex]::Matches($txt, [regex]::Escape($Rule.done_literal))

    if ($origMatches.Count -gt 1 -or $doneMatches.Count -gt 1 -or ($origMatches.Count -gt 0 -and $doneMatches.Count -gt 0)) {
        return 'ambiguous'
    }
    if ($origMatches.Count -eq 0 -and $doneMatches.Count -eq 1) { return 'already_patched' }
    if ($origMatches.Count -eq 0) { return 'no_match' }
    if ($DryRun) { return 'ready' }

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $FilePath -Destination $BackupPath -Force
    }
    $newTxt = [regex]::Replace($txt, $Rule.find, $Rule.replace, 1)
    try {
        [System.IO.File]::WriteAllText($FilePath, $newTxt, (New-Object System.Text.UTF8Encoding($false)))
        Clear-IdeJsCache
        return 'patched'
    } catch {
        Copy-Item -LiteralPath $BackupPath -Destination $FilePath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Load-SignatureRules([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Файл сигнатур не найден: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json
    return @($json.rules | Where-Object { $_.enabled -eq $true })
}

function Invoke-HelperAction([string]$Act, [string]$Tgt, [string]$Override) {
    if ($Act -eq 'close') {
        [void](Stop-AntigravityProcesses)
        return
    }

    $targets = @(Find-AntigravityTargets $Tgt $Override)
    if ($targets.Count -eq 0) {
        Write-Warn "Установленные компоненты Google Antigravity не найдены автоматически."
        Write-Info "Можно указать путь вручную: .\antigravity_helper.ps1 -Action $Act -Target cli -CustomPath 'C:\path\to\agy.exe'"
        return
    }

    if ($Act -in @('patch', 'restore')) {
        $running = @(Test-AntigravityProcessesRunning)
        if ($running.Count -gt 0 -and $ForceClose) {
            Write-Info "Закрываю запущенные процессы Antigravity перед операцией..."
            [void](Stop-AntigravityProcesses)
            $running = @(Test-AntigravityProcessesRunning)
        }
        if ($running.Count -gt 0) {
            Write-Err "Закрой все процессы Antigravity перед операцией: $($running -join ', ')"
            return
        }
    }

    if ($Act -eq 'restore') {
        $restored = 0
        foreach ($t in $targets) {
            if (-not $t.HasBak) { continue }
            $bakHash = [KotekAgyPeScanner]::Sha256($t.Backup)
            Copy-Item -LiteralPath $t.Backup -Destination $t.Path -Force
            if ([KotekAgyPeScanner]::Sha256($t.Path) -eq $bakHash) {
                Remove-Item -LiteralPath $t.Backup -Force
                if ($t.Kind -eq 'ide') { Clear-IdeJsCache }
                Write-Ok "Восстановлен [$($t.Kind)]: $($t.Path)"
                $restored++
            } else {
                Write-Err "Хэш не совпал после восстановления: $($t.Path)"
            }
        }
        if ($restored -eq 0) { Write-Info "Бэкапы *.agybak не найдены — все файлы оригинальные." }
        return
    }

    $rules = @(Load-SignatureRules $SignaturesPath)
    if ($rules.Count -eq 0) {
        Write-Warn "В signatures.json нет активных правил."
        return
    }

    $dry = ($Act -eq 'status')
    foreach ($t in $targets) {
        $kindRules = @($rules | Where-Object { $_.target -eq $t.Kind })
        if ($kindRules.Count -eq 0) {
            Write-Info "[$($t.Kind)] $($t.Path) — нет правил в signatures.json"
            continue
        }
        foreach ($r in $kindRules) {
            if ($r.type -eq 'js_regex') {
                $st = Invoke-JsRegexPatch $t.Path $t.Backup $r $dry
                $offStr = ''
            } else {
                $res = [KotekAgyPeScanner]::InspectOrPatch($t.Path, $t.Backup, $r.find, $r.replace, $r.arch, $dry)
                $st = $res.Status
                $offStr = if ($res.Offset -ge 0) { (' @ 0x{0:X}' -f $res.Offset) } else { '' }
                if ($st -eq 'error') { Write-Err "[$($t.Kind)] $($t.Path) — $($res.Error)"; continue }
            }
            switch ($st) {
                'ready'           { Write-Info "[$($t.Kind)] $($t.Path) — готов к патчу ($($r.id)$offStr)" }
                'patched'         { Write-Ok   "[$($t.Kind)] $($t.Path) — пропатчен ($($r.id)$offStr), бэкап .agybak создан" }
                'already_patched' { Write-Ok   "[$($t.Kind)] $($t.Path) — уже пропатчен ($($r.id)$offStr)" }
                'ambiguous'       { Write-Warn "[$($t.Kind)] $($t.Path) — неоднозначная сигнатура ($($r.id)), пропущено" }
                'arch_mismatch'   { Write-Warn "[$($t.Kind)] $($t.Path) — другая архитектура (нужна $($r.arch))" }
                'no_match'        { Write-Warn "[$($t.Kind)] $($t.Path) — сигнатура $($r.id) не найдена (вероятно, вышел новый билд Antigravity)" }
                default           { Write-Warn "[$($t.Kind)] $($t.Path) — статус: $st" }
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Action -ne 'close') {
        Sync-RemoteSignatures $SignaturesUrl $SignaturesPath
    }

    if ($Action -eq 'menu') {
        while ($true) {
            Write-Host ""
            Write-Host "=== Kotek Antigravity Helper (v0.2.0) ===" -ForegroundColor Cyan
            Write-Host "1. Проверить статус установленных клиентов Antigravity"
            Write-Host "2. Применить патч (с бэкапом *.agybak)"
            Write-Host "3. Откатить всё из *.agybak"
            Write-Host "0. Выход"
            $choice = Read-Host "Выбери действие"
            switch ($choice.Trim()) {
                '1' { Invoke-HelperAction 'status'  $Target $CustomPath }
                '2' { Invoke-HelperAction 'patch'   $Target $CustomPath }
                '3' { Invoke-HelperAction 'restore' $Target $CustomPath }
                '0' { break }
                default { Write-Warn "Неизвестный пункт: $choice" }
            }
            if ($choice.Trim() -eq '0') { break }
        }
    } else {
        Invoke-HelperAction $Action $Target $CustomPath
    }
}
