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
        ChatMessage(role: .agent, text: "What do you want to buy? Describe it naturally, e.g. “Sony 55-inch TV, must arrive within 1 month, never above $500, buy on your own under $400.”")
    ]
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var draft: RequestDraft?
    @State private var isSending = false
    @State private var errorMessage: String?

    @State private var isSubmitting = false
    @State private var submitStep = 0
    private static let submitSteps = ["Comparing stores…", "Reading the price history…", "Writing your rules to ENS…", "Almost there…"]

    var body: some View {
        NavigationStack {
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
                        if draft != nil {
                            DraftCard(draft: Binding(get: { draft! }, set: { draft = $0 }))
                                .disabled(isSubmitting)
                                .opacity(isSubmitting ? 0.6 : 1)
                                .id("draft")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: draft != nil) { _, shown in
                    if shown { withAnimation { proxy.scrollTo("draft", anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if draft == nil { inputBar } else { confirmBar }
            }
            .background(Theme.background)
            .navigationTitle("New Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
        }
    }

    /// One primary action, pinned above the home indicator. Locks immediately so a slow backend can't be double-submitted.
    private var confirmBar: some View {
        VStack(spacing: 8) {
            Button(action: confirm) {
                HStack(spacing: 10) {
                    if isSubmitting { ProgressView().tint(.white) }
                    Text(isSubmitting ? Self.submitSteps[submitStep] : "Save rules & start watching")
                        .fontWeight(.semibold)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accentBlue)
            .disabled(isSubmitting)
            .animation(.easeInOut(duration: 0.25), value: submitStep)
            .sensoryFeedback(.impact(weight: .medium), trigger: isSubmitting) { _, new in new }

            Text(isSubmitting ? "Hero is checking every store and signing your rules. This takes a few seconds."
                              : "Your rules are saved on your ENS name. Above your max, Hero simply can't pay.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.background.opacity(0.92))
    }

    /// Liquid Glass capsule like Messages/Slack: text grows up to 5 lines, send appears as a prominent glass button.
    private var inputBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Hero to buy something…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: .capsule)
                if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: canSend)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .light), trigger: messages.count)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
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
        guard let draft, !isSubmitting else { return }
        inputFocused = false
        isSubmitting = true
        submitStep = 0
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if submitStep < Self.submitSteps.count - 1 { submitStep += 1 }
            }
        }
        Task {
            defer { ticker.cancel() }
            do {
                try await store.submitDraft(draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
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

/// The agent's parsed draft, shown in the conversation as the rules the user is about to sign off.
private struct DraftCard: View {
    @Binding var draft: RequestDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Your rules")

            TextField("What should Hero buy?", text: $draft.title, axis: .vertical)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Picker("Category", selection: $draft.category) {
                Text("Hobby").tag("Hobby")
                Text("Needs").tag("Needs")
            }
            .pickerStyle(.segmented)

            PolicyStrip(auto: draft.autoUsd, max: draft.maxUsd)

            VStack(spacing: 0) {
                amountRow("Buys on its own up to", value: $draft.autoUsd, tint: Theme.accentGreen)
                HairlineDivider()
                amountRow("Asks you up to", value: $draft.maxUsd, tint: Theme.accentAmber)
                HairlineDivider()
                HStack {
                    Image(systemName: "calendar").foregroundStyle(Theme.textSecondary).frame(width: 16)
                    Text("Arrives by").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    DatePicker("", selection: $draft.deadline, in: Date()..., displayedComponents: .date)
                        .labelsHidden()
                }
                .padding(.vertical, 10)
            }
            .font(.subheadline)
        }
        .padding(Theme.cardPadding)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func amountRow(_ label: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8).frame(width: 16)
            Text(label).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("$").foregroundStyle(Theme.textSecondary)
            TextField("0", value: value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .fontWeight(.semibold)
                .frame(width: 72)
        }
        .padding(.vertical, 10)
    }
}

/// Auto | ask | never, drawn to scale so the bands read at a glance.
private struct PolicyStrip: View {
    let auto: Double
    let max: Double

    var body: some View {
        let top = Swift.max(max * 1.2, 1)
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 3) {
                Capsule().fill(Theme.accentGreen).frame(width: Swift.max(8, w * auto / top))
                Capsule().fill(Theme.accentAmber).frame(width: Swift.max(8, w * (max - auto) / top))
                Capsule().fill(Theme.border)
            }
        }
        .frame(height: 6)
        .animation(.spring(duration: 0.3), value: auto)
        .animation(.spring(duration: 0.3), value: max)
    }
}
