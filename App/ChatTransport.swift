// Chat send, streaming and dispatch to the selected inference source.

import Foundation
import SwiftUI

extension ChatView {
    private func enhancedPrompt(_ message: String) -> String {
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
        let prefix = "\n\n[Svarpræferencer: "
        let suffix = "]"
        let available = 2000 - message.unicodeScalars.count - prefix.unicodeScalars.count - suffix.unicodeScalars.count
        guard available > 0 else { return message }
        let preferences = rules.joined(separator: "; ").unicodeScalars.prefix(available)
        return message + prefix + String(preferences) + suffix
    }

    var transportMessage: String { transportMessage(for: effectiveReplySource) }

    func transportMessage(for destination: ReplySource) -> String {
        var message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let attachedNote, noteDestination == destination { message += "\n\nVedhæftet note til kontekst:\n" + attachedNote }
        if let attachedQuote, quoteDestination == destination { message += "\n\nCitat fra et tidligere svar til kontekst:\n" + attachedQuote }
        return message
    }

    func send() {
        dictation.stop()
        let originalDraft = draft
        let message = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = resolvedRoute
        let outgoing = transportMessage(for: route.source)
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
        let modelMessage = routeGrok || collectionQuestion ? outgoing : enhancedPrompt(outgoing)
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
        let turn = ChatTurn(prompt: message, createdAt: .now)
        let history = turns.suffix(6).filter { !$0.reply.isEmpty }
            .map { "Bruger: \($0.prompt)\nSvar: \($0.reply)" }.joined(separator: "\n")
        turns.append(turn)
        let turnID = turn.id
        let context = String(history.suffix(max(0, 3000 - modelMessage.count)))
        status = "Venter på svar…"
        let input = ChatRequest(message: modelMessage, session_id: sessionID)
        inFlightAutoRoute = route.automatic
        save(pending: true)
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
                        try await answerOnPhone(modelMessage, context: context, modelID: route.modelID ?? phoneModel, turnID: turnID)
                    case .pc: try await answerOnPC(input, modelID: route.modelID, turnID: turnID)
                    case .grok: try await answerOnGrok(cloudMessages, turnID: turnID)
                    }
                }
                if let index = turnIndex(turnID), turns[index].notice == nil {
                    completedReplies += 1
                    if voiceMode && !turns[index].reply.isEmpty && !dictation.active {
                        speak(turns[index].reply)
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
                        if source == .pc, pcBusyMessage(error) != nil { busyPCTurn = turnID }
                        turns[index].notice = pcBusyMessage(error) ?? AppErrorPresentation(error).title
                    }
                }
            }
        }
    }

    private func turnIndex(_ id: UUID) -> Int? { turns.firstIndex { $0.id == id } }

    private func queuePCMessage(_ prompt: String, outgoing: String, address: String, modelID: String?) {
        guard canQueuePC, pcTargetAddress == address, let pcQueueTargetID else { return }
        do {
            try PCChatOutbox().enqueue(address: address, targetID: pcQueueTargetID, prompt: prompt, message: outgoing, sessionID: sessionID,
                                       modelID: modelID)
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
        try await GrokAPI.reply(input: messages) { output in
            await MainActor.run {
                guard !Task.isCancelled, let index = turnIndex(turnID) else { return }
                streamedText = output
                turns[index].reply = safeText(output, complete: true)
            }
        }
    }

    private func answerOnPhone(_ message: String, context: String, modelID: String, turnID: UUID) async throws {
        guard let index = turnIndex(turnID) else { return }
        turns[index].source = "Telefon"
        status = "Telefon · Forbereder svar…"
        let prompt = context.isEmpty ? message : "\(context)\nBruger: \(message)"
        try await PhoneModels.reply(modelID: modelID, prompt: prompt,
                                    instructions: "Svar på brugerens sprog. Du kan bruge teksten i chatten og udfører ingen opgaver på PC’en.") { answer in
            guard !Task.isCancelled, let index = turnIndex(turnID) else { return }
            turns[index].reply = safeText(answer)
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
                    receive(type: event.type.rawValue, content: event.content, index: index)
                }
            }
            try Task.checkCancellation()
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
            if !Task.isCancelled, pcBusyMessage(error) != nil { busyPCTurn = turnID }
            turns[index].notice = Task.isCancelled ? "Modtagelsen er stoppet. Et job kan stadig køre."
                : pcBusyMessage(error) ?? AppErrorPresentation(error).title
        }
    }

    private func receive(type: String, content: String, index: Int) {
        switch type {
        case "tool_status":
            let step = safeText(content)
            status = step
            if !step.isEmpty && searchSteps.last != step {
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
