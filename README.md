# MCP Hub

Инструмент для Windows, который ставит, настраивает, запускает и
мониторит MCP-серверы для **ComfyUI** и **Blender** (список расширяется),
показывает их статус и генерирует конфиги подключения для клиентов
(Claude Desktop, Cursor и др.).

Сценарий, под который сделан инструмент: ComfyUI и Blender работают на
Windows-компьютере с видеокартой, а Claude Desktop запущен на другом
компьютере (например, на Linux) и подключается по локальной сети.

## Структура проекта

```text
mcp-hub/
├── mcp-hub.ps1      # основной скрипт: вся логика + реестр приложений
├── client/
│   └── comfy-mount.py  # CLI для Linux/macOS: SMB-шара референсов через Tailscale
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
| (без аргументов)     | **авто-режим**: установка если нужно → запуск всех прокси → статус |
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

Проще всего — двойной клик по `mcp-hub.exe`: запустится авто-режим,
который ставит окружения (если их ещё нет), поднимает прокси для всех
приложений и показывает итоговый статус. Окно не закроется, пока не
нажмёшь Enter. Конфиг `mcp-hub.config.json` создаётся рядом с exe при
первом же запуске.

Заметь: если окружения ещё не созданы, первый запуск займёт несколько
минут (создание venv и pip install).

1. На Windows-компьютере с ComfyUI/Blender — двойной клик по
   `mcp-hub.exe` (или то же самое по шагам):

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
  - `blender-mcp-env` — официальный MCP-сервер Blender Lab из git;
  - `mcp-proxy-env` — `mcp-proxy`.
- `comfy-cli` настраивается на существующую установку ComfyUI
  (`comfy set-default`), новая установка не создаётся.
- `mcp-proxy` превращает локальные stdio MCP-серверы в HTTP-эндпоинты
  локальной сети: ComfyUI — порт 8000, Blender — 8001.

## Blender: ручные шаги в самом Blender

mcp-hub ставит официальный MCP-сервер [Blender Lab](https://projects.blender.org/lab/blender_mcp)
(из git-репозитория, поэтому для Blender нужен Git for Windows). Аддон
в Blender ставится и запускается руками:

1. **Аддон**: Blender 5.1+ → Edit → Preferences → Get Extensions →
   найди **MCP** (Blender Lab) → Install. Либо скачай zip со страницы
   [blender.org/lab/mcp-server](https://www.blender.org/lab/mcp-server/)
   и установи через Install from Disk.
2. **Разрешение сети**: Edit → Preferences → **System → Network →
   Allow Online Access**. Без этого кнопка запуска выдаёт
   «Online access must be enabled in the system preferences» — аддон
   открывает порт только на этом же компьютере, но правило Blender
   требует включить переключатель.
3. **Запуск**: Edit → Preferences → Add-ons → **MCP** → **Start MCP
   Bridge Server**. Статус должен смениться на «Server is running».
   Галочка **Auto Start** запускает сервер автоматически при старте
   Blender. Аддон слушает `localhost:9876`.

Важно: не ставь community-аддон ahujasid (BlenderMCP / MCP for
Blender) вместе с официальным — оба используют порт 9876, но говорят
на разных протоколах. Если он был установлен раньше — отключи его.

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
подставь свои; точный вариант с реальным токеном печатает `config`):

```json
{
  "mcpServers": {
    "comfyui": {
      "command": "/home/USER/.venvs/mcp-hub-client/bin/mcp-proxy",
      "args": ["--transport", "streamablehttp", "--headers", "Authorization", "Bearer <TOKEN>",
               "http://192.168.1.50:8000/mcp"]
    },
    "blender": {
      "command": "/home/USER/.venvs/mcp-hub-client/bin/mcp-proxy",
      "args": ["--transport", "streamablehttp", "--headers", "Authorization", "Bearer <TOKEN>",
               "http://192.168.1.50:8001/mcp"]
    }
  }
}
```

`<TOKEN>` — значение `AuthToken` из `mcp-hub.config.json` на
Windows-машине. Если `NoAuth: true`, заголовки можно убрать.

## Firewall и безопасность

Три линии защиты, изнутри наружу:

1. **Bearer-токен.** Каждый входящий HTTP-запрос к прокси проверяется по
   токену (генерируется автоматически при первом `start`, хранится в
   `AuthToken` конфига). Клиент передаёт его в заголовке
   `Authorization: Bearer <TOKEN>` — готовый фрагмент печатает `config`.
   Токен лежит в `mcp-hub.config.json`, который в `.gitignore`.
2. **Firewall Windows.** Порты 8000/8001 открывай только для IP клиента,
   а 445 (SMB) — только для tailnet (PowerShell от администратора):

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

3. **Tailscale.** Доступ извне домашней сети — только через tailnet
   (WireGuard-шифрование, порт на роутере не открывается). См. раздел
   «Доступ откуда угодно через Tailscale».

Дополнительно:

- у учётной записи Windows, под которой ходит SMB, должен быть
  **нормальный пароль** — учётки без пароля сетевой доступ не проходят;
- `"NoAuth": true` отключает проверку токена — не делай так, если прокси
  доступен дальше доверенной сети: MCP-серверы (особенно Blender)
  выполняют код на машине;
- для отзыва доступа просто удали `AuthToken` из конфига и перезапусти
  `start` — сгенерируется новый.

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
| `TailscaleIp`   | адрес в tailnet `100.x.y.z` (определяется сам, если стоит Tailscale) |
| `ClientIp`      | IP компьютера с Claude Desktop (для подсказок)      |
| `BindAll`       | `true` — слушать все интерфейсы (LAN + Tailscale одновременно) |
| `AllowedHosts`  | дополнительные Host-авторитеты mcp-proxy (имена/IP, с портом или без) |
| `AuthToken`     | Bearer-токен для входящих запросов (генерируется автоматически) |
| `NoAuth`        | `true` — отключить проверку токена (не рекомендуется) |

## Доступ откуда угодно через Tailscale

Прокси по умолчанию доступен только в локальной сети. Чтобы подключаться
из любой сети (с работы, из кафе, из другой страны), поставь
[Tailscale](https://tailscale.com) на оба компьютера и войди в один
аккаунт:

- Windows-машина с mcp-hub получает адрес вида `100.x.y.z`;
- Linux-ноутбук с Claude Desktop — свой `100.x.y.z`.

Дальше ничего настраивать не нужно: mcp-hub сам определит Tailscale-адрес
при `start`, прокси начнёт принимать подключения из tailnet, а команда
`config` напечатает фрагмент для Claude Desktop уже с tailnet-адресом и
Bearer-токеном (клиентский mcp-proxy передаёт его в заголовке
`Authorization`).

Что даёт эта схема:

- порт на роутере **не открывается** — входящих соединений извне нет;
- трафик шифруется (WireGuard), доступ есть только у твоих устройств;
- каждый запрос проверяется по Bearer-токену (вторая линия защиты).

Если хочешь добавить подключение по MagicDNS-имени (например
`myhost.tailnet-xyz.ts.net`), впиши его в `AllowedHosts` в конфиге.

Отключить проверку токена можно ключом `"NoAuth": true` — но тогда не
открывай прокси дальше доверенной сети: MCP-серверы (особенно Blender)
выполняют код на машине.

## Шара референсов по SMB: comfy-mount (Linux/macOS)

Для генерации изображений по референсам клиенту нужен доступ к папке
на Windows-машине. `client/comfy-mount.py` — однофайловая утилита на
Python 3 (без зависимостей), которая подключает SMB-шару через
Tailscale:

```bash
sudo python3 comfy-mount.py            # интерактивно, Enter оставляет значение по умолчанию
sudo python3 comfy-mount.py --yes      # без вопросов
sudo python3 comfy-mount.py --unmount  # отключить шару
```

Что делает:

1. `tailscale ping` до сервера — проверяет туннель;
2. сохраняет учётные данные в файл с правами 600
   (Linux: `/etc/cifs-credentials`, macOS: `/etc/nsmb.conf`) — пароль
   не светится в истории shell и в `ps`;
3. проверяет видимость шары (`smbclient` / `smbutil`);
4. монтирует шару с uid/gid твоего пользователя и показывает файлы.

Каждая ошибка сопровождается диагнозом и способом лечения: недоступный
Tailscale, файрвол Windows на порту 445 (готовая PowerShell-команда),
неверный логин/пароль, опечатка в имени шары, отсутствие `cifs-utils`,
проблемы версии SMB. В конце печатает готовую строку для `/etc/fstab`
с `x-systemd.automount` — шара монтируется после перезагрузки при
первом обращении, когда Tailscale уже поднят.

Значения по умолчанию (адрес, имя шары, пользователь) заданы в начале
файла в словаре `DEFAULTS` — поменяй под себя. Свои пароли в публичные
репозитории не клади.

## Диагностика

| Симптом | Причина и лечение |
|---------|-------------------|
| Прокси Blender стартует минуту-две, mcp-hub раньше писал «не поднялся» | Первый запуск Blender-сервера грузит корпус документации API — mcp-hub теперь ждёт до 3 минут с прогрессом и пишет `OK (стартовал за N c)` |
| Прокси упал: что случилось | Вывод прокси пишется в `logs/<app>-err.log` рядом с exe; при падении mcp-hub сам печатает хвост лога и запускает MCP-сервер напрямую, чтобы показать traceback |
| comfy-mcp падает с ошибкой про `mcp` после установки mcp-proxy в то же окружение | Конфликт версий пакета `mcp` — держи серверы и прокси в **раздельных venv** (mcp-hub делает это сам) |
| comfy-cli: `Bad git executable` / ImportError git | Не найден `git.exe` — поставь Git for Windows, путь подхватится автоматически |
| Blender: кнопка запуска серая или ошибка «Online access must be enabled» | Edit → Preferences → System → Network → **Allow Online Access** |
| Два аддона MCP в Blender ругаются на занятый порт 9876 | Оставь только официальный Blender Lab; community-аддон ahujasid использует тот же порт, но другой протокол |
| Клиент получает 401/403 от прокси | Токен не совпадает: возьми свежий фрагмент из `mcp-hub.exe config` |
| `mount error(112): Host is down` при монтировании шары | Файрвол Windows режет 445 — команда для правила в выводе comfy-mount; также попробуй `--vers 3.1.1` |
| После перезагрузки Linux шара не смонтировалась | Используй строку fstab из вывода comfy-mount (с `x-systemd.automount`), а не статический mount |
| SmartScreen не даёт запустить exe | «Подробнее» → «Выполнить в любом случае», либо используй ps1-версию |

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

Сервер (Windows):

- Windows 10/11, PowerShell 5.1 (встроен), .NET Framework 4.x (встроен).
- Git for Windows (для comfy-cli и сервера Blender Lab).
- Работающий ComfyUI / Blender — MCP лишь подключается к ним.

Клиент (Linux/macOS):

- Python 3 (для venv с `mcp-proxy` и для `comfy-mount.py`).
- `cifs-utils` + `smbclient` (Linux) — для монтирования шары; на macOS
  всё нужное встроено.
- Tailscale — если нужен доступ вне домашней сети (и MCP, и SMB-шара).
