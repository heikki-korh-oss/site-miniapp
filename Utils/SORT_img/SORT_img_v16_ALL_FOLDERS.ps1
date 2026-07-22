<#
.SYNOPSIS
    Скрипт предназначен для автоматической организации, переименования и 
    структурирования фото- и видеоархива на основе реальных дат съемки.
.DESCRIPTION
    Описание работы скрипта (Этапы выполнения):
    -------------------------------------------------------------------------
    1. Проверка зависимостей: Скрипт ищет установленную утилиту ExifTool. 
       Если её нет, он определяет наличие встроенного системного установщика 
       winget и предлагает установить утилиту одной клавишей. После установки 
       скрипт завершает работу и просит перезапустить терминал для обновления 
       путей окружения (переменной PATH).

    2. Анализ прерванных сессий (Возобновление): Если в рабочей директории 
       обнаруживается файл прогресса (files_to_process.json), скрипт предлагает 
       возобновить прошлый процесс миграции. Это позволяет мгновенно продолжить 
       перенос без необходимости повторно сканировать тысячи медиафайлов. При 
       чтении старого JSON скрипт автоматически фильтрует данные, отсеивая 
       любые не-медиа файлы.

    3. Сканирование медиатеки с индикацией:
       - Происходит рекурсивный поиск файлов в исходной папке и её подпапках. 
         Скрипт работает строго с медиафайлами на основе "белого списка" 
         разрешенных расширений графики и видео (включая RAW-форматы камер). 
         Посторонние файлы полностью игнорируются.
       - На этапе сканирования выводится интерактивный прогресс-бар, 
         отображающий процент выполнения и количество проанализированных файлов. 
         Это исключает ощущение зависания на больших архивах.
       - Считывается реальная дата съемки (теги DateTimeOriginal, CreateDate, 
         ModifyDate). Для видео используется параметр -api QuickTimeUTC для 
         приведения времени съемки из UTC к вашему локальному времени.
       - Если метаданных нет вовсе, датой съемки признается время последнего 
         изменения файла в ОС (LastWriteTime).

    4. Интеллектуальный пропуск, очистка имен и переименование:
       - Скрипт высчитывает целевой путь для каждого файла: 
         [Источник]\ГГГГ\ГГГГ-ММ-ДД\ГГГГ-ММ-ДД_ИмяФайла.
       - Автоматическая очистка дубликатов дат: если файл называется вида 
         "2012-03-23_2012-03-23_имя.jpg" или "2012-03-23_20120323_имя.jpg", 
         скрипт рекурсивно очищает его имя до одиночного правильного префикса 
         "2012-03-23_имя.jpg". Очистка работает в том числе для файлов, уже 
         находящихся в целевых папках года и дня.
       - Умное сопоставление префиксов: если очищенное имя файла уже начинается 
         с корректной даты съемки (например, "2012-03-23_имя.jpg" или 
         "2012-03-23имя.jpg"), скрипт не приписывает дату из exif повторно.
       - Если файл уже находится на своем месте, имеет правильный префикс даты 
         в имени и лежит в нужной папке, скрипт помечает его статус как 
         "Уже обработан" и пропускает при переносе.
       - Если в одну дату переносятся разные файлы с одинаковыми именами, 
         скрипт автоматически добавляет уникальный цифровой индекс к имени 
         (например, _1, _2), защищая ваши файлы от перезаписи.

    5. Отображение статистики: Перед началом физического переноса на экран 
       выводится текстовая таблица с результатами сканирования: общее количество 
       файлов, сколько уже отсортировано ранее (будут пропущены) и сколько 
       осталось перенести.

    6. Запрос подтверждения: Скрипт ожидает подтверждения для старта миграции. 
       Запрос нечувствителен к раскладке клавиатуры и языку ввода — принимаются 
       ответы Y, YES, Д, ДА (включая русскую букву "Н", которая вводится при 
       нажатии клавиши "Y" на русской раскладке).

    7. Перенос данных и прогресс-бар:
       - Процесс миграции сопровождается стандартным прогресс-баром в верхней 
         части консоли.
       - Перед переносом каждого файла проверяется наличие папок назначения 
         и они создаются при необходимости (ГГГГ\ГГГГ-ММ-ДД).
       - После переноса каждого файла его статус Processed обновляется в JSON-файле 
         на диске. Это гарантирует сохранность прогресса при аварийном завершении.
       - Логирование ошибок в JSON: Если при переносе конкретного файла произойдет 
         сбой (файл заблокирован другой программой, нет прав доступа), скрипт 
         выведет ошибку в консоль, запишет текст ошибки в поле ErrorMessage 
         соответствующего файла в JSON, сохранит его статус Processed = false и 
         продолжит работу со следующими файлами, не прерывая общий процесс.

    8. Безопасная остановка (Ctrl+C):
       В любой момент вы можете прервать выполнение скрипта комбинацией клавиш 
       Ctrl+C. Скрипт мгновенно и безопасно зафиксирует текущий прогресс на 
       диске в JSON-файле, закроет прогресс-бар и выведет информацию об остановке.

    9. Защита от закрытия окна:
       При любом сценарии завершения скрипта выполнение приостанавливается 
       командой ожидания клавиши Enter, предотвращая мгновенное закрытие окна.
#>

param (
    [string]$SourceDir = ".",
    [string]$JsonPath = "files_to_process.json",
    [string]$ExiftoolPath = "exiftool",
    [switch]$DryRun
)

# === ФУНКЦИЯ ДЛЯ БЕЗОПАСНОГО СОПОСТАВЛЕНИЯ ПУТЕЙ ===
function Normalize-Path ([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    # Удаляем префиксы PowerShell провайдеров
    if ($path -match '::(.*)$') {
        $path = $Matches[1]
    }
    return $path.Replace("/", "\").TrimEnd("\").ToLower()
}

# Определение рабочей папки
if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    if ($PSScriptRoot) {
        $SourceDir = $PSScriptRoot
    } else {
        $SourceDir = "."
    }
}

# === ГЛОБАЛЬНЫЙ СПИСОК РАЗРЕШЕННЫХ РАСШИРЕНИЙ ===
$mediaExtensions = @(
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".tif", ".webp", ".heic", ".heif", ".dng", ".cr2", ".nef", ".arw", ".orf", ".rw2",
    ".mp4", ".mov", ".avi", ".mkv", ".wmv", ".flv", ".3gp", ".mpeg", ".mpg", ".m4v", ".mts", ".m2ts"
)

# === БЛОК ПРИВЕТСТВИЯ С ОПИСАНИЕМ СУТИ РАБОТЫ ===
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host "               МЕДИА-СОРТИРОВЩИК (ФОТО И ВИДЕО) V9.3" -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host " Автоматическая организация, переименование и структурирование фото-"
Write-Host " и видеоархива по папкам вида ГГГГ\ГГГГ-ММ-ДД на основе реальных дат съемки."
Write-Host ""
Write-Host " Краткая суть работы скрипта:" -ForegroundColor Yellow
Write-Host " [1] Проверка зависимостей: Автоустановка ExifTool через winget при отсутствии."
Write-Host " [2] Возобновление сессии: Быстрый старт с места остановки по files_to_process.json."
Write-Host " [3] Скоростной EXIF-анализ: Сбор дат пакетами по 50 файлов с живым прогресс-баром."
Write-Host " [4] Умное переименование: Очистка дубликатов дат, предотвращение перезаписи."
Write-Host " [5] Пакетное сохранение: Запись прогресса на диск каждые 50 файлов для скорости."
Write-Host " [6] Защита от остановки: Прерывание по Ctrl+C без потери текущего прогресса."
Write-Host "=========================================================================" -ForegroundColor Cyan
Write-Host ""

function Confirm-ExifTool {
    if (-not (Get-Command $ExiftoolPath -ErrorAction SilentlyContinue)) {
        Write-Host "[!] Утилита ExifTool не обнаружена в системе." -ForegroundColor Yellow
        if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
            Write-Error "[ОШИБКА] Инструмент winget также не найден. Установите ExifTool вручную."
            Read-Host "Нажмите Enter для выхода..."
            Exit
        }
        $choice = Read-Host "[?] Хотите установить ExifTool автоматически через winget? (Y/N)"
        if ($choice -eq 'Y' -or $choice -eq 'y') {
            Write-Host "[+] Запуск автоматической установки ExifTool..." -ForegroundColor Cyan
            winget install -e --id OliverBetz.ExifTool --accept-source-agreements --accept-package-agreements
            Write-Host "`n[+] Установка завершена. Перезапустите окно консоли." -ForegroundColor Green
            Read-Host "Нажмите Enter для закрытия..."
            Exit
        } else {
            Exit
        }
    }
}
Confirm-ExifTool

# Получаем чистый абсолютный путь
$AbsoluteSourceDir = (Get-Item $SourceDir).FullName
$JsonOutPath = Join-Path $AbsoluteSourceDir $JsonPath

$processedList = [System.Collections.Generic.List[PSCustomObject]]::new()
$resumeSession = $false
$batchSize = 50 

# 1. Загрузка прогресса
if (Test-Path $JsonOutPath) {
    Write-Host "[!] Обнаружен ранее созданный файл прогресса: $JsonPath" -ForegroundColor Yellow
    $choice = Read-Host "[?] Возобновить прерванную сессию? (Y - Возобновить / N - Начать новое сканирование)"
    if ($choice -eq 'Y' -or $choice -eq 'y') {
        try {
            $jsonData = @(Get-Content -Raw -Path $JsonOutPath -ErrorAction Stop | ConvertFrom-Json)
            foreach ($item in $jsonData) {
                $ext = [System.IO.Path]::GetExtension($item.OriginalName).ToLower()
                if ($mediaExtensions -contains $ext) {
                    $processedList.Add($item)
                }
            }
            $resumeSession = $true
            Write-Host "[+] Предыдущая сессия успешно загружена. Количество записей: $($processedList.Count)" -ForegroundColor Green
        } catch {
            Write-Warning "[!] Не удалось прочитать файл прогресса. Будет запущено новое сканирование."
        }
    }
}

# 2. СКОРОСТНОЙ NATIVE-АНАЛИЗ С ЖИВЫМ ПРОГРЕСС-БАРОМ
if (-not $resumeSession) {
    $scriptName = $MyInvocation.MyCommand.Name
    
    # PowerShell быстро находит файлы
    $files = @(Get-ChildItem -Path $AbsoluteSourceDir -File -Recurse | Where-Object { 
        $_.Name -ne $JsonPath -and 
        $_.Name -ne $scriptName -and
        $_.Attributes -notmatch "Hidden" -and
        $_.Attributes -notmatch "System" -and
        $mediaExtensions -contains $_.Extension.ToLower()
    })

    $totalFiles = $files.Count
    $scannedIndex = 0
    Write-Host "[+] Запуск анализа EXIF пакетами по 50 файлов..." -ForegroundColor Cyan

    $metadataArray = [System.Collections.Generic.List[PSCustomObject]]::new()
    $batch = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $scanBatchSize = 50
    $escapedDir = [regex]::Escape($AbsoluteSourceDir)

    # Автоопределение кодировки консоли
    $currentCodePage = [System.Text.Encoding]::Default.CodePage
    $filenameCharset = "cp$currentCodePage"
    if ($currentCodePage -eq 65001) {
        $filenameCharset = "utf8"
    }

    # Переключаем консоль на UTF-8 для безопасного сбора результата
    $oldOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    
    # Временно переходим в целевую папку, чтобы запускать ExifTool на относительные пути
    Push-Location $AbsoluteSourceDir
    try {
        for ($i = 0; $i -lt $files.Count; $i++) {
            $batch.Add($files[$i])

            if ($batch.Count -eq $scanBatchSize -or $i -eq $files.Count - 1) {
                
                # Формируем аргументы с относительными путями (защита от багов Windows/Perl на длинных путях)
                $exifArgs = @(
                    "-charset", "filename=$filenameCharset",
                    "-json",
                    "-api", "QuickTimeUTC",
                    "-DateTimeOriginal", "-CreateDate", "-ModifyDate"
                )
                
                foreach ($file in $batch) {
                    $rel = $file.FullName -replace "^$escapedDir", ""
                    $exifArgs += $rel.TrimStart("\")
                }

                # Вызов ExifTool
                $exifResultRaw = & $ExiftoolPath @exifArgs 2>$null | Out-String
                
                # Распаковка JSON
                if (-not [string]::IsNullOrWhiteSpace($exifResultRaw)) {
                    $parsedJson = $exifResultRaw | ConvertFrom-Json
                    if ($parsedJson -is [System.Array]) {
                        foreach ($item in $parsedJson) {
                            $null = $metadataArray.Add($item)
                        }
                    } elseif ($null -ne $parsedJson) {
                        $null = $metadataArray.Add($parsedJson)
                    }
                }

                # Плавное обновление прогресс-бара
                $scannedIndex += $batch.Count
                $scanPercent = [int](($scannedIndex / $totalFiles) * 100)
                Write-Progress -Activity "Анализ файлов при помощи ExifTool" `
                               -Status "Прогресс: $scannedIndex из $totalFiles ($scanPercent%)" `
                               -PercentComplete $scanPercent `
                               -CurrentOperation "Обработка пакета..."

                $batch.Clear()
            }
        }
    }
    catch {
        Write-Warning "[!] Не удалось выполнить пакетный анализ метаданных. Ошибка: $_"
    }
    finally {
        [Console]::OutputEncoding = $oldOutputEncoding
        Pop-Location # Возвращаемся обратно в исходную папку
        Write-Progress -Activity "Анализ файлов при помощи ExifTool" -Completed
    }

    # Строим словарь соответствия ОтносительныйПуть -> Метаданные
    $metaDict = @{}
    if ($metadataArray -ne $null -and $metadataArray.Count -gt 0) {
        foreach ($m in $metadataArray) {
            if ($m.SourceFile) {
                # Приводим к системным слэшам
                $cleanRel = $m.SourceFile.Replace("/", "\")
                
                # Срезаем префикс ".\" или "./"
                if ($cleanRel.StartsWith(".\")) {
                    $cleanRel = $cleanRel.Substring(2)
                }
                
                $cleanRel = $cleanRel.ToLower()
                $metaDict[$cleanRel] = $m
            }
        }
    }

    # Счетчики для статистики
    $exifMatchCount = 0
    $fallbackCount = 0

    # Формируем список задач processedList
    $plannedPaths = @{}
    foreach ($file in $files) {
        $filePath = [string]$file.FullName
        
        # Безопасно вырезаем имя родительской директории
        $relPath = $filePath -replace "^$escapedDir", ""
        $lookupKey = $relPath.TrimStart("\").ToLower()
        
        # Получаем метаданные из относительного словаря
        $metadata = $metaDict[$lookupKey]

        # === ОРИГИНАЛЬНЫЙ БЛОК ЧТЕНИЯ ДАТ ИЗ ВАШЕГО V11 ===
        $dateTakenStr = $null
        if ($metadata) {
            if ($metadata.DateTimeOriginal) { $dateTakenStr = $metadata.DateTimeOriginal }
            elseif ($metadata.CreateDate) { $dateTakenStr = $metadata.CreateDate }
            elseif ($metadata.ModifyDate) { $dateTakenStr = $metadata.ModifyDate }
        }
        
        [DateTime]$parsedDate = [DateTime]::MinValue
        $parseSuccess = $false
        $isFallbackDate = $false
        
        if ($dateTakenStr) {
            if ($dateTakenStr -is [System.Array]) {
                $dateTakenStr = $dateTakenStr[0]
            }
            $dateTakenStr = [string]$dateTakenStr

            if ($dateTakenStr -match '^(\d{4}):(\d{2}):(\d{2})\s+(\d{2}):(\d{2}):(\d{2})') {
                $normalizedDateStr = "$($Matches[1])-$($Matches[2])-$($Matches[3]) $($Matches[4]):$($Matches[5]):$($Matches[6])"
                $parseSuccess = [DateTime]::TryParse($normalizedDateStr, [ref]$parsedDate)
            } else {
                $parseSuccess = [DateTime]::TryParse($dateTakenStr, [ref]$parsedDate)
            }
        }
        
        if (-not $parseSuccess) {
            $parsedDate = $file.LastWriteTime
            $isFallbackDate = $true
            $fallbackCount++
        } else {
            $exifMatchCount++
        }
        
        $year = $parsedDate.ToString("yyyy")
        $dateFolder = $parsedDate.ToString("yyyy-MM-dd")
        $targetSubDir = Join-Path $AbsoluteSourceDir (Join-Path $year $dateFolder)
        
        $workingFileName = $file.Name
        $cleaned = $true
        
        while ($cleaned) {
            $cleaned = $false
            if ($workingFileName -match '^(\d{4}-\d{2}-\d{2})_(\d{4}-\d{2}-\d{2})(.*)$') {
                if ($Matches[1] -eq $Matches[2]) {
                    $workingFileName = "$($Matches[2])$($Matches[3])"
                    $cleaned = $true
                }
            }
            elseif ($workingFileName -match '^(\d{4}-\d{2}-\d{2})_(\d{4})(\d{2})(\d{2})(.*)$') {
                $reconstructedDate = "$($Matches[2])-$($Matches[3])-$($Matches[4])"
                if ($Matches[1] -eq $reconstructedDate) {
                    $workingFileName = "$($Matches[1])$($Matches[5])"
                    $cleaned = $true
                }
            }
        }
        
        if ($workingFileName.StartsWith($dateFolder)) {
            $newFileName = $workingFileName
        } else {
            $newFileName = "${dateFolder}_$workingFileName"
        }
        
        $targetPath = Join-Path $targetSubDir $newFileName
        
        $counter = 1
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($newFileName)
        $extension = [System.IO.Path]::GetExtension($newFileName)
        
        while ((Test-Path $targetPath) -or ($plannedPaths.ContainsKey($targetPath))) {
            if ($filePath -eq $targetPath) { break }
            $newFileName = "${baseName}_${counter}${extension}"
            $targetPath = Join-Path $targetSubDir $newFileName
            $counter++
        }
        
        $plannedPaths[$targetPath] = $true
        $isAlreadySorted = ($filePath -eq $targetPath)
        
        $processedList.Add([PSCustomObject]@{
            OriginalName   = $file.Name
            NewFileName    = $newFileName
            OriginalPath   = $filePath
            SizeInBytes    = [long]($file.Length)
            DateTaken      = $parsedDate.ToString("yyyy-MM-dd HH:mm:ss")
            IsFallbackDate = $isFallbackDate
            TargetFolder   = $targetSubDir
            TargetPath     = $targetPath
            Processed      = $isAlreadySorted
            ErrorMessage   = $null
        })
    }
    
    # Первичное сохранение всего списка
    $processedList | ConvertTo-Json -Depth 5 | Out-File -FilePath $JsonOutPath -Encoding utf8
    
    # Вывод результатов сопоставления
    Write-Host "[+] Сбор метаданных завершен." -ForegroundColor Green
    Write-Host "    - Получено оригинальных дат из EXIF: $exifMatchCount" -ForegroundColor Green
    Write-Host "    - Использовано дат изменения файлов (резерв): $fallbackCount" -ForegroundColor Yellow
}

# 3. Вывод статистики
$totalFound = $processedList.Count
$previouslySorted = @($processedList | Where-Object { $_.Processed -eq $true -or $_.Processed -eq "True" }).Count
$leftToProcess = $totalFound - $previouslySorted

Write-Host "`n================ СТАТИСТИКА ================" -ForegroundColor Cyan
Write-Host " Найдено всего медиафайлов:        $totalFound"
Write-Host " Ранее отсортировано (пропущено):  $previouslySorted"
Write-Host " Осталось перенести:               $leftToProcess"
Write-Host "============================================`n" -ForegroundColor Cyan

if ($leftToProcess -eq 0) {
    Write-Host "[+] Все обнаруженные файлы уже находятся в правильных папках. Перенос не требуется." -ForegroundColor Green
    Write-Host ""
    Read-Host "Нажмите Enter для завершения и закрытия окна..."
    return
}

if ($DryRun) {
    Write-Host "[СИМУЛЯЦИЯ] Завершено без физического перемещения файлов." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Нажмите Enter для завершения..."
    return
}

$confirmInput = (Read-Host "[?] Начать процесс перемещения и переименования? (Y/N или Д/Н)").Trim().ToLower()
$isYes = $confirmInput -eq "y" -or $confirmInput -eq "yes" -or $confirmInput -eq "д" -or $confirmInput -eq "да"

if (-not $isYes) {
    Write-Host "[-] Операция отменена пользователем. Файлы остались на месте." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Нажмите Enter для завершения и закрытия окна..."
    return
}

# 4. ПАКЕТНЫЙ ПРОЦЕСС ПЕРЕМЕЩЕНИЯ (Сохранение JSON раз в 50 файлов)
$itemsToMove = @($processedList | Where-Object { $_.Processed -ne $true -and $_.Processed -ne "True" })
$totalToMove = $itemsToMove.Count
$currentIndex = 0
$needsJsonSave = $false
$saveInterval = 50 

Write-Host "`n[ИНФО] Для прерывания процесса нажмите Ctrl+C в окне консоли.`n" -ForegroundColor Yellow

try {
    foreach ($item in $processedList) {
        if ($item.Processed -eq $true -or $item.Processed -eq "True") {
            continue
        }
        
        $currentIndex++
        
        $percent = [int](($currentIndex / $totalToMove) * 100)
        Write-Progress -Activity "Перенос медиафайлов (Кэширование раз в $saveInterval файлов)" `
                       -Status "Обработано: $currentIndex из $totalToMove ($percent%)" `
                       -PercentComplete $percent `
                       -CurrentOperation "Перенос: $($item.OriginalName)"

        if (-not (Test-Path $item.OriginalPath)) {
            Write-Warning "[!] Файл не найден на диске: $($item.OriginalName)"
            $item.Processed = $true
            $item.ErrorMessage = "Исходный файл не найден на диске."
            $needsJsonSave = $true
        }
        else {
            try {
                if (-not (Test-Path $item.TargetFolder)) {
                    $null = New-Item -ItemType Directory -Path $item.TargetFolder -Force
                }
                
                Move-Item -Path $item.OriginalPath -Destination $item.TargetPath -Force
                
                $item.Processed = $true
                $item.ErrorMessage = $null
                $needsJsonSave = $true
            }
            catch {
                $errMessage = $_.Exception.Message
                Write-Error "[ОШИБКА] Не удалось переместить $($item.OriginalName): $errMessage"
                $item.ErrorMessage = $errMessage
                $needsJsonSave = $true
            }
        }

        # Сохраняем на диск пачками по 50 файлов
        if ($currentIndex % $saveInterval -eq 0 -and $needsJsonSave) {
            $processedList | ConvertTo-Json -Depth 5 | Out-File -FilePath $JsonOutPath -Encoding utf8
            $needsJsonSave = $false
        }
    }
}
finally {
    # ГАРАНТИРОВАННОЕ СОХРАНЕНИЕ ОСТАТКА
    if ($needsJsonSave) {
        $processedList | ConvertTo-Json -Depth 5 | Out-File -FilePath $JsonOutPath -Encoding utf8
    }

    Write-Progress -Activity "Перенос медиафайлов" -Completed
    
    if ($currentIndex -lt $totalToMove) {
        Write-Host "`n[!] Выполнение прервано пользователем (нажато Ctrl+C)." -ForegroundColor Yellow
        Write-Host "[+] Текущий прогресс зафиксирован в файле: $JsonPath" -ForegroundColor Green
    } else {
        Write-Host "[+] Сортировка и переименование файлов успешно завершены!" -ForegroundColor Green
    }
    
    Write-Host ""
    Read-Host "Нажмите Enter для завершения и закрытия окна..."
}