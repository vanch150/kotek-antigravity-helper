#Requires -Version 5.1
# Kotek Antigravity Helper — Interactive GitHub Commit & Release Publisher (dev/publish_github.ps1)
param([string]$Root = '')

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$Root = [System.IO.Path]::GetFullPath($Root.Trim('"', "'")).TrimEnd('\', '/')
$repoSlug = 'vanch150/kotek-antigravity-helper'
$repoUrl  = "https://github.com/$repoSlug.git"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$verFile = Join-Path $Root 'version.txt'
$curVer  = if (Test-Path -LiteralPath $verFile) { ([string](Get-Content -LiteralPath $verFile -TotalCount 1 -Encoding UTF8)).Trim() } else { '0.2.0' }

Clear-Host
Write-Host ''
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host "    (=^.^=) KOTEK ANTIGRAVITY HELPER v$curVer — ПУБЛИКАЦИЯ НА GITHUB" -ForegroundColor Cyan
Write-Host '  ==================================================================' -ForegroundColor Cyan
Write-Host "  Папка       : $Root" -ForegroundColor Gray
Write-Host "  Репозиторий : https://github.com/$repoSlug" -ForegroundColor Gray
Write-Host '  ------------------------------------------------------------------' -ForegroundColor DarkGray

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '  [X] git не найден в PATH. Установи Git for Windows.' -ForegroundColor Red
    exit 1
}

Push-Location -LiteralPath $Root
try {
    # 0. Auto-init git repo if missing
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        Write-Host "`n  [*] Папка ещё не привязана к Git — инициализирую репозиторий..." -ForegroundColor Yellow
        & git init | Out-Null
        & git branch -M main | Out-Null
        & git remote add origin $repoUrl 2>$null
        Write-Host "  [OK] Привязано к $repoUrl" -ForegroundColor Green
    } else {
        $curOrigin = (& git remote get-url origin 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($curOrigin)) {
            & git remote add origin $repoUrl 2>$null
        }
    }

    # 1. Quick PS 5.1 syntax & JSON check
    Write-Host "`n  [1] Проверка синтаксиса PS 5.1 и signatures.json..." -ForegroundColor Yellow
    $parseErrs = 0
    foreach ($f in (Get-ChildItem -Path $Root -Filter '*.ps1' -Recurse | Where-Object { $_.FullName -notmatch '\\\.git\\' })) {
        $tok = $null; $err = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
        if ($err -and $err.Count -gt 0) {
            $parseErrs++
            foreach ($e in $err) { Write-Host "  [FAIL] $($f.Name):$($e.Extent.StartLineNumber) — $($e.Message)" -ForegroundColor Red }
        }
    }
    $sigPath = Join-Path $Root 'signatures.json'
    if (Test-Path -LiteralPath $sigPath) {
        try { $null = (Get-Content -LiteralPath $sigPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { $parseErrs++; Write-Host "  [FAIL] Невалидный signatures.json: $($_.Exception.Message)" -ForegroundColor Red }
    }
    if ($parseErrs -gt 0) {
        Write-Host '  [!] Исправь ошибки перед публикацией.' -ForegroundColor Red
        exit 1
    }
    Write-Host '  [OK] Синтаксис PS 5.1 и JSON в порядке.' -ForegroundColor Green

    # 2. Show git status
    $statusLines = @(& git status --short)
    Write-Host "`n  Изменённых файлов: $($statusLines.Count)" -ForegroundColor Gray
    foreach ($sl in ($statusLines | Select-Object -First 15)) { Write-Host "    $sl" -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '  [1] Только коммит + push кода на GitHub' -ForegroundColor Green
    Write-Host '  [2] Полный релиз (обновить версию/README + собрать ZIP + push + GitHub Release)' -ForegroundColor Cyan
    Write-Host '  [0] Выход' -ForegroundColor DarkGray
    Write-Host ''
    $mode = Read-Host '  Выбери действие [0/1/2] (Enter = Выход)'
    if ($mode -notin @('1', '2')) { exit 0 }

    $newVer = $curVer
    if ($mode -eq '2') {
        $vIn = Read-Host "  Версия релиза (Enter = $curVer)"
        if (-not [string]::IsNullOrWhiteSpace($vIn)) {
            $newVer = $vIn.Trim().TrimStart('v', 'V')
        }
        [System.IO.File]::WriteAllText($verFile, "$newVer`r`n", $utf8NoBom)

        $readmePath = Join-Path $Root 'README.md'
        if (Test-Path -LiteralPath $readmePath) {
            $rd = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
            $rdNew = [regex]::Replace($rd, 'kotek-antigravity-helper-v\d+\.\d+\.\d+\.zip', "kotek-antigravity-helper-v$newVer.zip")
            if ($rdNew -ne $rd) {
                [System.IO.File]::WriteAllText($readmePath, $rdNew, $utf8NoBom)
                Write-Host "  [OK] README.md обновлён под v$newVer" -ForegroundColor Green
            }
        }
    }

    $defMsg = if ($mode -eq '2') { "release: v$newVer" } else { "chore: update helper and signatures" }
    $msgIn = Read-Host "  Текст коммита (Enter = '$defMsg')"
    $commitMsg = if ([string]::IsNullOrWhiteSpace($msgIn)) { $defMsg } else { $msgIn.Trim() }

    & git add -A
    $staged = @(& git status --short)
    if ($staged.Count -gt 0) {
        & git commit -m $commitMsg
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  [X] Ошибка git commit.' -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host '  [*] Новых изменений для коммита нет — продолжаю push.' -ForegroundColor DarkGray
    }

    Write-Host "`n  [*] Отправляю ветку main на GitHub..." -ForegroundColor Cyan
    & git push -u origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  [!] Обычный push не прошёл (возможно, на GitHub уже есть начальный коммит LICENSE/README).' -ForegroundColor Yellow
        $pullAns = Read-Host '  Подтянуть историю с GitHub (--allow-unrelated-histories) и повторить push? [Д/н]'
        if ([string]::IsNullOrWhiteSpace($pullAns) -or $pullAns -notmatch '^[nNнН]') {
            & git pull origin main --allow-unrelated-histories --no-edit
            & git push -u origin main
        }
    }

    if ($mode -eq '2') {
        $buildScript = Join-Path $Root 'dev\build_release.ps1'
        Write-Host "`n  [*] Собираю релизный архив v$newVer..." -ForegroundColor Cyan
        & $buildScript -Version $newVer
        $zipPath = Join-Path (Split-Path -Parent $Root) "kotek-antigravity-helper-v$newVer.zip"
        if (-not (Test-Path -LiteralPath $zipPath)) {
            Write-Host "  [X] Не найден собранный архив: $zipPath" -ForegroundColor Red
            exit 1
        }

        $tagName = "v$newVer"
        & git tag -f $tagName
        & git push -f origin $tagName

        $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
        if ($null -ne $ghCmd) {
            Write-Host "`n  [*] Создаю GitHub Release $tagName через gh CLI..." -ForegroundColor Cyan
            $notes = "Подключаемый модуль Google Antigravity для Zapret2 Kotek (v$newVer).`n`nИнструкция по установке — в [README](https://github.com/$repoSlug#readme)."
            & gh release create $tagName $zipPath --repo $repoSlug --title "Kotek Antigravity Helper $tagName" --notes $notes
            if ($LASTEXITCODE -ne 0) {
                & gh release upload $tagName $zipPath --repo $repoSlug --clobber
            }
            Write-Host "  [OK] Релиз опубликован: https://github.com/$repoSlug/releases/tag/$tagName" -ForegroundColor Green
        } else {
            Write-Host "`n  [*] gh CLI не установлен — открываю страницу создания релиза в браузере и папку с ZIP..." -ForegroundColor Yellow
            try { Start-Process "https://github.com/$repoSlug/releases/new?tag=$tagName&title=Kotek+Antigravity+Helper+$tagName" } catch {}
            try { Start-Process 'explorer.exe' -ArgumentList "/select,`"$zipPath`"" } catch {}
            Write-Host "  Просто перетащи выделенный ZIP в окно браузера и нажми Publish release!" -ForegroundColor Green
        }
    }
    Write-Host "`n  [OK] Готово!" -ForegroundColor Green
} finally {
    Pop-Location
}
