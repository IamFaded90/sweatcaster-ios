import ImageIO
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable final class BotComputerStore {
    private struct Draft: Equatable {
        let prompt: String
        let fileID: UUID?
        let phoneKind: BotPhoneActionKind?
        let phoneTime: String?
        let context: String?
        let agentProfile: String?
        let webSearch: Bool
        let taskModel: String?
        let requestID = UUID()

        func matches(_ prompt: String, _ fileID: UUID?, _ phoneKind: BotPhoneActionKind?,
                     _ context: String?, _ agentProfile: String?, _ webSearch: Bool, _ taskModel: String?) -> Bool {
            self.prompt == prompt && self.fileID == fileID && self.phoneKind == phoneKind &&
                self.context == context && self.agentProfile == agentProfile && self.webSearch == webSearch &&
                self.taskModel == taskModel
        }
    }

    var status: BotComputerStatus?
    var jobs: [BotComputerJob] = []
    var files: [BotComputerFile] = []
    var watching = false
    var controlling = false
    var frame: BotDesktopImage?
    var busy = false
    var loadedCatalog = false
    var connectionError: String?
    var catalogError: String?
    var screenError: String?
    var feedback: String?
    private var target: String?
    private var revision = 0
    private var draft: Draft?

    var canSend: Bool { status != nil && connectionError == nil }

    func selectConnection(_ id: String?) {
        guard id != target else { return }
        target = id
        revision += 1
        status = nil
        jobs = []
        files = []
        loadedCatalog = false
        busy = false
        draft = nil
        feedback = nil
        connectionError = nil
        catalogError = nil
        leaveDesktop()
    }

    func leaveDesktop() {
        watching = false
        controlling = false
        frame = nil
        screenError = nil
    }

    func forgetDraft() { draft = nil }

    func monitor(_ client: BotComputerClient) async {
        var nextStatusCheck = ContinuousClock.now
        while !Task.isCancelled {
            if !busy {
                if ContinuousClock.now >= nextStatusCheck {
                    await refresh(client)
                    nextStatusCheck = ContinuousClock.now.advanced(by: .seconds(5))
                }
                if watching && status?.status == .running { await refreshScreen(client) }
            }
            do { try await Task.sleep(for: watching ? .seconds(1) : .seconds(2)) }
            catch { return }
        }
    }

    private func isCurrent(_ client: BotComputerClient, _ revision: Int) -> Bool {
        !Task.isCancelled && target == client.api.queueTargetID && self.revision == revision
    }

    private func refresh(_ client: BotComputerClient) async {
        let current = revision
        do {
            let value = try await client.status()
            guard isCurrent(client, current) else { return }
            status = value
            connectionError = nil
            if value.status != .running { leaveDesktop() }
        } catch {
            guard isCurrent(client, current) else { return }
            status = nil
            leaveDesktop()
            connectionError = Self.message(for: error)
            return
        }
        await refreshCatalog(client, revision: current)
    }

    private func refreshCatalog(_ client: BotComputerClient, revision: Int) async {
        do {
            async let nextJobs = client.jobs()
            async let nextFiles = client.files()
            let snapshot = try await (nextJobs, nextFiles)
            guard isCurrent(client, revision) else { return }
            jobs = snapshot.0
            files = snapshot.1
            SimulationEngine.shared.ingestJobs(jobs.map { .init(id: $0.id, status: $0.status) },
                                               for: client.botID, targetID: client.api.queueTargetID)
            loadedCatalog = true
            catalogError = nil
        } catch {
            guard isCurrent(client, revision) else { return }
            catalogError = Self.message(for: error)
        }
    }

    private func refreshScreen(_ client: BotComputerClient) async {
        let current = revision
        do {
            let data = try await client.screenshot()
            guard isCurrent(client, current), watching else { return }
            guard let image = BotDesktopImage(data) else { throw APIError.malformed }
            frame = image
            screenError = nil
        } catch {
            guard isCurrent(client, current), watching else { return }
            frame = nil
            controlling = false
            screenError = Self.message(for: error)
        }
    }

    @discardableResult private func perform<T>(
        _ client: BotComputerClient, operation: () async throws -> T,
        apply: (T) -> Void
    ) async -> Bool {
        guard target == client.api.queueTargetID, !busy else { return false }
        revision += 1
        let current = revision
        busy = true
        feedback = nil
        defer { if revision == current { busy = false } }
        do {
            let response = try await operation()
            guard isCurrent(client, current) else { return false }
            apply(response)
            return true
        } catch {
            guard isCurrent(client, current) else { return false }
            feedback = Self.message(for: error)
            return false
        }
    }

    func changePower(start: Bool, client: BotComputerClient) async {
        if !start { leaveDesktop() }
        await perform(client) {
            if start { try await client.start() } else { try await client.stop() }
        } apply: { status = $0 }
    }

    @discardableResult func send(_ input: BotComputerClient.Input, client: BotComputerClient) async -> Bool {
        guard watching, controlling, frame != nil, status?.status == .running else { return false }
        return await perform(client) { try await client.send(input) } apply: { _ in }
    }

    func submit(prompt: String, fileID: UUID?, phoneKind: BotPhoneActionKind?, context: String?,
                agentProfile: String?, webSearch: Bool, client: BotComputerClient, taskModel: String? = nil) async -> Bool {
        guard canSend, !busy else { return false }
        guard loadedCatalog else {
            feedback = "Vent, til bottens opgaver er hentet, og prøv igen."
            return false
        }
        guard phoneKind == nil || status?.phoneActions == true else {
            feedback = "Opdatér FadedAI på PC’en for at bruge iPhone-opgaver."
            return false
        }
        guard context == nil || status?.taskContext == true else {
            feedback = "Opdatér FadedAI på PC’en for at bruge opslag i botopgaver."
            return false
        }
        guard !webSearch || status?.webSearch == true else {
            feedback = "Opdatér FadedAI på PC’en for at bruge websøgning i opgaven."
            return false
        }
        guard taskModel == nil || status?.taskModels?.contains(taskModel ?? "") == true else {
            feedback = "Opdatér PC’en og forbind OpenRouter for at bruge den valgte model."
            return false
        }
        let current = if let draft, draft.matches(prompt, fileID, phoneKind, context, agentProfile, webSearch, taskModel) {
            draft
        } else {
            Draft(prompt: prompt, fileID: fileID, phoneKind: phoneKind,
                  phoneTime: phoneKind.map { _ in BotPhoneAction.localFormatter().string(from: .now) },
                  context: context, agentProfile: agentProfile, webSearch: webSearch, taskModel: taskModel)
        }
        draft = current
        return await perform(client) {
            try await client.submit(prompt: prompt, fileID: fileID, requestID: current.requestID,
                                    phoneKind: current.phoneKind, phoneTime: current.phoneTime,
                                    taskContext: current.context, agentProfile: current.agentProfile, webSearch: current.webSearch,
                                    taskModel: current.taskModel)
        } apply: { job in
            draft = nil
            applyJob(job)
        }
    }

    func cancel(_ id: UUID, client: BotComputerClient) async {
        await perform(client) { try await client.cancel(id) } apply: { applyJob($0) }
    }

    func upload(name: String, content: String, client: BotComputerClient) async -> BotComputerFile? {
        var imported: BotComputerFile?
        await perform(client) {
            try await client.upload(name: name, content: content)
        } apply: { file in
            files.insert(file, at: 0)
            feedback = "Filen ligger i bottens arbejdsrum."
            imported = file
        }
        return imported
    }

    func share(_ file: BotComputerFile, with recipient: VillageBot, client: BotComputerClient) async -> BotComputerFile? {
        var copy: BotComputerFile?
        await perform(client) {
            try await client.share(fileID: file.id, with: recipient.id)
        } apply: {
            copy = $0
            feedback = "En kopi er delt med \(recipient.name)."
        }
        return copy
    }

    private func applyJob(_ job: BotComputerJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.insert(job, at: 0) }
    }

    static func message(for error: any Error) -> String {
        guard let error = error as? APIError else { return "PC’ens svar kunne ikke læses. Prøv igen." }
        if case .http(_, let problem) = error, let message = problem?.message, !message.isEmpty { return message }
        switch error {
        case .http(404, _): return "Funktionen eller filen blev ikke fundet. Tjek, at FadedAI på PC’en er opdateret."
        case .http(422, _): return "Tjek teksten, filen eller handlingen, og prøv igen."
        case .http(409, _): return "Handlingen kan ikke udføres i den aktuelle tilstand. Opdater og prøv igen."
        case .http(503, _): return "Tjek, at Docker Desktop og FadedAI kører på PC’en."
        case .offline, .transport(_): return "Forbindelsen til FadedAI på PC’en er afbrudt."
        default: return error.title
        }
    }
}
