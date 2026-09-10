import Combine
import StoreKit
import SwiftUI

/// Optional, one-time support. Purchases never gate app features or identity.
@MainActor
public final class AppSupportStore: ObservableObject {
    public static let shared = AppSupportStore()
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var purchasingProductID: String?
    @Published public private(set) var message: String?
    private let productIDs: Set<String>
    private var updates: Task<Void, Never>?

    public init(productIDs: [String]? = nil, observeTransactions: Bool = true) {
        self.productIDs = Set(productIDs ?? Bundle.main.object(forInfoDictionaryKey: "AppSupportTipProductIDs") as? [String] ?? [])
        if observeTransactions {
            updates = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled else { return }
                    await self?.finishVerifiedTip(result)
                }
            }
        }
    }

    deinit { updates?.cancel() }

    public func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: productIDs)
                .filter { productIDs.contains($0.id) && $0.type == .consumable }
                .sorted { $0.price == $1.price ? $0.id < $1.id : $0.price < $1.price }
            message = products.isEmpty ? "Tips are temporarily unavailable. You can try again later." : nil
        } catch {
            message = "The App Store could not load tips. Check your connection and try again."
        }
    }

    public func purchase(_ product: Product) async {
        guard purchasingProductID == nil, productIDs.contains(product.id), product.type == .consumable else { return }
        guard AppStore.canMakePayments else {
            message = "Purchases are not allowed on this device."
            return
        }
        purchasingProductID = product.id
        message = nil
        defer { purchasingProductID = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await finishVerifiedTip(verification)
            case .pending:
                message = "Your tip is awaiting approval. You can keep using the app."
            case .userCancelled:
                break
            @unknown default:
                message = "The purchase could not be completed. Please try again."
            }
        } catch StoreKitError.userCancelled {
            // A canceled purchase needs no error or further solicitation.
        } catch {
            message = "The purchase could not be completed. Please try again."
        }
    }

    private func finishVerifiedTip(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else {
            message = "The App Store could not verify this purchase. Please try again later."
            return
        }
        guard productIDs.contains(transaction.productID), transaction.productType == .consumable else { return }
        await transaction.finish()
        if transaction.revocationDate == nil {
            message = "Thank you for supporting continued development."
        }
    }

    public static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "the app"
    }

    public static func reviewURL(appID: UInt64) -> URL? {
        guard appID > 0 else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")
    }

    public static func informationURL(forKey key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    public static func reviewURL() async -> URL? {
        if let text = Bundle.main.object(forInfoDictionaryKey: "AppSupportAppleID") as? String,
           let id = UInt64(text), let url = reviewURL(appID: id) { return url }
        // Xcode can create the listing on the first upload. The production
        // receipt supplies that listing's ID without a hard-coded placeholder.
        guard let result = try? await AppTransaction.shared,
              case .verified(let app) = result,
              app.bundleID == Bundle.main.bundleIdentifier,
              let id = app.appID else { return nil }
        return reviewURL(appID: id)
    }
}

/// Place only in settings/about. Never shown automatically or after a purchase.
public struct AppSupportCard: View {
    @Environment(\.openURL) private var openURL
    @State private var showsTips = false
    @State private var reviewMessage: String?
    @State private var openingReview = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Support & feedback", systemImage: "heart")
                .font(.headline)
            Text("Help shape the app with an honest review, or leave an optional tip to support its development.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(alignment: .leading, spacing: 12) { actions }
            }
            if let reviewMessage {
                Text(reviewMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                if let url = AppSupportStore.informationURL(forKey: "AppSupportURL") {
                    Link("Contact Support", destination: url)
                        .accessibilityIdentifier("app.support.contact")
                }
                if let url = AppSupportStore.informationURL(forKey: "AppSupportPrivacyPolicyURL") {
                    Link("Privacy Policy", destination: url)
                        .accessibilityIdentifier("app.support.privacy")
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(isPresented: $showsTips) { AppTipSheet() }
    }

    @ViewBuilder private var actions: some View {
        Button { showsTips = true } label: {
            Label("Leave a Tip", systemImage: "heart")
        }
        .accessibilityIdentifier("app.support.tip")
        Button {
            guard !openingReview else { return }
            openingReview = true
            reviewMessage = nil
            Task {
                defer { openingReview = false }
                if let url = await AppSupportStore.reviewURL() {
                    openURL(url) { accepted in
                        if !accepted { reviewMessage = "The App Store could not be opened. Please try again." }
                    }
                } else {
                    reviewMessage = "App Store reviews become available after the app is published. In TestFlight, you can use Send Beta Feedback."
                }
            }
        } label: {
            Label("Write an App Store Review", systemImage: "star.bubble")
        }
        .disabled(openingReview)
        .accessibilityIdentifier("app.support.review")
    }
}

public struct AppTipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AppSupportStore.shared

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "heart.circle")
                            .font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                        Text("Support \(AppSupportStore.appName)")
                            .font(.title2.bold())
                        Text("Your support helps fund maintenance and improvements. Tips are optional, one-time purchases and do not unlock features.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if store.isLoading && store.products.isEmpty {
                        ProgressView("Loading tips…").frame(maxWidth: .infinity).padding(.vertical, 20)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.products, id: \.id) { product in
                                Button { Task { await store.purchase(product) } } label: {
                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(product.displayName).font(.headline)
                                            Text(product.description).font(.caption).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 10)
                                        if store.purchasingProductID == product.id { ProgressView().controlSize(.small) }
                                        Text(product.displayPrice).font(.headline).fixedSize()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .contentShape(RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .disabled(store.purchasingProductID != nil)
                                .accessibilityIdentifier("app.support.purchase.\(product.id)")
                            }
                        }
                    }
                    if let message = store.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("app.support.status")
                    }
                    if store.products.isEmpty && !store.isLoading {
                        Button("Try Again") { Task { await store.loadProducts() } }
                    }
                    Text("Payment is handled by Apple. There is no subscription, and the app works the same whether or not you tip.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .navigationTitle("Optional support")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await store.loadProducts() }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 480, idealHeight: 580)
        #else
        .presentationDetents([.large])
        #endif
    }
}
