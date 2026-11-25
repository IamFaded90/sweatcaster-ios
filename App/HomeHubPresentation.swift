import SwiftUI

@MainActor enum FadedHubRoute {
    static let changed = Notification.Name("FadedAIHubRoute")
    static func open(_ kind: EveningPlan.Kind) {
        NotificationCenter.default.post(name: changed, object: kind.rawValue)
    }
}

extension Home {
    func hubPresentation<V: View>(_ view: V) -> some View {
        AnyView(view).sheet(isPresented: $showEvening) {
            EveningPlanView { kind in showEvening = false; openEvening(kind) }
        }
        .sheet(isPresented: $showMystery) { VillageMysteryView() }
        .sheet(isPresented: $showCreativeHub) { CreativeHubView() }
        .modifier(CaseTrackerSync(api: studioAPI))
        .sheet(isPresented: $showPersonalSearch, onDismiss: {
            if personalSearchAdvanced { personalSearchAdvanced = false; openSearch() }
        }) {
            PersonalHubSearchView(model: UserDefaults.standard.string(forKey: AppStorageKeys.phoneModel) ?? "apple") {
                personalSearchAdvanced = true; showPersonalSearch = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: FadedHubRoute.changed)) { value in
            guard !privateStudioPresented, let raw = value.object as? String,
                  let kind = EveningPlan.Kind(rawValue: raw) else { return }
            openEvening(kind)
        }
    }
    func openEvening(_ kind: EveningPlan.Kind) {
        switch kind {
        case .film: selectSpace(.entertainment)
        case .music: selectSpace(.music)
        case .village: selectSpace(.village)
        }
    }
}
