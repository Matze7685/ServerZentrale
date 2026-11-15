# Server-Zentrale

Menüleisten-App für den Mac mini: zeigt grün/rot, ob Webserver und Seiten erreichbar sind,
verwaltet die Weiterleitungen (z. B. `ha.guderjahn.homeip.net` → Gerät im Heimnetz),
importiert das Caddyfile vom Raspberry und aktualisiert die Pizzaseite.

## Bauen

**Mit Xcode:** Ordner dieses Repos in Xcode öffnen (Datei → Öffnen, den Ordner wählen), oben „My Mac“ wählen, ▶ drücken.

**Im Terminal:** `bash bauen.sh` – baut die App, legt sie in „Programme“ ab und startet sie.

Bei Fehlern bitte die Ausgabe von `swift build` schicken.

## Voraussetzung

Die App steuert den Webserver (Caddy), der bisher mit `hosting/mac-mini/einrichten.sh --domain …`
aus dem Repo mgPizza_mk1 eingerichtet wird. Sie liest und schreibt dabei:

- `~/.mgpizza/weiterleitungen.json` und `~/.mgpizza/sites/weiterleitungen.caddy` (die Weiterleitungen)
- `~/.mgpizza/Caddyfile` (wird von einrichten.sh angelegt)
- Dienst `de.mgpizza.webserver` (launchd)

Passwort-Hashes stehen nur in diesen lokalen Dateien, nie im Repo.
