import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: TranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            ChatTranscriptView(
                messages: store.transcript,
                isSending: store.isSending
            )

            TextEditor(text: $store.editableText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 110)
                .border(Color.gray.opacity(0.3))

            HStack {
                Button("Grab") { store.grab() }
                    .disabled(store.isScanning)
                Button("Scan screen") { store.scanScreen() }
                    .disabled(store.isScanning || store.isSending)
                Button("Clear") { store.clear() }
                    .disabled(store.isScanning)
                Button("Submit") { store.submit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(store.isScanning)
                if store.isSending || store.isScanning {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 360)
        .onAppear {
            debugLog("[ui] ContentView appeared, calling startListening()")
            store.startListening()
        }
    }
}

private struct ChatTranscriptView: View {
    let messages: [ChatMessage]
    let isSending: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if messages.isEmpty {
                        Text("Conversation will show up here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }

                    ForEach(messages) { message in
                        MessageBubble(message: message, isSending: isSending)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: messages.last?.content ?? "") { _ in
                scrollToBottom(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .border(Color.gray.opacity(0.3))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let isSending: Bool

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 36) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(isUser ? "You" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if message.content.isEmpty && !isUser && isSending {
                    ProgressView().controlSize(.small)
                        .padding(.vertical, 4)
                } else {
                    Text(message.content)
                        .font(.system(.body, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                }
            }
            .padding(8)
            .background(isUser ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.14))
            .cornerRadius(10)

            if !isUser { Spacer(minLength: 36) }
        }
    }
}
