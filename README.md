# TermTint

*A macOS menu-bar app that labels and colour-codes your Terminal windows, so you
can tell at a glance which one is which — and which one is waiting for you.
Documentation below is in German.*

**Voraussetzungen:** macOS 14 oder neuer, Xcode-Befehlszeilenwerkzeuge, Apple Terminal.

Beschriftet Terminal-Fenster, damit man auf einen Blick weiß, worum es geht.

Maus über ein Terminal-Fenster → das Fenster erscheint milchig in seiner eigenen
Farbe, mit großem Namen in der Mitte. Die Titelleiste bleibt sichtbar und
greifbar, nur eingefärbt. Klick auf den Namen → umbenennen. Klick oder Tastendruck
irgendwo sonst → Overlay weg, Klick und Tastenanschlag landen ganz normal im
Terminal.

## Was die Farbe bedeutet

| Familie | wofür |
|---|---|
| Bernstein → Koralle | Claude Code |
| Cyan → Blau | Codex |
| Violett → Magenta | ein sonstiger laufender Prozess |
| fast neutral | reine Shell |

Innerhalb einer Familie liegen die Farbtöne so weit wie möglich auseinander —
fünf offene Claude-Fenster bleiben klar unterscheidbar. Die Rolle rastet ein,
sobald ein Werkzeug erkannt ist: ein kurz laufendes `git` färbt das Fenster nicht
um. Im Hintergrund liegt zusätzlich das Rollen-Symbol als angeschnittenes
Wasserzeichen.

## Namen

Die Beschriftung kommt automatisch aus dem Fenstertitel — Claude Code schreibt
seinen Sessionnamen dort hinein, sonst wird der Prozessname genommen. Klick auf
den Namen öffnet ein leeres Feld (kein Platzhalter zum Löschen), das beim Tippen
mitwächst. Enter übernimmt, Esc verwirft, ein leeres Feld gibt den automatischen
Namen wieder frei.

Selbst vergebene Namen werden gespeichert und kommen nach einem Neustart
zurück. Der Schlüssel ist **Arbeitsverzeichnis plus automatischer Name** — das
Verzeichnis allein reicht nicht, weil mehrere Claude-Sessions typischerweise aus
demselben Ordner laufen, oft direkt aus dem Home-Verzeichnis, und dann alle
denselben Namen erben würden. Die Farbe wird mitgespeichert und nur
zurückgeholt, wenn sie noch zur Rollenfamilie des Fensters passt. Ändert eine
Claude-Session ihr Thema, ändert sich der Schlüssel — der alte Eintrag wird dann
nicht mehr gefunden. „Eigene Namen zurücksetzen" im Menü leert auch den Speicher.

## ⌥Tab — Übersicht

⌥ halten und Tab drücken öffnet eine Liste aller Terminal-Fenster, nach Rolle
gruppiert und in den Fensterfarben. Tab blättert weiter, ⇧Tab zurück, die Maus
wählt direkt aus. Loslassen von ⌥, Enter oder ein Klick springt zum gewählten
Fenster; Esc oder ein Klick daneben bricht ab. Die Übersicht liegt über allen
Fenstern.

Unten in der Übersicht sitzt ein Schalter, der das Overlay in den Standby legt.
Klick irgendwo auf die Zeile oder Leertaste schaltet um; die Übersicht bleibt
dabei offen, damit man den Schalter umspringen sieht — und weil sie auch der Weg
zurück ist: das ⌥Tab-Fenster funktioniert weiter, wenn das Overlay pausiert.

## Einfrieren

Unter dem Namen im Overlay sitzt ein lila Knopf **Einfrieren**. Er hält die
ganze Sitzung des Fensters an (SIGSTOP): sie verbraucht keine Rechenzeit mehr,
ihren Speicher lagert macOS bei Bedarf aus. Das Fenster bekommt einen
Milchglas-Schleier „Eingefroren“. **Auftauen** lässt alles genau dort
weiterlaufen, wo es stand.

- Reihenfolge ist entscheidend: erst die Shell, dann ihre Kinder anhalten;
  beim Auftauen umgekehrt. Hält man nur das Programm an, übernimmt zsh das
  Terminal und der Job ist kaputt.
- Eine eingefrorene Sitzung schreibt nichts mehr in ihre Sitzungsdatei.
  `Activity.freeze()` unterdrückt deshalb die Fertig-Meldung; Auftauen meldet
  nichts nachträglich.
- Die Zuordnung Fenster → tty kommt per AppleScript, nur beim Klick.
- Beim Beenden von TermTint und beim Schließen eines eingefrorenen Fensters
  wird automatisch aufgetaut. Im Menü: „Alle auftauen“.

## Installation

```
./build.sh --install
```

Baut `TermTint.app`, kopiert sie nach `/Applications` und startet sie. Beim
ersten Start nach **Bedienungshilfen** fragen lassen und freigeben — ohne diese
Berechtigung kann keine App die Fenster anderer Programme sehen.

`build.sh` signiert mit deiner Apple-Development-Identität (überschreibbar per
`TERMTINT_IDENTITY`). Das ist wichtig: eine Ad-hoc-Signatur bekommt bei jedem
Build einen neuen Hash, wodurch macOS die erteilte Berechtigung stillschweigend
verwirft — ohne erneut zu fragen. Mit fester Identität überlebt die Freigabe
jeden Rebuild. Ändert sich die Signatur trotzdem, räumt `build.sh` den veralteten
Eintrag selbst weg, damit macOS neu fragt.

## Bedienung

| | |
|---|---|
| Hovern | Overlay ein |
| Klick auf den Namen | umbenennen (Enter übernimmt, Esc verwirft) |
| Klick sonstwo | Overlay aus, Klick geht ans Terminal |
| Tippen im aktiven Fenster | Overlay aus, Eingabe geht ans Terminal |
| Maus verlässt das Fenster | Overlay kommt beim nächsten Betreten zurück |
| ⌥Tab / ⇧⌥Tab | Übersicht öffnen und blättern |
| Leertaste in der Übersicht | Overlay in Standby / wieder aktiv |
| ⌥⌘T | pausieren / aktivieren |

Im Menüleisten-Icon: Status, Pausieren, Farben neu würfeln, eigene Namen
zurücksetzen, bei Anmeldung starten.

## Aufbau

- `TerminalWatcher` — Accessibility-Anbindung an Terminal.app. `AXObserver`
  meldet neue, bewegte, umbenannte und geschlossene Fenster; kein Polling.
  Liefert außerdem die Treffer-Abfrage `hitTest`, die Titelleistenhöhe und das
  Nach-vorn-Holen für die Übersicht.
- `HoverEngine` — Zustand pro Fenster, ein globaler Maus- und Tastatur-Monitor,
  Trefferprüfung und Verdeckungsberechnung.
- `OverlayPanel` / `OverlayView` — ein einziges, wiederverwendetes, komplett
  klick-durchlässiges Panel: Milchglas, Farbwäsche, eingefärbte Titelleiste,
  Wasserzeichen, Name, Inline-Editor.
- `Switcher` / `SwitcherPanel` — die ⌥Tab-Übersicht, Carbon-Hotkey in `HotKey`.
- `Role` — Rollenerkennung und Titel-Parser.
- `Palette` — Farbvergabe innerhalb der Rollenfamilie.

### Warum die Treffer-Abfrage über die Bedienungshilfen läuft

Naheliegend wäre, per `CGWindowListCopyWindowInfo` zu prüfen, ob das
Terminal-Fenster unter dem Zeiger das oberste ist. Das ist falsch, sobald
**Stage Manager** oder mehrere Spaces im Spiel sind: macOS meldet dort Fenster
als „on screen", die gar nicht sichtbar sind, und das Overlay bleibt scheinbar
grundlos aus. `AXUIElementCopyElementAtPosition` beantwortet stattdessen die
eigentliche Frage — was würde ein Klick hier treffen — und kostet 3 ms, nur bei
Zielwechsel. Die Fensterliste dient noch als Rückfallebene und zum Berechnen der
Verdeckungen; fremde Fenster werden dort zusätzlich per Treffer-Abfrage bestätigt.

### Zwei weitere Fallen, die im Code adressiert sind

**Eine fehlgeschlagene AX-Abfrage ist nicht dasselbe wie „keine Fenster".**
Gäbe `snapshot()` nur ein Dictionary zurück, sähe beides gleich aus — und ein
kurzer Fehlschlag würde jedes bekannte Fenster löschen. Direkt nach dem Start
passiert das tatsächlich; die App bliebe dann dauerhaft blind. Deshalb
unterscheidet `Snapshot` zwischen `.ok` und `.unavailable`, behält bei einem
Fehlschlag den bisherigen Stand und versucht es bis zu zwölfmal erneut.

**Ein Fenster ist nicht weg, nur weil es gerade nicht in der Liste steht.**
`snapshot()` lässt minimierte Fenster aus, und ein kurzer AX-Aussetzer sieht
genauso aus. Wer daraufhin den Zustand löscht, wirft den vom Nutzer getippten
Namen und die Farbe weg und vergibt beim Wiederauftauchen neue — für den Nutzer
sieht das aus, als würden Namen zufällig zurückgesetzt. Gelöscht wird deshalb
nur, wenn `AX.isAlive` ein wirklich ungültiges Element meldet; alles andere gilt
als „dasselbe Fenster, gerade nicht sichtbar".

**Ein Ausblenden darf ein späteres Einblenden nicht mehr anfassen.** Das
Ausblenden läuft über 90 ms und ordnet das Panel am Ende weg. Wechselt man
schneller als das von einem Fenster ins nächste, startet das Einblenden, während
das alte Ausblenden noch läuft — und dessen Abschluss ordnet das gerade
erschienene Overlay wieder weg. Sichtbar ist dann nur ein sehr kurzes Flackern,
und zwar zuverlässig immer beim selben Fenster, wenn der Weg dorthin kurz genug
ist. `OverlayPanel` vergibt deshalb pro Blendvorgang ein Token; ein
Abschluss-Handler wirkt nur noch, wenn er der aktuelle ist.

**Claude Code animiert einen Spinner im Fenstertitel.** Jede Änderung löst eine
AX-Benachrichtigung aus. Würde man darauf blind neu zeichnen, baut sich das
Overlay mehrmals pro Sekunde neu auf — sichtbar als Flackern, und nur bei
Claude-Fenstern. `applyTitle` meldet deshalb zurück, ob sich am *Angezeigten*
etwas geändert hat, und nur dann wird neu gezeichnet.

Im Leerlauf läuft kein Timer und kein Zeichenvorgang: 0,0 % CPU, ~26 MB. Beim
Bewegen der Maus über Fenster kurzzeitig 3–8 %; beim Wechsel auf ein Fenster
anderer Größe muss das Panel seinen Puffer neu anlegen, was einen kurzen
Speicherausschlag verursacht, der sofort wieder zurückgeht.

## Neustart überleben

Ein Neustart killt jede laufende Claude-Code-Sitzung. Die Chats selbst bleiben
auf der Platte; verloren geht nur die Zuordnung — welches Fenster gehörte zu
welcher Sitzung, in welchem Ordner, mit welchen Startoptionen.

```
tools/sessions.py save      # vor dem Neustart
tools/sessions.py show      # nachsehen, was gesichert ist
tools/sessions.py restore   # nach dem Neustart
```

`save` liest die offenen Terminal-Fenster, holt aus jedem Titel den Sessionnamen
und schlägt ihn im `aiTitle`-Feld der Sitzungsdateien unter
`~/.claude/projects` nach. Das liefert Sitzungs-ID, Startverzeichnis und
Startoptionen. `restore` öffnet daraus wieder je ein Terminal-Fenster mit
`claude --resume <id>`.

Die Beschriftungen kommen dabei von selbst zurück: Der Speicherschlüssel ist
Arbeitsverzeichnis plus automatischer Name, und beides ist nach dem
Wiederherstellen dasselbe.

Als Startverzeichnis zählt der **erste** `cwd`-Eintrag einer Sitzungsdatei.
Spätere wandern mit, wenn die Sitzung zwischendurch das Verzeichnis wechselt —
danach zu greifen führt beim Wiederherstellen in den falschen Ordner.

## Fehlersuche

```
defaults write eu.lecon.termtint debug -bool YES   # danach App neu starten
tail -f ~/Library/Logs/TermTint.log
defaults delete eu.lecon.termtint debug            # wieder aus
```

Protokolliert jede Hover-Entscheidung mit Zeigerposition, Kandidaten und
Treffer-Abfrage. Abgeschaltet kostet es nichts — es wird nichts formatiert und
nichts geschrieben.
