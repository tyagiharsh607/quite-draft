import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: TranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $store.editableText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
                .border(Color.gray.opacity(0.3))

            HStack {
                Button("Grab") { store.grab() }
                Button("Clear") { store.clear() }
                Button("Submit") { store.submit() }
                    .keyboardShortcut(.return, modifiers: [])
                if store.isSending {
                    ProgressView().controlSize(.small)
                }
            }

            Divider()

            ScrollView {
                Text(store.answer)
                    .font(.system(.body, design: .default))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(minWidth: 360, minHeight: 320)
        .onAppear {
            debugLog("[ui] ContentView appeared, calling startListening()")
            store.startListening()
        }
    }
}
