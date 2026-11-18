# MCP Hub

Windows-утилита, которая ставит, запускает и мониторит MCP-серверы
**ComfyUI** и **Blender**, показывает их статус и генерирует конфиги
подключения для клиентов (Claude Desktop, Cursor и др.).

Сценарий: ComfyUI и Blender работают на Windows-машине с видеокартой,
Claude Desktop — на другом компьютере (Linux/macOS), в домашней сети
или через Tailscale из любой точки мира.

## Быстрый старт

### Что нужно заранее

На Windows-машине (сервер):

- Windows 10/11 — PowerShell 5.1 и .NET Framework уже встроены;
- [Git for Windows](https://git-scm.com/install/windows) — нужен для
  comfy-cli и MCP-сервера Blender;
- работающие ComfyUI и/или Blender.

На машине с Claude Desktop (клиент):

- Python 3;
- Linux: `sudo apt install cifs-utils smbclient` — если нужна шара
  референсов (на macOS всё встроено);
- [Tailscale](https://tailscale.com) на обеих машинах — если нужен
  доступ вне домашней сети.

### Шаг 1. Настрой Blender (один раз)

1. Blender 5.1+ → Edit → Preferences → Get Extensions → **MCP**
   (Blender Lab) → Install.
2. Edit → Preferences → **System → Network → Allow Online Access** —
   без этого сервер аддона не стартует.
3. Add-ons → **MCP** → **Start MCP Bridge Server** — статус сменится на
   «Server is running». Галочка **Auto Start** будет запускать сервер
   вместе с Blender.

Не ставь community-аддон ahujasid (BlenderMCP) — тот же порт 9876, но
другой протокол, с официальным несовместим.

### Шаг 2. Запусти mcp-hub на Windows

Двойной клик по `mcp-hub.exe` — авто-режим (установка → запуск →
статус), окно ждёт Enter. Или по шагам:

```powershell
.\mcp-hub.exe setup     # окружения и конфиг; первый раз — несколько минут
.\mcp-hub.exe start     # прокси: 8000 (ComfyUI), 8001 (Blender)
.\mcp-hub.exe status    # проверить всё
```

Первый запуск Blender-прокси может занять 1–2 минуты (сервер грузит
документацию API) — mcp-hub ждёт до 3 минут и показывает прогресс.

### Шаг 3. Подключи Claude Desktop

На клиенте один раз:

```bash
python3 -m venv ~/.venvs/mcp-hub-client
~/.venvs/mcp-hub-client/bin/pip install mcp-proxy
```

Выполни на Windows `.\mcp-hub.exe config` и скопируй напечатанный
фрагмент в `~/.config/Claude/claude_desktop_config.json` — там уже
правильные адреса и Bearer-токен. Перезапусти Claude Desktop. Вид
фрагмента:

```json
{
  "mcpServers": {
    "comfyui": {
      "command": "/home/USER/.venvs/mcp-hub-client/bin/mcp-proxy",
      "args": ["--transport", "streamablehttp", "--headers", "Authorization",
               "Bearer <TOKEN>", "http://192.168.1.50:8000/mcp"]
    }
  }
}
```

`<TOKEN>` — значение `AuthToken` из `mcp-hub.config.json` на сервере.

### Шаг 4 (опционально). Доступ из любой сети

Поставь Tailscale на обе машины и войди в один аккаунт — больше ничего
делать не нужно. mcp-hub сам определит tailnet-адрес при `start`, а
`config` напечатает фрагмент уже с ним. Порт на роутере не
открывается, трафик шифруется (WireGuard), каждый запрос проверяется
по Bearer-токену. Подключение по MagicDNS-имени — впиши имя в
`AllowedHosts` конфига.

### Шаг 5 (опционально). Шара референсов

Для генерации по референсам клиенту нужна папка с Windows-машины.
Поделись папкой (ПКМ → Свойства → Доступ) и на клиенте запусти:

```bash
sudo python3 comfy-mount.py   # спросит адрес, шару, логин/пароль (Enter = значение по умолчанию)
```

Утилита проверит Tailscale, сохранит креды с правами 600, смонтирует
шару и напечатает готовую строку для `/etc/fstab`. Подробности — в
разделе «comfy-mount» ниже.

## Команды

| Команда          | Что делает                                              |
|------------------|---------------------------------------------------------|
| (без аргументов) | авто-режим: установка → запуск всех прокси → статус     |
| `setup`          | venv-окружения, пакеты, настройка `comfy-cli`           |
| `start [app]`    | запустить `mcp-proxy` (comfyui, blender или все)        |
| `stop [app]`     | остановить прокси                                       |
| `status`         | статус: прокси, ComfyUI API, аддон Blender, адреса      |
| `config`         | конфиги для Claude Desktop + команды firewall           |

ps1 и exe взаимозаменяемы:

```powershell
powershell -ExecutionPolicy Bypass -File .\mcp-hub.ps1 setup
.\mcp-hub.exe setup
```

## Как это устроено

- Три раздельных venv в `BaseDir` (конфликт версий пакета `mcp` не даёт
  держать всё в одном окружении): `comfy-mcp-env`, `blender-mcp-env`
  (официальный сервер Blender Lab из git) и `mcp-proxy-env`.
- `mcp-proxy` превращает локальные stdio MCP-серверы в HTTP-эндпоинты:
  ComfyUI — порт 8000, Blender — 8001. При `BindAll` прокси слушает все
  интерфейсы сразу — и LAN, и Tailscale.
- `comfy-cli` настраивается на существующую установку ComfyUI
  (`comfy set-default`), новая не создаётся.
- Логи прокси пишутся в `logs/<app>-err.log` рядом с exe; при падении
  mcp-hub сам печатает хвост лога и traceback MCP-сервера.
- exe — C#-обёртка (`src/Program.cs`, .NET Framework, без
  зависимостей) со встроенным `mcp-hub.ps1`: распаковывает скрипт во
  временную папку и запускает через PowerShell.

Пример вывода `status`:

```text
================ MCP Hub: статус ================
  Компьютер: DESKTOP-RTX    LAN IP: 192.168.1.50

  ComfyUI
    MCP endpoint    http://192.168.1.50:8000/mcp            [OK] прокси запущен
    ComfyUI API     http://127.0.0.1:8188/system_stats    [OK] отвечает

  Blender
    MCP endpoint    http://192.168.1.50:8001/mcp            [OK] прокси запущен
    Blender addon   127.0.0.1:9876                          [OK] отвечает
```

## Конфигурация

`mcp-hub.config.json` создаётся рядом с exe при первом запуске (в
`.gitignore` — содержит адреса и токен конкретной машины).

| Ключ            | Назначение                                                       |
|-----------------|------------------------------------------------------------------|
| `BaseDir`       | где создавать venv-окружения                                     |
| `ComfyWorkspace`| путь к установке ComfyUI для `comfy set-default`                 |
| `BasePython`    | Python для создания venv (подойдёт venv ComfyUI)                 |
| `GitExe`        | путь к `git.exe`                                                 |
| `ComfyUrl`      | адрес локального ComfyUI (порт из логов запуска)                 |
| `ServerIp`      | IP этого компьютера в LAN (определяется сам)                     |
| `TailscaleIp`   | адрес в tailnet `100.x.y.z` (определяется сам при наличии Tailscale) |
| `ClientIp`      | IP клиента с Claude Desktop (для подсказок firewall)             |
| `BindAll`       | `true` — слушать все интерфейсы (LAN + Tailscale)                |
| `AllowedHosts`  | доп. Host-авторитеты mcp-proxy (имена/IP, с портом или без)      |
| `AuthToken`     | Bearer-токен (генерируется автоматически)                        |
| `NoAuth`        | `true` — отключить проверку токена (не рекомендуется)            |

## Firewall и безопасность

Три линии защиты: **Bearer-токен** (каждый запрос к прокси проверяется,
клиент передаёт его в заголовке `Authorization`) → **firewall Windows**
(порты 8000/8001 — только IP клиента, 445/SMB — только tailnet) →
**Tailscale** (WireGuard-шифрование, порт на роутере не открывается).

PowerShell от администратора:

```powershell
# MCP-порты — только компьютеру с Claude
New-NetFirewallRule -DisplayName 'MCP ComfyUI' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8000 -RemoteAddress <CLIENT_IP> -Profile Private
New-NetFirewallRule -DisplayName 'MCP Blender' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8001 -RemoteAddress <CLIENT_IP> -Profile Private

# SMB (шара референсов) — только из tailnet
New-NetFirewallRule -DisplayName 'SMB for Tailscale' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 445 -RemoteAddress 100.64.0.0/10
```

Важно:

- у учётки Windows для SMB должен быть задан пароль — учётки без пароля
  сетевой доступ не проходят;
- `"NoAuth": true` отключает токен — не делай так, если прокси доступен
  дальше доверенной сети: MCP-серверы (особенно Blender) выполняют код
  на машине;
- отзыв доступа: удали `AuthToken` из конфига и перезапусти `start` —
  сгенерируется новый.

## Диагностика

| Симптом | Причина и лечение |
|---------|-------------------|
| Прокси Blender стартует 1–2 минуты | Норма: первый запуск грузит документацию API. mcp-hub ждёт до 3 минут и пишет `OK (стартовал за N c)` |
| Прокси упал | Хвост `logs/<app>-err.log` и traceback MCP-сервера mcp-hub печатает сам |
| Ошибка про пакет `mcp` после установки mcp-proxy в окружение сервера | Конфликт версий — серверы и прокси в раздельных venv (mcp-hub делает это сам) |
| comfy-cli: `Bad git executable` | Поставь Git for Windows, путь подхватится сам |
| Blender: «Online access must be enabled» | Preferences → System → Network → **Allow Online Access** |
| Два MCP-аддона ругаются на порт 9876 | Оставь только официальный Blender Lab |
| Клиент получает 401/403 | Токен не совпадает — возьми свежий фрагмент из `config` |
| `mount error(112): Host is down` | Файрвол режет 445 (команда в выводе comfy-mount); попробуй `--vers 3.1.1` |
| Шара не монтируется после перезагрузки | Используй строку fstab из вывода comfy-mount (`x-systemd.automount`) |
| SmartScreen не даёт запустить exe | «Подробнее» → «Выполнить в любом случае», либо ps1-версия |

## comfy-mount: подключение SMB-шары (Linux/macOS)

Однофайловая утилита на Python 3 без зависимостей:

```bash
sudo python3 comfy-mount.py            # интерактивно, Enter = значение по умолчанию
sudo python3 comfy-mount.py --yes      # без вопросов
sudo python3 comfy-mount.py --unmount  # отключить шару
```

Что делает:

1. `tailscale ping` до сервера — проверяет туннель;
2. сохраняет учётные данные с правами 600 (Linux:
   `/etc/cifs-credentials`, macOS: `/etc/nsmb.conf`) — пароль не
   светится в истории shell и в `ps`;
3. проверяет видимость шары (`smbclient` / `smbutil`);
4. монтирует с uid/gid твоего пользователя, печатает строку для
   `/etc/fstab` с `x-systemd.automount` — шара вернётся после
   перезагрузки при первом обращении, когда Tailscale уже поднят.

Любая ошибка — с диагнозом и способом лечения: недоступный Tailscale,
файрвол Windows на 445 (готовая PowerShell-команда), неверный
логин/пароль, опечатка в имени шары, отсутствие `cifs-utils`, версия
SMB. Значения по умолчанию — в словаре `DEFAULTS` в начале файла.
Свои пароли в публичные репозитории не клади.

## Как добавить приложение

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

`setup`/`start`/`status`/`config` подхватят новое приложение
автоматически.

## Сборка exe

```powershell
# Windows (штатный csc .NET Framework)
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

```bash
# Linux (mono)
sudo apt-get install -y mono-mcs && ./build.sh
```

Результат: `dist/mcp-hub.exe`. Изменил `mcp-hub.ps1` — пересобери.

- SmartScreen предупредит о неподписанном файле: «Подробнее» →
  «Выполнить в любом случае».
- PowerShell 7: `set MCP_HUB_PWSH=pwsh.exe` перед запуском.

## Структура проекта

```text
mcp-hub/
├── mcp-hub.ps1         # вся логика + реестр приложений
├── client/comfy-mount.py  # CLI для Linux/macOS: SMB-шара через Tailscale
├── src/Program.cs      # C#-обёртка: ps1 в один exe
├── assets/mcp-hub.ico
├── build.ps1 / build.sh
└── dist/               # результат сборки (в .gitignore)
```
