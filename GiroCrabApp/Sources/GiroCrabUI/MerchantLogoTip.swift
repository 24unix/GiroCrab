import SwiftUI
import TipKit

/// GitHub #33: instead of asking at first start (HIG › Onboarding: "Postpone
/// nonessential setup flows"), offer online merchant logos once, in context –
/// when real bookings are on screen and logos are still off.
struct MerchantLogoTip: Tip {
    enum ActionID {
        static let duckDuckGo = "duckduckgo"
        static let settings = "settings"
    }

    /// Real (non-demo) bookings are visible and online logos are off.
    @Parameter static var eligible: Bool = false

    var title: Text { Text("Händler-Logos anzeigen?") }

    var message: Text? {
        Text("GiroCrab kann Logos von DuckDuckGo laden. Übertragen wird nur die Händler-Domain (z. B. lidl.de) – keine Beträge, keine Kontodaten.")
    }

    var image: Image? { Image(systemName: "photo.on.rectangle") }

    var actions: [Action] {
        Action(id: ActionID.duckDuckGo, title: String(localized: "Mit DuckDuckGo laden"))
        Action(id: ActionID.settings, title: String(localized: "Einstellungen …"))
    }

    var rules: [Rule] {
        #Rule(Self.$eligible) { $0 == true }
    }
}

enum GiroCrabTips {
    /// Called once at app start. `--show-tips` (developer/screenshots) also
    /// shows tips in the demo vault and resets their state.
    @MainActor
    static func configure(_ options: LaunchOptions) {
        if options.showTips {
            try? Tips.resetDatastore()
        }
        try? Tips.configure([.datastoreLocation(.applicationDefault)])
    }
}

/// Inline tip at the top of the booking stream. Renders nothing unless
/// TipKit decides to show it (see `merchantLogoTipEligibility()`).
struct MerchantLogoTipView: View {
    @Environment(AppModel.self) private var model
    private let tip = MerchantLogoTip()

    var body: some View {
        TipView(tip, arrowEdge: nil) { action in
            switch action.id {
            case MerchantLogoTip.ActionID.duckDuckGo:
                model.saveSetting("merchants.online_logos", "duckduckgo")
                tip.invalidate(reason: .actionPerformed)
            case MerchantLogoTip.ActionID.settings:
                model.openSettings(.general)
            default:
                break
            }
        }
        .tipBackground(Theme.card)
    }
}

/// Feeds `MerchantLogoTip.eligible`. Attach to a view that is always on
/// screen – an empty TipView never runs its own modifiers.
private struct MerchantLogoTipEligibility: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let eligible = model.logoProvider == "off"
            && !model.dayGroups.isEmpty
            && (!model.isDemo || LaunchOptions.current.showTips)
        content
            .onChange(of: eligible, initial: true) { _, now in
                MerchantLogoTip.eligible = now
            }
            .onChange(of: model.logoProvider) { _, provider in
                // Chosen in Settings: the question is answered for good.
                if provider != "off" { MerchantLogoTip().invalidate(reason: .actionPerformed) }
            }
    }
}

extension View {
    func merchantLogoTipEligibility() -> some View { modifier(MerchantLogoTipEligibility()) }
}
