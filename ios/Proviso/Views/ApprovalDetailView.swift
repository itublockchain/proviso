import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

struct ApprovalDetailView: View {
    @Environment(Store.self) private var store
    @State var approval: Approval
    @State private var pollTask: Task<Void, Never>?
    @State private var approveTapped = false
    @State private var showQR = false
    @State private var worldPage = WorldApprovalPage()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingXL) {
                orderHeader
                if approval.status == .pending {
                    reasonText
                    if let code = approval.userCode {
                        WorldIDCodeCard(code: code)
                    }
                    approveButton
                } else if approval.status == .approved {
                    ProvisoCard {
                        HStack {
                            ProgressView()
                            Text("Approved — finalizing purchase…").foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if approval.status == .paid {
                    successCard
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    ProvisoCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(approval.status == .expired ? "Approval expired" : approval.denyReason?.localizedCaseInsensitiveContains("declined") == true ? "You declined" : "Purchase blocked",
                                  systemImage: "xmark.shield.fill")
                                .font(.headline)
                                .foregroundStyle(Theme.accentRed)
                            Text("Nothing was bought.")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(approval.denyReason ?? "The contract did not accept this order.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.opacity)
                }
            }
            .padding(16)
            .animation(.spring(duration: 0.45), value: approval.status)
        }
        .background(Theme.background)
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { pollTask?.cancel() }
        // Coming back from World App (via return_to or app switcher): refresh right away.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await store.refreshApproval(orderId: approval.orderId)
                if let updated = store.approval(id: approval.orderId) { approval = updated }
            }
        }
    }

    private var orderHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(approval.title).font(.title2.bold()).foregroundStyle(Theme.textPrimary)
            Text(approval.merchant).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Text(approval.price.usd)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 4)
            VStack(spacing: 0) {
                HairlineDivider()
                row("Pay to", shortAddress(approval.payTo))
                HairlineDivider()
                row("Order hash", shortHash(approval.orderHash))
                HairlineDivider()
                row("Expires", approval.expiresAt.formatted(date: .abbreviated, time: .shortened))
                HairlineDivider()
            }
        }
    }

    private var reasonText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Why approval is needed", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentAmber)
            Text("\(approval.price.usd) is above your \(approval.autoUsd.usd) auto-buy limit, but within your \(approval.maxUsd.usd) max. Approve with World ID to let the agent complete this exact order.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var approveButton: some View {
        VStack(spacing: 16) {
            Button {
                approveTapped.toggle()
                startApproval()
                if approval.userCode != nil, let url = URL(string: approval.approvalUrl) {
                    worldPage.open(url)
                } else {
                    openWorldApp()
                }
            } label: {
                Label(approval.userCode != nil ? "Confirm with World ID" : "Approve in World App",
                      systemImage: "person.fill.checkmark")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentGreen)
            .sensoryFeedback(.impact(weight: .medium), trigger: approveTapped)

            Button(showQR ? "Hide QR code" : "Use another device") {
                withAnimation { showQR.toggle() }
            }
            .font(.subheadline)

            if showQR {
                if let qr = qrImage(for: approval.approvalUrl) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(12)
                        .background(Theme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                }

                if let url = URL(string: approval.userCode != nil ? approval.approvalUrl : "https://simulator.worldcoin.org") {
                    Link(approval.userCode != nil ? "Open verification page" : "Open in World ID Simulator", destination: url)
                        .font(.footnote)
                }

                Button {
                    UIPasteboard.general.string = approval.approvalUrl
                } label: {
                    Label("Copy approval link", systemImage: "doc.on.doc")
                }
                .font(.footnote)
            }
        }
    }

    /// Opens the IDKit connector URL only if World App claims it as a universal link;
    /// otherwise (no World App / host not associated, e.g. simulator) falls back to the QR.
    private func openWorldApp() {
        guard let url = URL(string: approval.approvalUrl) else {
            withAnimation { showQR = true }
            return
        }
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            if !opened { withAnimation { showQR = true } }
        }
    }

    private var successCard: some View {
        ProvisoCard {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accentGreen)
                Text("Purchase complete").font(.headline).foregroundStyle(Theme.textPrimary)
                if let hash = approval.txHash {
                    Text(shortHash(hash)).font(.footnote.monospaced()).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .sensoryFeedback(.success, trigger: approval.status)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.footnote).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.footnote.monospaced()).foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, 9)
    }

    private func startApproval() {
        store.simulateApprovalCompletion(orderId: approval.orderId)
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await store.refreshApproval(orderId: approval.orderId)
                if let updated = store.approval(id: approval.orderId) {
                    approval = updated
                    if updated.status != .pending { worldPage.close() }
                    if updated.status == .paid || updated.status == .denied || updated.status == .expired {
                        break
                    }
                }
            }
        }
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 12 else { return hash }
        return "\(hash.prefix(8))...\(hash.suffix(6))"
    }

    private func qrImage(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
