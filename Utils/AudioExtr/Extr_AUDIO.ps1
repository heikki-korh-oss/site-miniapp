# Устанавливаем правильную кодировку для отображения текста
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Обширный список расширений видеофайлов
$videoExtensions = @(
    '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.mpg', '.mpeg', 
    '.m4v', '.webm', '.vob', '.ogv', '.3gp', '.ts'
)

Write-Host "Сканирование папки..." -ForegroundColor Cyan

# Ищем видеофайлы в текущей папке
$videoFiles = Get-ChildItem -File | Where-Object { $videoExtensions -contains $_.Extension.ToLower() }

# Проверка, найдены ли файлы
if ($videoFiles.Count -eq 0) {
    Write-Host "Видеофайлы не найдены!" -ForegroundColor Red
    Pause
    exit
}

# Вывод количества найденных файлов
Write-Host "==============================================="
Write-Host " Найдено видеофайлов: " -NoNewline
Write-Host $($videoFiles.Count) -ForegroundColor Green
Write-Host "==============================================="

# Настройки для разных аудиоформатов
$formats = @(
    [pscustomobject]@{ Num=1; Ext="mp3";  Desc="MP3  (Универсальный, высокое качество VBR)"; Args="-c:a libmp3lame -q:a 2" }
    [pscustomobject]@{ Num=2; Ext="wav";  Desc="WAV  (Без сжатия, максимальное качество)"; Args="-c:a pcm_s16le" }
    [pscustomobject]@{ Num=3; Ext="flac"; Desc="FLAC (Сжатие без потерь, аудиофильский)"; Args="-c:a flac" }
    [pscustomobject]@{ Num=4; Ext="aac";  Desc="AAC  (Хорошее сжатие, 192 kbps)"; Args="-c:a aac -b:a 192k" }
    [pscustomobject]@{ Num=5; Ext="m4a";  Desc="M4A  (Формат Apple AAC, 192 kbps)"; Args="-c:a aac -b:a 192k" }
    [pscustomobject]@{ Num=6; Ext="ogg";  Desc="OGG  (Vorbis, отличное качество)"; Args="-c:a libvorbis -q:a 5" }
)

Write-Host "`nВыберите формат для извлечения звука:" -ForegroundColor Yellow
foreach ($f in $formats) {
    Write-Host " [$($f.Num)] $($f.Desc)"
}

# Цикл проверки ввода (пока не будет введена правильная цифра)
$selectedFormat = $null
while ($null -eq $selectedFormat) {
    $choice = Read-Host "`nВведите цифру от 1 до $($formats.Count)"
    $selectedFormat = $formats | Where-Object { $_.Num -eq $choice }
    
    if ($null -eq $selectedFormat) {
        Write-Host "Неверный выбор. Пожалуйста, введите цифру из списка." -ForegroundColor Red
    }
}

# Создаем папку в зависимости от выбранного формата (например, Audio_MP3)
$outDir = "Audio_$($selectedFormat.Ext.ToUpper())"
if (-not (Test-Path -Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

Write-Host "`nНачинаем извлечение в формат $($selectedFormat.Ext.ToUpper())..." -ForegroundColor Cyan
Write-Host "==============================================="

$counter = 1
foreach ($file in $videoFiles) {
    Write-Host "[$counter/$($videoFiles.Count)] Обработка: " -NoNewline
    Write-Host $file.Name -ForegroundColor White
    
    $outputFile = Join-Path -Path $outDir -ChildPath "$($file.BaseName).$($selectedFormat.Ext)"
    
    # Разбиваем строку аргументов ffmpeg на массив для корректной передачи в PowerShell
    $ffmpegArgs = @("-hide_banner", "-loglevel", "error", "-i", $file.FullName, "-vn")
    $ffmpegArgs += $selectedFormat.Args.Split(' ')
    $ffmpegArgs += @($outputFile, "-y")
    
    # Запуск ffmpeg
    & ffmpeg @ffmpegArgs
    
    $counter++
}

Write-Host "==============================================="
Write-Host "Готово! Аудиофайлы сохранены в папке '$outDir'." -ForegroundColor Green
Pause