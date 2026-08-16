# DiskWarden

Ein unsichtbarer Hintergrunddienst für macOS, der genau die Caches abräumt, die
in „Über diesen Mac → Speicher" als **Systemdaten** auftauchen und dort auf
dutzende bis hunderte Gigabyte anwachsen können.

Kein Fenster, kein Menüleisten-Icon, kein Dock-Eintrag. Ein LaunchAgent, der
beim Login startet und danach von selbst arbeitet.

---

## Warum das nötig ist

Der mit Abstand größte Einzelposten auf diesem Mac war
`~/Library/Caches/CloudKit/com.apple.bird`.

`bird` — der iCloud-Drive-Daemon — legt beim Synchronisieren eine Staging-Kopie
jeder übertragenen Datei an und räumt sie nach Abschluss nicht zuverlässig ab.
Die Kopien sammeln sich unbegrenzt an. Auf diesem Rechner waren es bei der
ersten Messung **47 GB in 1.826 Assets**, in einem früheren Fall über 300 GB.

Dass es sich um tote Reste handelt und nicht um eine laufende Übertragung,
lässt sich belegen:

| Prüfung | Ergebnis |
|---|---|
| Zeitstempel aller Assets | alle vom selben Tag, letzter Schreibzugriff 06:04 |
| `find -newermt "-2 hours"` | 0 Dateien |
| Größenänderung über 20 s | 0 MB — der Sync steht still |
| `lsof` auf `bird` und `cloudd` | 0 offene Handles auf den Cache |

Genau diese Prüfungen bilden das Sicherheits-Gate von DiskWarden. Es löscht
nichts, was ein Prozess offen hat oder was kürzlich beschrieben wurde.

## Messung auf diesem System

Was die Analyse ergeben hat, geordnet nach Größe:

| Ort | Größe | Urteil |
|---|---|---|
| `~/Library/Caches/CloudKit/com.apple.bird` | 47,4 GB | Systemdaemon — **wird abgeräumt** |
| `~/Library/Mobile Documents/com~apple~CloudDocs` | 74,9 GB | echte Daten, bleibt |
| `~/Library/Developer/CoreSimulator/Devices` | 15,9 GB | Xcode, bleibt |
| `~/Library/Developer/Xcode` | 15,2 GB | Xcode, bleibt |
| `~/Library/Application Support/Claude` | 12,8 GB | App-eigener Store, bleibt |
| `/Library/Developer/CoreSimulator/Caches` | 6,1 GB | gehört zu Xcode, bleibt |
| übrige App-Caches | ~3,5 GB | bleiben |

Der Sweep gibt **47,4 GB** frei und rührt sonst nichts an.

---

## Sicherheitskonzept

Jede einzelne Löschung passiert ein Gate, das **fail closed** arbeitet: Eine
Prüfung, die sich nicht auswerten lässt, lehnt den Kandidaten ab, statt ihn
durchzuwinken. Lässt sich `lsof` nicht ausführen, wird der komplette Sweep
abgebrochen.

1. **Allowlist.** Ein Kandidat muss unterhalb eines fest einkompilierten Roots
   liegen (`~/Library/Caches`, `~/Library/Application Support`,
   `/Library/Caches`, `/Library/Developer/CoreSimulator/Caches`).
2. **Geschützte Pfade.** Home, Dokumente, Schreibtisch, Bilder, Mobile
   Documents, Keychains, Systemverzeichnisse und deren Vorfahren sind hart
   gesperrt. Ein Ziel, das Vorfahr eines geschützten Pfads ist, wird abgelehnt.
3. **Symlink-Auflösung.** Pfade werden aufgelöst und *danach* erneut gegen die
   Allowlist geprüft. Ein Link aus dem Cache heraus führt nirgendwohin.
4. **Volume-Grenze.** Weicht die Device-ID eines Kindes vom Container ab, ist es
   ein Mountpoint und wird ausgelassen.
5. **Karenzzeit.** Pro Ziel konfiguriert. Bei Verzeichnissen wird der gesamte
   Teilbaum nach dem jüngsten Zeitstempel durchsucht — die mtime eines Ordners
   allein bewegt sich nicht, wenn sich ein Enkel ändert.
6. **Offene Handles.** Ein `lsof`-Schnappschuss pro Sweep. Was ein Prozess
   offen hat — auch irgendwo unterhalb eines Verzeichnisses — bleibt liegen.
7. **Container bleiben stehen.** Gelöscht werden immer nur die *Kinder* eines
   Zielverzeichnisses, nie das Verzeichnis selbst. Ein falsch geratener Glob
   kann damit schlimmstenfalls einen Cache leeren, niemals einen Baum entfernen,
   den eine App besitzt.

Nachvollziehen lässt sich das ohne Risiko:

```bash
diskwarden --dry-run --verbose
```

Jede Entscheidung wird protokolliert, auch jede Ablehnung mit Begründung
(`zu jung`, `von einem Prozess geöffnet`, `Symlink verlässt erlaubten Bereich`).

---

## Installation

```bash
./install.sh
```

Das baut das Release-Binary, installiert es nach
`~/Library/Application Support/DiskWarden/bin`, signiert es ad hoc, schreibt den
LaunchAgent und startet ihn. Der Dienst läuft ab dann bei jedem Login.

### Full Disk Access ist zwingend

Ohne diesen Schritt räumt DiskWarden das Wichtigste nicht ab.

`~/Library/Caches/CloudKit` ist von macOS per TCC geschützt. Eine Shell hat den
Zugriff meist schon geerbt, ein LaunchAgent erbt ihn **nicht** — er bekommt
`EPERM, Operation not permitted`. Das Tückische daran: alle höheren APIs melden
dann einfach ein leeres Verzeichnis. Ohne Gegenmaßnahme sähe ein blockierter
Sweep exakt aus wie ein sauberer.

DiskWarden unterscheidet die beiden Fälle deshalb explizit, indem es bei einem
leeren Treffer per `opendir` den echten `errno` abfragt:

```
[WARN] cloudkit.bird: keine Treffer für ~/Library/Caches/CloudKit/com.apple.bird/*/Assets
       — /Users/…/Caches/CloudKit/com.apple.bird: nicht lesbar (Operation not
       permitted) — vermutlich fehlt Full Disk Access
```

`install.sh` erkennt das am Log des Agents und leitet durch die Freigabe:

1. Systemeinstellungen → Datenschutz & Sicherheit → **Festplattenvollzugriff**
2. „+", dann ⇧⌘G und
   `~/Library/Application Support/DiskWarden/bin` einfügen
3. `diskwarden` auswählen, Schalter aktivieren

Danach:

```bash
launchctl kickstart -k gui/$(id -u)/com.juliuspaetzke.diskwarden
```

Der Zugriff muss dem **Binary** erteilt werden, nicht dem Terminal. Deshalb ist
`diskwarden --check-access` aus der Shell nur bedingt aussagekräftig — es misst
den Kontext des aufrufenden Prozesses. Verbindlich ist das Log des Agents.

Entfernen:

```bash
./uninstall.sh
```

## Betrieb

```bash
diskwarden --status        # bisher freigegebener Speicher, Konfiguration
diskwarden --report        # aktuelle Größe jedes Ziels
diskwarden --explain       # jedes Ziel mit Begründung, warum es löschbar ist
diskwarden --check-access  # welche Ziele sind lesbar
diskwarden --dry-run       # Sweep simulieren, nichts löschen
diskwarden --once          # einen Sweep sofort ausführen
```

Log mitlesen:

```bash
tail -f ~/Library/Logs/DiskWarden/diskwarden.log
```

## Auslöser

Zwei, damit nichts liegen bleibt und trotzdem schnell reagiert wird:

- **Intervall** — alle 15 Minuten, plus einmal kurz nach dem Login.
- **FSEvents** — ein Watcher auf dem tiefsten wildcard-freien Vorfahren jedes
  Ziels. Das erste Ereignis einer Serie startet eine 90-Sekunden-Uhr, spätere
  Ereignisse werden eingesammelt.

Bewusst ein *Throttle*, kein zurücksetzender Debounce: auf einem belebten
Cache-Verzeichnis käme der nächste Schreibzugriff immer vor dem Ablauf des
Timers, und der ereignisgetriebene Sweep würde schlicht nie feuern. Eine
laufende Übertragung zu schützen ist ohnehin nicht Aufgabe des Zeitplans,
sondern des Gates — das prüft offene Handles und Zeitstempel pro Datei.

## Konfiguration

`~/Library/Application Support/DiskWarden/config.json`

```json
{
  "enabled": true,
  "dryRun": false,
  "sweepIntervalMinutes": 15,
  "watchDebounceSeconds": 90,
  "maxSweepSeconds": 600,
  "verboseLogging": false,
  "targets": {
    "playwright": { "enabled": false },
    "whatsapp": { "minimumAgeHours": 720 }
  }
}
```

| Schlüssel | Wirkung |
|---|---|
| `enabled` | Hauptschalter. `false` legt den Dienst schlafen, ohne ihn zu entladen. |
| `dryRun` | Protokolliert, löscht nicht. |
| `sweepIntervalMinutes` | Intervall des periodischen Sweeps, Minimum 1. |
| `watchDebounceSeconds` | Ruhezeit nach dem letzten Dateisystem-Ereignis. |
| `skipWhenFreeGigabytesAbove` | Sweep überspringen, solange so viel frei ist. |
| `maxSweepSeconds` | Zeitbudget pro Sweep; der Rest wird vertagt. |
| `targets.<id>.enabled` | Einzelnes Ziel an-/abschalten. |
| `targets.<id>.minimumAgeHours` | Karenzzeit dieses Ziels überschreiben. |

Ziel-IDs liefert `diskwarden --explain`.

## Ziele

Ab 1.1.0 gilt eine harte Richtlinie: **abgeräumt werden nur Caches, die einem
Systemdaemon gehören.** Alles, was einer Anwendung gehört — ihr Cache, ihr
Store, ihre heruntergeladenen Assets — ist tabu, unabhängig davon, wie leicht
es sich neu aufbauen ließe.

| ID | Karenz | Was |
|---|---|---|
| `cloudkit.bird` | 2 h | iCloud-Drive Transfer-Staging von `bird` |
| `iconservices` | 7 d | systemweiter Icon-Cache — **braucht root** |

### Zum root-Ziel

Ein User-LaunchAgent kann nicht nach `/Library` schreiben. `iconservices` ist
deshalb standardmäßig deaktiviert und wird bei jedem Sweep mit Begründung
übersprungen statt stillschweigend ignoriert.

Ein root-LaunchDaemon wäre technisch möglich, wurde aber bewusst nicht gebaut:
ein Prozess mit root-Rechten, der selbstständig im Home-Verzeichnis löscht, ist
das Risiko für ein paar GB Icon-Cache nicht wert.

## Was DiskWarden nie anfasst

`--report` misst diese Pfade weiterhin und zeigt sie unter **WIRD NIE
ANGEFASST**, damit das Speicherbild vollständig bleibt. Der Sweeper sieht sie
nicht: sie stehen in einer eigenen Liste (`TargetCatalogue.observed`), die
weder gelesen noch über die Konfiguration erreichbar ist. Es gibt keinen
Schalter, der aus einem beobachteten Pfad ein Löschziel macht.

| Pfad | Warum |
|---|---|
| `~/Library/Application Support/Claude/` | App-eigener Store, u. a. 12 GB `vm_bundles` |
| `~/Library/Caches/com.openai.codex`, `Codex` | App-eigener Cache |
| `~/Library/Caches/net.whatsapp.WhatsApp` | App-eigener Cache |
| `~/Library/Caches/*.ShipIt` | liegt in den Cache-Ordnern einzelner Apps |
| `~/Library/Developer/Xcode` | Entwickler-Toolchain |
| `~/Library/Developer/CoreSimulator/Devices` | Entwickler-Toolchain |
| `/Library/Developer/CoreSimulator/Caches` | gehört zu Xcode |
| `~/Library/Caches/ms-playwright` | dedizierter Store |
| `~/Library/Caches/Homebrew` | dedizierter Store, siehe `brew cleanup` |
| `~/Library/Caches/node-gyp`, `pip` | dedizierte Stores |
| `~/Library/Caches/Adobe Camera Raw 2` | App-eigener Cache |
| `~/Library/Caches/Steam` | App-eigener Cache |
| `~/Library/Mobile Documents` | echte iCloud-Drive-Daten, 75 GB |
| `/private/var/vm/sleepimage` | vom Kernel verwaltet |
| Papierkorb, Downloads, alles außerhalb der Allowlist | — |

## Anforderungen

macOS 14 oder neuer, Swift 6 Toolchain zum Bauen. Entwickelt und getestet auf
macOS 26.5 mit Xcode 26.6.
