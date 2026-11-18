#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
comfy-mount — подключение SMB-шары ComfyUI-Shared с Windows-машины
к Linux или macOS через Tailscale.

Что делает:
  [1/4] проверяет связность с сервером (tailscale ping)
  [2/4] создаёт файл учётных данных с правами 600
        (Linux: /etc/cifs-credentials, macOS: /etc/nsmb.conf)
  [3/4] проверяет видимость шары (smbclient / smbutil)
  [4/4] монтирует шару и проверяет, что файлы читаются

Использование:
  sudo ./comfy-mount.py              # интерактивно, все вопросы со значениями по умолчанию
  sudo ./comfy-mount.py --yes        # без вопросов, только значения по умолчанию
  sudo ./comfy-mount.py --unmount    # отключить шару
"""

import argparse
import getpass
import os
import platform
import pwd
import shutil
import subprocess
import sys

# ----------------------------------------------------------------------------
#  Значения по умолчанию (шара ComfyUI-Shared; адрес подставь свой)
# ----------------------------------------------------------------------------

DEFAULTS = {
    "server":   "100.x.y.z",         # Tailscale-адрес Windows-машины: tailscale ip -4
    "share":    "ComfyUI-Shared",
    "mount":    "/mnt/comfy",
    "user":     "comfy",
    "password": "",                  # пусто = спросит интерактивно (рекомендуется)
    "domain":   "",
    "vers":     "3.0",               # версия SMB (Linux)
}

CRED_FILE_LINUX = "/etc/cifs-credentials"
CRED_FILE_MAC = "/etc/nsmb.conf"

FIREWALL_PS = (
    'New-NetFirewallRule -DisplayName "SMB for Tailscale" -Direction Inbound '
    "-Protocol TCP -LocalPort 445 -RemoteAddress 100.64.0.0/10 -Action Allow"
)

# ----------------------------------------------------------------------------
#  Вывод
# ----------------------------------------------------------------------------

def _colorized():
    return sys.stdout.isatty() and "NO_COLOR" not in os.environ

def _c(code, s):
    return "\033[%sm%s\033[0m" % (code, s) if _colorized() else s

def ok(msg):      print(_c("32", "[ OK ] ") + msg)
def warn(msg):    print(_c("33", "[ ВНИМАНИЕ ] ") + msg)
def info(msg):    print(_c("36", msg))
def step(n, msg): print("\n" + _c("36", "[%s/4] " % n) + _c("1", msg))

def fail(title, detail=None, fixes=None):
    """Красный блок с причиной и способами лечения, после — выход."""
    print()
    print(_c("31", "=" * 60))
    print(_c("31", "ОШИБКА: ") + title)
    if detail:
        print(_c("31", "-" * 60))
        for line in detail.splitlines():
            print("  " + line)
    if fixes:
        print(_c("31", "-" * 60))
        print("Как исправить:")
        for i, fix in enumerate(fixes, 1):
            print("  %d. %s" % (i, fix))
    print(_c("31", "=" * 60))
    sys.exit(1)

# ----------------------------------------------------------------------------
#  Вспомогательные
# ----------------------------------------------------------------------------

def run(cmd, timeout=30, stdin_null=True):
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        stdin=subprocess.DEVNULL if stdin_null else None,
    )

def ask(label, default, secret=False):
    """Вопрос со значением по умолчанию (Enter = default)."""
    if ARGS.yes:
        return default
    try:
        if secret:
            if default:
                v = getpass.getpass("%s [Enter = %s]: " % (label, default))
            else:
                v = getpass.getpass("%s: " % label)
        else:
            v = input("%s [%s]: " % (label, default))
    except (EOFError, KeyboardInterrupt):
        print("\nОтменено пользователем.")
        sys.exit(130)
    return v.strip() or default

def real_uid_gid():
    """uid/gid пользователя, который вызвал sudo (файлы на шаре будут его)."""
    name = os.environ.get("SUDO_USER") or os.environ.get("USER") or "root"
    try:
        p = pwd.getpwnam(name)
        return p.pw_uid, p.pw_gid
    except KeyError:
        return 0, 0

def need_root():
    if os.geteuid() == 0:
        return
    print("Нужны права root (запись в /etc и mount). Перезапускаю через sudo...")
    try:
        os.execvp("sudo", ["sudo", sys.executable, os.path.abspath(__file__)] + sys.argv[1:])
    except FileNotFoundError:
        fail("sudo не найден", "Запусти утилиту от root: sudo python3 " + __file__)

# ----------------------------------------------------------------------------
#  Шаг 1. Tailscale
# ----------------------------------------------------------------------------

def check_tailscale(server):
    ts = shutil.which("tailscale")
    if ts is None:
        warn("tailscale не найден — пропускаю проверку туннеля.")
        print("    Если подключаешься из внешней сети, установи Tailscale:")
        print("      Linux/macOS:  curl -fsSL https://tailscale.com/install.sh | sh")
        print("      затем:        sudo tailscale up   (вход в тот же аккаунт)")
        return
    info("Пингую %s через tailnet..." % server)
    try:
        r = run([ts, "ping", "-c", "1", server], timeout=30)
    except subprocess.TimeoutExpired:
        fail("tailscale ping не ответил за 30 секунд",
             "Машина %s не отвечает." % server,
             ["Проверь на Windows-машине, что Tailscale-клиент запущен и подключён.",
              "Выполни 'sudo tailscale up' и войди в тот же аккаунт.",
              "Проверь машину в консоли: https://console.tailscale.com/admin/machines",
              "Если указано MagicDNS-имя сервера, включи MagicDNS в консоли Tailscale "
              "или используй IP-адрес 100.x.y.z."])
    if r.returncode != 0:
        fail("Машина %s недоступна через Tailscale" % server,
             (r.stderr or r.stdout or "").strip() or "tailscale ping завершился с кодом %d" % r.returncode,
             ["На Windows-машине проверь, что Tailscale-клиент запущен (иконка в трее).",
              "Выполни 'tailscale status' — машина должна быть в списке и Online.",
              "Если машины нет в tailnet — подключи её: tailscale up + вход в аккаунт.",
              "Если используешь MagicDNS-имя, а не IP — включи MagicDNS в консоли Tailscale."])
    out = (r.stdout or "").splitlines()
    pong = out[0] if out else "pong"
    ok("Tailscale-туннель работает: %s" % pong)

# ----------------------------------------------------------------------------
#  Шаг 2. Файл учётных данных
# ----------------------------------------------------------------------------

def write_credentials(server, user, password, domain):
    if SYS == "Linux":
        if os.path.exists(CRED_FILE_LINUX):
            shutil.copy2(CRED_FILE_LINUX, CRED_FILE_LINUX + ".bak")
            info("Старый %s сохранён как .bak" % CRED_FILE_LINUX)
        content = "username=%s\npassword=%s\n" % (user, password)
        if domain:
            content += "domain=%s\n" % domain
        path = CRED_FILE_LINUX
    else:  # macOS: nsmb.conf, секция [СЕРВЕР:ПОЛЬЗОВАТЕЛЬ]
        path = CRED_FILE_MAC
        section = "[%s:%s]" % (server.upper(), user.upper())
        old = ""
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                old = f.read()
            # убираем старую секцию этого сервера, если была
            lines, keep, skip = [], False, False
            for line in old.splitlines():
                if line.strip().startswith("["):
                    skip = line.strip().upper() == section
                    if not skip:
                        lines.append(line)
                    continue
                if not skip:
                    lines.append(line)
            old = "\n".join(lines).strip()
        content = (old + "\n\n" if old else "") + section + "\npassword=%s\n" % password
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(path, 0o600)
    except PermissionError:
        fail("Нет прав на запись в %s" % path,
             "Запусти утилиту через sudo.",
             ["sudo python3 " + __file__])
    ok("Учётные данные записаны: %s (права 600, пароль не светится в процессах)" % path)
    return path

# ----------------------------------------------------------------------------
#  Шаг 3. Видимость шары
# ----------------------------------------------------------------------------

def _classify_smb_error(stderr):
    s = (stderr or "").lower()
    if "logon_failure" in s or "logon failure" in s:
        return "auth"
    if "bad_network_name" in s:
        return "share"
    if ("connection_refused" in s or "timed out" in s or "timeout" in s
            or "host_unreachable" in s or "unreachable" in s or "no route" in s):
        return "network"
    if "protocol negotiation failed" in s:
        return "protocol"
    return "unknown"

def _smb_fixes(kind, server, share):
    if kind == "auth":
        return ["Проверь имя пользователя и пароль (по умолчанию comfy/comfy).",
                "Попробуй указать пользователя вместе с машиной: --user '<ИМЯ_МАШИНЫ>\\<пользователь>'.",
                "На Windows у локальной учётки comfy должен быть задан пароль "
                "(учётки без пароля для сетевого доступа Windows не пускает).",
                "Если на Windows-машине вход через аккаунт Microsoft — пароль SMB тот же, "
                "что от учётной записи Microsoft."]
    if kind == "share":
        return ["Проверь имя шары: на Windows-машине ПК правой кнопкой по папке → Свойства → "
                "Доступ. Имя должно совпадать с '%s' (регистр не важен)." % share,
                "Смотри шаг 2: возможно, шара называется иначе — укажи --share ИМЯ."]
    if kind == "network":
        return ["На Windows-машине разреши SMB для tailnet — PowerShell от администратора:\n        %s" % FIREWALL_PS,
                "Проверь, что на Windows-машине включён 'Общий доступ к файлам и принтерам' "
                "(Параметры → Сеть → Дополнительные параметры сети).",
                "Проверь сам туннель: tailscale ping %s с этой машины." % server]
    if kind == "protocol":
        return ["На Windows-машине отключён SMBv2/v3? Включи: PowerShell (админ):\n"
                "        Set-SmbServerConfiguration -EnableSMB2Protocol $true",
                "Попробуй другую версию: --vers 3.1.1 или --vers 2.1"]
    return ["Подробности смотри в сообщении выше.",
            "На Windows-машине помогает перезапуск службы: Restart-Service LanmanServer"]

def check_share_visible(server, user, cred_path):
    if SYS == "Linux":
        smb = shutil.which("smbclient")
        if smb is None:
            warn("smbclient не найден — пропускаю проверку видимости шары.")
            print("    Для диагностики поставь:  sudo apt install smbclient")
            return
        r = run([smb, "-L", "//" + server, "-A", cred_path], timeout=20)
    else:
        smb = shutil.which("smbutil")
        if smb is None:
            warn("smbutil не найден — пропускаю проверку видимости шары.")
            return
        r = run([smb, "view", "//%s@%s" % (user, server)], timeout=20)

    if r.returncode == 0:
        shares = [l.strip() for l in (r.stdout or "").splitlines() if l.strip()]
        found = any(ARGS.share.lower() in l.lower() for l in shares)
        if found:
            ok("Шара '%s' видна на сервере" % ARGS.share)
        else:
            names = ", ".join(l.split()[0] for l in shares if l and not l.startswith(" "))
            warn("Шара '%s' не найдена в списке. Сервер отдаёт: %s" % (ARGS.share, names or "?"))
            print("    Продолжаю — возможно, имя просто иначе отображается.")
        return

    kind = _classify_smb_error(r.stderr or r.stdout)
    fail("Сервер SMB не отдал список шар (%s)" % kind,
         (r.stderr or r.stdout or "").strip(),
         _smb_fixes(kind, server, ARGS.share))

# ----------------------------------------------------------------------------
#  Шаг 4. Монтирование
# ----------------------------------------------------------------------------

def mount_share(server, share, mountpoint, user, cred_path, vers, uid, gid):
    if os.path.ismount(mountpoint):
        if ARGS.yes:
            warn("%s уже смонтирован — пропускаю монтирование." % mountpoint)
            return
        ans = ask("%s уже смонтирован. Перемонтировать?" % mountpoint, "n")
        if ans.lower() in ("y", "yes", "д", "да"):
            r = run(["umount", mountpoint])
            if r.returncode != 0:
                fail("Не удалось отмонтировать %s" % mountpoint,
                     (r.stderr or "").strip(),
                     ["Закрой программы, которые используют файлы на шаре, и повтори.",
                      "Кто держит: lsof +D %s (Linux)" % mountpoint])
        else:
            info("Оставляю как есть.")
            return

    os.makedirs(mountpoint, exist_ok=True)

    if SYS == "Linux":
        if shutil.which("mount.cifs") is None:
            fail("mount.cifs не найден — не установлен пакет cifs-utils",
                 None,
                 ["Debian/Ubuntu:  sudo apt install cifs-utils",
                  "Fedora:         sudo dnf install cifs-utils",
                  "Arch:           sudo pacman -S cifs-utils"])
        opts = "credentials=%s,uid=%d,gid=%d,iocharset=utf8,vers=%s" % (cred_path, uid, gid, vers)
        cmd = ["mount", "-t", "cifs", "//%s/%s" % (server, share), mountpoint, "-o", opts]
    else:
        cmd = ["mount", "-t", "smbfs", "//%s@%s/%s" % (user, server, share), mountpoint]

    r = run(cmd, timeout=60)
    if r.returncode != 0:
        err = (r.stderr or "").strip()
        kind = _classify_smb_error(err)
        if "unknown filesystem type 'cifs'" in err:
            fail("Ядро не поддерживает cifs (не установлен cifs-utils)",
                 err,
                 ["sudo apt install cifs-utils (или dnf/pacman — см. выше)"])
        if "permission denied" in err.lower() and kind == "unknown":
            kind = "auth"
        fixes = _smb_fixes(kind, server, share) + [
            "Подробности: dmesg | tail -20",
            "Если ошибка про версию протокола — попробуй --vers 3.1.1 или --vers 2.1"]
        fail("Не удалось смонтировать //%s/%s (%s)" % (server, share, kind), err, fixes)

    if not os.path.ismount(mountpoint):
        fail("mount завершился без ошибок, но %s не смонтирован" % mountpoint,
             "Проверь вручную: mount | grep %s" % mountpoint)

    try:
        entries = sorted(os.listdir(mountpoint))[:5]
    except OSError as e:
        fail("Шара смонтирована, но читать её не получается",
             str(e),
             ["Проверь uid/gid: сейчас uid=%d, gid=%d (должны совпадать с твоим пользователем)" % (uid, gid)])

    ok("Смонтировано: //%s/%s → %s" % (server, share, mountpoint))
    if entries:
        print("    Файлы на шаре: %s%s" % (", ".join(entries),
                                           " ..." if len(entries) == 5 else ""))

# ----------------------------------------------------------------------------
#  Итоги
# ----------------------------------------------------------------------------

def print_success(server, share, mountpoint, cred_path, vers, uid, gid):
    print()
    print(_c("32", "=" * 60))
    print(_c("32", "  Готово! Шара подключена."))
    print(_c("32", "=" * 60))
    print("  //%s/%s  →  %s" % (server, share, mountpoint))
    print("  Учётные данные: %s (права 600)" % cred_path)
    if SYS == "Linux":
        print()
        print("  Отмонтировать:            sudo umount %s" % mountpoint)
        print("  Монтировать вручную:      sudo mount %s" % mountpoint)
        print()
        print("  Чтобы монтировалось само после перезагрузки, добавь в /etc/fstab:")
        print(_c("1", "  //%s/%s %s cifs credentials=%s,uid=%d,gid=%d,iocharset=utf8,vers=%s,_netdev,nofail,x-systemd.automount,x-systemd.requires=tailscaled.service 0 0"
              % (server, share, mountpoint, cred_path, uid, gid, vers)))
        print("  (x-systemd.automount — монтирует при первом обращении, когда Tailscale уже поднят)")
    else:
        print()
        print("  Отмонтировать:            sudo umount %s" % mountpoint)
        print("  Пароль хранится в %s — mount не будет спрашивать его." % CRED_FILE_MAC)
        print("  После перезагрузки мак не монтирует шару сам: повтори запуск утилиты")
        print("  или добавь её в Автозагрузку (System Settings → General → Login Items).")

def unmount(mountpoint):
    if not os.path.ismount(mountpoint):
        print("%s не смонтирован — нечего отключать." % mountpoint)
        return
    r = run(["umount", mountpoint], timeout=30)
    if r.returncode != 0:
        fail("Не удалось отмонтировать %s" % mountpoint,
             (r.stderr or "").strip(),
             ["Закрой программы, которые держат файлы на шаре.",
              "Кто использует: lsof +D %s (Linux) / lsof %s (macOS)" % (mountpoint, mountpoint)])
    ok("Шара отключена: %s" % mountpoint)

# ----------------------------------------------------------------------------
#  main
# ----------------------------------------------------------------------------

ARGS = None
SYS = platform.system()

def main():
    global ARGS
    p = argparse.ArgumentParser(
        description="Подключение SMB-шары ComfyUI-Shared (Windows) к Linux/macOS через Tailscale")
    p.add_argument("--server", default=DEFAULTS["server"], help="Tailscale-адрес или имя машины (по умолчанию: %(default)s)")
    p.add_argument("--share", default=DEFAULTS["share"], help="имя шары (по умолчанию: %(default)s)")
    p.add_argument("--mount", default=DEFAULTS["mount"], help="точка монтирования (по умолчанию: %(default)s)")
    p.add_argument("--user", default=DEFAULTS["user"], help="пользователь Windows (по умолчанию: %(default)s)")
    p.add_argument("--password", default=DEFAULTS["password"], help="пароль (лучше вводить интерактивно)")
    p.add_argument("--domain", default=DEFAULTS["domain"], help="домен/рабочая группа (не обязательно)")
    p.add_argument("--vers", default=DEFAULTS["vers"], help="версия SMB, Linux (по умолчанию: %(default)s)")
    p.add_argument("--yes", action="store_true", help="не задавать вопросов, использовать значения по умолчанию")
    p.add_argument("--unmount", action="store_true", help="отключить шару вместо подключения")
    ARGS = p.parse_args()

    if SYS not in ("Linux", "Darwin"):
        fail("Эта утилита для Linux и macOS. На Windows шара уже локальная.")
    need_root()

    if ARGS.unmount:
        unmount(ARGS.mount)
        return

    print(_c("1", "comfy-mount") + " — подключение SMB-шары ComfyUI-Shared через Tailscale")
    print("    Enter оставляет значение в скобках. Ctrl+C — выход.\n")

    server   = ask("Сервер (Tailscale-адрес или имя)", ARGS.server)
    share    = ask("Имя шары", ARGS.share)
    mountpoint = ask("Куда монтировать", ARGS.mount)
    user     = ask("Пользователь Windows", ARGS.user)
    password = ask("Пароль", ARGS.password, secret=True)
    if not password:
        fail("Пароль не задан",
             "Для учётной записи Windows без пароля SMB-доступ не работает.",
             ["Запусти утилиту без --yes и введи пароль.",
              "Или передай его флагом: sudo ./comfy-mount.py --password ПАРОЛЬ"])
    domain   = ask("Домен/рабочая группа (можно пустым)", ARGS.domain)
    vers     = DEFAULTS["vers"]
    if SYS == "Linux":
        vers = ask("Версия SMB", ARGS.vers)

    uid, gid = real_uid_gid()

    step(1, "Проверяю Tailscale-туннель до %s" % server)
    check_tailscale(server)

    step(2, "Сохраняю учётные данные (без пароля в командной строке)")
    cred_path = write_credentials(server, user, password, domain)

    step(3, "Проверяю, что шара %s видна" % share)
    check_share_visible(server, user, cred_path)

    step(4, "Монтирую //%s/%s в %s" % (server, share, mountpoint))
    mount_share(server, share, mountpoint, user, cred_path, vers, uid, gid)

    print_success(server, share, mountpoint, cred_path, vers, uid, gid)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nОтменено пользователем.")
        sys.exit(130)
