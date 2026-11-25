#!/usr/bin/env python3
"""Rettet die ganze Terminal-Landschaft über einen Neustart.

  fenster.py save      Zustand sichern (vor dem Neustart)
  fenster.py show      Gesichertes anzeigen
  fenster.py restore   Fenster wieder öffnen (nach dem Neustart)

Gesichert wird je Fenster: Position und Größe, Ordner, Startbefehl, die
Claude-Sitzung dahinter, das Terminal-Profil — und der TermTint-Name samt
Farbe. Letzterer ist der Grund, warum `sessions.py` nicht reichte: TermTint
hängt seine Namen an die Fensternummer, und die ist nach einem Neustart neu.
Deshalb schreibt `restore` die Namen nach dem Öffnen selbst wieder hinein,
auf die neuen Nummern, und startet TermTint danach neu.
"""
import glob
import json
import os
import plistlib
import re
import subprocess
import sys
import time

SNAPSHOT = os.path.expanduser("~/.termtint-fenster.json")
PREFS = os.path.expanduser("~/Library/Preferences/eu.lecon.termtint.plist")
PROJECTS = os.path.expanduser("~/.claude/projects")
# Maxi will jede Sitzung mit diesen beiden Schaltern — ohne sie fragt Claude
# bei jedem Schritt nach und kennt den Browser nicht.
MUST_HAVE = ["--dangerously-skip-permissions", "--chrome"]


def osa(script):
    out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return out.stdout.strip()


# ---------------------------------------------------------------- sichern

def live_windows():
    """Offene Terminal-Fenster. Geschlossene hinterlassen Geister ohne Tabs."""
    script = '''
    tell application "Terminal"
        set out to ""
        repeat with w in windows
            if (count of tabs of w) > 0 then
                set b to bounds of w
                set t to tab 1 of w
                set out to out & (id of w) & "\t" & (item 1 of b) & "\t" & (item 2 of b) ¬
                    & "\t" & (item 3 of b) & "\t" & (item 4 of b) & "\t" & (tty of t) ¬
                    & "\t" & (name of current settings of t) & "\t" & (name of w) & linefeed
            end if
        end repeat
        return out
    end tell'''
    rows = []
    for line in osa(script).splitlines():
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        rows.append({
            "id": int(parts[0]),
            "bounds": [int(p) for p in parts[1:5]],
            "tty": parts[5],
            "profile": parts[6],
            "title": parts[7],
        })
    return rows


def processes():
    """{tty: (pid, Befehlszeile)} für alles, was in einem Terminal läuft."""
    out = subprocess.run(["ps", "-Ao", "pid=,tty=,command="],
                         capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3 or parts[1] == "??":
            continue
        pid, tty, command = int(parts[0]), "/dev/" + parts[1], parts[2]
        name = command.split(" ")[0].split("/")[-1]
        # Die Hülle (login/zsh) interessiert nicht, das Programm darin schon.
        if name in ("login", "-zsh", "zsh", "bash", "-bash"):
            continue
        found[tty] = (pid, command)
    return found


def cwd_of(pid):
    out = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("n/"):
            return line[1:]
    return os.path.expanduser("~")


def session_from(command):
    """Sitzungs-ID aus dem Startbefehl: --resume <uuid> oder attach <kurz>."""
    match = re.search(r"--resume\s+([0-9a-f-]{8,})", command)
    if match:
        return match.group(1)
    match = re.search(r"\battach\s+([0-9a-f]{6,})", command)
    if match:
        hits = glob.glob(os.path.join(PROJECTS, "*", match.group(1) + "*.jsonl"))
        if hits:
            return os.path.basename(hits[0])[:-6]
    return None


def chat_name(title):
    """Der Chatname aus dem Fenstertitel: Ordner — ✳ Name — Befehl — 85×24."""
    parts = [p.strip() for p in title.split(" — ") if p.strip()]
    if parts and re.fullmatch(r"\d+[×x]\d+.*", parts[-1]):
        parts.pop()
    if len(parts) < 3:
        return None
    return re.sub(r"^[^\w]+\s*", "", " ".join(parts[1:-1])).strip() or None


def started_at(pid):
    """Startzeitpunkt des Prozesses als Zeitstempel."""
    # macOS kennt kein etimes, nur etime im Format [[dd-]hh:]mm:ss.
    out = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    days, _, rest = out.partition("-")
    if not rest:
        days, rest = "0", days
    pieces = [int(p) for p in rest.split(":")]
    while len(pieces) < 3:
        pieces.insert(0, 0)
    seconds = int(days) * 86400 + pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
    return time.time() - seconds


def first_entry(path):
    """Zeitstempel des ersten Eintrags einer Sitzungsdatei."""
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                if '"timestamp"' not in line:
                    continue
                try:
                    stamp = json.loads(line).get("timestamp")
                except ValueError:
                    continue
                if stamp:
                    return time.mktime(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S")) \
                        - time.timezone
    except OSError:
        pass
    return None


def session_by_start(pid, cwd):
    """Sitzung ohne --resume: die, die beim Start des Prozesses entstand.

    Nach dem Namen zu suchen führt in die Irre — Chatnamen tauchen in fremden
    Sitzungen auf, sobald dort über sie geredet wird. Der Start ist eindeutig:
    eine frische Sitzung legt ihre Datei in den Minuten danach an.
    """
    begin = started_at(pid) if pid else None
    if begin is None:
        return None
    slug = cwd.replace("/", "-")
    best = None
    for path in glob.glob(os.path.join(PROJECTS, slug, "*.jsonl")):
        first = first_entry(path)
        if first is None or not (begin - 120 <= first <= begin + 1800):
            continue
        if best is None or first < best[1]:
            best = (os.path.basename(path)[:-6], first)
    return best[0] if best else None


def labels():
    try:
        prefs = plistlib.load(open(PREFS, "rb"))
        return json.loads(prefs["labels"])
    except Exception:
        return {}


def flags_of(command):
    """Startoptionen von claude, ohne den doppelten Programmnamen."""
    parts = command.split()
    try:
        start = max(i for i, p in enumerate(parts) if p.split("/")[-1] == "claude")
    except ValueError:
        return []
    out, skip = [], False
    for piece in parts[start + 1:]:
        if skip:
            skip = False
            continue
        if piece in ("--resume", "attach"):
            skip = True
            continue
        if piece.startswith("-") or (out and out[-1] in ("--model", "-n")):
            out.append(piece)
    for flag in MUST_HAVE:
        if flag not in out:
            out.append(flag)
    return out


def save():
    store = labels()
    running = processes()
    entries = []
    for window in live_windows():
        pid, command = running.get(window["tty"], (None, ""))
        label = dict(store.get("win:%d" % window["id"]) or {})
        cwd = cwd_of(pid) if pid else os.path.expanduser("~")
        shown = chat_name(window["title"])
        # Ohne eigenen Eintrag zeigt TermTint den Chatnamen aus dem Titel —
        # genau der steht auch auf dem Overlay, also ist er der richtige Name.
        if not label.get("name"):
            label["name"] = shown
        session = session_from(command)
        if not session and "claude" in command:
            session = session_by_start(pid, cwd)
        entries.append({
            "title": window["title"],
            "bounds": window["bounds"],
            "profile": window["profile"],
            "cwd": cwd,
            "command": command,
            "session": session,
            "flags": flags_of(command) if "claude" in command else [],
            "label": {"name": label.get("name"), "hue": label.get("hue"),
                      "directory": label.get("directory")},
        })

    data = {
        "saved": time.strftime("%Y-%m-%d %H:%M"),
        "windows": entries,
        "labels": store,          # vollständiger Namensspeicher als Rückfalltür
    }
    with open(SNAPSHOT, "w") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    # Die ganzen Einstellungen als Rückfalltür daneben legen.
    try:
        with open(PREFS, "rb") as src, open(SNAPSHOT + ".plist", "wb") as dst:
            dst.write(src.read())
    except OSError as error:
        print("Einstellungen nicht gesichert:", error)
    show()
    print(f"\n{len(entries)} Fenster gesichert → {SNAPSHOT}")


# --------------------------------------------------------------- anzeigen

def show():
    if not os.path.exists(SNAPSHOT):
        sys.exit("Noch nichts gesichert. Erst: fenster.py save")
    data = json.load(open(SNAPSHOT))
    print(f"Gesichert am {data['saved']} — {len(data['windows'])} Fenster:\n")
    for e in data["windows"]:
        name = e["label"]["name"] or "(ohne Namen)"
        mark = "✓" if e["session"] else ("—" if not e["flags"] else "neu")
        print(f"  {mark} {name[:38]:<40} {str(e['session'])[:8]:<9} {e['cwd']}")


# --------------------------------------------------------- wiederherstellen

def open_window(command, profile):
    """Öffnet ein Fenster und gibt seine neue Fensternummer zurück.

    Das neue Fenster wird über die Gerätedatei seines Tabs gesucht, nicht über
    einen Objektvergleich: `t is theTab` ist in AppleScript unzuverlässig und
    lieferte dabei immer „nicht gefunden".

    Den Rahmen setzt erst `place` hinterher: direkt beim Öffnen nimmt Terminal
    die Position nicht an, die Größe schon.
    """
    script = f'''
    tell application "Terminal"
        set theTab to do script {json.dumps(command)}
        set wanted to tty of theTab
        try
            set current settings of theTab to settings set {json.dumps(profile)}
        end try
        repeat with w in windows
            if (count of tabs of w) > 0 then
                if (tty of tab 1 of w) is wanted then return (id of w) as text
            end if
        end repeat
        return "0"
    end tell'''
    try:
        return int(osa(script))
    except Exception as error:
        print("  ! Fenster ließ sich nicht öffnen:", error)
        return 0


def place(window_id, bounds):
    """Fenster an seinen Platz setzen. Zweimal — der erste Versuch verpufft,
    solange das Fenster noch auftaucht."""
    frame = "{%d, %d, %d, %d}" % tuple(bounds)
    for _ in range(2):
        try:
            osa(f'tell application "Terminal" to set bounds of window id {window_id} to {frame}')
        except RuntimeError:
            return False
        time.sleep(0.25)
    return True


def write_labels(pairs, store):
    """Namen und Farben auf die neuen Fensternummern schreiben.

    Zwei Dinge sind heikel. Erstens hält TermTint seinen Speicher im
    Arbeitsspeicher und schreibt ihn beim Ändern komplett zurück — läuft es
    dabei, überschreibt es uns sofort. Zweitens liegt der Speicher als
    Datenblock in den Einstellungen, nicht als Text: als Text geschrieben
    findet TermTint ihn nicht mehr und alle Namen wären weg.
    """
    subprocess.run(["pkill", "-x", "TermTint"], capture_output=True)
    time.sleep(1.5)
    fresh = {k: v for k, v in store.items() if not k.startswith("win:")}
    stamp = time.time() - 978307200          # Apple rechnet ab 2001
    written = 0
    for window_id, label in pairs:
        # Ohne Farbe kein Eintrag: TermTint verlangt sie, und ein unvollständiger
        # Eintrag macht den ganzen Speicher unlesbar. Diese Fenster zeigen
        # ohnehin ihren Chatnamen, der mit der Sitzung zurückkommt.
        if not label.get("name") or label.get("hue") is None:
            continue
        entry = {"name": label["name"], "hue": label["hue"], "updated": stamp}
        if label.get("directory"):
            entry["directory"] = label["directory"]
        fresh["win:%d" % window_id] = entry
        written += 1
    blob = json.dumps(fresh, ensure_ascii=False).encode("utf-8")
    subprocess.run(["defaults", "write", "eu.lecon.termtint", "labels",
                    "-data", blob.hex()], check=True)
    subprocess.run(["killall", "cfprefsd"], capture_output=True)
    time.sleep(1)
    subprocess.run(["open", "/Applications/TermTint.app"])
    return written


def already_open():
    """Sitzungen, die gerade schon in einem Terminal laufen."""
    out = subprocess.run(["ps", "-Ao", "command="], capture_output=True, text=True).stdout
    found = set(re.findall(r"--resume\s+([0-9a-f-]{8,})", out))
    # Der Chat, aus dem heraus wiederhergestellt wird, steht nicht immer mit
    # --resume in der Prozessliste — wer ihn über die Auswahl geöffnet hat,
    # startet schlicht `claude`. Die eigene Sitzung sagt die Umgebung.
    mine = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if mine:
        found.add(mine)
    return found


def restore():
    if not os.path.exists(SNAPSHOT):
        sys.exit("Noch nichts gesichert. Erst: fenster.py save")
    data = json.load(open(SNAPSHOT))
    running = already_open()
    pairs, places = [], []
    for entry in data["windows"]:
        # Den Chat, aus dem heraus wiederhergestellt wird, nicht doppelt öffnen.
        if entry["session"] and entry["session"] in running:
            print(f"  schon offen: {(entry['label']['name'] or '')[:46]}")
            continue
        if entry["session"]:
            command = "claude --resume %s %s" % (entry["session"], " ".join(entry["flags"]))
        elif entry["flags"]:
            command = "claude " + " ".join(entry["flags"])
        else:
            command = ""
        full = "cd %s" % json.dumps(entry["cwd"])
        if command:
            full += " && " + command.strip()
        new_id = open_window(full, entry["profile"])
        name = entry["label"]["name"] or entry["title"][:40]
        print(f"  geöffnet: {name[:46]:<48} #{new_id}")
        if new_id:
            pairs.append((new_id, entry["label"]))
            places.append((new_id, entry["bounds"]))
        time.sleep(0.8)

    print("\nFenster an ihren Platz setzen …")
    for window_id, bounds in places:
        place(window_id, bounds)
    written = write_labels(pairs, data.get("labels", {}))
    print(f"\n{len(data['windows'])} Fenster geöffnet, {written} Namen wieder gesetzt.")
    print("TermTint läuft wieder.")


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "show"
    {"save": save, "show": show, "restore": restore}.get(action, show)()
