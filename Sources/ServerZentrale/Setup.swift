import Foundation
import Observation

/// Richtet den Webserver auf dem Mac mini ein (früher das Skript einrichten.sh):
/// Caddy installieren, Pizzaseite herunterladen, Caddyfile schreiben, Hintergrunddienst starten.
@MainActor
@Observable
final class SetupModel {
    static let pizzaRepoURL = "https://github.com/Matze7685/mgPizza_mk1.git"
    static let localPort = 8080
    static let httpPort = 8081
    static let httpsPort = 8443

    var domain: String
    var log: [String] = []
    var isRunning = false
    var succeeded = false
    var error: String?

    private let model: ServerModel

    init(model: ServerModel) {
        self.model = model
        let saved = try? String(contentsOf: ServerModel.stateDir.appending(path: "eigene-domain"), encoding: .utf8)
        domain = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "guderjahn.homeip.net"
    }

    static var isSetUp: Bool {
        FileManager.default.fileExists(atPath: ForwardStore.caddyfile.path)
    }

    private var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func say(_ text: String) { log.append(text) }

    private func fail(_ text: String) {
        error = text
        say("✗ " + text)
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        log = []; error = nil; succeeded = false

        let host = domain.trimmingCharacters(in: .whitespaces).lowercased()
        guard Forward.validHost(host) else { fail("Adresse ungültig (z. B. guderjahn.homeip.net)"); return }

        let fm = FileManager.default
        let home = ServerModel.home.path

        // 1. Caddy
        say("1/5  Caddy (Webserver) …")
        if ForwardStore.caddyBinary == nil {
            guard let brew else {
                fail("Homebrew fehlt. Bitte einmal im Terminal installieren (siehe brew.sh) und hier erneut starten."); return
            }
            say("  Installiere Caddy, das dauert etwa eine Minute …")
            let r = await Shell.run(brew, ["install", "caddy"])
            if !r.ok { fail("Caddy-Installation fehlgeschlagen: " + tail(r.output)); return }
        }
        guard let caddy = ForwardStore.caddyBinary else { fail("Caddy nicht gefunden."); return }
        say("  ✓ Caddy ist da.")

        // 2. Pizzaseite
        say("2/5  Pizzaseite …")
        let repo = model.repoPath
        for forbidden in ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
        where repo.hasPrefix("\(home)/\(forbidden)") {
            fail("Der Ordner \(repo) liegt in „\(forbidden)“. Dort darf der Webserver im Hintergrund nicht lesen. Bitte einen Ordner direkt im Benutzerordner nehmen."); return
        }
        if !fm.fileExists(atPath: repo + "/docs/index.html") {
            if fm.fileExists(atPath: repo) && ((try? fm.contentsOfDirectory(atPath: repo))?.isEmpty == false) {
                fail("In \(repo) liegt schon etwas, aber keine Pizzaseite (docs/index.html)."); return
            }
            say("  Lade die Pizzaseite von GitHub …")
            let r = await Shell.run("/usr/bin/git", ["clone", "--depth", "1", Self.pizzaRepoURL, repo])
            if !r.ok { fail("Herunterladen fehlgeschlagen: " + tail(r.output)); return }
        }
        guard fm.fileExists(atPath: repo + "/docs/index.html") else { fail("Keine Pizzaseite unter \(repo)/docs gefunden."); return }
        say("  ✓ Pizzaseite liegt in \(repo)")

        // 3. Caddyfile
        say("3/5  Einstellungen schreiben …")
        let state = ServerModel.stateDir
        let site = repo + "/docs"
        do {
            try fm.createDirectory(at: state.appending(path: "sites"), withIntermediateDirectories: true)
            try fm.createDirectory(at: ServerModel.logsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: ServerModel.launchAgents, withIntermediateDirectories: true)
            let oldCaddyfile = try? Data(contentsOf: ForwardStore.caddyfile)
            try caddyfileText(domain: host, site: site, state: state.path)
                .write(to: ForwardStore.caddyfile, atomically: true, encoding: .utf8)
            let check = await Shell.run(caddy, ["validate", "--config", ForwardStore.caddyfile.path, "--adapter", "caddyfile"])
            if !check.ok {
                if let oldCaddyfile { try? oldCaddyfile.write(to: ForwardStore.caddyfile) } else { try? fm.removeItem(at: ForwardStore.caddyfile) }
                fail("Caddy lehnt die Einstellungen ab: " + tail(check.output)); return
            }
            try host.write(to: state.appending(path: "eigene-domain"), atomically: true, encoding: .utf8)
        } catch {
            fail(error.localizedDescription); return
        }
        // Bereits gespeicherte Weiterleitungen behalten (Datei sites/weiterleitungen.caddy bleibt unverändert)
        say("  ✓ Einstellungen geprüft.")

        // 4. Hintergrunddienst
        say("4/5  Hintergrunddienst …")
        let plistURL = ServerModel.launchAgents.appending(path: ServerModel.webLabel + ".plist")
        let plist: [String: Any] = [
            "Label": ServerModel.webLabel,
            "ProgramArguments": [caddy, "run", "--config", ForwardStore.caddyfile.path, "--adapter", "caddyfile"],
            "EnvironmentVariables": ["HOME": home],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": ServerModel.logsDir.appending(path: "webserver.log").path,
            "StandardErrorPath": ServerModel.logsDir.appending(path: "webserver.log").path,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            fail(error.localizedDescription); return
        }
        let domainTarget = "gui/\(getuid())"
        await Shell.run("/bin/launchctl", ["bootout", "\(domainTarget)/\(ServerModel.webLabel)"])
        try? await Task.sleep(for: .seconds(2))
        let boot = await Shell.run("/bin/launchctl", ["bootstrap", domainTarget, plistURL.path])
        if !boot.ok { fail("Dienst konnte nicht gestartet werden: " + tail(boot.output)); return }

        // 5. Prüfen
        say("5/5  Warte auf den Webserver …")
        var up = false
        for _ in 0..<15 {
            if case .ok = await ServerModel.probe(URL(string: "http://127.0.0.1:\(Self.localPort)/")!) { up = true; break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard up else {
            fail("Der Webserver antwortet nicht. Protokoll: Menü → Protokolle anzeigen."); return
        }
        say("  ✓ Läuft: http://127.0.0.1:\(Self.localPort)/")
        say("")
        say("Fertig. Am Router (UDM) müssen diese Weiterleitungen stehen:")
        say("  außen TCP 80  → dieser Mac, Port \(Self.httpPort)")
        say("  außen TCP 443 → dieser Mac, Port \(Self.httpsPort)")
        say("Beim ersten Aufruf von https://\(host)/ holt Caddy das Zertifikat (bis zu einer Minute).")
        say("Fragt macOS nach eingehenden Verbindungen für „caddy“: Erlauben.")
        succeeded = true
        await model.refresh()
    }

    private func tail(_ output: String) -> String {
        output.split(separator: "\n").suffix(3).joined(separator: " ")
    }

    private func caddyfileText(domain: String, site: String, state: String) -> String {
        """
        {
        \thttp_port \(Self.httpPort)
        \thttps_port \(Self.httpsPort)
        \tadmin off
        }

        # Von außen: https://\(domain) (Router leitet 80 -> \(Self.httpPort) und 443 -> \(Self.httpsPort) weiter)
        \(domain) {
        \troot * "\(site)"
        \tfile_server
        }

        # Nur auf dem Mac selbst, für die Statusprüfung der App
        http://127.0.0.1:\(Self.localPort) {
        \troot * "\(site)"
        \tfile_server
        }

        # Weitere Weiterleitungen, von der App „Server-Zentrale“ verwaltet
        import "\(state)/sites/*.caddy"

        """
    }
}
