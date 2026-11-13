// Starter FadedAI, registrerer genveje og anvender appens tekststørrelse.

import AppIntents
import SwiftUI

struct OpenSweatCasterChat: AppIntent {
    static let title: LocalizedStringResource = "Åbn FadedAI-chat"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("chat", forKey: AppStorageKeys.spacesShortcut)
        return .result()
    }
}

struct OpenSweatCasterVideo: AppIntent {
    static let title: LocalizedStringResource = "Vælg klip i FadedAI"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("video", forKey: AppStorageKeys.spacesShortcut)
        return .result()
    }
}

struct OpenFadedAIPrivateChat: AppIntent {
    static let title: LocalizedStringResource = "Start privat chat"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("private-chat", forKey: AppStorageKeys.spacesShortcut)
        return .result()
    }
}

struct OpenFadedAIImages: AppIntent {
    static let title: LocalizedStringResource = "Lav billede i FadedAI"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("images", forKey: AppStorageKeys.spacesShortcut)
        return .result()
    }
}

struct OpenFadedAIConnection: AppIntent {
    static let title: LocalizedStringResource = "Tjek PC-forbindelsen i FadedAI"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("connection", forKey: AppStorageKeys.spacesShortcut)
        return .result()
    }
}

struct SweatCasterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSweatCasterChat(), phrases: ["Åbn chat i \(.applicationName)"],
                    shortTitle: "Åbn chat", systemImageName: "bubble.left")
        AppShortcut(intent: OpenSweatCasterVideo(), phrases: ["Vælg klip i \(.applicationName)"],
                    shortTitle: "Vælg klip", systemImageName: "film")
        AppShortcut(intent: OpenFadedAIPrivateChat(), phrases: ["Start privat chat i \(.applicationName)"],
                    shortTitle: "Privat chat", systemImageName: "lock.shield")
        AppShortcut(intent: OpenFadedAIImages(), phrases: ["Lav billede med \(.applicationName)"],
                    shortTitle: "Lav billede", systemImageName: "photo")
        AppShortcut(intent: OpenFadedAIConnection(), phrases: ["Tjek PC i \(.applicationName)"],
                    shortTitle: "Tjek PC", systemImageName: "network")
    }
}

struct PromptExample: Identifiable {
    let text: String
    var id: String { text }
    static let examples = [
        Self(text: "Lav et hype-klip af den nyeste fil."),
        Self(text: "Analyser denne tekst:"),
        Self(text: "Foreslå en kort titel til mit næste klip."),
        Self(text: "Lav en tjekliste til min næste optagelse."),
        Self(text: "Giv mig tre idéer til et sjovt gamingklip.")
    ]
}

@main struct SweatCasterApp: App {
    @UIApplicationDelegateAdaptor(FadedAIModelDownloadDelegate.self) private var modelDownloadDelegate
    @AppStorage(AppStorageKeys.appTextScale) private var textScale = 0.0
    @AppStorage(AppStorageKeys.appResetGeneration) private var resetGeneration = ""
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var villageNotice: String?
    var body: some Scene {
        WindowGroup {
            Home().id(resetGeneration).dynamicTypeSize(textScale == 0 ? systemTextSize :
                [DynamicTypeSize.large, .xLarge, .xxLarge, .xxxLarge,
                 .accessibility1, .accessibility2][min(5, max(0, Int(textScale)))])
                .onChange(of: scenePhase, initial: true) { _, phase in
                    StudioImageDownloads.shared.setForeground(phase == .active)
                    if phase == .active { Task { await PhoneModelDownloads.shared.resumeInterruptedVisionDownload() } }
                    let village = SimulationEngine.shared
                    village.handle(phase)
                    villageNotice = village.readError
                }
                .alert("Landsbyen", isPresented: Binding(
                    get: { villageNotice != nil },
                    set: { if !$0 { villageNotice = nil; SimulationEngine.shared.readError = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(villageNotice ?? "")
                }
        }
    }
}
