import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Fenster „Weiterleitungen“: alle Adressen, die über den Mac mini zu Geräten im Heimnetz führen.
struct ForwardsView: View {
    let store: ForwardStore
    let model: ServerModel
    @State private var editing: Forward?
    @State private var isNew = false
    @State private var showImporter = false
    @State private var info: String?
    @State private var reach: [UUID: Bool] = [:]
    @State private var siteReach: Bool?
    @AppStorage("legacyServerIP") private var legacyIP = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                if model.hasSite { siteRow }
                ForEach(store.forwards) { forward in
                    row(forward)
                }
            }
            .frame(minHeight: 220)

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if let info {
                Label(info, systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
            }

            HStack {
                Button("Hinzufügen", systemImage: "plus") {
                    isNew = true
                    editing = Forward(host: "", target: "")
                }
                Button("Caddyfile importieren …", systemImage: "square.and.arrow.down") { showImporter = true }
                TextField("IP des alten Servers", text: $legacyIP).frame(width: 130)
                    .help("Ziele wie 127.0.0.1:80 im alten Caddyfile liegen auf dem alten Server. Sie werden auf diese IP umgeschrieben.")
                Spacer()
                if store.isApplying { ProgressView().controlSize(.small) }
                Button("Erreichbarkeit prüfen", systemImage: "arrow.clockwise") { Task { await checkReach() } }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
        .disabled(store.isApplying)
        .task { await checkReach() }
        .sheet(item: $editing) { forward in
            ForwardEditor(forward: forward, isNew: isNew) { saved in
                let ok = await store.save(saved)
                if ok { await checkReach() }
                return ok
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .plainText]) { result in
            guard case .success(let url) = result else { return }
            Task { await importFile(url) }
        }
    }

    /// Die eigene Webseite (fest, wird in der Einrichtung festgelegt und kann hier nicht gelöscht werden).
    private var siteRow: some View {
        HStack {
            Image(systemName: siteReach == true ? "checkmark.circle.fill"
                  : siteReach == false ? "xmark.octagon.fill" : "circle.dashed")
                .foregroundStyle(siteReach == true ? .green : siteReach == false ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let url = model.publicURL {
                    Link((url.host() ?? url.absoluteString) + "  (Webseite)", destination: url)
                } else {
                    Text("Webseite (noch nicht eingerichtet)")
                }
                Text("→ Ordner \(model.siteRoot)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Fest").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ forward: Forward) -> some View {
        HStack {
            Image(systemName: reach[forward.id] == true ? "checkmark.circle.fill"
                  : reach[forward.id] == false ? "xmark.octagon.fill" : "circle.dashed")
                .foregroundStyle(reach[forward.id] == true ? .green : reach[forward.id] == false ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let url = forward.url { Link(forward.host, destination: url) } else { Text(forward.host) }
                Text("→ \(forward.target)\(forward.isProtected ? "  🔒 Passwortschutz" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Bearbeiten") { isNew = false; editing = forward }
            Button("Löschen", role: .destructive) {
                Task { _ = await store.delete(forward); await checkReach() }
            }
        }
    }

    private func checkReach() async {
        if model.hasSite { siteReach = await TCPProbe.reachable(target: "127.0.0.1:\(SetupModel.localPort)") }
        let list = store.forwards
        var result: [UUID: Bool] = [:]
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for f in list { group.addTask { (f.id, await TCPProbe.reachable(target: f.target)) } }
            for await (id, ok) in group { result[id] = ok }
        }
        reach = result
    }

    private func importFile(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            info = "Datei konnte nicht gelesen werden."; return
        }
        let parsed = CaddyImporter.parse(text, replaceLocalhostWith: legacyIP.trimmingCharacters(in: .whitespaces))
        guard !parsed.forwards.isEmpty else {
            info = "Keine Weiterleitungen gefunden." + (parsed.skipped.isEmpty ? "" : " Übersprungen: \(parsed.skipped.joined(separator: ", "))")
            return
        }
        let ok = await store.add(parsed.forwards)
        if ok {
            var text = "\(parsed.forwards.count) übernommen."
            if !parsed.skipped.isEmpty {
                text += " Nicht übernommen (Ziel ungültig): \(parsed.skipped.joined(separator: ", "))."
            }
            info = text
            await checkReach()
        }
    }
}

private struct ForwardEditor: View {
    @State var forward: Forward
    let isNew: Bool
    let onSave: (Forward) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var protect = false
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    init(forward: Forward, isNew: Bool, onSave: @escaping (Forward) async -> Bool) {
        _forward = State(initialValue: forward)
        _protect = State(initialValue: forward.isProtected)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Adresse", text: $forward.host, prompt: Text("ha.meinhaus.example.net"))
            TextField("Ziel im Heimnetz", text: $forward.target, prompt: Text("192.168.96.90:8123"))
                .onChange(of: forward.target) {
                    // Proxmox (Port 8006/8007) spricht nur HTTPS mit eigenem Zertifikat
                    if forward.isKnownSelfSignedTarget { forward.skipTLSVerify = true }
                }
            Toggle("Ziel spricht HTTPS mit eigenem Zertifikat (z. B. Proxmox)", isOn: $forward.skipTLSVerify)
            Toggle("Mit Passwort schützen", isOn: $protect)
            if protect {
                TextField("Benutzername", text: $forward.user)
                SecureField(forward.isProtected ? "Neues Passwort (leer lassen = unverändert)" : "Passwort", text: $password)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        var f = forward
        f.host = f.host.trimmingCharacters(in: .whitespaces).lowercased()
        // "https://name.example.net/" wird oft mit Schema eingefügt; die Adresse braucht nur den Namen
        for prefix in ["https://", "http://"] where f.host.hasPrefix(prefix) { f.host.removeFirst(prefix.count) }
        while f.host.hasSuffix("/") { f.host.removeLast() }
        f.target = f.target.trimmingCharacters(in: .whitespaces)
        if protect {
            if !password.isEmpty {
                guard let hash = await ForwardStore.hashPassword(password) else {
                    error = "Passwort konnte nicht verschlüsselt werden (ist Caddy installiert?)"; return
                }
                f.passwordHash = hash
            }
        } else {
            f.user = ""; f.passwordHash = ""
        }
        if await onSave(f) { dismiss() } else { error = "Speichern nicht möglich. Details im Hauptfenster." }
    }
}
