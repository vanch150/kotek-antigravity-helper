# Kotek Antigravity Helper

Официальный подключаемый модуль-компаньон для **[Zapret2 Kotek](https://github.com/vanch150/zapret2-kotek)** (Windows 10/11).

Снимает локальную проверку региона (`eligibility`) в клиентах **Google Antigravity** (IDE, Manager, CLI, Extension) для российских Google-аккаунтов — на чистом **PowerShell 5.1 + встроенном C# 5**, без Python и сторонних зависимостей.

## Зачем нужен этот модуль

У доступа к Google Antigravity из РФ два барьера:
1. **Сетевой (GeoIP / DPI)** — решается в основном `zapret2-kotek` через раздел **«Обход ИИ» → `Google Antigravity`** (Windows NRPT + SmartDNS).
2. **Локальная проверка аккаунта в клиенте** — решается этим модулем. Он вынесен в отдельный репозиторий, чтобы основной `zapret2-kotek` не ловил ложные срабатывания Windows Defender / SmartScreen.

## Установка в 3 шага (через мастер Zapret2 Kotek)

1. Скачай свежий **`kotek-antigravity-helper-vX.Y.Z.zip`** со страницы [Releases](https://github.com/vanch150/kotek-antigravity-helper/releases/latest).
2. В **Zapret2 Kotek** открой **«Обход ИИ» → «Сервисы ▾»**, поставь галочку **Google Antigravity** и нажми **«Пошаговая настройка →»**.
3. На Шаге 2 нажми **«2. Указать скачанный ZIP...»** — Котек сам распакует модуль в `modules\antigravity\` и переведёт тебя на Шаг 3 для применения патча.

*(Также модуль можно запускать автономно двойным кликом по `!_START_ANTIGRAVITY_HELPER.bat`.)*

## Безопасность и откат

* Сканирует **только исполняемые секции PE** (`IMAGE_SCN_MEM_EXECUTE`) и срабатывает строго при **1 уникальном совпадении** (fail-closed).
* Перед записью создаёт резервную копию **`*.agybak`** с проверкой SHA-256 и чистит V8-кэш IDE (`CachedData`, `Code Cache\js`).
* Полный откат к оригинальным файлам — одной кнопкой **«Откатить (.agybak)»** на Шаге 3.
* Актуальные `signatures.json` подтягиваются автоматически с GitHub при каждом запуске.

## Инструменты автора (`dev/`)

* `dev\SYNC_SIGNATURES.bat` — в 1 клик синхронизирует свежие Windows x64/JS-сигнатуры из [QNIX-Dev/eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher) в `signatures.json` и предлагает запушить в GitHub.
* `dev\BUILD_RELEASE.bat` — собирает чистый `kotek-antigravity-helper-v0.2.0.zip` (без `dev/` и `.git/`) для публикации в GitHub Releases.
