import Foundation
import Observation

/// Liest den Zustand des Mac-mini-Servers und führt Aktionen aus.
/// Pfade und Dienstnamen passen zu hosting/mac-mini/einrichten.sh.
@MainActor
@Observable
final class ServerModel {
    enum Health: Equatable {
        case unknown, ok, warning(String), down(String)

        var symbol: String {
            switch self {
            case .unknown: "circle.dashed"
            case .ok: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .down: "xmark.octagon.fill"
            }
        }
        var isDown: Bool {
            if case .down = self { return true }
            return false
        }
        var detail: String? {
            switch self {
            case .warning(let t), .down(let t): t
            default: nil
            }
        }
    }

    struct Check: Identifiable {
        let id: String
        let title: String
        var health: Health = .unknown
        var url: URL?
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// Einstellungen. Beim ersten Zugriff wird ein alter Ordner ~/.mgpizza (frühere Version) übernommen.
    static let stateDir: URL = {
        let fm = FileManager.default
        let new = home.appending(path: ".serverzentrale")
        let old = home.appending(path: ".mgpizza")
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
            try? fm.copyItem(at: old, to: new)
            // Das alte Caddyfile verweist auf den alten Ordner; die Einrichtung schreibt es neu.
            try? fm.removeItem(at: new.appending(path: "Caddyfile"))
        }
        return new
    }()
    static let logsDir = home.appending(path: "Library/Logs/ServerZentrale")
    static let launchAgents = home.appending(path: "Library/LaunchAgents")
    static let webLabel = "de.serverzentrale.webserver"
    static let legacyWebLabel = "de.mgpizza.webserver"

    var checks: [Check] = []
    var lastUpdate: Date?
    var isBusy = false
    var message: String?

    /// Ordner einer eigenen Webseite, die unter der Hauptadresse ausgeliefert wird (leer = keine).
    var siteFolder: String {
        get { UserDefaults.standard.string(forKey: "siteFolder") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "siteFolder") }
    }
    /// Unterordner darin, der die Seite enthält (z. B. "docs"), leer = der Ordner selbst.
    var siteSubfolder: String {
        get { UserDefaults.standard.string(forKey: "siteSubfolder") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "siteSubfolder") }
    }
    /// Git-Adresse der Webseite zum Herunterladen und Aktualisieren (leer = keine).
    var siteRepoURL: String {
        get { UserDefaults.standard.string(forKey: "siteRepoURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "siteRepoURL") }
    }
    var hasSite: Bool { !siteFolder.isEmpty }
    var siteRoot: String { siteSubfolder.isEmpty ? siteFolder : siteFolder + "/" + siteSubfolder }
    /// Liegt die Webseite in einem Git-Ordner (dann gibt es „Webseite aktualisieren“)?
    var canUpdateSite: Bool {
        guard hasSite else { return false }
        var url = URL(fileURLWithPath: siteRoot)
        for _ in 0..<3 {
            if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) { return true }
            url = url.deletingLastPathComponent()
        }
        return false
    }

    /// Öffentliche Adresse, z. B. https://meinhaus.example.net (aus ~/.serverzentrale/eigene-domain).
    var publicURL: URL? {
        let file = Self.stateDir.appending(path: "eigene-domain")
        guard let host = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        return URL(string: "https://\(host)/")
    }

    var menuBarSymbol: String {
        checks.contains(where: \.health.isDown) ? "exclamationmark.triangle" : "server.rack"
    }

    @ObservationIgnored private var timer: Timer?

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: - Prüfen

    func refresh() async {
        var result: [Check] = []

        var web = Check(id: "web", title: "Webserver (Caddy)")
        let launchd = await Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.webLabel)"])
        web.health = launchd.output.contains("state = running") ? .ok : .down("Läuft nicht")
        result.append(web)

        if hasSite {
            var local = Check(id: "local", title: "Webseite auf dem Mac", url: URL(string: "http://127.0.0.1:8080/"))
            local.health = await Self.probe(local.url!)
            result.append(local)
        }

        if let url = publicURL {
            var pub = Check(id: "public", title: url.host() ?? url.absoluteString, url: url)
            pub.health = await Self.probe(url)
            result.append(pub)
        }

        checks = result
        lastUpdate = .now
    }

    /// Ruft eine Adresse ab. Zertifikatsfehler und Zeitüberschreitungen werden als Fehler gemeldet.
    static func probe(_ url: URL) async -> Health {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<400: return .ok
            case 400..<500: return .warning("Antwortet mit Fehler \(code)")
            default: return .down("Antwortet mit Fehler \(code)")
            }
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                return .down("Zertifikat ungültig")
            case .timedOut: return .down("Keine Antwort")
            case .cannotConnectToHost: return .down("Nicht erreichbar")
            default: return .down(error.localizedDescription)
            }
        } catch {
            return .down(error.localizedDescription)
        }
    }

    // MARK: - Aktionen

    func restartWebserver() async {
        await perform("Webserver neu gestartet") {
            await Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Self.webLabel)"])
        }
    }

    func updateSite() async {
        let folder = siteRoot
        await perform("Webseite ist aktuell") {
            await Shell.run("/usr/bin/git", ["pull", "--ff-only"], in: URL(fileURLWithPath: folder))
        }
    }

    private func perform(_ success: String, _ action: () async -> Shell.Result) async {
        isBusy = true
        defer { isBusy = false }
        let result = await action()
        message = result.ok ? success : "Fehler: " + result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await Task.sleep(for: .seconds(2))
        await refresh()
    }
}
