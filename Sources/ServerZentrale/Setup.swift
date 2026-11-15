import Foundation
import Observation

/// Richtet den Webserver auf dem Mac ein: Caddy installieren, optional eine Webseite bereitstellen,
/// Caddyfile schreiben, Hintergrunddienst starten.
@MainActor
@Observable
final class SetupModel {
    static let localPort = 8080
    static let httpPort = 8081
    static let httpsPort = 8443

    var domain: String
    var siteFolder: String
    var siteSubfolder: String
    var siteRepoURL: String
    var log: [String] = []
    var isRunning = false
    var succeeded = false
    var error: String?

    private let model: ServerModel

    init(model: ServerModel) {
        self.model = model
        let saved = try? String(contentsOf: ServerModel.stateDir.appending(path: "eigene-domain"), encoding: .utf8)
        domain = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        siteFolder = model.siteFolder
        siteSubfolder = model.siteSubfolder
        siteRepoURL = model.siteRepoURL
        if siteFolder.isEmpty, let legacy = Self.legacySiteRoot() {
            // Webseite aus der früheren Einrichtung übernehmen
            if legacy.hasSuffix("/docs") {
                siteFolder = String(legacy.dropLast(5)); siteSubfolder = "docs"
            } else {
                siteFolder = legacy
            }
        }
    }

    /// Liest den Ordner der Webseite aus dem Caddyfile der früheren Version (~/.mgpizza/Caddyfile).
    private static func legacySiteRoot() -> String? {
        let file = ServerModel.home.appending(path: ".mgpizza/Caddyfile")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("root * ") else { continue }
            return t.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return nil
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
        guard Forward.validHost(host) else { fail("Adresse ungültig (z. B. meinhaus.example.net)"); return }

        let fm = FileManager.default
        let home = ServerModel.home.path
        let folder = siteFolder.trimmingCharacters(in: .whitespaces)
        let sub = siteSubfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let repoURL = siteRepoURL.trimmingCharacters(in: .whitespaces)
        let root = sub.isEmpty ? folder : folder + "/" + sub
        if folder.contains("\"") || sub.contains("\"") { fail("Der Ordnername darf kein Anführungszeichen enthalten."); return }

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

        // 2. Webseite (optional)
        say("2/5  Webseite …")
        if folder.isEmpty {
            say("  Keine eigene Webseite, nur Weiterleitungen.")
        } else {
            for forbidden in ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            where folder.hasPrefix("\(home)/\(forbidden)") {
                fail("Der Ordner liegt in „\(forbidden)“. Dort darf der Webserver im Hintergrund nicht lesen. Bitte einen Ordner direkt im Benutzerordner nehmen."); return
            }
            if !repoURL.isEmpty, !fm.fileExists(atPath: folder) {
                say("  Lade die Webseite herunter …")
                let r = await Shell.run("/usr/bin/git", ["clone", "--depth", "1", repoURL, folder])
                if !r.ok { fail("Herunterladen fehlgeschlagen: " + tail(r.output)); return }
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                fail("Ordner \(root) existiert nicht."); return
            }
            say("  ✓ Webseite: \(root)")
        }
        model.siteFolder = folder
        model.siteSubfolder = sub
        model.siteRepoURL = repoURL

        // 3. Caddyfile
        say("3/5  Einstellungen schreiben …")
        let state = ServerModel.stateDir
        do {
            try fm.createDirectory(at: state.appending(path: "sites"), withIntermediateDirectories: true)
            try fm.createDirectory(at: ServerModel.logsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: ServerModel.launchAgents, withIntermediateDirectories: true)
            let oldCaddyfile = try? Data(contentsOf: ForwardStore.caddyfile)
            try caddyfileText(domain: host, root: folder.isEmpty ? nil : root, state: state.path)
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
        say("  ✓ Einstellungen geprüft.")

        // 4. Hintergrunddienst
        say("4/5  Hintergrunddienst …")
        let domainTarget = "gui/\(getuid())"
        // Dienst der früheren Version beenden, sonst belegt er die Ports
        let legacyPlist = ServerModel.launchAgents.appending(path: ServerModel.legacyWebLabel + ".plist")
        if fm.fileExists(atPath: legacyPlist.path) {
            await Shell.run("/bin/launchctl", ["bootout", "\(domainTarget)/\(ServerModel.legacyWebLabel)"])
            try? fm.removeItem(at: legacyPlist)
            say("  Alter Dienst der früheren Version entfernt.")
        }
        let plistURL = ServerModel.launchAgents.appending(path: ServerModel.webLabel + ".plist")
        let logFile = ServerModel.logsDir.appending(path: "webserver.log").path
        let plist: [String: Any] = [
            "Label": ServerModel.webLabel,
            "ProgramArguments": [caddy, "run", "--config", ForwardStore.caddyfile.path, "--adapter", "caddyfile"],
            "EnvironmentVariables": ["HOME": home],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": logFile,
            "StandardErrorPath": logFile,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            fail(error.localizedDescription); return
        }
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
        say("Fertig. Am Router müssen diese Weiterleitungen stehen:")
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

    private func caddyfileText(domain: String, root: String?, state: String) -> String {
        let content = root.map { "\troot * \"\($0)\"\n\tfile_server" }
            ?? "\trespond \"Server-Zentrale läuft.\" 200"
        let local = root == nil ? "" : """

        # Nur auf dem Mac selbst, für die Statusprüfung der App
        http://127.0.0.1:\(Self.localPort) {
        \troot * "\(root!)"
        \tfile_server
        }

        """
        return """
        {
        \thttp_port \(Self.httpPort)
        \thttps_port \(Self.httpsPort)
        \tadmin off
        }

        # Von außen: https://\(domain) (Router leitet 80 -> \(Self.httpPort) und 443 -> \(Self.httpsPort) weiter)
        \(domain) {
        \(content)
        }
        \(local)
        # Weitere Weiterleitungen, von der App „Server-Zentrale“ verwaltet
        import "\(state)/sites/*.caddy"

        """
    }
}
