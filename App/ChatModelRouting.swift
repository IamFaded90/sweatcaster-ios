import SwiftUI

extension ChatView {
    enum ReplySource: String, CaseIterable {
        case phone = "Telefon"
        case pc = "PC"
        case grok = "Grok"
        case composio = "Composio"
        case nvidia = "NVIDIA"
        case openrouter = "OpenRouter"

        var icon: String {
            switch self {
            case .phone: "iphone"
            case .pc: "desktopcomputer"
            case .grok, .composio, .nvidia, .openrouter: "cloud"
            }
        }
    }

    var chatRouteModelTitle: String? {
        guard !demo else { return nil }
        return chatModelCurrentOption(resolvedRoute).title
    }

    var chatModelSelectionButton: some View { chatModelSelectionButton(showCurrentModel: false) }

    @ViewBuilder func chatModelSelectionButton(showCurrentModel: Bool) -> some View {
        if !demo {
            let route = resolvedRoute
            let current = chatModelCurrentOption(route)
            let hasPCCatalog = api is LiveAPI && !legacyChat
            let pcSetup: (() -> Void)? = hasPCCatalog ? { showPCModelSetup = true } : (api == nil ? reconnectPC : nil)
            ChatModelSelectionButton(
                current: current, options: chatModelOptions, blocked: task != nil,
                pcHint: modelsLoading ? "Henter PC’ens modeller…" : pcEngineOffline ? pcEngineOfflineMessage : modelsError,
                resetTitle: manualRoute == nil ? nil : autoRouterEnabled ? "Brug Auto igen" : "Brug mit normale valg",
                smartSelected: autoRouterEnabled && manualRoute == nil,
                showCurrentModel: showCurrentModel,
                pcSetupTitle: hasPCCatalog ? "Se hele PC-kataloget" : "Forbind til PC",
                onOpen: { composerFocused = false },
                onChoose: { chooseModelForNextMessage($0.source, modelID: $0.modelID) },
                onReset: { manualRoute = nil },
                onSmart: { autoRouterEnabled = true; manualRoute = nil },
                onPhoneSetup: { showPhoneModelSetup = true }, onPCSetup: pcSetup
            )
        }
    }

    private var chatModelOptions: [ChatModelOption] {
        var options = phoneRoutingCandidates.map { ChatModelOption(source: .phone, modelID: $0.id, title: $0.name) }
        if !options.contains(where: { $0.modelID == "apple" }) {
            options.append(ChatModelOption(source: .phone, modelID: "apple", title: "Apple Foundation Models",
                                           available: PhoneModels.isReady("apple")))
        }
        let phone = PhoneModels.effectiveModelID(phoneModel)
        if !options.contains(where: { $0.modelID == phone }) {
            options.append(ChatModelOption(source: .phone, modelID: phone, title: phoneModelLabel(for: phone),
                                           available: PhoneModels.isReady(phone)))
        }
        if legacyChat || !(api is LiveAPI) {
            options.append(ChatModelOption(source: .pc, modelID: nil, title: "PC’ens standardmodel",
                                           available: api != nil || canQueuePC))
        } else {
            options.append(contentsOf: models.map {
                ChatModelOption(source: .pc, modelID: $0.id, title: $0.label,
                                available: !pcEngineOffline && !modelsLoading && PCModelSelection.usable($0))
            })
        }
        if cloudKeyAvailable {
            options.append(ChatModelOption(source: .grok, modelID: nil, title: GrokAPI.requestedModelID))
        }
        if composioCloud.allows("deepseek") {
            options.append(ChatModelOption(source: .composio, modelID: "deepseek-chat", title: "DeepSeek · Composio"))
            options.append(ChatModelOption(source: .composio, modelID: "deepseek-reasoner", title: "DeepSeek · Tænk grundigt"))
        }
        if composioCloud.allows("grok") {
            options.append(ChatModelOption(source: .composio, modelID: "grok-4.7", title: "Grok · Composio"))
        }
        options.append(contentsOf: nvidiaCloud.models.filter { _ in nvidiaCloud.enabled }.map {
            ChatModelOption(source: .nvidia, modelID: $0, title: NvidiaCloud.title($0))
        })
        options.append(contentsOf: openRouterCloud.models.filter { _ in openRouterCloud.enabled }.map {
            ChatModelOption(source: .openrouter, modelID: $0, title: OpenRouterCloud.title($0))
        })
        return options
    }

    private func chatModelCurrentOption(_ route: ResolvedRoute) -> ChatModelOption {
        switch route.source {
        case .phone:
            let id = route.modelID ?? PhoneModels.effectiveModelID(phoneModel)
            return ChatModelOption(source: .phone, modelID: id, title: phoneModelLabel(for: id), available: PhoneModels.isReady(id))
        case .pc:
            let entry = models.first { $0.id == route.modelID }
            let title = entry?.label ?? route.modelID ?? "PC’ens standardmodel"
            let catalogReady = legacyChat || !(api is LiveAPI) || (route.modelID == nil ? !models.isEmpty : entry != nil)
            return ChatModelOption(source: .pc, modelID: route.modelID, title: title,
                                   available: api != nil && !modelsLoading && !pcEngineOffline && catalogReady)
        case .grok:
            return ChatModelOption(source: .grok, modelID: nil, title: GrokAPI.requestedModelID, available: cloudKeyAvailable)
        case .openrouter:
            let id = route.modelID ?? "openrouter/free"
            return ChatModelOption(source: .openrouter, modelID: id, title: OpenRouterCloud.title(id), available: openRouterCloud.enabled)
        case .nvidia:
            let id = route.modelID ?? nvidiaCloud.models.first ?? ""
            return ChatModelOption(source: .nvidia, modelID: id, title: NvidiaCloud.title(id), available: nvidiaCloud.enabled)
        case .composio:
            let id = route.modelID ?? "deepseek-chat"
            return ChatModelOption(source: .composio, modelID: id,
                                   title: id == "grok-4.7" ? "Grok · Composio" : "DeepSeek · Composio",
                                   available: composioCloud.enabled)
        }
    }
}
