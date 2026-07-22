# 🔧 Защита от закрытия окна и проблем с кодировкой
$ErrorActionPreference = 'Continue'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force 2>$null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function ObjToHash($o) {
    $h = @{}
    foreach($p in $o.PSObject.Properties) { 
        $v = $p.Value
        if ($v -is [pscustomobject]) { $v = ObjToHash $v }
        $h[$p.Name] = $v 
    }
    return $h
}

# Функция красивого прогресс-бара (Сплошные квадраты)
function Get-ProgressBar([int]$Percent, [int]$Length = 40) {
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $filled = [math]::Round(($Percent / 100) * $Length)
    $empty = $Length - $filled
    return "[$('█' * $filled)$('░' * $empty)] $Percent%"
}

try {

Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Пакетный Умный Конвертер Видео для TV (NVENC / CPU)    " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "ЧТО ДЕЛАЕТ ЭТОТ СКРИПТ:" -ForegroundColor Yellow
Write-Host "  [*] Интеллектуальный отбор" -ForegroundColor Cyan
    Write-Host "     Ищет видео во всех подпапках. Если файл уже идеален для совместимости с ТВ " -ForegroundColor White -NoNewline
    Write-Host "(MP4, H.264, yuv420p)" -ForegroundColor DarkGray -NoNewline
    Write-Host " - он пропускается." -ForegroundColor White
Write-Host "  [>>] Умное кодирование " -ForegroundColor Cyan
    Write-Host "     Несовместимые с TV файлы (MKV, AVI, HEVC, AV1, WebM) кодируются " -ForegroundColor White -NoNewline
    Write-Host "через видеокарту NVIDIA" -ForegroundColor Green -NoNewline
    Write-Host " (не нагружая процессор)." -ForegroundColor White
    Write-Host "     При сбоях автоматически включается " -ForegroundColor White -NoNewline
    Write-Host "CPU декодер" -ForegroundColor Yellow -NoNewline
    Write-Host " для надёжного восстановления." -ForegroundColor White
Write-Host "  [=>] Сохранение свойств оригинала " -ForegroundColor Cyan
    Write-Host "     - Контейнер:   перепаковывается в универсальный " -ForegroundColor White -NoNewline
    Write-Host "MP4" -ForegroundColor Green
    Write-Host "     - Разрешение:  " -ForegroundColor White -NoNewline
    Write-Host "ОСТАЕТСЯ ОРИГИНАЛЬНЫМ " -ForegroundColor Green -NoNewline
    Write-Host "(4K -> 4K, 720p -> 720p)" -ForegroundColor DarkGray
    Write-Host "     - Кадры (FPS): " -ForegroundColor White -NoNewline
    Write-Host "ОСТАЮТСЯ ОРИГИНАЛЬНЫМИ " -ForegroundColor Green -NoNewline
    Write-Host "(60 fps не урежется до 30)" -ForegroundColor DarkGray
    Write-Host "     - Битрейт:     " -ForegroundColor White -NoNewline
    Write-Host "КОПИРУЕТСЯ 1 В 1 " -ForegroundColor Green -NoNewline
    Write-Host "(визуальное качество и вес файла сильно не меняются)" -ForegroundColor DarkGray
    Write-Host "     - Звук:        " -ForegroundColor White -NoNewline
    Write-Host "ВСЕ ДОРОЖКИ " -ForegroundColor Green -NoNewline
    Write-Host "кодируются в AAC, " -ForegroundColor White -NoNewline
    Write-Host "КАНАЛЫ СОХРАНЯЮТСЯ " -ForegroundColor Green -NoNewline
    Write-Host "(5.1 и 7.1 останутся объемными)" -ForegroundColor DarkGray
Write-Host "  [!!] Безопасность и очистка" -ForegroundColor Cyan
    Write-Host "     Создается временный файл. Оригинал удаляется " -ForegroundColor White -NoNewline
    Write-Host "ТОЛЬКО " -ForegroundColor Red -NoNewline
    Write-Host "после успешной проверки." -ForegroundColor White
Write-Host "  [=]  Сохранение прогресса" -ForegroundColor Cyan
    Write-Host "     При нажатии Ctrl+C скрипт аккуратно остановится. Можно продолжить позже." -ForegroundColor White
Write-Host "  [?]  Требования" -ForegroundColor Cyan
    Write-Host "     Скрипту требуется " -ForegroundColor White -NoNewline
    Write-Host "FFmpeg" -ForegroundColor Green -NoNewline
    Write-Host " (full build с NVENC). Если FFmpeg не установлен," -ForegroundColor White
    Write-Host "     скрипт предложит автоматическую установку через winget/choco/scoop." -ForegroundColor White
Write-Host ""

Write-Host "ВЫБЕРИТЕ БАЛАНС СКОРОСТЬ / КАЧЕСТВО:" -ForegroundColor Magenta
Write-Host "  [1] МАКСИМУМ КАЧЕСТВА (NVENC p7 / CPU slow) - Лучшее сжатие, медленнее" -ForegroundColor Green
Write-Host "  [2] БАЛАНС             (NVENC p4 / CPU medium) - Оптимально для большинства" -ForegroundColor Yellow
Write-Host "  [3] МАКСИМУМ СКОРОСТИ  (NVENC p1 / CPU veryfast) - Быстро, файлы чуть больше" -ForegroundColor Red
Write-Host ""

do {
    $choice = Read-Host "Введите 1, 2 или 3 и нажмите ENTER для запуска"
    if ($choice -notmatch '^[1-3]$') {
        Write-Host "[!] Неверный ввод. Пожалуйста, введите цифру 1, 2 или 3." -ForegroundColor Red
    }
} while ($choice -notmatch '^[1-3]$')

Write-Host "`n[OK] Подготовка окружения..." -ForegroundColor Green
Start-Sleep -Milliseconds 500

# 📁 Авто-определение папки
$videoDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$videoDir = [System.IO.Path]::GetFullPath($videoDir).TrimEnd('\')
$logFile  = Join-Path $videoDir "FFmpeg_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$progressFile = Join-Path $videoDir "recode_progress.json"
$fallbackBitrate = "5000k"

# 📦 АВТОПРОВЕРКА И УМНАЯ УСТАНОВКА FFMPEG
$hasFFmpeg = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
$hasFFprobe = [bool](Get-Command ffprobe -ErrorAction SilentlyContinue)

if (-not ($hasFFmpeg -and $hasFFprobe)) {
    Write-Host "`n==========================================================" -ForegroundColor Red
    Write-Host " [!] FFmpeg или ffprobe не найдены в системном PATH" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "`nПОЧЕМУ НУЖЕН FFMPEG:" -ForegroundColor Yellow
    Write-Host "  Для работы скрипта требуется пакет 'ffmpeg' (желательно Full Build с поддержкой NVENC)." -ForegroundColor White
    Write-Host "`nДОСТУПНЫЕ В ВАШЕЙ СИСТЕМЕ СПОСОБЫ УСТАНОВКИ:" -ForegroundColor Yellow
    
    $managers = @{}
    $optNum = 1
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  [$optNum] winget (Встроенный менеджер Windows - Рекомендуется)" -ForegroundColor Cyan
        $managers[$optNum.ToString()] = "winget"
        $optNum++
    }
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "  [$optNum] choco (Chocolatey)" -ForegroundColor Cyan
        $managers[$optNum.ToString()] = "choco"
        $optNum++
    }
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "  [$optNum] scoop" -ForegroundColor Cyan
        $managers[$optNum.ToString()] = "scoop"
        $optNum++
    }
    
    $manualOpt = $optNum.ToString()
    Write-Host "  [$manualOpt] Скачать вручную (откроется сайт Gyan.dev)" -ForegroundColor Cyan
    $optNum++
    
    $exitOpt = $optNum.ToString()
    Write-Host "  [$exitOpt] Выход" -ForegroundColor Cyan
    
    Write-Host ""
    $pattern = "^[1-$exitOpt]$"
    
    do {
        $instChoice = Read-Host "Выберите действие (1-$exitOpt)"
        if ($instChoice -notmatch $pattern) { Write-Host "Неверный ввод." -ForegroundColor Red }
    } while ($instChoice -notmatch $pattern)
    
    if ($instChoice -eq $exitOpt) {
        Write-Host "`n[!] Выход отменен пользователем." -ForegroundColor Yellow
        exit
    } elseif ($instChoice -eq $manualOpt) {
        Write-Host "`n[i] Открываем браузер... Скачайте архив 'ffmpeg-release-full.7z'" -ForegroundColor Yellow
        Start-Process "https://www.gyan.dev/ffmpeg/builds/"
        Write-Host "Распакуйте его и добавьте папку 'bin' в системные переменные среды (PATH)." -ForegroundColor White
        Read-Host "Нажмите Enter для завершения скрипта"
        exit
    } else {
        $selectedMgr = $managers[$instChoice]
        Write-Host "`n[>>] Запуск автоматической установки через $selectedMgr..." -ForegroundColor Magenta
        
        try {
            if ($selectedMgr -eq "winget") {
                Start-Process -FilePath "winget" -ArgumentList "install Gyan.FFmpeg --accept-package-agreements --accept-source-agreements" -Wait -NoNewWindow
            } elseif ($selectedMgr -eq "choco") {
                Start-Process -FilePath "choco" -ArgumentList "install ffmpeg -y" -Wait -NoNewWindow
            } elseif ($selectedMgr -eq "scoop") {
                Start-Process -FilePath "scoop" -ArgumentList "install ffmpeg" -Wait -NoNewWindow
            }
            Write-Host "`n[OK] Установка завершена!" -ForegroundColor Green
            Write-Host "ВАЖНО: ПЕРЕЗАПУСТИТЕ КОНСОЛЬ (POWERSHELL), чтобы система увидела новые переменные PATH!" -ForegroundColor Yellow
        } catch {
            Write-Host "`n[ERR] Ошибка при установке. Возможно требуются права администратора." -ForegroundColor Red
        }
        Read-Host "Нажмите Enter для выхода"
        exit
    }
}

# Безопасное объединение старых логов
try {
    $oldLogs = Get-ChildItem -LiteralPath $videoDir -Filter "FFmpeg_Log_*.txt" -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $logFile }
    if ($oldLogs) {
        Write-Host "[DIR] Найдена старая история логов. Объединяем и чистим..." -ForegroundColor DarkGray
        foreach ($oldLog in $oldLogs) {
            $oldContent = Get-Content -LiteralPath $oldLog.FullName -Raw -ErrorAction SilentlyContinue
            if ($oldContent) {
                Add-Content -LiteralPath $logFile -Value $oldContent -Encoding UTF8 -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $oldLog.FullName -Force -ErrorAction SilentlyContinue
        }
    }
} catch { Write-Host "[WARN] Возникла проблема при чтении старых логов, продолжаем..." -ForegroundColor Yellow }

function Write-Log { param([string]$Message) try { [System.IO.File]::AppendAllText($logFile, "$Message`n", [System.Text.Encoding]::UTF8) } catch {} }

function Read-LockedFile {
    param([string]$FilePath)
    try {
        $fs = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $content = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $content
    } catch { return $null }
}

# Загрузка прогресса (Добавлены накопительные переменные объемов данных)
$progress = @{ version="v39.0"; created=(Get-Date).ToString("o"); last_run=""; stats=@{found=0; skipped=0; success=0; failed=0; total_orig_size=0; total_new_size=0}; files=@{} }
if (Test-Path -LiteralPath $progressFile) {
    try {
        $raw = Get-Content -LiteralPath $progressFile -Raw -Encoding UTF8
        if ($raw -and $raw.Trim() -ne "") {
            $progress = ObjToHash ($raw | ConvertFrom-Json)
        }
    } catch { }
}
$progress["last_run"] = (Get-Date).ToString("o")

# Гарантируем, что переменные объемов инициализированы в истории
if ($null -eq $progress.stats.total_orig_size) { $progress.stats.total_orig_size = 0 }
if ($null -eq $progress.stats.total_new_size) { $progress.stats.total_new_size = 0 }

function Save-Progress { 
    try {
        $tmpJson = $progressFile + ".tmp"
        $progress | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmpJson -Encoding UTF8 -Force
        Move-Item -LiteralPath $tmpJson -Destination $progressFile -Force
    } catch { }
}

# 🚀 АВТООПРЕДЕЛЕНИЕ ДОСТУПНОСТИ NVIDIA NVENC
$nvencAvailable = $false
try {
    $encodersOutput = & ffmpeg -hide_banner -encoders 2>&1 | Out-String
    if ($encodersOutput -match "h264_nvenc") {
        $nvencAvailable = $true
    }
} catch { }

# ⚙️ Настройка кодека и пресетов
if ($nvencAvailable) {
    $videoCodec = "h264_nvenc"
    $presetMap = @{ "1" = "p7"; "2" = "p4"; "3" = "p1" }
    $codecLabel = "NVENC (GPU)"
    $codecColor = "Green"
} else {
    $videoCodec = "libx264"
    $presetMap = @{ "1" = "slow"; "2" = "medium"; "3" = "veryfast" }
    $codecLabel = "libx264 (CPU)"
    $codecColor = "Yellow"
}

$activePreset = $presetMap[$choice]
Write-Log "=== Новый запуск: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Кодек: $videoCodec | Пресет: $activePreset ==="

Write-Host "[INFO] Рабочая папка: $videoDir" -ForegroundColor Cyan
Write-Host "[INFO] Кодер: " -ForegroundColor Cyan -NoNewline
Write-Host $codecLabel -ForegroundColor $codecColor -NoNewline
Write-Host " | Пресет: $activePreset" -ForegroundColor Cyan
Write-Host "[TIP] Нажмите Ctrl+C в любой момент для безопасной паузы.`n" -ForegroundColor DarkYellow

$files = Get-ChildItem -LiteralPath $videoDir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '\.(mp4|mkv|avi|mov|webm|flv|m4v)$' }

if ($files.Count -eq 0) {
    Write-Host "[WARN] Видеофайлы не найдены." -ForegroundColor Yellow
    Read-Host "Нажмите Enter для выхода"
    exit
}

# 🔍 Предварительный анализ с расширенным логированием
$toProcess = 0; $alreadyCompat = 0; $alreadySuccess = 0; $inaccessible = 0
$analyzeIndex = 0
$pendingFilesSize = 0 # Сумма объемов только тех файлов, которые БУДУТ перекодированы в этой сессии

foreach ($f in $files) {
    $analyzeIndex++
    $analyzePct = [math]::Round(($analyzeIndex / $files.Count) * 100)
    $aBar = Get-ProgressBar $analyzePct 30
    
    Write-Progress -Id 0 -Activity "[i] Предварительный анализ файлов (ffprobe)" -Status "$aBar | Чтение: $($f.Name)" -PercentComplete -1
    
    $key = [System.IO.Path]::GetFullPath($f.FullName).TrimEnd('\')
    $status = $progress.files[$key].status
    
    if ($status -eq "success") { $alreadySuccess++; continue }
    if ($status -eq "skipped") { $alreadyCompat++; continue }
    if ($status -eq "error") { $inaccessible++; continue }
    
    if ($f.Attributes -band [System.IO.FileAttributes]::Offline) { 
        $inaccessible++
        $progress.files[$key] = @{ status="error"; reason="offline" }
        continue 
    }
    if ($f.Length -lt 1024) { 
        $inaccessible++
        $progress.files[$key] = @{ status="error"; reason="empty" }
        continue 
    }
    
    $fullPath = [System.IO.Path]::GetFullPath($f.FullName)
    
    # ⚡ Оптимизация: берем полную JSON-выписку с ffprobe за один запуск
    $probeObj = $null
    try {
        $probeOut = & ffprobe -v error -print_format json -show_format -show_streams -select_streams v:0 $fullPath 2>$null
        if ($probeOut) {
            $jsonText = $probeOut -join "`n"
            $probeObj = $jsonText | ConvertFrom-Json
        }
    } catch { }
    
    if ($null -eq $probeObj -or -not $probeObj.streams -or $probeObj.streams.Count -eq 0) { 
        $inaccessible++
        $progress.files[$key] = @{ status="error"; reason="probe_failed" }
        continue 
    }
    
    $codec = $probeObj.streams[0].codec_name
    $pixFmt = $probeObj.streams[0].pix_fmt
    $width = $probeObj.streams[0].width
    $height = $probeObj.streams[0].height
    $duration = $probeObj.format.duration
    
    $bitrate = $probeObj.format.bit_rate
    if (-not $bitrate) { $bitrate = $probeObj.streams[0].bit_rate }
    
    $totalSec = if ($duration -match "^\d+\.?\d*$") { [double]$duration } else { 0 }
    
    # Расчет битрейта "математически", если метаданные пусты
    if (($null -eq $bitrate -or $bitrate -notmatch "^\d+") -and $totalSec -gt 0) {
        $calculatedBR = ($f.Length * 8) / $totalSec
        $bitrate = [math]::Round($calculatedBR)
    }
    if (-not $bitrate) { $bitrate = 0 }
    
    $resInfo = if ($width -and $height) { "${width}x${height}" } else { "Неизвестно" }
    $codecInfo = "$codec, $pixFmt, $resInfo"
    
    if ($f.Extension -eq ".mp4" -and $codec -match "h264|avc1" -and $pixFmt -match "yuv420p") { 
        $alreadyCompat++
        $progress.files[$key] = @{ status="skipped"; reason="compatible"; updated=(Get-Date).ToString("o") }
    } else { 
        $toProcess++
        # Сохраняем все вычисленные данные в кэш
        $progress.files[$key] = @{ 
            status    = "pending"
            codecInfo = $codecInfo
            bitrate   = $bitrate
            duration  = $totalSec
            width     = $width
            height    = $height
            sizeBytes = $f.Length
        }
        $pendingFilesSize += $f.Length
        
        # 📝 Расширенное логирование SCAN
        $sizeMB = [math]::Round($f.Length / 1MB, 2)
        $brKbps = [math]::Round($bitrate / 1000)
        Write-Log "$(Get-Date -Format 'HH:mm:ss') | SCAN | File: $($f.Name) | Size: $sizeMB MB | Codec: $codec | Res: $resInfo | BR: ${brKbps}k"
    }
}
Write-Progress -Id 0 -Activity "Анализ завершен" -Completed

$pendingFilesSizeMB = [math]::Round($pendingFilesSize / 1MB, 2)
$progress.stats.found = $files.Count; $progress.stats.skipped = $alreadyCompat; $progress.stats.success = $alreadySuccess
Save-Progress

Write-Log "=== Предварительный итог: Всего: $($files.Count) | Будет перекодировано: $toProcess ($pendingFilesSizeMB MB) ==="

Write-Host "==========================================================" -ForegroundColor DarkGray
Write-Host " [FILES] НАЙДЕНО ФАЙЛОВ:        $($files.Count)" -ForegroundColor Cyan
Write-Host " [OK]    УЖЕ СОВМЕСТИМО:         $alreadyCompat" -ForegroundColor DarkGreen
Write-Host " [DONE]  РАНЕЕ ОБРАБОТАНО:       $alreadySuccess" -ForegroundColor Green
Write-Host " [!]     НЕДОСТУПНО/ПУСТО:       $inaccessible" -ForegroundColor Yellow
Write-Host " [PROC]  БУДЕТ ПЕРЕКОНВЕРТИР.:   $toProcess ($pendingFilesSizeMB MB)" -ForegroundColor Magenta
Write-Host " [CODEC] КОДЕР / ПРЕСЕТ:         $codecLabel / $activePreset" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor DarkGray
Write-Host ""

if ($toProcess -eq 0) {
    Write-Host "[INFO] Нечего конвертировать. Всё уже готово." -ForegroundColor Yellow
    Read-Host "Нажмите Enter для выхода..."
    exit
}

$proc = $null
$currentFile = 0

foreach ($file in $files) {
    $currentFile++
    
    $overallPct = if ($files.Count -gt 0) { [math]::Min([math]::Round(($currentFile / $files.Count) * 100), 100) } else { 0 }
    $qBar = Get-ProgressBar $overallPct 40
    
    Write-Progress -Id 0 -Activity "Общая очередь: Файл $currentFile из $($files.Count)" `
                   -Status "$qBar | Текущий: $($file.Name)" `
                   -PercentComplete -1

    $inputFile = [System.IO.Path]::GetFullPath($file.FullName)
    $key = $inputFile.TrimEnd('\')
    
    $status = $progress.files[$key].status
    if ($status -in @("success","skipped","error")) { continue }

    # ⚡ Берем все параметры из кэша. Ни одного ffprobe в основном цикле!
    $fileData = $progress.files[$key]
    $codecInfo = $fileData.codecInfo
    $targetBitrateVal = $fileData.bitrate
    $totalSec = $fileData.duration
    $width = $fileData.width
    $height = $fileData.height
    $origSizeBytes = $fileData.sizeBytes

    $targetBitrate = if ($targetBitrateVal -gt 0) { "$([math]::Round($targetBitrateVal / 1000))k" } else { $fallbackBitrate }

    $progress.files[$key].status = "processing"
    $progress.files[$key].started = (Get-Date).ToString("o")
    Save-Progress

    $dir       = $file.DirectoryName
    $tmpOut    = Join-Path $dir "$($file.BaseName)_tmp.mp4"
    $ffmpegErr = Join-Path $env:TEMP "fferr_$([System.Guid]::NewGuid().ToString().Substring(0,8)).log"
    $ffProgFile= Join-Path $env:TEMP "ffprog_$([System.Guid]::NewGuid().ToString().Substring(0,8)).txt"

    $safeCurrentInput = $inputFile -replace '"', '\"'
    $safeTmpOut = $tmpOut -replace '"', '\"'
    $safeProgFile = $ffProgFile -replace '"', '\"'

    $isSuccess = $false
    $usedFallback = $false
    
    Write-Host "-----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " [PROC] ФАЙЛ: $($file.Name)" -ForegroundColor Cyan
    Write-Host "   -> Причина перекодировки: Исходник = [$codecInfo], Формат = [$($file.Extension)]" -ForegroundColor Yellow
    Write-Host "   -> Попытка 1: $codecLabel -> Битрейт: $targetBitrate | Пресет: $activePreset" -ForegroundColor Green

    if ($nvencAvailable) {
        $ffmpegArgsStr = "-i `"$safeCurrentInput`" -map 0:v:0 -map 0:a? -c:v h264_nvenc -profile:v high -preset $activePreset -tune hq -rc:v vbr -b:v $targetBitrate -maxrate $targetBitrate -pix_fmt yuv420p -c:a aac -err_detect ignore_err -fflags +discardcorrupt -movflags +faststart -progress `"$safeProgFile`" -y `"$safeTmpOut`""
    } else {
        $ffmpegArgsStr = "-i `"$safeCurrentInput`" -map 0:v:0 -map 0:a? -c:v libx264 -profile:v high -preset $activePreset -threads 0 -b:v $targetBitrate -maxrate $targetBitrate -bufsize 2M -pix_fmt yuv420p -c:a aac -err_detect ignore_err -fflags +discardcorrupt -movflags +faststart -progress `"$safeProgFile`" -y `"$safeTmpOut`""
    }

    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgsStr -NoNewWindow -PassThru -RedirectStandardError $ffmpegErr

    while (!$proc.HasExited) {
        try {
            if (Test-Path -LiteralPath $ffProgFile) {
                $pContent = Read-LockedFile -FilePath $ffProgFile
                if ($pContent) {
                    $timeMatches = [regex]::Matches($pContent, "out_time=(\d{2}):(\d{2}):(\d{2})")
                    $speedMatches = [regex]::Matches($pContent, "speed=\s*([\d.]+)x")

                    if ($timeMatches.Count -gt 0) {
                        $lastTime = $timeMatches[$timeMatches.Count - 1].Groups
                        $curSec = [int]$lastTime[1].Value*3600 + [int]$lastTime[2].Value*60 + [int]$lastTime[3].Value
                        $speed = if ($speedMatches.Count -gt 0) { "$($speedMatches[$speedMatches.Count - 1].Groups[1].Value)x" } else { "?" }
                        
                        if ($totalSec -gt 0) {
                            $filePct = [math]::Min([math]::Round(($curSec / $totalSec) * 100), 100)
                            $fBar = Get-ProgressBar $filePct 40
                            Write-Progress -Id 1 -Activity "Энкодер: $codecLabel (Попытка 1)" -Status "$fBar | Скорость: $speed | Время: $curSec из $([math]::Round($totalSec)) сек" -PercentComplete -1
                        } else {
                            Write-Progress -Id 1 -Activity "Энкодер: $codecLabel (Попытка 1)" -Status "[████████████████████████████████████████] ???% | Скорость: $speed | Обработано: $curSec сек" -PercentComplete -1
                        }
                    }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    
    Write-Progress -Id 1 -Activity "Сборка файла" -Status "Финализация (Faststart / перенос метаданных). Пожалуйста, подождите..." -PercentComplete -1
    
    $proc.WaitForExit()
    $proc.Refresh()
    
    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode) { $exitCode = -1 }
    Write-Progress -Id 1 -Activity "Завершение файла..." -Completed

    if (Test-Path -LiteralPath $tmpOut) {
        $fileSize = (Get-Item -LiteralPath $tmpOut).Length
        if ($fileSize -gt 1024) {
            if ($exitCode -eq 0) {
                $isSuccess = $true
            } else {
                Write-Host "   [INFO] Выполняется финальная проверка целостности..." -ForegroundColor DarkGray
                Write-Progress -Id 1 -Activity "Верификация" -Status "Глубокая проверка целостности..." -PercentComplete -1
                $verifyNew = $null
                try {
                    $verifyNew = & ffprobe -v error -analyzeduration 10M -probesize 10M -show_entries format=duration -of csv=p=0 $tmpOut 2>$null
                } catch {}
                $newDur = if ($verifyNew -match "^\d+\.?\d*$") { [double]$verifyNew } else { 0 }
                
                Write-Progress -Id 1 -Activity "Верификация" -Completed
                
                if ($newDur -gt 0 -and ([math]::Abs($totalSec - $newDur) -lt 30 -or $totalSec -eq 0)) {
                    $isSuccess = $true
                    Write-Host "   [OK] Проверка пройдена успешно." -ForegroundColor Green
                } else {
                    Write-Host "   [ERR] Файл поврежден: оригинал=$([math]::Round($totalSec)) сек, результат=$([math]::Round($newDur)) сек" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "   [ERR] Файл слишком мал: $fileSize байт" -ForegroundColor Red
        }
    } else {
        Write-Host "   [ERR] Выходной файл не создан" -ForegroundColor Red
    }

    if (-not $isSuccess) {
        $cpuFallbackPreset = if($choice -eq '1'){"slow"}elseif($choice -eq '2'){"medium"}else{"veryfast"}
        
        Write-Host "   [>>] Запуск восстановительного кодирования (CPU: libx264, Пресет: $cpuFallbackPreset)..." -ForegroundColor Magenta
        Write-Log "$(Get-Date -Format 'HH:mm:ss') | FALLBACK TRIGGERED | $inputFile"
        $usedFallback = $true
        
        if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
        
        $ffmpegArgsStr = "-threads 0 -hwaccel none -ignore_unknown -i `"$safeCurrentInput`" -map 0:v:0 -map 0:a? -c:v libx264 -profile:v high -preset $cpuFallbackPreset -b:v $targetBitrate -maxrate $targetBitrate -bufsize 2M -pix_fmt yuv420p -c:a aac -err_detect ignore_err -fflags +discardcorrupt -max_muxing_queue_size 9999 -movflags +faststart -progress `"$safeProgFile`" -y `"$safeTmpOut`""

        $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgsStr -NoNewWindow -PassThru -RedirectStandardError $ffmpegErr

        while (!$proc.HasExited) {
            try {
                if (Test-Path -LiteralPath $ffProgFile) {
                    $pContent = Read-LockedFile -FilePath $ffProgFile
                    if ($pContent) {
                        $timeMatches = [regex]::Matches($pContent, "out_time=(\d{2}):(\d{2}):(\d{2})")
                        $speedMatches = [regex]::Matches($pContent, "speed=\s*([\d.]+)x")

                        if ($timeMatches.Count -gt 0) {
                            $lastTime = $timeMatches[$timeMatches.Count - 1].Groups
                            $curSec = [int]$lastTime[1].Value*3600 + [int]$lastTime[2].Value*60 + [int]$lastTime[3].Value
                            $speed = if ($speedMatches.Count -gt 0) { "$($speedMatches[$speedMatches.Count - 1].Groups[1].Value)x" } else { "?" }
                            
                            if ($totalSec -gt 0) {
                                $filePct = [math]::Min([math]::Round(($curSec / $totalSec) * 100), 100)
                                $fBar = Get-ProgressBar $filePct 40
                                Write-Progress -Id 1 -Activity "Энкодер: libx264 (FALLBACK)" -Status "$fBar | Скорость: $speed | Время: $curSec из $([math]::Round($totalSec)) сек" -PercentComplete -1
                            } else {
                                Write-Progress -Id 1 -Activity "Энкодер: libx264 (FALLBACK)" -Status "[████████████████████████████████████████] ???% | Скорость: $speed | Обработано: $curSec сек" -PercentComplete -1
                            }
                        }
                    }
                }
            } catch { }
            Start-Sleep -Milliseconds 500
        }
        
        Write-Progress -Id 1 -Activity "Сборка файла" -Status "Финализация (Faststart / перенос метаданных). Пожалуйста, подождите..." -PercentComplete -1
        $proc.WaitForExit()
        $proc.Refresh()
        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) { $exitCode = -1 }
        Write-Progress -Id 1 -Activity "Завершение файла..." -Completed

        if (Test-Path -LiteralPath $tmpOut) {
            $fileSize = (Get-Item -LiteralPath $tmpOut).Length
            if ($fileSize -gt 1024) {
                if ($exitCode -eq 0) {
                    $isSuccess = $true
                } else {
                    Write-Host "   [INFO] Выполняется финальная проверка целостности..." -ForegroundColor DarkGray
                    Write-Progress -Id 1 -Activity "Верификация" -Status "Глубокая проверка целостности..." -PercentComplete -1
                    $verifyNew = $null
                    try {
                        $verifyNew = & ffprobe -v error -analyzeduration 10M -probesize 10M -show_entries format=duration -of csv=p=0 $tmpOut 2>$null
                    } catch {}
                    $newDur = if ($verifyNew -match "^\d+\.?\d*$") { [double]$verifyNew } else { 0 }
                    
                    Write-Progress -Id 1 -Activity "Верификация" -Completed
                    
                    if ($newDur -gt 0 -and ([math]::Abs($totalSec - $newDur) -lt 30 -or $totalSec -eq 0)) {
                        $isSuccess = $true
                        Write-Host "   [OK] Проверка пройдена успешно (CPU Fallback)." -ForegroundColor Green
                    } else {
                        Write-Host "   [ERR] Файл поврежден: оригинал=$([math]::Round($totalSec)) сек, результат=$([math]::Round($newDur)) сек" -ForegroundColor Red
                    }
                }
            } else {
                Write-Host "   [ERR] Файл слишком мал: $fileSize байт" -ForegroundColor Red
            }
        } else {
            Write-Host "   [ERR] Выходной файл не создан после fallback" -ForegroundColor Red
        }
    }

    if ($isSuccess) {
        $replaced = $false
        $retryRename = 0
        
        while (-not $replaced -and $retryRename -lt 5) {
            try {
                if (Test-Path -LiteralPath $inputFile) {
                    Remove-Item -LiteralPath $inputFile -Force -ErrorAction Stop
                }
                if (Test-Path -LiteralPath $tmpOut) {
                    Rename-Item -LiteralPath $tmpOut -NewName "$($file.BaseName).mp4" -Force -ErrorAction Stop
                }
                $replaced = $true
            } catch {
                Start-Sleep -Milliseconds 1500
                $retryRename++
            }
        }

        if ($replaced) {
            $statusMsg = if ($usedFallback) { "[OK] ГОТОВО! (CPU Fallback) Оригинал удален." } else { "[OK] ГОТОВО! Оригинал удален." }
            Write-Host "   $statusMsg" -ForegroundColor DarkGreen
            
            $finalCodec = if ($usedFallback) { "libx264" } else { $videoCodec }
            
            $newFullName = Join-Path $file.DirectoryName "$($file.BaseName).mp4"
            $newKey = [System.IO.Path]::GetFullPath($newFullName).TrimEnd('\')
            
            # Получаем размер нового созданного файла
            $newSizeBytes = (Get-Item -LiteralPath $newFullName).Length
            $newSizeMB = [math]::Round($newSizeBytes / 1MB, 2)
            $origSizeMB = [math]::Round($origSizeBytes / 1MB, 2)
            $resInfo = if ($width -and $height) { "${width}x${height}" } else { "Неизвестно" }

            $progress.files[$newKey] = @{ status="success"; codec=$finalCodec; bitrate=$targetBitrate; fallback=$usedFallback; updated=(Get-Date).ToString("o") }
            if ($newKey -ne $key) {
                $progress.files.Remove($key)
            }
            
            # 💾 Накапливаем статистику размеров файлов (даже при обрывах и продолжениях)
            $progress.stats.total_orig_size += $origSizeBytes
            $progress.stats.total_new_size += $newSizeBytes
            
            $progress.stats.success++; Save-Progress
            
            # 📝 Расширенное логирование SUCCESS
            Write-Log "$(Get-Date -Format 'HH:mm:ss') | SUCCESS | NewFile: $($file.BaseName).mp4 | Codec: $finalCodec | Res: $resInfo | Size: $newSizeMB MB (Original: $origSizeMB MB)"
        } else {
            Write-Host "   [!] Ошибка замены: Сетевой диск заблокировал файл. Попробуйте перезапустить скрипт позже." -ForegroundColor Red
            $progress.files[$key] = @{ status="failed"; error="network_lock"; updated=(Get-Date).ToString("o") }
            $progress.stats.failed++; Save-Progress
            Write-Log "$(Get-Date -Format 'HH:mm:ss') | FAILED | $inputFile | ERROR: Network Drive Lock"
        }
    } else {
        Write-Host "   [ERR] ОШИБКА кодирования (Сбой после двух попыток)" -ForegroundColor Red
        $errTxt = if (Test-Path -LiteralPath $ffmpegErr) { (Get-Content -LiteralPath $ffmpegErr -Raw).Trim() } else { "Нет лога" }
        $shortErr = ($errTxt -split "`n" | Select-Object -Last 2) -join " | "
        $fileSizeInfo = if (Test-Path -LiteralPath $tmpOut) { " | Size: $((Get-Item -LiteralPath $tmpOut).Length)" } else { "" }
        $progress.files[$key] = @{ status="failed"; error=$shortErr; updated=(Get-Date).ToString("o") }
        $progress.stats.failed++; Save-Progress
        Write-Log "$(Get-Date -Format 'HH:mm:ss') | FAILED | $inputFile | ExitCode: $exitCode$fileSizeInfo | ERROR: $shortErr"
        if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path -LiteralPath $ffmpegErr) { Remove-Item -LiteralPath $ffmpegErr -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $ffProgFile) { Remove-Item -LiteralPath $ffProgFile -Force -ErrorAction SilentlyContinue }
}

} catch {
    Write-Host "`n[ERR] ВЫПОЛНЕНИЕ ПРЕРВАНО ИЛИ ПРОИЗОШЛА ОШИБКА:" -ForegroundColor Red
    Write-Host $($_.Exception.Message) -ForegroundColor White
} finally {
    
    if ($null -ne $proc -and -not $proc.HasExited) {
        Write-Host "`n[>>] Принудительная остановка фонового кодировщика (ffmpeg)..." -ForegroundColor Yellow
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        try { $proc.WaitForExit(3000) } catch { } 
    }

    Start-Sleep -Seconds 1 
    Save-Progress
    
    Write-Host "`n[DEL] Поиск и удаление мусора..." -ForegroundColor Yellow
    Get-ChildItem -LiteralPath $env:TEMP -Filter "fferr_*" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $env:TEMP -Filter "ffprog_*" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    
    $tmpFiles = Get-ChildItem -LiteralPath $videoDir -Recurse -Filter "*_tmp.mp4" -File -ErrorAction SilentlyContinue
    foreach ($f in $tmpFiles) {
        $retry = 0
        while ((Test-Path -LiteralPath $f.FullName) -and $retry -lt 5) {
            try { 
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                Write-Host "   [DEL] Удален недоделанный файл: $($f.Name)" -ForegroundColor DarkGray
                break 
            } catch { 
                Start-Sleep -Milliseconds 500
                $retry++ 
            }
        }
    }
    
    Write-Progress -Id 0 -Activity "Завершение" -Completed
    Write-Progress -Id 1 -Activity "Завершение" -Completed
    
    Write-Host "`n==========================================================" -ForegroundColor DarkGray
    Write-Host " [SUM] ИТОГ: Успешно: $($progress.stats.success) | Пропущено: $($progress.stats.skipped) | Ошибки: $($progress.stats.failed)" -ForegroundColor Cyan
    
    # 💾 Анализ и расчёт итоговой экономии / увеличения размера (С кумулятивной поддержкой резюмирования)
    $origTotal = $progress.stats.total_orig_size
    $newTotal = $progress.stats.total_new_size
    
    if ($origTotal -gt 0) {
        $diff = $origTotal - $newTotal
        $diffPct = [math]::Round(($diff / $origTotal) * 100, 1)
        
        $origTotalMB = [math]::Round($origTotal / 1MB, 2)
        $newTotalMB = [math]::Round($newTotal / 1MB, 2)
        $diffMB = [math]::Round($diff / 1MB, 2)
        
        $origStr = if ($origTotalMB -gt 1024) { "$([math]::Round($origTotalMB / 1024, 2)) GB" } else { "$origTotalMB MB" }
        $newStr = if ($newTotalMB -gt 1024) { "$([math]::Round($newTotalMB / 1024, 2)) GB" } else { "$newTotalMB MB" }
        $diffStr = if ([math]::Abs($diffMB) -gt 1024) { "$([math]::Round([math]::Abs($diffMB) / 1024, 2)) GB" } else { "$([math]::Round([math]::Abs($diffMB), 2)) MB" }
        
        Write-Host " [STATS] Исходный  объем файлов:  $origStr" -ForegroundColor Cyan
        Write-Host " [STATS] Новый объем кодированных:   $newStr" -ForegroundColor Cyan
        
        if ($diff -ge 0) {
            Write-Host " [STATS] Сжатие (Экономия места):      $diffStr ($diffPct%)" -ForegroundColor Green
            Write-Log "$(Get-Date -Format 'HH:mm:ss') | TOTAL STATS | Orig: $origStr | New: $newStr | Saved: $diffStr ($diffPct%)"
        } else {
            $absDiffPct = [math]::Abs($diffPct)
            Write-Host " [STATS] Увеличение объема:            $diffStr (+$absDiffPct%)" -ForegroundColor Yellow
            Write-Log "$(Get-Date -Format 'HH:mm:ss') | TOTAL STATS | Orig: $origStr | New: $newStr | Increased: $diffStr (+$absDiffPct%)"
        }
    }
    
    Write-Host " [LOG] Лог: $logFile" -ForegroundColor Yellow
    Write-Host " [PROG] Прогресс: $progressFile" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor DarkGray
    
    Write-Host "`n[=] Нажмите Enter для выхода..." -ForegroundColor Cyan
    try { Read-Host } catch { cmd /c pause >nul }
}