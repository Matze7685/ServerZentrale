# Server-Zentrale

Menüleisten-App für einen Mac, der als Zentrale für Weiterleitungen dient: Adressen wie
`ha.meinhaus.example.net` werden mit automatischem https-Zertifikat an Geräte im Heimnetz weitergereicht.

- Weiterleitungen anlegen, ändern, löschen, optional mit Passwortschutz
- Caddyfile eines alten Servers importieren
- Status grün/rot für Webserver und jede Weiterleitung
- Optional: eine eigene Webseite unter der Hauptadresse ausliefern und per Git aktualisieren

## Bauen

**Mit Xcode:** Ordner dieses Repos öffnen (Ablage → Öffnen), oben „My Mac“ wählen, ▶ drücken.

**Im Terminal:** `bash bauen.sh` – baut die App, legt sie in „Programme“ ab und startet sie.

Bei Fehlern bitte die Ausgabe von `swift build` schicken.

## Erste Einrichtung

Menü → **Einrichtung …** → Adresse eintragen → **Einrichten**. Die App
1. installiert Caddy (Webserver) über Homebrew, falls es fehlt,
2. stellt optional eine Webseite bereit (Ordner wählen oder Git-Adresse zum Herunterladen angeben),
3. schreibt und prüft das Caddyfile,
4. legt den Hintergrunddienst an (startet bei jeder Anmeldung).

Danach am Router: außen TCP 80 → Mac:8081 und TCP 443 → Mac:8443.
Voraussetzung ist nur Homebrew ([brew.sh](https://brew.sh)).

Wer eine frühere Version benutzt hat (Ordner `~/.mgpizza`): Einstellungen und Weiterleitungen werden
beim ersten Start übernommen, danach einmal „Einrichten“ drücken. Der alte Dienst wird dabei ersetzt.

## Wo was liegt

- `~/.serverzentrale/` – `Caddyfile`, `weiterleitungen.json`, `sites/weiterleitungen.caddy`, `eigene-domain`
- `~/Library/LaunchAgents/de.serverzentrale.webserver.plist` – Hintergrunddienst
- `~/Library/Logs/ServerZentrale/` – Protokolle

Passwort-Hashes stehen nur in diesen lokalen Dateien, nie im Repo.
