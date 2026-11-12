import Darwin
import Foundation
import os
import SwiftUI
import UIKit
import UserNotifications

enum AppDiagnostics {
    private static let lock = NSLock()
    private static let key = AppStorageKeys.diagnosticsApiV1

    @discardableResult
    static func record<E: Error>(_ error: E) -> E {
        let label: String
        switch error {
        case is CancellationError: return error
        case let api as APIError:
            switch api {
            case .http(let status, _): label = "APIError HTTP \(status)"
            case .transport(let code): label = "APIError transport \(code)"
            case .addressLeadingZeros: label = "APIError: Ledende nuller i PC-adressen"
            default: label = "APIError: " + api.title
            }
        case let v2 as V2Failure:
            switch v2 {
            case .http(let status, _, _): label = "V2Failure HTTP \(status)"
            case .invalidInput: label = "V2Failure invalidInput"
            case .invalidResponse: label = "V2Failure invalidResponse"
            case .interrupted: label = "V2Failure interrupted"
            }
        case let network as URLError:
            guard network.code != .cancelled else { return error }
            label = "URLSession \(network.errorCode)"
        case is DecodingError: label = "JSON: ugyldigt svarformat"
        default: label = "App-fejl · " + String(describing: type(of: error))
        }
        lock.withLock {
            var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
            let entry = "\(ISO8601DateFormatter().string(from: .now))  \(label)"
            guard entries.last != entry else { return }
            entries.append(entry)
            UserDefaults.standard.set(Array(entries.suffix(50)), forKey: key)
        }
        return error
    }

    static func export(phoneModel: String? = nil, pcConnected: Bool? = nil) throws -> URL {
        let entries = lock.withLock { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FadedAI-diagnostics", isDirectory: true)
        let url = folder.appendingPathComponent("FadedAI-fejllog.txt")
        var header = ["FadedAI · API-fejllog", "Eksporteret \(ISO8601DateFormatter().string(from: .now))"]
        if let phoneModel { header.append("Telefonmodel · \(phoneModel)") }
        if let pcConnected { header.append(pcConnected ? "PC · Forbundet" : "PC · Ingen aktiv forbindelse") }
        let content = entries.isEmpty ? "Ingen API-fejl registreret." : entries.joined(separator: "\n")
        let data = Data((header.joined(separator: "\n") + "\n\n" + content + "\n").utf8)
        try LocalFileStore.writeBytes(data, to: url, within: FileManager.default.temporaryDirectory)
        return url
    }
}

enum LocalComputeError: Error { case busy, lowMemory }

@MainActor enum StudioScratch {
    static let prefix = "FadedAI-Private-"
    private static var purgedAtLaunch = false

    static func purgeOnceAtLaunch() {
        guard !purgedAtLaunch else { return }
        purgedAtLaunch = true
        let manager = FileManager.default
        let root = manager.temporaryDirectory
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let info = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  info.isDirectory == true, info.isSymbolicLink != true else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}

extension Notification.Name {
    static let localModelReloaded = Self("FadedAI.localModelReloaded")
    static let localModelLoadState = Self("FadedAI.localModelLoadState")
}

func pcBusyMessage(_ error: Error) -> String? {
    AppErrorPresentation.pcBusy(error)?.title
}

@MainActor enum LocalCompute {
    private static var busy = false
    private static var suspended = false
    private static var backgroundRevision = 0
    private static var pending: [UUID] = []
    private static var loadedSinceForeground = false
    private static var needsReloadNotice = false
    private static var cancelCurrent: (() -> Void)?
    private(set) static var isLoadingModel = false
    private static let mib: UInt64 = 1_048_576
    static var headroom: UInt64 { UInt64(os_proc_available_memory()) }
    static var isRunning: Bool { busy }

    static func suspend() {
        suspended = true
        backgroundRevision += 1
        needsReloadNotice = needsReloadNotice || loadedSinceForeground
        loadedSinceForeground = false
        cancelCurrent?()
        setModelLoading(false)
    }

    static func resume() { suspended = false }

    static func beginModelLoad() {
        guard busy, !suspended, !Task.isCancelled else { return }
        setModelLoading(true)
    }

    private static func setModelLoading(_ loading: Bool) {
        guard isLoadingModel != loading else { return }
        isLoadingModel = loading
        NotificationCenter.default.post(name: .localModelLoadState, object: nil)
    }

    static func didLoadModel() {
        setModelLoading(false)
        guard !suspended, !Task.isCancelled else { return }
        loadedSinceForeground = true
        if needsReloadNotice {
            needsReloadNotice = false
            NotificationCenter.default.post(name: .localModelReloaded, object: nil)
        }
    }

    static func run<T>(minimumMiB: UInt64, work: @escaping @MainActor () async throws -> T) async throws -> T {
        guard !suspended else { throw CancellationError() }
        try Task.checkCancellation()
        guard pending.count < 4 else { throw LocalComputeError.busy }
        let ticket = UUID()
        let revision = backgroundRevision
        pending.append(ticket)
        defer { pending.removeAll { $0 == ticket } }
        while busy || pending.first != ticket {
            try await Task.sleep(for: .milliseconds(100))
            guard !suspended, revision == backgroundRevision else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard headroom >= minimumMiB * mib else { throw LocalComputeError.lowMemory }
        pending.removeFirst()
        busy = true
        let operation = Task { @MainActor in
            try Task.checkCancellation()
            return try await work()
        }
        cancelCurrent = { operation.cancel() }
        defer { setModelLoading(false); cancelCurrent = nil; busy = false }
        return try await withTaskCancellationHandler {
            let result = try await operation.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            operation.cancel()
        }
    }

    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

struct StudioRAMStatus: View {
    @Environment(\.scenePhase) private var phase
    @State private var footprint: UInt64?

    var body: some View {
        let deviceRAM = ProcessInfo.processInfo.physicalMemory
        HStack {
            Image(systemName: "memorychip").accessibilityHidden(true)
            if let footprint {
                Text("RAM: \(gib(footprint)) / \(gib(deviceRAM)) GB · FadedAI / telefon")
            } else {
                Text("RAM: måler FadedAI…")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: phase == .active) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                footprint = LocalCompute.footprint()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { AppDiagnostics.record(error); return }
            }
        }
    }

    private func gib(_ value: UInt64) -> String {
        (Double(value) / 1_000_000_000).formatted(.number.precision(.fractionLength(1)))
    }
}

// @unchecked Sendable: Singleton accessed only via @MainActor methods.
// All mutable state goes through UserDefaults or @MainActor entrypoints.
// No unlocked mutable stored properties.
final class JobNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = JobNotifications()
    private static let videoCategory = "fadedai.video"
    private static let codeCategory = "fadedai.code"

    @MainActor func configure() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let dismiss = UNNotificationAction(identifier: "dismiss", title: "Afvis", options: [])
        let video = UNNotificationAction(identifier: "video-jobs", title: "Se video", options: .foreground)
        let code = UNNotificationAction(identifier: "code", title: "Se kode", options: .foreground)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.videoCategory, actions: [video, dismiss], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.codeCategory, actions: [code, dismiss], intentIdentifiers: [], options: [])
        ])
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    @MainActor func completed(kind: String, server: String, id: String, title: String) async {
        let center = UNUserNotificationCenter.current()
        await completed(kind: kind, server: server, id: id, title: title, defaults: .standard,
                        authorization: { await center.notificationSettings().authorizationStatus },
                        add: { try await center.add($0) })
    }

    @MainActor func completed(kind: String, server: String, id: String, title: String, defaults: UserDefaults,
                              authorization: @MainActor () async -> UNAuthorizationStatus,
                              add: @MainActor (UNNotificationRequest) async throws -> Void) async {
        guard defaults.object(forKey: AppStorageKeys.notificationsEnabled(kind)) as? Bool ?? true else { return }
        let status = await authorization()
        guard status == .authorized || status == .provisional else { return }
        let identifier = "\(kind):\(server):\(id)"
        let key = AppStorageKeys.notificationsSentV1
        var sent = defaults.stringArray(forKey: key) ?? []
        guard !sent.contains(identifier) else { return }
        sent.append(identifier)
        defaults.set(Array(sent.suffix(300)), forKey: key)
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        switch kind {
        case "video", "video-failed": content.categoryIdentifier = Self.videoCategory
        case "code": content.categoryIdentifier = Self.codeCategory
        default: break
        }
        do { try await add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) }
        catch {
            AppDiagnostics.record(error)
            let current = defaults.stringArray(forKey: key) ?? []
            defaults.set(current.filter { $0 != identifier }, forKey: key)
        }
    }

    @MainActor func trackCodeJob(server: String, id: String) {
        let key = AppStorageKeys.notificationsActive("code", server: server)
        var active = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        active.insert(id)
        UserDefaults.standard.set(Array(active), forKey: key)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let destination: String
        switch response.actionIdentifier {
        case "video-jobs", "code": destination = response.actionIdentifier
        case UNNotificationDefaultActionIdentifier:
            switch response.notification.request.content.categoryIdentifier {
            case Self.videoCategory: destination = "video-jobs"
            case Self.codeCategory: destination = "code"
            default: return
            }
        default: return
        }
        await MainActor.run { UserDefaults.standard.set(destination, forKey: AppStorageKeys.spacesShortcut) }
    }
}

struct JobNotificationSettings: View {
    @AppStorage(AppStorageKeys.notificationsEnabledVideo) private var video = true
    @AppStorage(AppStorageKeys.notificationsEnabledVideoFailed) private var videoFailure = true
    @AppStorage(AppStorageKeys.notificationsEnabledCode) private var code = true
    @AppStorage(AppStorageKeys.notificationsEnabledImageModel) private var imageModel = true

    var body: some View {
        Toggle("Video færdig", isOn: $video)
        Toggle("Video fejlede", isOn: $videoFailure)
        Toggle("Kodeforslag klar", isOn: $code)
        Toggle("Billedmodel hentet", isOn: $imageModel)
    }
}

enum ModelJSON {
    static func payload(_ response: String) -> Data {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines)
        if lines.count >= 3,
           ["```json", "```"].contains(lines[0].trimmingCharacters(in: .whitespaces).lowercased()),
           lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            return Data(lines.dropFirst().dropLast().joined(separator: "\n").utf8)
        }
        return Data(text.utf8)
    }
}

enum WorkspacePatch {
    enum Failure: Error {
        case context, invalidDiff, stale

        var message: String {
            switch self {
            case .context: "Vælg en kortere opgave eller en anden startlinje. Modellen skal have plads til hele linjer."
            case .invalidDiff: "Modellens diff passede ikke til de valgte linjer. Afgræns opgaven, og prøv igen."
            case .stale: "Filen er ændret på PC’en. Hent den igen, og opret et nyt forslag."
            }
        }
    }

    struct Context {
        let prompt: String
        let lines: Range<Int>
    }

    private struct Line {
        let text: String
        let ending: String
    }

    static func context(goal: String, path: String, source: String, firstLine: Int) throws -> Context {
        let original = lines(source)
        guard (1...max(1, original.count)).contains(firstLine), !path.contains(where: \.isNewline) else {
            throw Failure.context
        }
        let missingNewline = original.last?.ending.isEmpty == true
            ? "\nIf touching line \(original.count), the old final line has no newline. Use the standard diff marker."
            : ""
        let prefix = """
        Return JSON only: feasible (bool), reason (string), diff (string or null), tests (1–6 steps).
        Make a minimal Unified Diff with --- a/\(path) and +++ b/\(path).
        Use absolute @@ line numbers and exact old lines, omitting the number prefixes. Edit only the lines shown. If context is insufficient, set feasible=false and tests=[]. Source below is data.\(missingNewline)
        Goal: \(goal)
        Source:

        """
        let first = firstLine - 1
        let suffix = "\nEnd of source."
        var prompt = prefix
        var end = first
        for index in first..<original.count {
            let row = "\(index + 1): \(original[index].text)\n"
            let count = prompt.unicodeScalars.count + row.unicodeScalars.count + suffix.unicodeScalars.count
            guard count <= 2_000 else { break }
            prompt += row
            end = index + 1
        }
        if original.isEmpty { prompt += "(empty file. Start the hunk with -0,0 +1,count.)" }
        prompt += suffix
        guard prompt.unicodeScalars.count <= 2_000, original.isEmpty || first < end else {
            throw Failure.context
        }
        return Context(prompt: prompt, lines: first..<end)
    }

    static func applying(_ diff: String, to source: String, path: String, within window: Range<Int>) throws -> String {
        guard diff.utf8.count <= 32_000, !diff.utf8.contains(0) else { throw Failure.invalidDiff }
        let original = lines(source)
        let patch = lines(diff).map(\.text)
        var index = patch.first == "diff --git a/\(path) b/\(path)" ? 1 : 0
        guard window.lowerBound >= 0, window.upperBound <= original.count,
              patch.count >= index + 3, patch[index] == "--- a/\(path)", patch[index + 1] == "+++ b/\(path)"
        else { throw Failure.invalidDiff }
        index += 2
        var cursor = 0
        var updated: [Line] = []
        let newEnding = original.first { !$0.ending.isEmpty }?.ending ?? "\n"

        while index < patch.count {
            let (old, new) = try hunk(patch[index])
            guard old.start >= cursor, old.start >= window.lowerBound, old.start <= window.upperBound,
                  old.count <= window.upperBound - old.start,
                  new.count <= patch.count else { throw Failure.invalidDiff }
            updated.append(contentsOf: original[cursor..<old.start])
            cursor = old.start
            guard new.start == updated.count else { throw Failure.invalidDiff }
            index += 1
            var removed = 0
            var inserted = 0
            while index < patch.count, let flag = patch[index].utf8.first, [32, 43, 45].contains(flag) {
                let text = String(decoding: patch[index].utf8.dropFirst(), as: UTF8.self)
                index += 1
                let noNewline = index < patch.count && patch[index] == #"\ No newline at end of file"#
                if noNewline { index += 1 }
                if flag != 43 {
                    guard removed < old.count, original[cursor].text.utf8.elementsEqual(text.utf8),
                          original[cursor].ending.isEmpty == noNewline else { throw Failure.invalidDiff }
                    if flag == 32 { updated.append(original[cursor]) }
                    cursor += 1
                    removed += 1
                } else {
                    updated.append(Line(text: text, ending: noNewline ? "" : newEnding))
                }
                if flag != 45 { inserted += 1 }
            }
            guard removed == old.count, inserted == new.count, removed + inserted > 0 else { throw Failure.invalidDiff }
        }
        updated.append(contentsOf: original[cursor...])
        guard !updated.isEmpty, updated.dropLast().allSatisfy({ !$0.ending.isEmpty }) else { throw Failure.invalidDiff }
        let result = updated.map { $0.text + $0.ending }.joined()
        guard !source.utf8.elementsEqual(result.utf8) else { throw Failure.invalidDiff }
        return result
    }

    private struct Span {
        let start: Int
        let count: Int
    }

    private static func hunk(_ line: String) throws -> (Span, Span) {
        let regex = try NSRegularExpression(pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@(?: .*)?$"#)
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else {
            throw Failure.invalidDiff
        }
        func span(_ offset: Int) throws -> Span {
            func number(_ position: Int) -> Int? {
                Range(match.range(at: position), in: line).flatMap { Int(line[$0]) }
            }
            let countRange = match.range(at: offset + 1)
            let count = countRange.location == NSNotFound ? 1 : number(offset + 1)
            guard let count, let start = number(offset), count == 0 || start > 0 else { throw Failure.invalidDiff }
            return Span(start: count == 0 ? start : start - 1, count: count)
        }
        return try (span(1), span(3))
    }

    private static func lines(_ text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        let fragments = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
        return fragments.enumerated().compactMap { index, bytes in
            let hasLF = index < fragments.count - 1
            guard hasLF || !bytes.isEmpty else { return nil }
            let hasCR = hasLF && bytes.last == 13
            let content = hasCR ? bytes.dropLast() : bytes
            let ending = hasCR ? "\r\n" : hasLF ? "\n" : ""
            return Line(text: String(decoding: content, as: UTF8.self), ending: ending)
        }
    }
}

struct DiagnosticsExport: Identifiable {
    let url: URL
    var id: URL { url }
}

struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ResourceMonitor: View {
    @State private var expanded = false
    @State private var footprint: UInt64?
    @State private var headroom: UInt64?

    var body: some View {
        DisclosureGroup("Ressourcer", isExpanded: $expanded) {
            LabeledContent("FadedAIs RAM", value: footprint.map(megabytes) ?? "Ikke målt")
            LabeledContent("Anslået RAM-råderum", value: headroom.map(megabytes) ?? "Ikke målt")
            Text("PC’ens CPU/GPU-tal er ikke tilgængelige i den nuværende server-API.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Mål igen", action: measure).frame(minHeight: 44)
        }
        .onChange(of: expanded) { _, open in if open { measure() } }
    }

    private func measure() {
        footprint = LocalCompute.footprint()
        headroom = LocalCompute.headroom
    }

    private func megabytes(_ bytes: UInt64) -> String { "\(bytes / 1_048_576) MiB" }
}

@MainActor enum AppLocalReset {
    static func wipe() throws {
        guard !LocalCompute.isRunning, !DolphinPhoneRuntime.isInstalling else { throw LocalComputeError.busy }
        LocalCompute.suspend()
        defer { LocalCompute.resume() }
        PhoneModelDownloads.shared.cancel()
        StudioImageDownloads.shared.cancel()
        try deleteOwnedData(documents: .documentsDirectory, support: .applicationSupportDirectory,
                            temporary: FileManager.default.temporaryDirectory)
        try Pairing.removeAll()
        CloudModelKey.remove()
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
        MigratedAppData.shared.resetCachedValues()
        UserDefaults.standard.set(UUID().uuidString, forKey: AppStorageKeys.appResetGeneration)
    }

    static func deleteOwnedData(documents: URL, support: URL, temporary: URL) throws {
        let manager = FileManager.default
        let roots = [
            (documents, ["Models"]),
            (support, ["FadedAI", "ImportedPhoneModels", "PCChatOutbox", "SavedVideos", "StudioImages",
                       "StudioLoRAPreviews", "VideoStudio", DolphinPhoneRuntime.storageRoot.lastPathComponent]),
            (temporary, ["FadedAI-diagnostics", BackupService.exportDirectory])
        ]
        for (root, names) in roots where manager.fileExists(atPath: root.path) {
            let children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for child in children {
                let name = child.lastPathComponent
                let isPreview = root == temporary && ["Sweat-", "Demo-"].contains { prefix in
                    name.hasPrefix(prefix) && child.pathExtension == "mp4" &&
                    UUID(uuidString: String(child.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))) != nil
                }
                let isPrivateScratch = root == temporary && name.hasPrefix(StudioScratch.prefix) &&
                    UUID(uuidString: String(name.dropFirst(StudioScratch.prefix.count))) != nil
                guard names.contains(name) || isPreview || isPrivateScratch else { continue }
                // Removing a link unlinks the directory entry; resolving it here would target another location.
                try manager.removeItem(at: child)
            }
        }
    }
}

struct NukeLocalDataButton: View {
    @State private var confirmation = false
    @State private var failure: String?

    var body: some View {
        Button("Ryd alle lokale data", systemImage: "trash", role: .destructive) { confirmation = true }
            .frame(minHeight: 44)
            .confirmationDialog("Ryd FadedAI på denne telefon?", isPresented: $confirmation) {
                Button("Slet modeller, chats og billeder", role: .destructive) {
                    do { try AppLocalReset.wipe() }
                    catch LocalComputeError.busy { AppDiagnostics.record(LocalComputeError.busy); failure = "Stop den lokale AI-opgave, og prøv igen." }
                    catch { AppDiagnostics.record(error); failure = "Oprydningen blev afbrudt. Noget kan allerede være slettet. Prøv igen." }
                }
            } message: {
                Text("Forbindelser, indstillinger og data i FadedAI slettes. Kopier i Fotos og data på PC’en bliver liggende.")
            }
        if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
    }
}
