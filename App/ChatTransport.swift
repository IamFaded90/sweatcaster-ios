// Chat send, streaming and dispatch to the selected inference source.

import Foundation
import SwiftUI

extension ChatView {
    private func responsePreferences() -> [String] {
        var rules = ["tone=\(aiTone)", "længde=\(aiLength)", "sprog=\(aiLanguage)", "kreativitet=\(aiCreativity)"]
        let flags: [(Bool, String)] = [
            (aiBullets, "punktform"), (aiExamples, "eksempler"), (aiSummary, "kort resumé først"),
            (aiActions, "næste handling til sidst"), (aiClarify, "spørg ved uklarhed"),
            (aiSimple, "enkelt sprog"), (aiNoJargon, "intet unødigt fagsprog"), (aiSteps, "trin for trin"),
            (aiTables, "tabel ved sammenligning"), (aiUncertainty, "markér usikkerhed"),
            (aiCounterpoint, "ét modargument"), (aiAssumptions, "vis antagelser"),
            (aiSources, "kilder ved research"), (aiCodeComments, "korte kodekommentarer"),
            (aiPreserveNames, "bevar præcise navne"), (aiEmojis, "få emojis"),
            (aiHeadings, "korte overskrifter"), (aiRecapQuestion, "kontrolspørgsmål til sidst"),
            (aiSuggestions, "relevante genveje"), (aiRisks, "fremhæv risici"),
            (aiProsCons, "fordele og ulemper"), (aiChecklist, "tjekliste ved opgaver")
        ]
        rules.append(contentsOf: flags.filter { $0.0 }.map { $0.1 })
        return rules
    }

    private func enhancedPrompt(_ message: String, preferences: [String]) -> String {
        let prefix = "\n\n[Svarpræferencer: "
        let suffix = "]"
        let available = 2000 - message.unicodeScalars.count - prefix.unicodeScalars.count - suffix.unicodeScalars.count
        guard available > 0 else { return message }
        let settings = preferences.joined(separator: "; ").unicodeScalars.prefix(available)
        return message + prefix + String(settings) + suffix
    }

    private func phoneHistory(for message: String) -> [PhoneModels.ChatExchange] {
        var remaining = max(0, 3_000 - message.count)
        var history: [PhoneModels.ChatExchange] = []
        for turn in turns.suffix(6).reversed() where turn.notice == nil && !turn.reply.isEmpty {
            let size = turn.prompt.count + turn.reply.count + 24
            guard size <= remaining else { break }
            history.append(.init(prompt: turn.prompt, reply: turn.reply))
            remaining -= size
        }
        return Array(history.reversed())
    }

    var transportMessage: String { transportMessage(for: effectiveReplySource) }

    func transportMessage(for destination: ReplySource) -> String {
        var message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let attachedNote, noteDestination == destination { message += "\n\nVedhæftet note til kontekst:\n" + attachedNote }
        if let attachedQuote, quoteDestination == destination { message += "\n\nCitat fra et tidligere svar til kontekst:\n" + attachedQuote }
        return message
    }

    func send() {
        guard stagedPhoto == nil else {
            chatNotice = "Analysér eller fjern billedet, før du sender."
            return
        }
        dictation.stop()
        let originalDraft = draft
        let message = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = resolvedRoute
        let outgoing = transportMessage(for: route.source)
        if route.source != .pc, route.automatic != nil, PhoneModels.shouldUseLiteModel,
           ModelRouter.intent(for: message) == .cardCollection {
            chatNotice = "Kortsamlingen ligger på PC’en. Vælg PC manuelt for at spørge den."
            return
        }
        if !demo, route.source == .phone, !PhoneModels.isReady(route.modelID ?? phoneModel) {
            chatNotice = "Telefonmodellen er ikke klar. Din kladde bliver gemt."
            return
        }
        guard task == nil, !message.isEmpty, outgoing.unicodeScalars.count <= 2000, canSend(to: route) else { return }
        let source = route.source
        let phoneNote = source == .phone && noteDestination == .phone ? attachedNote : nil
        let phoneQuote = source == .phone && quoteDestination == .phone ? attachedQuote : nil
        let routeGrok = source == .grok && !demo
        let collectionQuestion = message.lowercased().hasPrefix("kortsamling:")
        let preferences = responsePreferences()
        let modelMessage = source == .pc && !collectionQuestion ? enhancedPrompt(outgoing, preferences: preferences) : outgoing
        clearPCFallbackAction()
        if source == .pc && canQueuePC, let address = pcTargetAddress {
            queuePCMessage(message, outgoing: modelMessage, address: address, modelID: route.modelID)
            return
        }
        let cloudMessages = routeGrok ? grokMessages(endingWith: outgoing) : []
        sourceExcerpt = routeGrok || attachedNote != nil ? nil : localReference(for: message)
        attachedNote = nil
        attachedQuote = nil
        chatNotice = nil
        draft = ""
        savedDraft = ""
        searchSteps = []
        streamedText = ""
        responseDuration = nil
        let turn = ChatTurn(prompt: message, createdAt: .now)
        let history = source == .phone ? phoneHistory(for: outgoing) : []
        turns.append(turn)
        let turnID = turn.id
        status = "Venter på svar…"
        let input = ChatRequest(message: modelMessage, session_id: sessionID)
        inFlightAutoRoute = route.automatic
        save(pending: true)
        let startedAt = ContinuousClock.now
        task = Task {
            defer {
                status = nil
                task = nil
                manualRoute = nil
                inFlightAutoRoute = nil
                save()
            }
            do {
                if demo {
                    status = "Demo · Finder et testklip…"
                    try await Task.sleep(for: .milliseconds(600))
                    guard let index = turnIndex(turnID) else { return }
                    turns[index].reply = "Jeg fandt et testklip. "
                    try await Task.sleep(for: .milliseconds(600))
                    if let current = turnIndex(turnID) { turns[current].reply += "Demoen starter ikke et video-job." }
                } else {
                    switch source {
                    case .phone:
                        try await answerOnPhone(outgoing, history: history, preferences: preferences,
                                                modelID: route.modelID ?? phoneModel, turnID: turnID)
                    case .pc: try await answerOnPC(input, modelID: route.modelID, turnID: turnID)
                    case .grok: try await answerOnGrok(cloudMessages, turnID: turnID)
                    }
                }
                if let index = turnIndex(turnID), turns[index].notice == nil {
                    completedReplies += 1
                    if !turns[index].reply.isEmpty {
                        let elapsed = startedAt.duration(to: ContinuousClock.now).components.seconds
                        responseDuration = (turnID, Int(clamping: elapsed))
                    }
                    if voiceMode && !turns[index].reply.isEmpty && !dictation.active {
                        speak(turns[index].reply, turnID: turnID)
                    }
                }
            } catch is CancellationError {
                AppDiagnostics.record(CancellationError())
                if let index = turnIndex(turnID) {
                    turns[index].notice = "Modtagelsen er stoppet."
                }
            } catch {
                AppDiagnostics.record(error)
                if let index = turnIndex(turnID) {
                    if source == .phone && !demo {
                        let hasPartial = !turns[index].reply.isEmpty
                        turns[index].notice = phoneError(error, hasPartial: hasPartial)
                        if !hasPartial, draft.isEmpty, attachedNote == nil, attachedQuote == nil {
                            draft = originalDraft
                            savedDraft = originalDraft
                            if let phoneNote { attachedNote = phoneNote; noteDestination = .phone }
                            if let phoneQuote { attachedQuote = phoneQuote; quoteDestination = .phone }
                        }
                    } else {
                        turns[index].notice = source == .pc ? pcChatFailure(error, turnID: turnID) : AppErrorPresentation(error).title
                    }
                }
            }
        }
    }

    private func turnIndex(_ id: UUID) -> Int? { turns.firstIndex { $0.id == id } }

    private func queuePCMessage(_ prompt: String, outgoing: String, address: String, modelID: String?) {
        guard canQueuePC, pcTargetAddress == address, let pcQueueTargetID else { return }
        do {
            let entry = try PCChatOutbox().enqueue(address: address, targetID: pcQueueTargetID, prompt: prompt,
                                                   message: outgoing, sessionID: sessionID, modelID: modelID)
            turns.append(ChatTurn(id: entry.id, prompt: entry.prompt, notice: "Venter på PC", source: "PC", createdAt: entry.createdAt))
            manualRoute = nil
            attachedNote = nil
            attachedQuote = nil
            draft = ""
            savedDraft = ""
            composerFocused = false
            save()
            chatNotice = "Beskeden venter i udbakken til denne PC."
            reloadOutbox()
        } catch PCChatOutbox.Failure.full {
            AppDiagnostics.record(PCChatOutbox.Failure.full)
            chatNotice = "Udbakken er fuld. Fjern en besked, og prøv igen."
        } catch {
            AppDiagnostics.record(error)
            chatNotice = "Beskeden kunne ikke gemmes i udbakken. Din kladde er bevaret."
        }
    }

    func sourceIcon(_ source: String?) -> String {
        switch source ?? "" {
        case "Telefon": "iphone"
        case GrokAPI.sourceLabel: "cloud"
        default: "desktopcomputer"
        }
    }

    func phoneModelLabel(for id: String) -> String {
        switch id {
        case "apple": "Apple Foundation Models"
        case "imported": "Importeret model"
        default: PhoneModels.catalog.first { $0.id == id }?.name ?? id
        }
    }

    func replyAttribution(for turn: ChatTurn) -> String {
        let source = turn.source ?? "AI"
        guard let id = turn.replyModelID else {
            return turn.source == nil ? source : "\(source) · Model ikke oplyst"
        }
        let name = switch source {
        case "Telefon": phoneModelLabel(for: id)
        case "PC": models.first { $0.id == id }?.label ?? id
        default: id
        }
        return "\(source) · \(name)"
    }

    private func grokMessages(endingWith message: String) -> [GrokAPI.Message] {
        let history = turns.filter { $0.source == GrokAPI.sourceLabel && $0.notice == nil && !$0.reply.isEmpty }
            .suffix(4).flatMap { turn in
                [GrokAPI.Message(role: .user, content: String(turn.prompt.prefix(2000))),
                 GrokAPI.Message(role: .assistant, content: String(turn.reply.prefix(4000)))]
            }
        return (history + [GrokAPI.Message(role: .user, content: message)]).map {
            GrokAPI.Message(role: $0.role, content: (api as? LiveAPI)?.redactChat($0.content, complete: true) ?? $0.content)
        }
    }

    private func answerOnGrok(_ messages: [GrokAPI.Message], turnID: UUID) async throws {
        guard let index = turnIndex(turnID) else { return }
        turns[index].source = GrokAPI.sourceLabel
        status = "Grok · Venter på svar…"
        let modelID = try await GrokAPI.reply(input: messages) { output in
            await MainActor.run {
                guard !Task.isCancelled, let index = turnIndex(turnID) else { return }
                streamedText = output
                turns[index].reply = safeText(output, complete: true)
            }
        }
        if let index = turnIndex(turnID) { turns[index].replyModelID = modelID }
    }

    private func answerOnPhone(_ message: String, history: [PhoneModels.ChatExchange], preferences: [String],
                               modelID: String, turnID: UUID) async throws {
        guard let index = turnIndex(turnID) else { return }
        turns[index].source = "Telefon"
        status = "Telefon · Forbereder svar…"
        let instructions = "Besvar brugerens seneste besked direkte. En hilsen skal bare have en kort hilsen som svar. "
            + "Brug tidligere beskeder, når de er relevante. Du udfører ingen opgaver på PC’en. "
            + "Svarpræferencer: " + preferences.joined(separator: ", ") + "."
        let prompt: String
        if modelID == "apple" && !history.isEmpty {
            let context = history.map { "Bruger: \($0.prompt)\nSvar: \($0.reply)" }.joined(separator: "\n")
            prompt = "\(context)\nBruger: \(message)"
        } else {
            prompt = message
        }
        try await PhoneModels.reply(modelID: modelID, prompt: prompt, instructions: instructions, history: history) { answer in
            guard !Task.isCancelled, let index = turnIndex(turnID) else { return }
            turns[index].reply = safeText(answer)
            turns[index].replyModelID = modelID
            streamedText = answer
        }
        try Task.checkCancellation()
        if let index = turnIndex(turnID) {
            turns[index].reply = safeText(streamedText, complete: true)
        }
    }

    private func phoneError(_ error: Error, hasPartial: Bool) -> String {
        if hasPartial { return "Telefonsvaret blev afbrudt." }
        if case .busy? = error as? LocalComputeError { return "Telefonen arbejder allerede. Prøv igen om lidt." }
        if case .lowMemory? = error as? LocalComputeError { return "Telefonen har for lidt ledig hukommelse til modellen." }
        if case .unavailable? = error as? PhoneModelError { return "Vælg en klar model under Lokale modeller, eller skift til PC." }
        if case .contextLimit? = error as? PhoneModelError { return "Beskeden er for lang til telefonmodellen. Forkort den, eller vælg en anden model." }
        return "Telefonmodellen kunne ikke svare. Prøv igen, eller vælg en anden kilde."
    }

    private func answerOnPC(_ input: ChatRequest, modelID: String?, turnID: UUID) async throws {
        guard let index = turnIndex(turnID) else { return }
        guard let api else {
            turns[index].notice = "Denne besked kræver en model, der er klar. Forbind til PC’en, eller vælg en lokal model i Indstillinger."
            return
        }
        turns[index].source = "PC"
        status = "PC · Venter på svar…"
        if let live = api as? LiveAPI, !legacyChat {
            let request = try V2ChatRequest(message: input.message, sessionID: input.session_id?.uuidString, modelID: modelID)
            try await live.v2Chat(request) { event in
                await MainActor.run {
                    guard !Task.isCancelled, let index = turnIndex(turnID) else { return }
                    if let reported = live.reportedReplyModelID(for: event) { turns[index].replyModelID = reported }
                    receive(type: event.type.rawValue, content: event.content, index: index)
                }
            }
            try Task.checkCancellation()
            pcEngineOffline = false
        } else {
            await run(api, input: input, turnID: turnID)
        }
    }

    private func run(_ api: any ChatAPI, input: ChatRequest, turnID: UUID) async {
        do {
            try await api.chat(input) { event in
                await MainActor.run {
                    guard !Task.isCancelled, let index = turnIndex(turnID) else { return }
                    receive(type: event.type, content: event.content, index: index)
                }
            }
            try Task.checkCancellation()
        } catch {
            AppDiagnostics.record(error)
            guard let index = turnIndex(turnID) else { return }
            turns[index].notice = Task.isCancelled ? "Modtagelsen er stoppet. Et job kan stadig køre."
                : pcChatFailure(error, turnID: turnID)
        }
    }

    private func pcChatFailure(_ error: Error, turnID: UUID) -> String {
        let problem: (code: String?, message: String?)
        if case .http(503, let code, let message)? = error as? V2Failure {
            problem = (code, message)
        } else if case .http(503, let body)? = error as? APIError {
            problem = (body?.code, body?.message)
        } else {
            problem = (nil, nil)
        }
        if problem.code?.uppercased() == "DEPENDENCY_MISSING" {
            busyPCTurn = turnID
            let reason = problem.message?.lowercased() ?? ""
            if reason.contains("assistant container") || reason.contains("agent container") {
                pcEngineOffline = true
                return pcEngineOfflineMessage
            }
            if reason.contains("model") {
                return "PC’en kan ikke indlæse den valgte model. Tjek Ollama på PC’en, eller vælg en anden PC-model."
            }
            return "PC’en mangler en tjeneste til chat. Start FadedAI og Ollama på PC’en, og prøv igen."
        }
        if let busy = pcBusyMessage(error) {
            busyPCTurn = turnID
            return busy
        }
        return AppErrorPresentation(error).title
    }

    private func receive(type: String, content: String, index: Int) {
        switch type {
        case "tool_status":
            let step: String = switch content {
            case "Waiting for the one model slot.": "Venter på, at PC’ens modelplads bliver ledig."
            case "Preparing the selected model.": "PC’en gør modellen klar."
            case "Reading process status.": "Tjekker PC’ens status."
            case "Looking up local documents.": "Søger i lokale dokumenter på PC’en."
            case "Writing inside the workspace folder.": "Tjekker anmodningen om en filændring."
            case "Writing the reply from the local model.": "PC’en skriver svaret."
            case "The assistant container did not confirm the model.": "PC’en kunne ikke gøre modellen klar."
            case "The assistant container did not answer.": "PC’ens chatmotor svarede ikke."
            case "The assistant container refused the chat.": "PC’ens chatmotor afviste forespørgslen."
            case let message where message.hasPrefix("Search the public web with only the sanitized question."):
                "PC’en søger på nettet."
            case let message where message.hasPrefix("List clip file names and modification times"):
                "Tjekker kliplisten på PC’en."
            case let message where message.hasPrefix("Call the host video API only when"):
                "Tjekker videoanmodningen."
            default: safeText(content)
            }
            guard !step.isEmpty else { return }
            status = step
            if searchSteps.last != step {
                searchSteps.append(step)
                if searchSteps.count > 30 { searchSteps.removeFirst() }
                save(pending: true)
            }
        case "text":
            streamedText += content
            turns[index].reply = safeText(streamedText)
        case "done":
            turns[index].reply = safeText(streamedText, complete: true)
        default: break
        }
    }

    func safeText(_ text: String, complete: Bool = false) -> String {
        let safe = (api as? LiveAPI)?.redactChat(text, complete: complete) ?? text
        if safe.contains("Traceback (most recent call last)") { return "PC’en sendte en intern fejl." }
        return safe.replacingOccurrences(of: #"(?i)(?:\b[A-Z]:[\\/]|\\\\)[^\r\n`"<>]+"#,
                                         with: "[filsti skjult]", options: .regularExpression)
    }
}
