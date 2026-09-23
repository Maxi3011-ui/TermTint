#!/usr/bin/env python3
"""Rettet offene Claude-Code-Fenster über einen Neustart.

  sessions.py save      Zustand sichern (vor dem Neustart)
  sessions.py show      Gesichertes anzeigen
  sessions.py restore   Fenster wieder öffnen (nach dem Neustart)

Die Chats selbst liegen ohnehin auf der Platte. Was verloren geht, ist die
Zuordnung: welches Fenster gehörte zu welcher Sitzung, in welchem Ordner, mit
welchen Startoptionen. Genau das wird hier gesichert.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

SNAPSHOT = os.path.expanduser("~/.termtint-sessions.json")
PROJECTS = os.path.expanduser("~/.claude/projects")


def window_titles():
    """Titel aller offenen Terminal-Fenster, über AppleScript."""
    script = 'tell application "Terminal" to get name of every window'
    out = subprocess.run(["osascript", "-e", script],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("Terminal nicht erreichbar: " + out.stderr.strip())
    return [t.strip() for t in out.stdout.strip().split(",") if t.strip()]


def session_index():
    """{aiTitle: (session_id, cwd, mtime)} — bei Dubletten gewinnt die jüngste."""
    index = {}
    for path in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
        title = cwd = None
        try:
            with open(path, errors="ignore") as fh:
                for line in fh:
                    if '"aiTitle"' not in line and '"cwd"' not in line:
                        continue
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    title = entry.get("aiTitle") or title
                    # Der erste Eintrag ist das Startverzeichnis der Sitzung.
                    # Spätere wandern mit, wenn die Sitzung das Verzeichnis
                    # wechselt — dann landet man beim Wiederherstellen falsch.
                    if cwd is None:
                        cwd = entry.get("cwd")
        except OSError:
            continue
        if not title:
            continue
        mtime = os.path.getmtime(path)
        known = index.get(title)
        if known is None or mtime > known[2]:
            index[title] = (os.path.basename(path)[:-6], cwd, mtime)
    return index


def parse(title):
    """Sessionname und Startbefehl aus einem Terminal-Fenstertitel."""
    parts = [p.strip() for p in title.split(" — ") if p.strip()]
    if parts and re.fullmatch(r"\d+[×x]\d+.*", parts[-1]):
        parts.pop()
    if len(parts) < 2:
        return None, None
    command = parts[-1]
    name = " ".join(parts[1:-1]) if len(parts) >= 3 else None
    if name:
        name = re.sub(r"^[^\w]+\s*", "", name).strip()
    return name, command


def claude_flags(command):
    """Startoptionen aus 'caffeinate ◂ claude --foo' herausziehen."""
    for segment in command.split("◂"):
        segment = segment.strip()
        if segment.split(" ")[0].split("/")[-1] == "claude":
            return segment.split(" ")[1:]
    return []


def save():
    index = session_index()
    entries, skipped = [], []
    for title in window_titles():
        name, command = parse(title)
        if not name or not command or "claude" not in command:
            skipped.append(title)
            continue
        found = index.get(name)
        if not found:
            skipped.append(title)
            continue
        session_id, cwd, _ = found
        entries.append({
            "name": name,
            "session": session_id,
            "cwd": cwd or os.path.expanduser("~"),
            "flags": claude_flags(command),
        })

    with open(SNAPSHOT, "w") as fh:
        json.dump({"saved": time.strftime("%Y-%m-%d %H:%M"), "windows": entries},
                  fh, indent=2, ensure_ascii=False)

    print(f"{len(entries)} Sitzungen gesichert → {SNAPSHOT}")
    for e in entries:
        print(f"  {e['name'][:44]:<46} {e['cwd']}")
    if skipped:
        print(f"\n{len(skipped)} Fenster ohne Claude-Sitzung übersprungen:")
        for t in skipped:
            print(f"  {t[:70]}")


def show():
    if not os.path.exists(SNAPSHOT):
        sys.exit("Noch nichts gesichert. Erst: sessions.py save")
    data = json.load(open(SNAPSHOT))
    print(f"Gesichert am {data['saved']} — {len(data['windows'])} Fenster:\n")
    for e in data["windows"]:
        print(f"  {e['name'][:44]:<46} {e['cwd']}")


def restore():
    if not os.path.exists(SNAPSHOT):
        sys.exit("Noch nichts gesichert. Erst: sessions.py save")
    data = json.load(open(SNAPSHOT))
    for entry in data["windows"]:
        flags = " ".join(entry["flags"])
        command = f"cd {json.dumps(entry['cwd'])} && claude --resume {entry['session']} {flags}".strip()
        script = f'tell application "Terminal" to do script {json.dumps(command)}'
        subprocess.run(["osascript", "-e", script], capture_output=True)
        print(f"  geöffnet: {entry['name'][:50]}")
        time.sleep(0.6)
    print(f"\n{len(data['windows'])} Fenster wiederhergestellt.")


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "show"
    {"save": save, "show": show, "restore": restore}.get(action, show)()
