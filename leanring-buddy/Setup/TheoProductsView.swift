//
//  TheoProductsView.swift
//  leanring-buddy
//
//  Theo, Clicky and Dictation as three products a person turns on one by one (rules in ClickyCore `TheoProducts`):
//  the saved choice, what changes when one is switched, the product cards with their demos (Setup › Pick products,
//  Settings › Products), and the page a product shows while it's off. Dictation runs on Apple's recognizer until a Sarvam key is saved.
//

import ClickyCore
import Combine
import SwiftUI

extension Notification.Name {
    /// A product was turned on or off.
    static let theoProductsChanged = Notification.Name("TheoProductsChanged")
}

@MainActor
final class TheoProducts: ObservableObject {
    static let shared = TheoProducts()

    @Published private(set) var revision = 0
    private var keysWatch: AnyCancellable?

    private init() {
        // A key saved or removed anywhere changes whether dictation is blocked.
        keysWatch = ProviderKeys.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.revision += 1 }
    }

    /// Readable from anywhere: one UserDefaults read.
    nonisolated static func isOn(_ product: TheoProduct) -> Bool {
        TheoProductChoice.isOn(stored: UserDefaults.standard.object(forKey: product.settingKey) as? Bool, setupCompleted: ClickySettings.isSetupCompleted)
    }

    func isOn(_ product: TheoProduct) -> Bool { Self.isOn(product) }

    var picked: Set<TheoProduct> { Set(TheoProduct.allCases.filter(Self.isOn)) }

    func set(_ product: TheoProduct, on: Bool) {
        UserDefaults.standard.set(on, forKey: product.settingKey)
        revision += 1
        NotificationCenter.default.post(name: .theoProductsChanged, object: product.rawValue)
        apply()
    }

    /// Finishing setup saves every product as a choice, so none can later fall back to "on because setup is done".
    func saveChoices() {
        for product in TheoProduct.allCases where UserDefaults.standard.object(forKey: product.settingKey) == nil {
            UserDefaults.standard.set(false, forKey: product.settingKey)
        }
        revision += 1
    }

    /// Whether dictation runs, and on what: off, Apple's recognizer, or Sarvam once its key is saved.
    var dictationAccess: DictationAccess {
        DictationAccess.of(productOn: isOn(.dictation), hasSarvamKey: ProviderKeys.shared.hasKey(for: Self.dictationKeyProvider))
    }

    /// Read straight from the Keychain, for the moment a shortcut is pressed.
    static var dictationAccessNow: DictationAccess {
        DictationAccess.of(productOn: isOn(.dictation), hasSarvamKey: ProviderKeychain.get(dictationKeyProvider) != nil)
    }

    static let dictationKeyProvider = "sarvam"

    /// What a switch changes straight away; the rest reads the choice when it next runs.
    func apply() {
        CompanionManager.current?.applyProducts()
        TheoGateway.shared.apply()
        // A page for something that's now off moves to Home.
        let selection = BotsSelection.shared
        if !isOn(.clicky), selection.pane == .clicky { selection.pane = .home }
    }
}

// MARK: - Product card

/// One product: its demo, what it does, what it needs, and its switch.
struct TheoProductCard: View {
    let product: TheoProduct
    @ObservedObject private var products = TheoProducts.shared
    @ObservedObject private var keys = ProviderKeys.shared
    var demoWidth: CGFloat = 272

    private var isOn: Bool { products.isOn(product) }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ProductDemoView(product: product, width: demoWidth)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    IconTile(symbol: product.symbol, colors: product.colors, size: 24)
                    Text(product.title).font(TheoType.headline).foregroundColor(DS.Colors.textPrimary)
                    Spacer(minLength: 8)
                    Toggle("Use \(product.title)", isOn: Binding(get: { isOn }, set: { products.set(product, on: $0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Text(product.tagline).font(TheoType.body).foregroundColor(DS.Colors.textSecondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(product.points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(DS.Colors.textTertiary)
                            Text(point).font(TheoType.caption).foregroundColor(DS.Colors.textPrimary)
                        }
                    }
                }
                status
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isOn ? DS.Colors.accent.opacity(0.7) : DS.Colors.borderSubtle, lineWidth: isOn ? 1.5 : 1))
    }

    /// The status as a pill: "On, with Apple's dictation" with the optional Sarvam key field under it, "On" in green, "Off" in grey.
    @ViewBuilder private var status: some View {
        if product == .dictation, products.dictationAccess == .appleOnly {
            VStack(alignment: .leading, spacing: 6) {
                StatusPill(text: "On, with Apple's dictation", tone: .good)
                SarvamKeyField()
            }
        } else if isOn {
            StatusPill(text: "On", tone: .good)
        } else {
            StatusPill(text: "Off", tone: .neutral)
        }
    }
}

extension TheoProduct {
    var symbol: String {
        switch self {
        case .dictation: return "mic.fill"
        case .clicky: return "cursorarrow.rays"
        case .theo: return "person.2.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .dictation: return TileColors.rose
        case .clicky: return TileColors.ember
        case .theo: return TileColors.indigo
        }
    }
}

/// Paste a Sarvam key right where dictation asks for it. The key goes to the Keychain like any other
/// (Models & API keys lists it too) and is never shown again.
struct SarvamKeyField: View {
    @ObservedObject private var keys = ProviderKeys.shared
    @State private var draft = ""
    @State private var saveFailed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField("Sarvam API key (sk_…)", text: $draft)
                    .focused($focused).theoField(focused: focused).font(TheoType.mono)
                    .onSubmit(save)
                    .frame(maxWidth: 220)
                Button("Save", action: save).buttonStyle(.theoPrimary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 4) {
                Text("No key yet?").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
                if let url = URL(string: "https://dashboard.sarvam.ai") {
                    Link(destination: url) {
                        HStack(spacing: 2) {
                            Text("Get one from Sarvam")
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                        }
                        .font(TheoType.caption).foregroundColor(DS.Colors.accentText)
                    }
                }
            }
            if saveFailed {
                Text("The Keychain didn't save that. Try Save again.").font(TheoType.caption).foregroundColor(DS.Colors.destructiveText)
            }
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard keys.save(trimmed, for: TheoProducts.dictationKeyProvider) else {
            saveFailed = true
            return
        }
        saveFailed = false
        draft = ""
        // The key card folds wherever it shows (Home, Setup, Products).
        PixelCardFolds.shared.fold("key:sarvam", did: "Saved your Sarvam key", about: "Dictation is ready")
        Task { await keys.test(TheoProducts.dictationKeyProvider) }
    }
}

// MARK: - Settings › Products and Setup › Pick products

/// The three cards. Used by Setup and by Settings.
struct TheoProductsList: View {
    var demoWidth: CGFloat = 272

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(TheoProduct.allCases) { product in
                TheoProductCard(product: product, demoWidth: demoWidth)
            }
        }
    }
}

struct ProductsSettingsContent: View {
    @ObservedObject private var products = TheoProducts.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if products.picked.isEmpty {
                Text("Nothing is on yet. Turn on the products you want; each one works without the others.")
                    .font(TheoType.body).foregroundColor(DS.Colors.warningText)
            }
            TheoProductsList(demoWidth: 260)
        }
    }
}

// MARK: - While a product is off

/// What a product's own page shows while it's off: its demo and the switch to turn it on.
struct ProductOffView: View {
    let product: TheoProduct
    @ObservedObject private var products = TheoProducts.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ProductDemoView(product: product, width: 440)
                VStack(spacing: 6) {
                    Text("\(product.title) is off").font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
                    Text(product.tagline).font(TheoType.body).foregroundColor(DS.Colors.textSecondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                Button("Turn on \(product.title)") { products.set(product, on: true) }.buttonStyle(.theoPrimary)
                Button("See all products") { BotsSelection.shared.openSettings(.products) }.buttonStyle(.theoGhost)
            }
            .padding(.top, 56).padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Home while Theo (the product) is off: the products, what's on, and their demos.
struct ProductsHomeView: View {
    @ObservedObject private var products = TheoProducts.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your products").font(TheoType.title).foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle).font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
                }
                TheoProductsList(demoWidth: 280)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        let on = TheoProduct.allCases.filter(products.isOn).map(\.title)
        guard !on.isEmpty else { return "Nothing is on yet. Each product works without the others." }
        return "On: " + on.joined(separator: ", ") + ". Turn on Theo for bots, teams and coding runs."
    }
}
