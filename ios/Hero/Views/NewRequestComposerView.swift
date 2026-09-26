import SwiftUI

private struct ChatMessage: Identifiable {
    enum Role { case user, agent }
    let id = UUID()
    let role: Role
    let text: String
}

struct NewRequestComposerView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = [
        ChatMessage(role: .agent, text: "What do you want to buy? Describe it naturally, e.g. \"Sony 55\\\" TV, must arrive within 1 month, never above $500, buy on your own under $400.\"")
    ]
    @State private var input = ""
    @State private var draft: RequestDraft?
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                            if isSending {
                                ProgressView().padding(.leading, 4)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) {
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                if let draft {
                    DraftForm(draft: Binding(get: { draft }, set: { self.draft = $0 }), onConfirm: confirm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 10) {
                    TextField("Describe your purchase request…", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Theme.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(input.isEmpty ? Theme.textSecondary : Theme.accentBlue)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                }
                .padding(12)
                .background(Theme.cardBackground)
            }
            .background(Theme.background)
            .navigationTitle("New Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text))
        input = ""
        isSending = true
        Task {
            do {
                let reply = try await store.sendChat(requestId: nil, message: text)
                messages.append(ChatMessage(role: .agent, text: reply.reply))
                if let d = reply.draft {
                    withAnimation { draft = d }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    private func confirm() {
        guard let draft else { return }
        Task {
            do {
                try await store.submitDraft(draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(.body)
                .foregroundStyle(message.role == .user ? .white : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.role == .user ? Theme.accentBlue : Theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if message.role == .agent { Spacer(minLength: 40) }
        }
    }
}

/// Editable draft form shown after the agent proposes a parsed request.
private struct DraftForm: View {
    @Binding var draft: RequestDraft
    let onConfirm: () -> Void
    @State private var confirmed = false

    var body: some View {
        Form {
            Section("Draft policy") {
                TextField("Title", text: $draft.title)
                TextField("Category", text: $draft.category)
                HStack {
                    Text("Auto-buy under")
                    Spacer()
                    TextField("Auto", value: $draft.autoUsd, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                HStack {
                    Text("Never above")
                    Spacer()
                    TextField("Max", value: $draft.maxUsd, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                DatePicker("Deadline", selection: $draft.deadline, displayedComponents: .date)
            }
            Section {
                Button {
                    confirmed.toggle()
                    onConfirm()
                } label: {
                    Text("Write policy to ENS")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .sensoryFeedback(.success, trigger: confirmed)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .frame(height: 340)
    }
}
