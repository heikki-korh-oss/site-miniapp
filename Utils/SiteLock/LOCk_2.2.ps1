<#
.SYNOPSIS
LOCk 2.2 — анализатор сети: маршрутизация, DNS, доступность AI/IT-сервисов, split-tunneling.
Совместимость: Windows PowerShell 5.1 и PowerShell 7+.

.DESCRIPTION
Исправления относительно 2.1 (все проверены эмпирически, см. блок CHANGELOG в конце файла):
  1. Чтение тела HTTP-ошибки: ErrorDetails + поток (в 2.1 тело почти всегда было пустым).
  2. HTTP 403 больше не считается признаком доступности.
  3. IPv6: свойство AddressState вместо несуществующего State.
  4. Upstream DNS: берётся строка-IP из TXT, а не 'edns0-client-subnet ...'.
  5. Маршрут определяется по фактическому выходному IP на каждый домен, а не по коду HTTP.
  6. JSON-парсер: @($v)[0] вместо $v[0] (иначе строка режется до первой буквы).
  7. Пункты меню: нумерация, подтверждения, отказ от -Name "*" для IPv6.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

try { [Net.ServicePointManager]::SecurityProtocol = 3072 -bor 12288 } catch {}

$script:IsPS7      = $PSVersionTable.PSVersion.Major -ge 6
$script:IsAdmin    = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:CurrentDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:UserAgent  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

# Фразы, по которым сервис явно сообщает о блокировке.
# ВАЖНО: коды ответов НЕ разделяют норму и геоблок:
#   Gemini  — и «неверный ключ», и «локация не поддерживается» отдают HTTP 400;
#   OpenAI  — норма 401, геоблок 403;
#   Anthropic — норма 401/404/405, любой 403 = блокировка.
# Поэтому решает тело ответа, а не статус.
$script:GeoBlockPatterns = @(
    'User location is not supported'                 # Google Gemini (HTTP 400 + FAILED_PRECONDITION)
    'Country, region, or territory not supported'    # OpenAI (HTTP 403)
    'unsupported_country'                            # OpenAI: unsupported_country_region_territory
    'not available in your region'
    'error code: 1020'                               # Cloudflare Access Denied (HTTP 403)
    'Sorry, you have been blocked'                   # Cloudflare block page
    'Request not allowed'                            # Anthropic 403
    'region is not supported'
    'unsupported region'
    'запрещен на территории'
)

function Show-Header {
    Clear-Host
    $engine = if ($script:IsPS7) { "PowerShell $($PSVersionTable.PSVersion.Major)+" } else { 'PowerShell 5.1' }
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "   АНАЛИЗАТОР СЕТИ: AI, VPN & SPLIT TUNNELING    " -ForegroundColor Cyan
    Write-Host "   [ Движок: $engine | LOCk 2.2 ]" -ForegroundColor DarkGray
    if ($script:IsAdmin) {
        Write-Host "         [ РЕЖИМ: АДМИНИСТРАТОР ]" -ForegroundColor Green
    } else {
        Write-Host "         [ РЕЖИМ: ОГРАНИЧЕННЫЙ ]" -ForegroundColor Yellow
    }
    Write-Host "=================================================" -ForegroundColor Cyan
}

function New-RequestArgs {
    param([string]$Uri, [int]$TimeoutSec = 8, [string]$Method = 'Get', [switch]$Browser)
    $a = @{ Uri = $Uri; Method = $Method; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    # Браузерный UA нужен сайтам с антибот-защитой, но ЛОМАЕТ часть API:
    # ipinfo.io на такой UA отвечает HTTP 406. Поэтому он только по требованию.
    if ($Browser) { $a['UserAgent'] = $script:UserAgent }
    if (-not $script:IsPS7) { $a['UseBasicParsing'] = $true }
    return $a
}

# --------------------------------------------------------------------------
# Кросс-версионное чтение HTTP-ошибки.
# В PS 5.1 тело приходит ЛИБО в $_.ErrorDetails.Message, ЛИБО в потоке ответа —
# зависит от сервиса. В PS 7 поток уже закрыт, работает только ErrorDetails.
# Поэтому проверяем оба источника.
# --------------------------------------------------------------------------
function Get-HttpError {
    param($ErrorRecord)

    $code = 0
    $body = ''

    $resp = $null
    try { $resp = $ErrorRecord.Exception.Response } catch {}

    if ($resp -and $resp.StatusCode) {
        try { $code = [int]$resp.StatusCode } catch { $code = 0 }
    }

    # Источник №1 — ErrorDetails (основной для PS7, частый для PS5.1)
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $body = [string]$ErrorRecord.ErrorDetails.Message
        }
    } catch {}

    # Источник №2 — поток ответа (нужен там, где ErrorDetails пуст)
    if (-not $body -and $resp) {
        $stream = $null; $reader = $null
        try {
            if ($resp.PSObject.Methods.Name -contains 'GetResponseStream') {
                $stream = $resp.GetResponseStream()
                if ($stream) {
                    if ($stream.CanSeek) { $stream.Position = 0 }
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                }
            } elseif ($resp.Content) {
                $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
        } catch {}
        finally {
            if ($reader) { try { $reader.Dispose() } catch {} }
            if ($stream) { try { $stream.Dispose() } catch {} }
        }
    }

    # Cloudflare помечает свои блокировки заголовком cf-mitigated.
    $cfMitigated = ''
    try { if ($resp -and $resp.Headers) { $cfMitigated = [string]$resp.Headers['cf-mitigated'] } } catch {}

    $isGeo = $false
    foreach ($p in $script:GeoBlockPatterns) {
        if ($body -match [regex]::Escape($p)) { $isGeo = $true; break }
    }
    if (-not $isGeo -and $cfMitigated) { $isGeo = $true }

    return [pscustomobject]@{ Code = $code; Body = $body; IsGeoBlocked = $isGeo; CfMitigated = $cfMitigated }
}

function Get-BodySnippet {
    param([string]$Body, [int]$Max = 70)
    if (-not $Body) { return '' }
    $s = ($Body -replace '\s+', ' ').Trim()
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max) + '…' }
    return $s
}

# --------------------------------------------------------------------------
# [1/6] Фактический маршрут: выходной IP отдельно по каждому домену.
# Один общий "мой IP" не показывает split-tunneling: разные домены могут
# уходить разными путями. Сравнение нескольких эхо-сервисов это выявляет.
# --------------------------------------------------------------------------
function Get-ExitIdentity {
    param([string]$Name, [string]$Url)

    $ip = ''; $extra = ''
    try {
        $req = New-RequestArgs -Uri $Url -TimeoutSec 8
        $r = Invoke-WebRequest @req
        $txt = [string]$r.Content

        if ($txt -match 'ip=([0-9a-fA-F\.:]+)') { $ip = $Matches[1] }
        if ($txt -match 'colo=([A-Z]+)')        { $extra = "colo=$($Matches[1])" }

        if (-not $ip) {
            try {
                $j = $txt | ConvertFrom-Json
                if ($j.ip)  { $ip = [string]$j.ip } else { $ip = ($txt.Trim() -replace '"','') }
                if ($j.cc)  { $extra = [string]$j.cc }
                if ($j.country -and -not $extra) { $extra = [string]$j.country }
            } catch {
                $ip = ($txt.Trim() -replace '"','')
            }
        }
    } catch {}

    return [pscustomobject]@{ Probe = $Name; IP = $ip; Extra = $extra }
}

# Возвращает @{ Country; Org } или $null. Два независимых провайдера:
# у бесплатного ipinfo.io есть суточный лимит, ipwho.is — запасной.
function Get-IpInfo {
    param([string]$Ip)
    if (-not $Ip) { return $null }

    try {
        $req = New-RequestArgs -Uri "https://ipinfo.io/$Ip/json" -TimeoutSec 6
        $r = Invoke-RestMethod @req
        if ($r.country) { return [pscustomobject]@{ Country = [string]$r.country; Org = [string]$r.org } }
    } catch {}

    try {
        $req = New-RequestArgs -Uri "https://ipwho.is/$Ip" -TimeoutSec 6
        $r = Invoke-RestMethod @req
        if ($r.success -and $r.country_code) {
            $org = ''
            if ($r.connection -and $r.connection.isp) { $org = [string]$r.connection.isp }
            return [pscustomobject]@{ Country = [string]$r.country_code; Org = $org }
        }
    } catch {}

    return $null
}

function Show-RoutingSection {
    Write-Host "`n[1/6] Фактический маршрут (выходной IP по каждому домену)..." -ForegroundColor Yellow

    $probes = @(
        @{ N = 'cloudflare.com'; U = 'https://www.cloudflare.com/cdn-cgi/trace' }
        @{ N = 'ipinfo.io';      U = 'https://ipinfo.io/json' }
        @{ N = 'ipify.org';      U = 'https://api.ipify.org?format=json' }
        @{ N = 'yandex.ru';      U = 'https://yandex.ru/internet/api/v0/ip' }
    )

    $results = @()
    foreach ($p in $probes) {
        $res = Get-ExitIdentity -Name $p.N -Url $p.U
        $results += $res
        $shown = if ($res.IP) { $res.IP } else { '— не ответил —' }
        $info  = Get-IpInfo -Ip $res.IP
        $tail  = ''
        if ($info) { $tail = "[$($info.Country), $($info.Org)]" }
        elseif ($res.Extra) { $tail = "[$($res.Extra)]" }
        Write-Host ("  {0,-16} -> {1,-16} {2}" -f $p.N, $shown, $tail) -ForegroundColor Cyan
    }

    $unique = @($results | Where-Object { $_.IP } | Select-Object -ExpandProperty IP -Unique)

    Write-Host ""
    if ($unique.Count -eq 0) {
        Write-Host "  ❌ Ни один эхо-сервис не ответил — сети нет или всё заблокировано." -ForegroundColor Red
    } elseif ($unique.Count -eq 1) {
        $info = Get-IpInfo -Ip $unique[0]
        if ($info -and $info.Country -in @('RU','BY')) {
            Write-Host "  ℹ️ Один выходной IP ($($unique[0]), $($info.Country)) — весь трафик идёт напрямую," -ForegroundColor Yellow
            Write-Host "     VPN/split-tunnel сейчас не работает." -ForegroundColor DarkGray
        } elseif ($info) {
            Write-Host "  ✅ Один выходной IP на все домены ($($info.Country)) — FULL TUNNEL." -ForegroundColor Green
        } else {
            Write-Host "  ℹ️ Один выходной IP на все домены — FULL TUNNEL (страну определить не удалось)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ✅ Обнаружено $($unique.Count) разных выходных IP — SPLIT TUNNEL работает." -ForegroundColor Green
        Write-Host "     Разные домены уходят разными маршрутами — это и есть штатное поведение." -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------------------------
# [2/6] Upstream DNS
# --------------------------------------------------------------------------
function Show-DnsSection {
    Write-Host "`n[2/6] Детекция реального внешнего DNS-резолвера..." -ForegroundColor Yellow

    try {
        Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses.Count -gt 0 } |
            ForEach-Object { Write-Host ("  DNS на «{0}»: {1}" -f $_.InterfaceAlias, ($_.ServerAddresses -join ', ')) -ForegroundColor Cyan }
    } catch {
        Write-Host "  Не удалось прочитать настройки DNS Windows." -ForegroundColor DarkGray
    }

    try {
        $recs = Resolve-DnsName -Name 'o-o.myaddr.l.google.com' -Type TXT -ErrorAction Stop

        # TXT возвращает НЕСКОЛЬКО строк; IP-резолвера — та, что похожа на IP.
        # Первая строка обычно 'edns0-client-subnet a.b.c.0/24' и IP-адресом НЕ является.
        $strings = @()
        foreach ($r in $recs) { if ($r.Strings) { $strings += $r.Strings } }

        $resolverIp = $strings |
            Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -or $_ -match '^[0-9a-fA-F]{0,4}:[0-9a-fA-F:]+$' } |
            Select-Object -First 1

        $ecs = $strings | Where-Object { $_ -match 'edns0-client-subnet' } | Select-Object -First 1

        if (-not $resolverIp) {
            Write-Host "  ⚠️ TXT-ответ получен, но IP резолвера в нём не найден." -ForegroundColor Yellow
            return
        }

        $info = Get-IpInfo -Ip $resolverIp
        $org  = if ($info) { "$($info.Org), $($info.Country)" } else { 'страну определить не удалось' }
        Write-Host "  Внешний резолвер: " -NoNewline
        Write-Host "$resolverIp [$org]" -ForegroundColor Cyan
        if ($ecs) { Write-Host "  EDNS Client Subnet: $ecs" -ForegroundColor DarkGray }

        if (-not $info) {
            Write-Host "  ⚠️ Гео-сервисы недоступны — вердикт по DNS не выносится." -ForegroundColor Yellow
        } elseif ($info.Country -in @('RU','BY')) {
            Write-Host "  ℹ️ DNS-запросы уходят резолверу в РФ/РБ. Для split-DNS это норма," -ForegroundColor Yellow
            Write-Host "     но именно так работает подмена ответов (NXDOMAIN) для заблокированных доменов." -ForegroundColor DarkGray
        } else {
            Write-Host "  ✅ DNS идёт через зарубежный резолвер — подмена ответов провайдером маловероятна." -ForegroundColor Green
        }
    } catch {
        Write-Host "  ⚠️ Не удалось определить внешний резолвер (TXT-запрос не прошёл)." -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# [3/6] IPv6
# --------------------------------------------------------------------------
function Show-Ipv6Section {
    Write-Host "`n[3/6] Проверка IPv6 на утечки..." -ForegroundColor Yellow
    try {
        # ВАЖНО: у Get-NetIPAddress свойство называется AddressState, а НЕ State.
        # Обращение к $_.State даёт $null, и фильтр молча не находит ничего.
        $global6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop | Where-Object {
            $_.AddressState -eq 'Preferred' -and
            $_.IPAddress -notmatch '^fe80'  -and
            $_.IPAddress -ne '::1'          -and
            $_.IPAddress -notmatch '^f[cd]' -and
            $_.IPAddress -notmatch '^2001:0?:' -and   # Teredo
            $_.IPAddress -notmatch '^2002:'           # 6to4
        }

        if ($global6) {
            Write-Host "  ⚠️ Найден глобальный IPv6-адрес — возможна утечка мимо туннеля:" -ForegroundColor Yellow
            foreach ($a in $global6) {
                Write-Host ("     {0}  (интерфейс: {1})" -f $a.IPAddress, $a.InterfaceAlias) -ForegroundColor Yellow
            }
            Write-Host "     Утечка реальна ТОЛЬКО если IPv6 при этом маршрутизируется наружу — проверяется ниже." -ForegroundColor DarkGray

            try {
                $req = New-RequestArgs -Uri 'https://api6.ipify.org?format=json' -TimeoutSec 6
                $r = Invoke-WebRequest @req
                $v6 = ($r.Content | ConvertFrom-Json).ip
                Write-Host "  ❌ IPv6 наружу РАБОТАЕТ (выходной v6: $v6) — утечка подтверждена." -ForegroundColor Red
            } catch {
                Write-Host "  ✅ IPv6 наружу не проходит — адрес есть, но утечки нет." -ForegroundColor Green
            }
        } else {
            Write-Host "  ✅ Глобального IPv6-адреса нет (fe80::/ULA безопасны) — утекать нечему." -ForegroundColor Green
        }
    } catch {
        Write-Host "  Не удалось прочитать адреса адаптеров." -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------------------------
# [4/6] и [5/6] Доступность сервисов
# --------------------------------------------------------------------------
function Test-Endpoint {
    param(
        [string]$Name,
        [string]$Url,
        [int]$PadTo = 26,
        [switch]$ExpectRussian,
        [switch]$Browser,
        [switch]$GeoVerdictUnreliable
    )

    if ($PadTo -gt 0) {
        $pad  = $PadTo - $Name.Length
        $dots = if ($pad -gt 0) { '.' * $pad } else { '...' }
        Write-Host "  $Name $dots " -NoNewline
    }

    try {
        $req = New-RequestArgs -Uri $Url -TimeoutSec 8 -Browser:$Browser
        $null = Invoke-WebRequest @req
        Write-Host "✅ ДОСТУПЕН (HTTP 200)" -ForegroundColor Green
        return
    } catch {
        $e = Get-HttpError $_

        # Проверяем тело ДО анализа кода: у Gemini геоблок приходит с HTTP 400,
        # который сам по себе выглядит как безобидная ошибка API.
        if ($e.IsGeoBlocked) {
            if ($GeoVerdictUnreliable) {
                Write-Host "⚠️ Сообщает «локация не поддерживается» (код $($e.Code))." -ForegroundColor DarkYellow
                Write-Host ("      У этого endpoint это чаще баг привязки Cloud Project, чем реальный геоблок.") -ForegroundColor DarkGray
            } else {
                Write-Host "❌ БЛОКИРОВКА (код $($e.Code)): $(Get-BodySnippet $e.Body)" -ForegroundColor Red
            }
            return
        }

        switch ($e.Code) {
            0 {
                if ($ExpectRussian) {
                    Write-Host "❌ ТАЙМАУТ/СБРОС (домен ушёл в VPN или сайт лежит)" -ForegroundColor Red
                } else {
                    Write-Host "❌ ТАЙМАУТ/СБРОС (блокировка на стороне провайдера / ТСПУ)" -ForegroundColor Red
                }
            }
            403 {
                # 403 НЕ является признаком доступности: так отвечают геоблок,
                # Cloudflare 1020 и антибот-защита. Показываем тело, не гадаем.
                $sn = Get-BodySnippet $e.Body
                if ($sn) { Write-Host "⚠️ HTTP 403 — проверьте причину: $sn" -ForegroundColor DarkYellow }
                else     { Write-Host "⚠️ HTTP 403 — доступ запрещён (геоблок или антибот)" -ForegroundColor DarkYellow }
            }
            { $_ -in 400,401,404,405 } {
                # Сервис ответил осмысленной ошибкой API => сеть до него дошла,
                # и тело выше не содержало признаков блокировки.
                Write-Host "✅ ДОСТУПЕН (сервис ответил, код $($e.Code))" -ForegroundColor Green
            }
            default {
                Write-Host "⚠️ HTTP $($e.Code)" -ForegroundColor DarkYellow
            }
        }
    }
}

function Show-ForeignSection {
    Write-Host "`n[4/6] Зарубежные AI/IT-сервисы (доступность)..." -ForegroundColor Yellow
    Write-Host "  Примечание: доступность ≠ маршрут. Маршрут показан в разделе [1/6]." -ForegroundColor DarkGray

    # API — без браузерного UA (часть API отвечает 406 на подменённый UA).
    Test-Endpoint -Name 'OpenAI (ChatGPT) API'   -Url 'https://api.openai.com/v1/models'
    Test-Endpoint -Name 'Claude (Anthropic) API' -Url 'https://api.anthropic.com/v1/messages'
    Test-Endpoint -Name 'Google Gemini API'      -Url 'https://generativelanguage.googleapis.com/v1beta/models?key=TEST'
    Test-Endpoint -Name 'Google Cloud AI'        -Url 'https://cloudaicompanion.googleapis.com/' -GeoVerdictUnreliable
    Test-Endpoint -Name 'Telegram API'           -Url 'https://api.telegram.org/'

    # Сайты — с браузерным UA, иначе часть отдаёт 403 от антибот-защиты.
    Test-Endpoint -Name 'YouTube'                -Url 'https://www.youtube.com/'            -Browser
    Test-Endpoint -Name 'GitHub'                 -Url 'https://github.com/'                 -Browser
    Test-Endpoint -Name 'GitHub Raw'             -Url 'https://raw.githubusercontent.com/'  -Browser
    Test-Endpoint -Name 'Docker Hub'             -Url 'https://hub.docker.com/'             -Browser
    Test-Endpoint -Name 'Microsoft'              -Url 'https://www.microsoft.com/'          -Browser
    Test-Endpoint -Name 'Ubuntu Repo'            -Url 'https://archive.ubuntu.com/'         -Browser
    Test-Endpoint -Name 'X (Twitter)'            -Url 'https://x.com/'                      -Browser
}

function Test-RuEndpoint {
    param([string]$Name, [string]$Url, [string]$Domain)

    $pad = 12 - $Name.Length
    $sp  = if ($pad -gt 0) { ' ' * $pad } else { ' ' }
    Write-Host "  $Name$sp(DNS) ... " -NoNewline

    $ips = ''
    try {
        $ips = (Resolve-DnsName -Name $Domain -Type A -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' } |
                Select-Object -ExpandProperty IPAddress) -join ', '
    } catch {
        try {
            $ips = ([System.Net.Dns]::GetHostAddresses($Domain) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                    Select-Object -ExpandProperty IPAddressToString) -join ', '
        } catch {}
    }

    if ($ips) { Write-Host "✅ РЕЗОЛВИТСЯ " -ForegroundColor Green -NoNewline }
    else      { Write-Host "❌ СБОЙ DNS " -ForegroundColor Red -NoNewline }

    Write-Host "| (HTTP) ... " -NoNewline
    Test-Endpoint -Name '' -Url $Url -PadTo 0 -ExpectRussian -Browser
}

function Show-RussianSection {
    Write-Host "`n[5/6] Российские сервисы (должны идти напрямую)..." -ForegroundColor Yellow
    Test-RuEndpoint -Name 'Госуслуги' -Url 'https://www.gosuslugi.ru/' -Domain 'gosuslugi.ru'
    Test-RuEndpoint -Name 'Сбербанк'  -Url 'https://www.sberbank.ru/'  -Domain 'sberbank.ru'
    Test-RuEndpoint -Name 'Mos.ru'    -Url 'https://www.mos.ru/'       -Domain 'mos.ru'
    Test-RuEndpoint -Name 'Яндекс'    -Url 'https://ya.ru/'            -Domain 'ya.ru'
}

# --------------------------------------------------------------------------
# [6/6] Сводка
# --------------------------------------------------------------------------
function Show-Summary {
    Write-Host "`n[6/6] Активные сетевые интерфейсы..." -ForegroundColor Yellow
    try {
        Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up' |
            ForEach-Object { Write-Host ("  {0,-28} {1}" -f $_.Name, $_.InterfaceDescription) -ForegroundColor Cyan }
    } catch {
        Write-Host "  Не удалось получить список адаптеров." -ForegroundColor DarkGray
    }
}

function Invoke-FullAnalysis {
    Show-Header
    Show-RoutingSection
    Show-DnsSection
    Show-Ipv6Section
    Show-ForeignSection
    Show-RussianSection
    Show-Summary
    Write-Host "`nНажмите Enter, чтобы перейти в главное меню..." -ForegroundColor Yellow
    [void](Read-Host)
}

# --------------------------------------------------------------------------
# Массовая проверка списка из ip-list.json
# --------------------------------------------------------------------------
function Invoke-JsonTests {
    $jsonPath = Join-Path $script:CurrentDir 'ip-list.json'

    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "      АНАЛИЗАТОР КАСТОМНОГО СПИСКА (JSON)        " -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan

    if (-not (Test-Path $jsonPath)) {
        Write-Host "`n❌ Файл 'ip-list.json' не найден." -ForegroundColor Red
        Write-Host "Положите его в папку: $script:CurrentDir" -ForegroundColor Yellow
        Start-Sleep -Seconds 4
        return
    }

    $rawContent = Get-Content -Path $jsonPath -Raw -Encoding UTF8
    $itemsToTest = @()
    $isJsonObj = $false

    try {
        $parsed = $rawContent | ConvertFrom-Json -ErrorAction Stop
        if ($parsed -isnot [array]) {
            $isJsonObj = $true
            $services = @($parsed.psobject.Properties)
            foreach ($svc in $services) {
                $name = $svc.Name
                $domain = ''
                $vals = @($svc.Value)

                if ($vals.Count -gt 0 -and $vals[0] -match '\.[A-Za-z]{2,}$' -and $vals[0] -notmatch '\s') {
                    $domain = [string]$vals[0]
                } elseif ($name -match '\.[A-Za-z]{2,}$' -and $name -notmatch '\s') {
                    $domain = $name
                }
                if ($domain) {
                    $itemsToTest += [pscustomobject]@{ Name = $name; Domain = $domain }
                }
            }
        } elseif ($parsed -is [array]) {
            foreach ($item in $parsed) {
                $domain = [string]$item
                if ($domain -match '\.[A-Za-z]{2,}$' -and $domain -notmatch '\s') {
                    $itemsToTest += [pscustomobject]@{ Name = $domain; Domain = $domain }
                }
            }
        }
    } catch {}

    if ($itemsToTest.Count -eq 0) {
        $lines = $rawContent -split "`r?`n" | Where-Object { $_ -match '\S' }
        foreach ($line in $lines) {
            $domain = $line.Trim() -replace '^https?://', '' -replace '/.*$', '' -replace '^\*\.', ''
            if ($domain -match '\.[A-Za-z]{2,}$' -and $domain -notmatch '\s') {
                $itemsToTest += [pscustomobject]@{ Name = $domain; Domain = $domain }
            }
        }
    }

    if ($itemsToTest.Count -eq 0) {
        Write-Host "`n❌ В файле не найдено ни одного валидного домена." -ForegroundColor Red
        [void](Read-Host 'Enter для возврата')
        return
    }

    Write-Host "`nЗагружено доменов для проверки: $($itemsToTest.Count)." -ForegroundColor Green
    if ($isJsonObj) { Write-Host "Формат: JSON-словарь (по 1 домену на сервис)`n" -ForegroundColor DarkGray }
    else            { Write-Host "Формат: Простой список`n" -ForegroundColor DarkGray }

    if ($itemsToTest.Count -gt 50) {
        Write-Host "⚠️ Внимание: проверка $($itemsToTest.Count) доменов может занять $([math]::Round($itemsToTest.Count * 8 / 60, 1)) мин." -ForegroundColor Yellow
        $c = Read-Host 'Продолжить? (y/N)'
        if ($c -notmatch '^[yYдД]') { return }
        Write-Host ""
    }

    foreach ($item in $itemsToTest) {
        $domain = $item.Domain -replace '^https?://', '' -replace '/.*$', '' -replace '^\*\.', ''
        if (-not $domain) { continue }
        Test-Endpoint -Name $item.Name -Url "https://$domain/" -PadTo 32 -Browser
    }

    Write-Host "`n✅ Проверка списка завершена." -ForegroundColor Green
    [void](Read-Host 'Enter для возврата в меню')
}

# --------------------------------------------------------------------------
# Действия меню
# --------------------------------------------------------------------------
function Clear-DnsCache {
    $ok = $true
    try { Clear-DnsClientCache -ErrorAction Stop } catch { $ok = $false }
    if ($ok) {
        Write-Host "`n✅ Кэш DNS очищен." -ForegroundColor Green
    } else {
        Write-Host "`n❌ Не удалось очистить кэш DNS (нужны права администратора)." -ForegroundColor Red
    }
    Start-Sleep -Seconds 2
}

function Restart-WslEnvironment {
    Write-Host "`n⚠️ Будут остановлены ВСЕ дистрибутивы WSL, включая бэкенд Docker Desktop." -ForegroundColor Yellow
    $c = Read-Host 'Продолжить? (y/N)'
    if ($c -notmatch '^[yYдД]') { Write-Host 'Отменено.' -ForegroundColor DarkGray; Start-Sleep -Seconds 1; return }

    wsl --shutdown 2>$null | Out-Null
    Write-Host "✅ WSL остановлена. Запустится сама при следующем обращении." -ForegroundColor Green
    Start-Sleep -Seconds 2
}

function Set-Ipv6Binding {
    param([switch]$Enable)

    if (-not $script:IsAdmin) {
        Write-Host "`n❌ Требуются права администратора." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $action = if ($Enable) { 'ВКЛЮЧИТЬ' } else { 'ОТКЛЮЧИТЬ' }

    # -Name "*" затрагивает и tun0, и vEthernet (Hyper-V/WSL) — это ломает
    # виртуальные сети. Показываем список и даём выбрать.
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    if (-not $adapters) { Write-Host "`nАдаптеры не найдены." -ForegroundColor Red; Start-Sleep -Seconds 2; return }

    Write-Host "`nАдаптеры, на которых можно $action IPv6:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $b = Get-NetAdapterBinding -Name $adapters[$i].Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        $state = if ($b -and $b.Enabled) { 'IPv6 вкл' } else { 'IPv6 выкл' }
        $warn  = if ($adapters[$i].InterfaceDescription -match 'Hyper-V|Tunnel|TAP|WSL') { '  ⚠️ виртуальный — не трогайте без нужды' } else { '' }
        Write-Host ("  {0}. {1,-28} [{2}]{3}" -f ($i + 1), $adapters[$i].Name, $state, $warn)
    }
    Write-Host "  A. Все физические (кроме виртуальных и туннелей)"
    $sel = Read-Host "`nНомер адаптера, A, или Enter для отмены"

    $targets = @()
    if ($sel -match '^[Aa]$') {
        $targets = $adapters | Where-Object { $_.InterfaceDescription -notmatch 'Hyper-V|Tunnel|TAP|WSL|Loopback' }
    } elseif ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $adapters.Count) {
        $targets = @($adapters[[int]$sel - 1])
    } else {
        Write-Host 'Отменено.' -ForegroundColor DarkGray; Start-Sleep -Seconds 1; return
    }

    foreach ($t in $targets) {
        try {
            if ($Enable) { Enable-NetAdapterBinding  -Name $t.Name -ComponentID ms_tcpip6 -ErrorAction Stop }
            else         { Disable-NetAdapterBinding -Name $t.Name -ComponentID ms_tcpip6 -ErrorAction Stop }
            Write-Host ("  ✅ {0}: IPv6 {1}" -f $t.Name, $(if ($Enable) { 'включен' } else { 'отключен' })) -ForegroundColor Green
        } catch {
            Write-Host ("  ❌ {0}: {1}" -f $t.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }
    Start-Sleep -Seconds 3
}

function Restart-AsAdministrator {
    if ($script:IsAdmin) { return }
    if (-not $PSCommandPath) {
        Write-Host "`n⚠️ Скрипт запущен не из файла — перезапуск невозможен." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        return $false
    }
    try {
        $exe = (Get-Process -Id $PID).Path
        Start-Process $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -ErrorAction Stop
        return $true
    } catch {
        Write-Host "`n⚠️ Перезапуск отменён или невозможен: $($_.Exception.Message)" -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        return $false
    }
}

# --------------------------------------------------------------------------
# Точка входа
# --------------------------------------------------------------------------
try {
    Invoke-FullAnalysis

    $run = $true
    while ($run) {
        Show-Header
        Write-Host "`n=================================================" -ForegroundColor Cyan
        Write-Host "                 МЕНЮ ИНСТРУМЕНТОВ               " -ForegroundColor Cyan
        Write-Host "=================================================" -ForegroundColor Cyan
        Write-Host "  1. 🔍 Полная диагностика сети" -ForegroundColor Green
        Write-Host "  2. 🧹 Очистить кэш DNS Windows"
        Write-Host "  3. 🔄 Остановить WSL (перезапустится сама)"
        if ($script:IsAdmin) {
            Write-Host "  4. 🚫 Отключить IPv6 (выбор адаптера)" -ForegroundColor Yellow
            Write-Host "  5. 🌐 Включить IPv6 (выбор адаптера)"
        } else {
            Write-Host "  4. 🚫 Отключить IPv6            [нужен админ]" -ForegroundColor DarkGray
            Write-Host "  5. 🌐 Включить IPv6             [нужен админ]" -ForegroundColor DarkGray
            Write-Host "  6. 🔑 Перезапустить от имени администратора" -ForegroundColor Yellow
        }
        Write-Host "  7. 📂 Проверить список из ip-list.json" -ForegroundColor Magenta
        Write-Host "  0. ❌ Выход"

        $choice = Read-Host "`nВыберите действие"
        switch ($choice) {
            '1' { Invoke-FullAnalysis }
            '2' { Clear-DnsCache }
            '3' { Restart-WslEnvironment }
            '4' { Set-Ipv6Binding }
            '5' { Set-Ipv6Binding -Enable }
            '6' { if (-not $script:IsAdmin) { if (Restart-AsAdministrator) { $run = $false } } else { Write-Host "`nУже администратор." -ForegroundColor DarkGray; Start-Sleep -Seconds 1 } }
            '7' { Invoke-JsonTests }
            '0' { $run = $false }
            default { Write-Host "`nНет такого пункта." -ForegroundColor DarkGray; Start-Sleep -Seconds 1 }
        }
    }
}
catch {
    Write-Host "`n[КРИТИЧЕСКАЯ ОШИБКА] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    [void](Read-Host 'Enter для выхода')
}
finally {
    Write-Host "`nРабота завершена." -ForegroundColor Yellow
}

<#
CHANGELOG 2.1 -> 2.2

[КРИТИЧНО] Get-HttpDetails читал тело ошибки только из GetResponseStream(), который
           в PS 5.1 почти всегда пуст (проверено: OpenAI/Anthropic/Google — 0 байт,
           тело лежит в $_.ErrorDetails.Message). Из-за этого детект геоблока
           не срабатывал НИКОГДА, и 403-геоблок отображался как «✅ ДОСТУПЕН».
           Теперь читаются оба источника.

[КРИТИЧНО] 403 исключён из списка «кодов успеха». Геоблокировка OpenAI
           (unsupported_country_region_territory), любой 403 у api.anthropic.com
           и Cloudflare 1020 — всё это HTTP 403.

[КРИТИЧНО] Геоблок Gemini приходит с HTTP 400 (status FAILED_PRECONDITION,
           «User location is not supported for the API use»), а 400 в 2.1
           числился кодом успеха. Тело ответа теперь проверяется ДО кода.
           У Gemini «неверный ключ» и «геоблок» отдают ОДИН И ТОТ ЖЕ код 400 —
           различить их можно только по телу.

[КРИТИЧНО] IPv6-фильтр использовал $_.State — такого свойства у Get-NetIPAddress нет
           (есть AddressState). Условие всегда ложно => «утечек нет» при любой
           конфигурации. Исправлено + добавлена реальная проверка выхода по IPv6.

[КРИТИЧНО] Upstream DNS: $dnsRes.Strings[0] — это 'edns0-client-subnet a.b.c.0/24',
           а не IP. Скрипт строил битый URL и показывал СВОЙ выходной IP как
           «внешний DNS». Теперь из TXT выбирается строка-IP.

[ВАЖНО]    Вердикт о туннеле строился по одному публичному IP. Split-tunnel так
           не детектируется. Теперь опрашиваются несколько эхо-сервисов на разных
           доменах; несколько разных выходных IP = split-tunnel подтверждён.

[ВАЖНО]    Убраны надписи «Маршрут через VPN» / «Маршрут через РФ» у HTTP-проверок:
           код ответа не говорит о маршруте. Маршрут показан в разделе [1/6].

[ОБЫЧНОЕ]  JSON-парсер: @($v)[0] вместо $v[0] (строка резалась до первого символа).
[ОБЫЧНОЕ]  Браузерный User-Agent — только для сайтов (меньше ложных 403 от
           антибот-защиты). Для API он вреден: ipinfo.io на него отвечает 406.
[ОБЫЧНОЕ]  cloudaicompanion.googleapis.com помечен как ненадёжный гео-индикатор:
           «User location is not supported» там часто означает не геоблок,
           а незавершённую привязку Cloud Project.
[ОБЫЧНОЕ]  Гео-провайдер продублирован (ipinfo.io -> ipwho.is): у бесплатного
           ipinfo есть суточный лимит, и при отказе 2.1 выносила вердикт вслепую.
[ОБЫЧНОЕ]  Учитывается заголовок cf-mitigated (метка блокировки Cloudflare).
[ОБЫЧНОЕ]  Пункт «Отключить IPv6» больше не бьёт по -Name "*" (задевало tun0
           и vEthernet Hyper-V/WSL) — теперь выбор адаптера.
[ОБЫЧНОЕ]  Clear-DnsClientCache проверяется на успех, а не рапортует успех всегда.
[ОБЫЧНОЕ]  Пункт «перезапуск от админа» не роняет скрипт при отказе от UAC.
[ОБЫЧНОЕ]  Потоки/ридеры освобождаются; в switch добавлен default.
#>
