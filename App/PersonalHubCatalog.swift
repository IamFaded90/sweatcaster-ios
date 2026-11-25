import CastBrowserFeature
import Foundation

struct PersonalHubSource: Identifiable {
    let record: PersonalHubRecall.Record
    var bot: VillageBot?
    var file: URL?
    var music: MusicTrack?
    var page: URL?
    var project: FadedProject?
    var creative: CreativeProject?
    var workspace: AgentWorkspace.File?
    var native: AgentLocalDestination?
    var id: String { record.id }
}

@MainActor enum PersonalHubCatalog {
    static func load() -> (sources: [PersonalHubSource], warning: String?) {
        var warning: String?
        let bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
        let links = (try? PersonalMediaLink.Store().load()) ?? []
        let turns = MigratedAppData.shared.regularStudioTurns().filter { $0.botID != VillageBot.lumiID }.suffix(300)
        var result: [PersonalHubSource] = []
        for turn in turns {
            let bot = bots.first { $0.id == turn.botID }
            if let name = turn.imageName, let file = StudioImageFiles.savedImage(name), FileManager.default.fileExists(atPath: file.path) {
                let link = links.last { $0.id == turn.id }
                let music = link.map { MusicTrack(id: $0.musicID, title: $0.musicTitle, artist: $0.musicArtist) }
                let relation = link.map { "\nVed billedets færdiggørelse spillede: \($0.musicTitle) · \($0.musicArtist)." } ?? ""
                result.append(.init(record: .init(id: "image:" + turn.id.uuidString, kind: .image, title: turn.prompt,
                    text: turn.prompt + relation, botID: turn.botID, relatedMusicID: music?.id), bot: bot, file: file, music: music))
            } else if turn.imageName == nil, !turn.reply.isEmpty {
                result.append(.init(record: .init(id: "chat:" + turn.id.uuidString, kind: turn.agentAction == nil ? .conversation : .task,
                    title: turn.prompt, text: "Dig: " + String(turn.prompt.prefix(1_200)) + "\n\n" + (bot?.name ?? "Agent") + ": " + String(turn.reply.prefix(5_000)), botID: turn.botID), bot: bot))
            }
        }
        var creative: [CreativeProject] = []
        do { creative = try CreativeProject.Store().list().filter { $0.botID != VillageBot.lumiID } }
        catch { AppDiagnostics.record(error); warning = "Nogle kreative forløb kunne ikke læses." }
        for item in creative.prefix(40) {
            let music = item.musicID.map { MusicTrack(id: $0, title: item.musicTitle ?? "Gemt sang", artist: item.musicArtist ?? "") }
            result.append(.init(record: .init(id: "creative:" + item.id.uuidString, kind: .creative, title: item.title.isEmpty ? item.kind.rawValue : item.title,
                text: item.brief + "\n\n" + String(item.text.prefix(6_000)), botID: item.botID), bot: bots.first { $0.id == item.botID }, music: music, creative: item))
        }
        let creativeIDs = Set(creative.map(\.id))
        var projects: [FadedProject] = []
        do { projects = try FadedProjectStore.load() }
        catch { AppDiagnostics.record(error); warning = "Nogle projekter kunne ikke læses." }
        for item in projects.filter({ !creativeIDs.contains($0.id) }).suffix(40) {
            result.append(.init(record: .init(id: "project:" + item.id.uuidString, kind: .file, title: item.title,
                text: String(item.content.prefix(6_000))), project: item))
        }
        for bot in bots {
            do { result.append(contentsOf: try nativeSources(bot: bot)) }
            catch { warning = "Nogle lokale kildeforløb kunne ikke læses." }
            if let workspace = try? AgentWorkspace(botID: bot.id).load() {
                for file in workspace.files.suffix(20) {
                    result.append(.init(record: .init(id: "workspace:" + file.id.uuidString, kind: .file, title: file.name,
                        text: String(file.text.prefix(6_000)), botID: bot.id), bot: bot, workspace: file))
                }
            }
            if let task = try? AgentTaskJourney.Store(botID: bot.id).load() {
                result.append(.init(record: .init(id: "task:" + task.id.uuidString, kind: .task, title: task.subject.isEmpty ? task.goal : task.subject,
                    text: task.summary, botID: bot.id), bot: bot))
            }
        }
        var musicIDs = Set<String>()
        for track in MusicLibrary.shared.saved.favorites + MusicLibrary.shared.saved.downloads + MusicLibrary.shared.recent where musicIDs.insert(track.id).inserted {
            result.append(.init(record: .init(id: "music:" + track.id, kind: .music, title: track.title, text: track.artist), music: track))
        }
        for item in CastLibraryBridge.items() {
            result.append(.init(record: .init(id: "film:" + item.id, kind: .film, title: item.title,
                text: item.isSource ? "En af dine gemte filmkilder" : "Fra din filmhistorik"), page: item.page))
        }
        if !MigratedAppData.shared.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.init(record: .init(id: "notes", kind: .file, title: "Mine noter", text: String(MigratedAppData.shared.notes.prefix(6_000)))))
        }
        return (result, warning)
    }
}
