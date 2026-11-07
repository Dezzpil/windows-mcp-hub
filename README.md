# MCP Hub

Инструмент для Windows, который ставит, настраивает, запускает и
мониторит MCP-серверы для **ComfyUI** и **Blender** (список расширяется),
показывает их статус и генерирует конфиги подключения для клиентов
(Claude Desktop, Cursor и др.).

Сценарий, под который сделан инструмент: ComfyUI и Blender работают на
Windows-компьютере с видеокартой, а Claude Desktop запущен на другом
компьютере (например, на Linux) и подключается по локной сети.

## Структура проекта

```text
mcp-hub/
├── mcp-hub.ps1      # основной скрипт: вся логика + реестр приложений
├── src/
│   └── Program.cs   # C#-обёртка: упаковывает ps1 в один exe
├── assets/
│   └── mcp-hub.ico  # иконка exe
├── build.ps1        # сборка exe на Windows (штатный csc, без зависимостей)
├── build.sh         # сборка exe на Linux (mono-mcs)
├── dist/            # результат сборки (в .gitignore)
└── README.md
```

## Команды

| Команда              | Что делает                                        |
|----------------------|---------------------------------------------------|
| `setup`              | проверяет Git/Python, создаёт venv-окружения, ставит пакеты, настраивает `comfy-cli` |
| `start [app]`        | запускает `mcp-proxy` для приложений (по сети)    |
| `stop [app]`         | останавливает прокси                               |
| `status`             | наглядный статус: прокси, ComfyUI API, аддон Blender, адреса |
| `config`             | готовые конфиги для Claude Desktop + firewall      |

Использование — ps1 или exe (одно и то же):

```powershell
powershell -ExecutionPolicy Bypass -File .\mcp-hub.ps1 setup
# или
.\mcp-hub.exe setup
```

## Быстрый старт

1. На Windows-компьютере с ComfyUI/Blender:

   ```powershell
   .\mcp-hub.exe setup        # создаст окружения и конфиг
   .\mcp-hub.exe start        # поднимет прокси (8000, 8001)
   .\mcp-hub.exe status       # проверить всё
   ```

2. Запусти сами приложения:
   - **ComfyUI** — обычный запуск через Desktop;
   - **Blender** — включи аддон (см. ниже) и нажми Start MCP Server.

3. На компьютере с Claude Desktop (Linux) добавь серверы в
   `~/.config/Claude/claude_desktop_config.json` — готовый фрагмент
   печатает `mcp-hub.exe config`. Перезапусти Claude Desktop.

## Что делает setup под капотом

- Три раздельных venv (конфликт версий пакета `mcp` не даёт держать всё
  в одном окружении):
  - `comfy-mcp-env` — `comfy-mcp` + `comfy-cli`;
  - `blender-mcp-env` — `blender-mcp` (сейчас называется `mcp-for-blender`);
  - `mcp-proxy-env` — `mcp-proxy`.
- `comfy-cli` настраивается на существующую установку ComfyUI
  (`comfy set-default`), новая установка не создаётся.
- `mcp-proxy` превращает локальные stdio MCP-серверы в HTTP-эндпоинты
  локальной сети: ComfyUI — порт 8000, Blender — 8001.

## Blender: ручной шаг

Аддон нельзя поставить за тебя — в Blender:

1. `uvx blender-mcp install-addon` (или скачай `addon.py` из репозитория
   ahujasid/mcp-for-blender).
2. Edit → Preferences → Add-ons → включи **MCP for Blender**.
3. В 3D-вьюпорте нажми `N` → вкладка MCP → **Start MCP Server**
   (аддон слушает `localhost:9876`).

`status` напомнит об этом, если порт 9876 не отвечает.

## Пример вывода status

```text
================ MCP Hub: статус ================
  Компьютер: DESKTOP-RTX    LAN IP: 192.168.1.50

  ComfyUI
    MCP endpoint    http://192.168.1.50:8000/mcp            [OK] прокси запущен (PID 4212)
    ComfyUI API     http://127.0.0.1:8188/system_stats    [OK] отвечает

  Blender
    MCP endpoint    http://192.168.1.50:8001/mcp            [DOWN] не запущен -> start blender
    Blender addon     127.0.0.1:9876                          [DOWN] недоступен
      Подсказка: в Blender включи аддон "MCP for Blender" и нажми Start MCP Server

--------------------------------------------------
  Подключение клиента (Claude Desktop и т.п.):
    ComfyUI:  http://192.168.1.50:8000/mcp
    Blender:  http://192.168.1.50:8001/mcp
```

## Подключение Claude Desktop (Linux)

На клиенте один раз:

```bash
python3 -m venv ~/.venvs/mcp-hub-client
~/.venvs/mcp-hub-client/bin/pip install mcp-proxy
```

Фрагмент для `~/.config/Claude/claude_desktop_config.json` (пути
подставь свои; точный вариант печатает `config`):

```json
{
  "mcpServers": {
    "comfyui": {
      "command": "/home/USER/.venvs/mcp-hub-client/bin/mcp-proxy",
      "args": ["--transport", "streamablehttp", "http://192.168.1.50:8000/mcp"]
    },
    "blender": {
      "command": "/home/USER/.venvs/mcp-hub-client/bin/mcp-proxy",
      "args": ["--transport", "streamablehttp", "http://192.168.1.50:8001/mcp"]
    }
  }
}
```

## Firewall и безопасность

Прокси **не аутентифицирует** клиентов. Открывай порты только для IP
компьютера с Claude (PowerShell от администратора):

```powershell
New-NetFirewallRule -DisplayName 'MCP ComfyUI' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8000 -RemoteAddress <CLIENT_IP> -Profile Private
New-NetFirewallRule -DisplayName 'MCP Blender' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8001 -RemoteAddress <CLIENT_IP> -Profile Private
```

Для доступа извне домашней сети — VPN, а не открытые порты.

## Конфигурация

`mcp-hub.config.json` создаётся рядом со скриптом/exe при `setup`
(в `.gitignore`, т.к. содержит пути и IP конкретной машины):

| Ключ            | Назначение                                          |
|-----------------|-----------------------------------------------------|
| `BaseDir`       | где создавать venv-окружения (по умолчанию `D:\Comfy-Desktop`) |
| `ComfyWorkspace`| путь к установке ComfyUI для `comfy set-default`    |
| `BasePython`    | Python, из которого создаются venv (venv ComfyUI)   |
| `GitExe`        | путь к `git.exe` для comfy-cli                      |
| `ComfyUrl`      | адрес локального ComfyUI (порт из логов запуска)    |
| `ServerIp`      | IP этого компьютера в LAN (определяется сам)        |
| `ClientIp`      | IP компьютера с Claude Desktop (для подсказок)      |

## Как добавить новое приложение

В начале `mcp-hub.ps1` есть реестр `$script:Apps`. Скопируй любой блок:

```powershell
@{
    Id        = 'myapp'            # аргумент: start myapp
    Name      = 'My App'
    Port      = 8002               # порт mcp-proxy
    Venv      = 'myapp-mcp-env'    # отдельное окружение
    Packages  = @('myapp-mcp')     # pip-пакеты
    ServerExe = @('myapp-mcp.exe') # exe в Scripts окружения
    Env       = @{}                # переменные окружения MCP-сервера
    Upstream  = @{ Kind = 'tcp'; Host = '127.0.0.1'; Port = 1234; Label = 'My App' }
    Hint      = 'Что проверить, если недоступно'
    PostSetup = {}
}
```

После этого `setup`/`start`/`status`/`config` подхватят новое приложение
автоматически, а `config` включит его в конфиг для клиента.

## Сборка exe

exe — это `src/Program.cs` (C#, .NET Framework, без зависимостей) со
встроенным `mcp-hub.ps1`. При запуске скрипт распаковывается во
временную папку и выполняется через PowerShell с обходом
ExecutionPolicy; конфиг создаётся рядом с exe (через `MCP_HUB_HOME`).

Windows (штатный компилятор .NET Framework):

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Linux (mono):

```bash
sudo apt-get install -y mono-mcs
./build.sh
```

Результат: `dist/mcp-hub.exe`. Изменил `mcp-hub.ps1` — просто
пересобери.

### Замечания к exe

- Windows SmartScreen предупредит о неподписанном файле: «Подробнее» →
  «Выполнить в любом случае». Некоторые антивирусы настороженно
  относятся к обёрткам над скриптами — тогда используй ps1-версию.
- Хочешь запускать через PowerShell 7: `set MCP_HUB_PWSH=pwsh.exe`.

## Требования

- Windows 10/11, PowerShell 5.1 (встроен), .NET Framework 4.x (встроен).
- Git for Windows (для comfy-cli).
- Работающий ComfyUI / Blender — MCP лишь подключается к ним.
