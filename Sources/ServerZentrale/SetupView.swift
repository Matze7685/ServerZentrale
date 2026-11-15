import SwiftUI

/// Fenster „Einrichtung“: legt Webserver, Pizzaseite und Hintergrunddienst an.
struct SetupView: View {
    @State var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Einrichtung").font(.title2.bold())
            Text("Installiert den Webserver (Caddy), holt die Pizzaseite von GitHub und startet alles automatisch bei jeder Anmeldung. Kann jederzeit erneut ausgeführt werden.")
                .font(.callout).foregroundStyle(.secondary)

            TextField("Deine Adresse", text: $setup.domain, prompt: Text("guderjahn.homeip.net"))
                .textFieldStyle(.roundedBorder)

            ScrollView {
                Text(setup.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 160)
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
        .frame(width: 520, height: 420)
    }
}
