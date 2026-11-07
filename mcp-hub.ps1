# ============================================================================
#  MCP Hub for Windows
#  Устанавливает, настраивает, запускает и показывает статус MCP-серверов
#  (ComfyUI, Blender; легко расширяется другими приложениями).
#
#  Использование:
#    powershell -ExecutionPolicy Bypass -File .\mcp-hub.ps1 setup
#    powershell -ExecutionPolicy Bypass -File .\mcp-hub.ps1 start
#    powershell -ExecutionPolicy Bypass -File .\mcp-hub.ps1 start blender
#    powershell -ExecutionPolicy Bypass -File .\mcp-hub.ps1 stop
#    powershell -ExecutionPolicy Bypass -File .\mcp-hub.ps1 status
#    powershell -ExecutionPolicy Bypass -File .\mcp-hub.ps1 config
#
#  Конфигурация хранится рядом в mcp-hub.config.json и создаётся автоматически.
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'status',

    [Parameter(Position = 1)]
    [string]$AppName
)

$ErrorActionPreference = 'Stop'
# MCP_HUB_HOME задаёт mcp-hub.exe (папка, где лежит exe), чтобы конфиг
# писался рядом с exe, а не во временную папку распакованного скрипта
$ScriptDir = if ($env:MCP_HUB_HOME) { $env:MCP_HUB_HOME }
              else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ConfigFile = Join-Path $ScriptDir 'mcp-hub.config.json'

# ----------------------------------------------------------------------------
#  КОНФИГУРАЦИЯ ПО УМОЛЧАНИЮ
#  Меняется автоматически (setup) или руками в mcp-hub.config.json
# ----------------------------------------------------------------------------
$script:Defaults = @{
    BaseDir        = 'D:\Comfy-Desktop'                                          # где живут venv-окружения
    ComfyWorkspace = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI\ComfyUI'        # установка ComfyUI
    BasePython     = 'D:\Comfy-Desktop\ComfyUI-Installs\ComfyUI\ComfyUI\.venv\Scripts\python.exe'
    GitExe         = 'C:\Program Files\Git\cmd\git.exe'
    ComfyUrl       = 'http://127.0.0.1:8188'
    ServerIp       = ''      # определяется автоматически при setup
    ClientIp       = ''      # IP компьютера с Claude Desktop — для подсказки про firewall
}

# ----------------------------------------------------------------------------
#  РЕЕСТР ПРИЛОЖЕНИЙ
#  Чтобы добавить новое приложение — скопируйте блок и заполните поля:
#    Id         — короткий идентификатор (аргумент командной строки)
#    Name       — человекочитаемое имя
#    Port       — порт mcp-proxy, открываемый в сеть
#    Venv       — имя venv (создаётся в BaseDir)
#    Packages   — pip-пакеты для установки в этот venv
#    ServerExe  — имя exe MCP-сервера в Scripts этого venv (или список кандидатов)
#    Env        — переменные окружения, передаваемые MCP-серверу
#    Upstream   — что проверять в статусе: Kind = 'http' | 'tcp'
#    Hint       — подсказка, если upstream недоступен
#    PostSetup  — скрипт-блок, выполняемый после установки (необязательно)
# ----------------------------------------------------------------------------
$script:Apps = @(
    @{
        Id         = 'comfyui'
        Name       = 'ComfyUI'
        Port       = 8000
        Venv       = 'comfy-mcp-env'
        Packages   = @('comfy-mcp', 'comfy-cli>=1.14.0')
        ServerExe  = @('comfy-mcp.exe')
        Env        = @{}
        Upstream   = @{ Kind = 'http'; Url = 'http://127.0.0.1:8188/system_stats'; Label = 'ComfyUI API' }
        Hint       = 'Запусти ComfyUI (Desktop) и проверь, что порт совпадает с ComfyUrl в конфиге.'
        PostSetup  = {
            # указываем comfy-cli на существующую установку ComfyUI
            $comfyExe = Join-Path $cfg.BaseDir 'comfy-mcp-env\Scripts\comfy.exe'
            if (Test-Path $comfyExe) {
                Write-Host "  -> comfy set-default $($cfg.ComfyWorkspace)"
                & $comfyExe set-default $cfg.ComfyWorkspace | Out-Null
            }
        }
    }
    @{
        Id         = 'blender'
        Name       = 'Blender'
        Port       = 8001
        Venv       = 'blender-mcp-env'
        # blender-mcp переименован в mcp-for-blender; старое имя работает как alias
        Packages   = @('blender-mcp')
        ServerExe  = @('blender-mcp.exe', 'mcp-for-blender.exe')
        Env        = @{}
        Upstream   = @{ Kind = 'tcp'; Host = '127.0.0.1'; Port = 9876; Label = 'Blender addon' }
        Hint       = 'В Blender: Edit > Preferences > Add-ons включи "MCP for Blender", затем в 3D-вьюпорте (N) на вкладке MCP нажми Start MCP Server. Аддон: uvx blender-mcp install-addon'
        PostSetup  = {}
    }
)

# Общий venv с mcp-proxy (держим отдельно, чтобы не конфликтовать с mcp у MCP-серверов)
$script:ProxyVenv = 'mcp-proxy-env'

# ----------------------------------------------------------------------------
#  УТИЛИТЫ
# ----------------------------------------------------------------------------

function Read-HubConfig {
    if (Test-Path $ConfigFile) {
        try {
            $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $map = @{}
            foreach ($p in $cfg.PSObject.Properties) { $map[$p.Name] = $p.Value }
            # дополняем недостающие ключи дефолтами
            foreach ($k in $script:Defaults.Keys) {
                if (-not $map.ContainsKey($k) -or [string]::IsNullOrEmpty("$($map[$k])")) {
                    $map[$k] = $script:Defaults[$k]
                }
            }
            return $map
        } catch {
            Write-Warning "Не удалось прочитать $ConfigFile ($($_.Exception.Message)). Использую значения по умолчанию."
        }
    }
    return $script:Defaults.Clone()
}

function Save-HubConfig($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile -Encoding UTF8
    Write-Host "Конфигурация сохранена: $ConfigFile"
}

function Get-LanIp {
    $ip = (Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1).IPv4Address.IPAddress
    if (-not $ip) {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1).IPAddress
    }
    return $ip
}

function Test-TcpPort {
    param([string]$Ip, [int]$Port, [int]$TimeoutMs = 600)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Ip, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) { return $true }
        return $false
    } catch { return $false }
    finally { $client.Close() }
}

function Test-HttpStatus {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec | Out-Null
        return $true
    } catch { return $false }
}

function Get-PortOwnerPid {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($conn) { return $conn.OwningProcess }
    return $null
}

function Write-Mark($Ok) {
    if ($Ok) { Write-Host ' [OK] ' -ForegroundColor Green -NoNewline }
    else { Write-Host ' [DOWN] ' -ForegroundColor Red -NoNewline }
}

function Select-App($Name) {
    if (-not $Name) { return $script:Apps }
    $found = @($script:Apps | Where-Object { $_.Id -eq $Name.ToLower() })
    if (-not $found) {
        throw "Приложение '$Name' не найдено. Доступно: $(($script:Apps | ForEach-Object Id) -join ', ')"
    }
    return $found
}

function Get-AppServerExe($app, $cfg) {
    $scripts = Join-Path (Join-Path $cfg.BaseDir $app.Venv) 'Scripts'
    foreach ($exe in $app.ServerExe) {
        $p = Join-Path $scripts $exe
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ----------------------------------------------------------------------------
#  SETUP — установка и настройка всего
# ----------------------------------------------------------------------------

function Invoke-Setup {
    $cfg = Read-HubConfig

    Write-Host ''
    Write-Host '=== MCP Hub: установка ===' -ForegroundColor Cyan

    # 1. Git
    Write-Host "`n[1/4] Проверяю Git" -ForegroundColor Yellow
    $gitOk = $false
    try { git --version *> $null; $gitOk = $true } catch {}
    if (-not $gitOk -and (Test-Path $cfg.GitExe)) {
        $env:GIT_PYTHON_GIT_EXECUTABLE = $cfg.GitExe
        try { & $cfg.GitExe --version *> $null; $gitOk = $true } catch {}
    }
    if ($gitOk) { Write-Host '  Git найден' -ForegroundColor Green }
    else {
        Write-Host '  Git НЕ найден. Установи Git for Windows (https://git-scm.com/install/windows)' -ForegroundColor Red
        Write-Host '  и повтори setup.' -ForegroundColor Red
        return
    }

    # 2. Базовый Python (из venv ComfyUI)
    Write-Host "`n[2/4] Проверяю базовый Python" -ForegroundColor Yellow
    if (-not (Test-Path $cfg.BasePython)) {
        Write-Host "  Не найден: $($cfg.BasePython)" -ForegroundColor Red
        Write-Host '  Укажи правильный путь в BasePython внутри mcp-hub.config.json и повтори setup.'
        return
    }
    Write-Host "  OK: $($cfg.BasePython)" -ForegroundColor Green

    # 3. Определяем LAN IP
    if (-not $cfg.ServerIp) { $cfg.ServerIp = Get-LanIp }
    if (-not $cfg.ServerIp) { $cfg.ServerIp = '127.0.0.1' }

    # 4. Окружения
    Write-Host "`n[3/4] Создаю окружения в $($cfg.BaseDir)" -ForegroundColor Yellow

    foreach ($app in $script:Apps) {
        Write-Host "`n  --- $($app.Name) ($($app.Venv)) ---" -ForegroundColor White
        $venvDir = Join-Path $cfg.BaseDir $app.Venv
        $py = Join-Path $venvDir 'Scripts\python.exe'

        if (-not (Test-Path $py)) {
            Write-Host "  Создаю venv: $venvDir"
            & $cfg.BasePython -m venv $venvDir
            if ($LASTEXITCODE -ne 0) { Write-Host '  ОШИБКА создания venv' -ForegroundColor Red; continue }
        }
        Write-Host "  Устанавливаю пакеты: $($app.Packages -join ', ')"
        & $py -m pip install --upgrade pip | Out-Null
        & $py -m pip install $app.Packages
        & $py -m pip check
        if ($app.PostSetup) { & $app.PostSetup }
    }

    # общий venv с mcp-proxy
    Write-Host "`n  --- mcp-proxy ($script:ProxyVenv) ---" -ForegroundColor White
    $proxyDir = Join-Path $cfg.BaseDir $script:ProxyVenv
    $proxyPy = Join-Path $proxyDir 'Scripts\python.exe'
    if (-not (Test-Path $proxyPy)) {
        Write-Host "  Создаю venv: $proxyDir"
        & $cfg.BasePython -m venv $proxyDir
    }
    & $proxyPy -m pip install --upgrade pip | Out-Null
    & $proxyPy -m pip install mcp-proxy
    & $proxyPy -m pip check

    # 5. Сохраняем конфиг
    Save-HubConfig $cfg

    Write-Host "`n[4/4] Готово" -ForegroundColor Green
    Write-Host ''
    Write-Host "Дальше:" -ForegroundColor Cyan
    Write-Host "  1) запусти приложения (ComfyUI Desktop, Blender + Start MCP Server)"
    Write-Host "  2) .\mcp-hub.ps1 start"
    Write-Host "  3) .\mcp-hub.ps1 status   — проверить всё"
    Write-Host "  4) .\mcp-hub.ps1 config  — как подключить Claude Desktop"
    Write-Host ''
    Write-Host 'Подсказка про firewall (выполни в PowerShell от администратора, подставь IP клиента):' -ForegroundColor DarkGray
    foreach ($app in $script:Apps) {
        Write-Host ("  New-NetFirewallRule -DisplayName 'MCP $($app.Name)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($app.Port) -RemoteAddress <CLIENT_IP> -Profile Private") -ForegroundColor DarkGray
    }
}

# ----------------------------------------------------------------------------
#  START / STOP
# ----------------------------------------------------------------------------

function Invoke-Start {
    $cfg = Read-HubConfig
    $apps = Select-App $AppName
    $proxyExe = Join-Path (Join-Path $cfg.BaseDir $script:ProxyVenv) 'Scripts\mcp-proxy.exe'
    if (-not (Test-Path $proxyExe)) {
        throw "mcp-proxy не найден: $proxyExe. Сначала выполни: .\mcp-hub.ps1 setup"
    }
    if (-not $cfg.ServerIp) { $cfg.ServerIp = Get-LanIp; Save-HubConfig $cfg }

    foreach ($app in $apps) {
        Write-Host ''
        Write-Host "=== Запуск MCP: $($app.Name) ===" -ForegroundColor Cyan

        if (Get-PortOwnerPid -Port $app.Port) {
            Write-Host "  Прокси уже запущен (порт $($app.Port)) — пропускаю" -ForegroundColor Yellow
            continue
        }
        $serverExe = Get-AppServerExe $app $cfg
        if (-not $serverExe) {
            Write-Host "  MCP-сервер не найден в $($cfg.BaseDir)\$($app.Venv). Выполни: .\mcp-hub.ps1 setup" -ForegroundColor Red
            continue
        }

        # переменные окружения для дочернего MCP-сервера
        $env:GIT_PYTHON_GIT_EXECUTABLE = $cfg.GitExe
        if ($app.Id -eq 'comfyui') {
            $env:COMFY_BIN = Join-Path (Join-Path $cfg.BaseDir $app.Venv) 'Scripts\comfy.exe'
            $env:COMFY_LOCAL_URL = $cfg.ComfyUrl
        }

        $host_ = $cfg.ServerIp
        $allowedHost = "$($host_):$($app.Port)"
        Write-Host "  Запускаю mcp-proxy на ${host_}:$($app.Port) -> $serverExe"

        $proc = Start-Process -FilePath $proxyExe `
            -ArgumentList @('--host', $host_, '--port', "$($app.Port)", '--allowed-host', $allowedHost, '--pass-environment', '--', $serverExe) `
            -WindowStyle Minimized -PassThru

        # ждём порт
        $ready = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (Get-PortOwnerPid -Port $app.Port) { $ready = $true; break }
            if ($proc.HasExited) { break }
        }
        if ($ready) {
            Write-Host "  OK: http://${host_}:$($app.Port)/mcp  (PID $($proc.Id))" -ForegroundColor Green
        } else {
            Write-Host "  Прокси не поднялся на порту $($app.Port). Открой свернутое окно mcp-proxy и посмотри ошибки." -ForegroundColor Red
        }
    }
    Write-Host ''
    Write-Host 'Статус: .\mcp-hub.ps1 status' -ForegroundColor DarkGray
}

function Invoke-Stop {
    $apps = Select-App $AppName
    foreach ($app in $apps) {
        $pid_ = Get-PortOwnerPid -Port $app.Port
        if ($pid_) {
            Write-Host "Останавливаю $($app.Name): PID $pid_ (порт $($app.Port))"
            Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "$($app.Name): прокси не запущен (порт $($app.Port))"
        }
    }
}

# ----------------------------------------------------------------------------
#  STATUS — наглядный статус
# ----------------------------------------------------------------------------

function Invoke-Status {
    $cfg = Read-HubConfig
    if (-not $cfg.ServerIp) { $cfg.ServerIp = Get-LanIp }
    $ip = $cfg.ServerIp
    if (-not $ip) { $ip = '127.0.0.1' }

    Write-Host ''
    Write-Host '================ MCP Hub: статус ================' -ForegroundColor Cyan
    Write-Host "  Компьютер: $env:COMPUTERNAME    LAN IP: $ip"

    foreach ($app in $script:Apps) {
        Write-Host ''
        Write-Host ('  ' + $app.Name) -ForegroundColor White
        $url = "http://${ip}:$($app.Port)/mcp"

        # прокси
        $pid_ = Get-PortOwnerPid -Port $app.Port
        Write-Host ('    MCP endpoint    {0,-45}' -f $url) -NoNewline
        if ($pid_) {
            Write-Mark $true; Write-Host "прокси запущен (PID $pid_)"
        } else {
            Write-Mark $false; Write-Host "не запущен  ->  .\mcp-hub.ps1 start $($app.Id)"
        }

        # upstream
        $up = $app.Upstream
        Write-Host ('    {0,-17} {1,-45}' -f $up.Label, ($(if ($up.Kind -eq 'http') { $up.Url } else { "$($up.Host):$($up.Port)" }))) -NoNewline
        $upOk = $false
        if ($up.Kind -eq 'http') { $upOk = Test-HttpStatus -Url $up.Url }
        else { $upOk = Test-TcpPort -Ip $up.Host -Port $up.Port }
        if ($upOk) { Write-Mark $true; Write-Host 'отвечает' }
        else {
            Write-Mark $false; Write-Host 'недоступен'
            Write-Host "      Подсказка: $($app.Hint)" -ForegroundColor DarkYellow
        }
    }

    Write-Host ''
    Write-Host '--------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  Подключение клиента (Claude Desktop и т.п.):' -ForegroundColor Cyan
    foreach ($app in $script:Apps) {
        Write-Host "    $($app.Name):  http://${ip}:$($app.Port)/mcp"
    }
    Write-Host '  Готовые конфиги:  .\mcp-hub.ps1 config'
    if ($cfg.ClientIp) {
        Write-Host "  Firewall: разрешите порты только с $($cfg.ClientIp) (команды в выводе setup/config)"
    } else {
        Write-Host '  Firewall: открывай порты только для IP клиента, не для всей сети' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ----------------------------------------------------------------------------
#  CONFIG — как подключиться
# ----------------------------------------------------------------------------

function Invoke-Config {
    $cfg = Read-HubConfig
    if (-not $cfg.ServerIp) { $cfg.ServerIp = Get-LanIp }
    $ip = $cfg.ServerIp
    if (-not $ip) { $ip = '<SERVER_IP>' }

    Write-Host ''
    Write-Host '================ Как подключиться ================' -ForegroundColor Cyan

    # --- вариант 1: Claude Desktop на ДРУГОМ компьютере (Linux/Windows) ---
    Write-Host ''
    Write-Host 'ВАРИАНТ 1 — Claude Desktop на другом компьютере (твой случай: Linux)' -ForegroundColor Yellow
    Write-Host 'На клиенте нужен mcp-proxy (pip install mcp-proxy), затем фрагмент для'
    Write-Host 'claude_desktop_config.json (Linux: ~/.config/Claude/claude_desktop_config.json):'
    Write-Host ''
    $blocks = @()
    foreach ($app in $script:Apps) {
        $lines = @(
            ('    "' + $app.Id + '": {'),
            '      "command": "/home/USER/.venvs/mcp-hub-client/bin/mcp-proxy",',
            ('      "args": ["--transport", "streamablehttp", "http://' + $ip + ':' + $app.Port + '/mcp"]'),
            '    }'
        )
        $blocks += ($lines -join "`n")
    }
    $body = ($blocks -join ",`n")
    $json = "{`n  `"mcpServers`": {`n$body`n  }`n}"
    Write-Host $json -ForegroundColor Green
    Write-Host ''
    Write-Host 'Пути /home/USER/... замени на фактический путь mcp-proxy на клиенте.'

    # --- вариант 2: Claude Desktop на ЭТОМ же компьютере ---
    Write-Host ''
    Write-Host 'ВАРИАНТ 2 — Claude Desktop на этом же Windows-компьютере' -ForegroundColor Yellow
    Write-Host 'Можно подключиться к прокси напрямую (локальный stdio не нужен):'
    Write-Host ''
    foreach ($app in $script:Apps) {
        Write-Host ('    ' + $app.Name + ':  http://' + $ip + ':' + $app.Port + '/mcp') -ForegroundColor Green
    }

    # --- firewall ---
    Write-Host ''
    Write-Host 'FIREWALL (PowerShell от администратора, подставь IP клиента):' -ForegroundColor Yellow
    foreach ($app in $script:Apps) {
        Write-Host ("  New-NetFirewallRule -DisplayName 'MCP $($app.Name)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($app.Port) -RemoteAddress <CLIENT_IP> -Profile Private")
    }
    Write-Host ''
    Write-Host 'Не открывай порты всему интернету: прокси не аутентифицирует клиентов.'
    Write-Host 'Для доступа извне LAN используй VPN.'
    Write-Host ''
}

# ----------------------------------------------------------------------------
#  DISPATCH
# ----------------------------------------------------------------------------

switch ($Command.ToLower()) {
    'setup'  { Invoke-Setup }
    'start'  { Invoke-Start }
    'stop'   { Invoke-Stop }
    'status' { Invoke-Status }
    'config' { Invoke-Config }
    'help'   {
        Write-Host ''
        Write-Host 'MCP Hub — управление MCP-серверами (ComfyUI, Blender, ...)' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  .\mcp-hub.ps1 setup            установка и настройка всего'
        Write-Host '  .\mcp-hub.ps1 start [app]       запуск прокси (comfyui | blender | все)'
        Write-Host '  .\mcp-hub.ps1 stop  [app]       остановка'
        Write-Host '  .\mcp-hub.ps1 status            наглядный статус и адреса'
        Write-Host '  .\mcp-hub.ps1 config            конфиги для подключения клиента'
        Write-Host ''
        Write-Host "Приложения: $(($script:Apps | ForEach-Object Id) -join ', ')"
        Write-Host 'Новое приложение добавляется блоком в реестре $script:Apps в начале скрипта.'
        Write-Host ''
    }
    default {
        throw "Неизвестная команда: $Command. Доступно: setup, start, stop, status, config, help"
    }
}
