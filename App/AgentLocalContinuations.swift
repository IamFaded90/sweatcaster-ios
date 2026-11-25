import SwiftUI

enum AgentLocalDestination: String { case audio, scan, dayPlan, capture, memory }

@MainActor struct AgentLocalContinuations: View {
    let bot: VillageBot
    @State private var audio: [AudioTranscript.Recording] = []
    @State private var plans: [DayPlan.Draft] = []
    @State private var scans = 0
    @State private var captures = 0
    @State private var notice: String?
    private var model: String { UserDefaults.standard.string(forKey: PhoneModels.agentModelKey(bot.id)) ?? UserDefaults.standard.string(forKey: AppStorageKeys.phoneModel) ?? "apple" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let recording = audio.first(where: { !$0.complete }) {
                NavigationLink { AudioJournalView(bot: bot, model: model, initialRecordingID: recording.id) } label: { card(recording.title, detail: bot.name + " · lyd kan fortsættes fra " + AudioTranscript.clock(recording.processedThrough ?? 0), icon: "waveform") }
            } else if !audio.isEmpty {
                NavigationLink { AudioJournalView(bot: bot, model: model) } label: { card("Optagelser · " + bot.name, detail: "\(audio.count) gemte lydforløb og transskriptioner", icon: "waveform") }
            }
            if let plan = plans.first {
                NavigationLink { DayPlanView(bot: bot, initialDraftID: plan.id) } label: { card("Dagsplan · " + bot.name, detail: plan.day.formatted(date: .abbreviated, time: .omitted) + " · læs kalenderen igen før næste fordeling", icon: "calendar.badge.clock") }
            }
            if scans > 0 {
                NavigationLink { DocumentScanView(bot: bot, model: model) } label: { card("Scanninger · " + bot.name, detail: "\(scans) dokumenter med lokale kildekopier", icon: "doc.viewfinder") }
            }
            if captures > 0 {
                NavigationLink { CaptureReviewView(bot: bot, model: model) } label: { card("Noter og opfølgning · " + bot.name, detail: "\(captures) gennemgåede kildeuddrag", icon: "square.and.pencil") }
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { load() }
    }
    private func card(_ title: String, detail: String, icon: String) -> some View {
        FadedCard { HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(FadedBrand.gradient).frame(width: 38)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline).foregroundStyle(.primary); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading) }
    }
    private func load() {
        do {
            audio = try AudioTranscript.Store(botID: bot.id).load(); plans = try DayPlan.Store(botID: bot.id).load()
            scans = try ScanDocument.Store(botID: bot.id).load().count; captures = try CapturedInsight.Store(botID: bot.id).load().count
        } catch { notice = "Et lokalt forløb kunne ikke læses. Prøv igen, mens telefonen er låst op." }
    }
}

extension PersonalHubCatalog {
    static func nativeSources(bot: VillageBot) throws -> [PersonalHubSource] {
        var result: [PersonalHubSource] = []
        for scan in try ScanDocument.Store(botID: bot.id).load().prefix(12) {
            result.append(.init(record: .init(id: "scan:" + scan.id.uuidString, kind: .file, title: scan.title, text: String(scan.text.prefix(6_000)), botID: bot.id), bot: bot, native: .scan))
        }
        for recording in try AudioTranscript.Store(botID: bot.id).load().prefix(8) {
            result.append(.init(record: .init(id: "audio:" + recording.id.uuidString, kind: .file, title: recording.title, text: String(recording.exportedText.prefix(6_000)), botID: bot.id), bot: bot, native: .audio))
        }
        for entry in try CapturedInsight.Store(botID: bot.id).load().prefix(24) {
            result.append(.init(record: .init(id: "capture:" + entry.id.uuidString, kind: .file, title: entry.proposal.text, text: entry.proposal.quote + "\nKilde: " + entry.source, botID: bot.id), bot: bot, native: .capture))
        }
        for item in try AgentMemory.Store(botID: bot.id).load().items.suffix(40) {
            result.append(.init(record: .init(id: "memory:" + item.id.uuidString, kind: .file, title: String(item.quote.prefix(100)), text: item.quote, botID: bot.id), bot: bot, native: .memory))
        }
        for plan in try DayPlan.Store(botID: bot.id).load().prefix(6) {
            result.append(.init(record: .init(id: "day-plan:" + plan.id.uuidString, kind: .task, title: "Dagsplan " + plan.day.formatted(date: .abbreviated, time: .omitted), text: plan.tasks.map { $0.title + ($0.receipt.map { " · " + $0 } ?? "") }.joined(separator: "\n"), botID: bot.id), bot: bot, native: .dayPlan))
        }
        return result
    }
}
