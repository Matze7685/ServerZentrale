import SwiftUI
import AppKit

/// Fenster „Einrichtung“: legt Webserver und Hintergrunddienst an.
struct SetupView: View {
    @State var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Einrichtung").font(.title2.bold())
            Text("Installiert den Webserver (Caddy) und startet ihn automatisch bei jeder Anmeldung. Kann jederzeit erneut ausgeführt werden, bestehende Weiterleitungen bleiben erhalten.")
                .font(.callout).foregroundStyle(.secondary)

            TextField("Deine Adresse", text: $setup.domain, prompt: Text("meinhaus.example.net"))
                .textFieldStyle(.roundedBorder)

            GroupBox("Eigene Webseite (optional)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Ordner", text: $setup.siteFolder, prompt: Text("leer = nur Weiterleitungen"))
                        Button("Wählen …") { chooseFolder() }
                    }
                    TextField("Unterordner mit der Seite", text: $setup.siteSubfolder, prompt: Text("z. B. docs, sonst leer"))
                    TextField("Git-Adresse zum Herunterladen", text: $setup.siteRepoURL, prompt: Text("https://github.com/…, sonst leer"))
                }
                .textFieldStyle(.roundedBorder)
                .padding(4)
            }

            ScrollView {
                Text(setup.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 130)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            if let error = setup.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            } else if setup.succeeded {
                Label("Fertig eingerichtet", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            HStack {
                if setup.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button(SetupModel.isSetUp ? "Erneut einrichten" : "Einrichten") {
                    Task { await setup.run() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(setup.isRunning)
            }
        }
        .padding(16)
        .frame(width: 540, height: 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { setup.siteFolder = url.path }
    }
}
