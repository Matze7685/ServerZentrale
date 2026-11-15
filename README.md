# Server-Zentrale

Menüleisten-App für den Mac mini: zeigt grün/rot, ob Webserver und Seiten erreichbar sind,
verwaltet die Weiterleitungen (z. B. `ha.guderjahn.homeip.net` → Gerät im Heimnetz),
importiert das Caddyfile vom Raspberry und aktualisiert die Pizzaseite.

## Bauen

**Mit Xcode:** Ordner dieses Repos in Xcode öffnen (Datei → Öffnen, den Ordner wählen), oben „My Mac“ wählen, ▶ drücken.

**Im Terminal:** `bash bauen.sh` – baut die App, legt sie in „Programme“ ab und startet sie.

Bei Fehlern bitte die Ausgabe von `swift build` schicken.

## Erste Einrichtung

Menü → **Einrichtung …** → Adresse prüfen → **Einrichten**. Die App
1. installiert Caddy (Webserver) über Homebrew, falls es fehlt,
2. lädt die Pizzaseite von GitHub nach `~/mgPizza_mk1` (nicht in Schreibtisch/Dokumente/Downloads),
3. schreibt und prüft das Caddyfile,
4. legt den Hintergrunddienst an (startet bei jeder Anmeldung).

Danach am Router (UDM): außen TCP 80 → Mac:8081 und TCP 443 → Mac:8443.
Voraussetzung ist nur Homebrew ([brew.sh](https://brew.sh)).

## Wo was liegt

- `~/.mgpizza/` – Einstellungen: `Caddyfile`, `weiterleitungen.json`, `sites/weiterleitungen.caddy`, `eigene-domain`
- `~/Library/LaunchAgents/de.mgpizza.webserver.plist` – Hintergrunddienst
- `~/Library/Logs/mgpizza/` – Protokolle

Passwort-Hashes stehen nur in diesen lokalen Dateien, nie im Repo.
