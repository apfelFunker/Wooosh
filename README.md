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

> **Gatekeeper**
> Die App ist nicht notarisiert (siehe [Verteilung](#verteilung)). Beim ersten
> Öffnen meldet macOS, dass der Entwickler nicht überprüft werden konnte.
> Rechtsklick auf Wooosh.app → **Öffnen** → **Öffnen**. Nur einmal nötig.

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

> **Nach jedem Update erneut freigeben**
> TCC bindet eine Freigabe an die Code-Signatur. Eine ad-hoc signierte App
> bekommt bei jedem Build einen neuen CDHash, womit die alte Freigabe ungültig
> wird — der Eintrag steht dann zwar noch in der Liste, greift aber nicht mehr.
> Wooosh meldet sich in dem Fall von selbst wieder. In den Systemeinstellungen
> den Schalter aus- und wieder einschalten, oder den Eintrag mit „−" entfernen
> und neu hinzufügen.
>
> Mit einem Developer-ID-Zertifikat entfiele auch das: TCC prüft dann gegen die
> Team-ID statt gegen den Hash, und Freigaben überleben Updates.

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

Die App ist **ad hoc signiert und nicht notarisiert.** Für Notarisierung braucht
es ein „Developer ID Application"-Zertifikat aus dem kostenpflichtigen Apple
Developer Program; ein reines Apple-Development-Zertifikat reicht dafür nicht.

Das hat zwei Folgen:

1. **Gatekeeper blockiert den ersten Start.** Heruntergeladene Kopien tragen das
   Quarantäne-Merkmal. Umweg: Rechtsklick → Öffnen, einmalig pro Version.
2. **Freigaben überleben kein Update.** Ad hoc bedeutet, dass die Signatur nur
   aus dem CDHash des Bundles besteht. Der ändert sich bei jedem Build, und TCC
   hängt den Festplattenvollzugriff genau daran.

Mit einem Developer-ID-Zertifikat entfällt beides — dann ergänzt man in
`build-release.sh` das Signieren mit der Identität sowie
`xcrun notarytool submit` und `xcrun stapler staple`.

Als Mittelweg ohne bezahltes Programm ließe sich ein selbstsigniertes
Code-Signing-Zertifikat anlegen und dauerhaft verwenden. Gatekeeper besänftigt
das nicht, aber die Signatur-Identität bliebe über Builds hinweg stabil, sodass
erteilte Freigaben Updates überstehen.

## Anforderungen

macOS 14 oder neuer. Entwickelt und getestet auf macOS 26.5 mit Xcode 26.6.

## Lizenz

MIT
