<div align="center">

# Wooosh

**Räumt den Zwischenspeicher ab, der auf dem Mac als „Systemdaten" auftaucht und dort unbegrenzt anwächst.**

Läuft im Hintergrund. Kein Fenster, kein Menüleistensymbol, nichts zu bedienen.

</div>

---

## Das Problem

`bird`, der iCloud-Drive-Dienst von macOS, legt beim Synchronisieren eine
Staging-Kopie jeder übertragenen Datei an — und räumt sie nach Abschluss nicht
zuverlässig wieder ab. Die Kopien sammeln sich unbegrenzt in
`~/Library/Caches/CloudKit/com.apple.bird`.

Auf dem Referenzsystem waren es **47 GB in 1.826 Dateien**, in einem früheren
Fall über 300 GB. In der Speicherübersicht taucht das als „Systemdaten" auf,
also als etwas, das man nicht anfassen kann.

Nach dem ersten Durchlauf von Wooosh: **820 KB.**

```
16:48:14  iCloud Drive Transfer-Staging (bird): 34,01 GB freigegeben
16:48:14  Sweep fertig: 34,01 GB in 1347 Objekten, 1.8 s
16:48:14  Frei: 176,52 GB -> 210,53 GB
```

## Installation

1. Aktuelle `Wooosh-x.y.z.zip` aus den [Releases](../../releases) laden
2. Entpacken und **Wooosh.app in den Programme-Ordner ziehen**
3. Öffnen — das Fenster führt durch die einmalige Freigabe

Beim ersten Start trägt sich Wooosh selbst als Anmeldeobjekt ein. Es gibt keinen
Installer und nichts, was zurückbleibt: Wooosh.app in den Papierkorb ziehen
entfernt auch den Autostart.

Die App ist mit Developer ID signiert und notarisiert, öffnet sich also per
Doppelklick ohne Gatekeeper-Umweg.

### Festplattenvollzugriff

**Ohne diesen Schritt tut Wooosh nichts.**

`~/Library/Caches/CloudKit` ist von macOS per TCC geschützt. Wooosh bekommt dort
`EPERM, Operation not permitted`.

Das Tückische: alle höheren macOS-APIs melden eine TCC-Sperre als *leeres
Verzeichnis*. Ohne Gegenmaßnahme sähe eine blockierte App exakt aus wie eine,
die sauber aufgeräumt hat. Wooosh fragt bei leerem Treffer deshalb per
`opendir` den echten `errno` ab und unterscheidet die beiden Fälle ausdrücklich:

```
[WARN] cloudkit.bird: keine Treffer für ~/Library/Caches/CloudKit/com.apple.bird/*/Assets
       — nicht lesbar (Operation not permitted) — vermutlich fehlt Full Disk Access
```

Erkennt Wooosh die Sperre, zeigt es das Einrichtungsfenster und schickt
zusätzlich eine Systemmitteilung — beim Start durch die Anmeldung gibt es sonst
keinen Hinweis darauf, dass die App nur wartet.

Die Freigabe selbst:

1. Systemeinstellungen → Datenschutz & Sicherheit → **Festplattenvollzugriff**
2. „+", dann Wooosh aus dem Programme-Ordner auswählen
3. Schalter aktivieren

**macOS beendet Wooosh dabei.** Das gehört so: neue Berechtigungen greifen erst
beim nächsten Start. Fragt macOS nach, „Beenden & neu öffnen" wählen —
verschwindet die App stattdessen kommentarlos, einmal neu öffnen.

Ist das Fenster während der Freigabe offen, erkennt Wooosh sie innerhalb von
zwei Sekunden und legt sofort los.

Einmal erteilt, bleibt die Freigabe über Updates hinweg bestehen: TCC bindet sie
an die Code-Signatur, und die ist mit Developer ID über die Team-ID stabil. Bei
einer ad-hoc signierten App wäre das anders — dort besteht die Signatur nur aus
dem CDHash des Bundles, der sich bei jedem Build ändert, womit die Freigabe
jedes Mal verfällt.

## Was gelöscht wird

Nur Zwischenspeicher, die einem **Systemdienst** gehören. Alles, was einer
Anwendung gehört — ihr Cache, ihr Store, ihre heruntergeladenen Assets — ist
tabu, unabhängig davon, wie leicht es sich neu aufbauen ließe.

| Ziel | Karenz | Was |
|---|---|---|
| `cloudkit.bird` | 2 h | iCloud-Drive Transfer-Staging von `bird` |
| `iconservices` | 7 d | systemweiter Icon-Cache — braucht root, daher aus |

### Was nie angefasst wird

Diese Pfade stehen in einer eigenen Liste (`TargetCatalogue.observed`), die der
Sweeper nicht liest. Es gibt keine Einstellung, die daraus ein Löschziel macht.

`~/Library/Application Support/Claude` · `~/Library/Caches/com.openai.codex` ·
`~/Library/Caches/net.whatsapp.WhatsApp` · `~/Library/Caches/*.ShipIt` ·
`~/Library/Developer/Xcode` · `~/Library/Developer/CoreSimulator/Devices` ·
`/Library/Developer/CoreSimulator/Caches` · `~/Library/Caches/ms-playwright` ·
`~/Library/Caches/Homebrew` · `~/Library/Caches/node-gyp` ·
`~/Library/Caches/pip` · `~/Library/Caches/Adobe Camera Raw 2` ·
`~/Library/Caches/Steam` · `~/Library/Mobile Documents` ·
`/private/var/vm/sleepimage` · Papierkorb · Downloads

## Sicherheitskonzept

Jede Löschung passiert ein Gate, das **fail closed** arbeitet: eine Prüfung, die
sich nicht auswerten lässt, lehnt den Kandidaten ab, statt ihn durchzuwinken.
Lässt sich `lsof` nicht ausführen, wird der komplette Durchlauf abgebrochen.

1. **Allowlist** — ein Kandidat muss unterhalb eines fest einkompilierten Roots
   liegen.
2. **Geschützte Pfade** — Home, Dokumente, Schreibtisch, Bilder, Mobile
   Documents, Keychains, Systemverzeichnisse und deren Vorfahren sind hart
   gesperrt. Ein Ziel, das Vorfahr eines geschützten Pfads ist, wird abgelehnt.
3. **Symlink-Auflösung** — Pfade werden aufgelöst und *danach* erneut gegen die
   Allowlist geprüft.
4. **Volume-Grenze** — weicht die Device-ID eines Kindes vom Container ab, ist
   es ein Mountpoint und wird ausgelassen.
5. **Karenzzeit** — pro Ziel. Bei Verzeichnissen wird der gesamte Teilbaum nach
   dem jüngsten Zeitstempel durchsucht; die mtime eines Ordners allein bewegt
   sich nicht, wenn sich ein Enkel ändert.
6. **Offene Handles** — ein `lsof`-Schnappschuss pro Durchlauf. Was ein Prozess
   offen hat, auch irgendwo unterhalb eines Verzeichnisses, bleibt liegen.
7. **Container bleiben stehen** — gelöscht werden immer nur die *Kinder* eines
   Zielverzeichnisses, nie dieses selbst.

Dass die 47 GB tote Reste waren und keine laufende Übertragung, wurde vor dem
Bau belegt: kein Schreibzugriff seit Stunden, keine Größenänderung über eine
Messperiode, null offene Handles von `bird` und `cloudd`. Genau diese Prüfungen
sind das Gate.

## Auslöser

- **Intervall** — alle 15 Minuten, plus einmal kurz nach dem Start.
- **FSEvents** — ein Watcher auf `~/Library/Caches/CloudKit/com.apple.bird`. Das
  erste Ereignis einer Serie startet eine 90-Sekunden-Uhr, spätere Ereignisse
  werden eingesammelt.

Bewusst ein *Throttle*, kein zurücksetzender Debounce: auf einem belebten
Cache-Verzeichnis käme der nächste Schreibzugriff immer vor dem Ablauf des
Timers, und der ereignisgetriebene Durchlauf würde nie feuern. Eine laufende
Übertragung zu schützen ist ohnehin Aufgabe des Gates, nicht des Zeitplans.

## Konfiguration

Optional. `~/Library/Application Support/Wooosh/config.json`

```json
{
  "enabled": true,
  "dryRun": false,
  "sweepIntervalMinutes": 15,
  "watchDebounceSeconds": 90,
  "maxSweepSeconds": 600,
  "verboseLogging": false,
  "targets": { "cloudkit.bird": { "minimumAgeHours": 6 } }
}
```

Protokoll: `~/Library/Logs/Wooosh/wooosh.log`

## Bauen

```bash
brew install xcodegen
cd Wooosh
./build-release.sh
```

Das Xcode-Projekt wird aus `project.yml` erzeugt und ist nicht eingecheckt —
neue Dateien müssen so nie von Hand eingetragen werden. Das App-Symbol kommt als
Icon-Composer-Paket aus `Icon/schild.icon`.

```
Wooosh/
├── Icon/                  schild.icon, schild.png, schild.pxd
└── Wooosh/
    ├── project.yml        Projektdefinition für xcodegen
    ├── build-release.sh
    ├── Resources/         Info.plist, Icon
    └── Sources/
        ├── Engine/        Sweeper, Sicherheits-Gate, Ziele, Konfiguration
        └── App/           Fenster, Zugriffsprüfung, Anmeldeobjekt, Mitteilungen
```

## Verteilung

Signiert mit **Developer ID Application (Team 9FZVQ84P7B)**, Hardened Runtime
aktiv, notarisiert und mit angehefetem Ticket. Damit startet die App per
Doppelklick, auch offline, und erteilte Freigaben überleben Updates.

`build-release.sh` erledigt die ganze Kette: archivieren, mit Developer ID
exportieren, packen, notarisieren, Ticket anheften, neu packen und das
Gatekeeper-Urteil ausgeben.

### Zugang für die Notarisierung

Einmalig pro Rechner:

```bash
xcrun notarytool store-credentials "wooosh-notary" \
    --apple-id DEINE@APPLE.ID --team-id 9FZVQ84P7B
```

Fragt nach einem app-spezifischen Passwort (appleid.apple.com → Anmeldung &
Sicherheit → App-spezifische Passwörter) und legt es im Schlüsselbund ab. Fehlt
das Profil, baut das Skript trotzdem eine signierte App, überspringt aber die
Notarisierung und sagt das deutlich.

### Zwei Fallstricke im Signierweg

**Signiert wird beim Export, nicht beim Bauen.** Xcode lehnt eine manuell
gesetzte Developer-ID-Identität bei automatischer Signierung ab
(„conflicting provisioning settings"). Deshalb archiviert das Skript mit
automatischer Signierung und lässt `-exportArchive` mit `method: developer-id`
neu signieren.

**Das Zertifikat ist für `security(1)` unsichtbar.** Xcode legt automatisch
verwaltete Identitäten in der Data-Protection-Keychain ab, die das
`security`-CLI nicht enumeriert — `security find-identity` zeigt die Developer
ID also nicht an, obwohl sie existiert und funktioniert. Ein direktes
`codesign -s "Developer ID Application"` findet sie ebenfalls nicht. Der Weg
über `xcodebuild -exportArchive` ist deshalb nicht nur bequemer, sondern
notwendig.

## Anforderungen

macOS 14 oder neuer. Entwickelt und getestet auf macOS 26.5 mit Xcode 26.6.

## Lizenz

MIT
