// Bot computers: tasks, files and the paired desktop. The phone keeps a copy so a result can be opened again after the app closes.

import Foundation

enum BotComputerTaskStatus: String, Codable, Equatable, Sendable {
    case waiting, running, done, failed, cancelled

    var title: String {
        switch self {
        case .waiting: "Venter"
        case .running: "Arbejder"
        case .done: "Færdig"
        case .failed: "Mislykkedes"
        case .cancelled: "Annulleret"
        }
    }
}

enum BotComputerLink: String, Codable, Equatable, Sendable {
    case online, pcOffline, dockerOffline, moduleMissing

    var title: String {
        switch self {
        case .online: "Forbundet"
        case .pcOffline: "PC’en er offline"
        case .dockerOffline: "Docker er offline"
        case .moduleMissing: "PC’en har ikke computer-modulet endnu"
        }
    }

    var detail: String {
        switch self {
        case .online: "Skrivebordet bruger den parrede forbindelse."
        case .pcOffline: "Opgaven bliver på telefonen, indtil PC’en svarer igen. Et nyt tryk starter den ikke to gange."
        case .dockerOffline: "PC’en svarer, men Docker er offline. Opgaven venter, indtil computeren er startet."
        case .moduleMissing: "Parringen virker, men computer-modulet er ikke lagt på PC’en endnu."
        }
    }
}

enum BotComputerFailure: Error, Equatable {
    case isolated
    case rejected(String)
    case pcOffline
    case dockerOffline
    case moduleMissing
}

struct BotComputerTask: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var botID: String
    var botName: String
    var idempotencyKey: String
    var retryKey: String?
    var instruction: String
    var inputPath: String?
    var status: BotComputerTaskStatus
    var resultText: String?
    var resultPath: String?
    var error: String?
    var attempt: Int
    var created: TimeInterval
    var updated: TimeInterval

    enum CodingKeys: String, CodingKey {
        case id
        case botID = "bot_id"
        case botName = "bot_name"
        case idempotencyKey = "idempotency_key"
        case retryKey = "retry_key"
        case instruction
        case inputPath = "input_path"
        case status
        case resultText = "result_text"
        case resultPath = "result_path"
        case error, attempt, created, updated
    }
}

struct BotComputerFile: Codable, Equatable, Identifiable, Sendable {
    var ownerID: String
    var ownerName: String
    var path: String
    var text: String
    var sharedWith: [String]
    var id: String { ownerID + "/" + path }

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case ownerName = "owner_name"
        case path, text
        case sharedWith = "shared_with"
    }
}

struct BotComputerSubmission: Equatable, Sendable {
    var link: BotComputerLink
    var task: BotComputerTask
}

@MainActor protocol BotComputerTransport {
    func health() async throws -> BotComputerLink
    func submit(_ task: BotComputerTask) async throws -> BotComputerSubmission
    func cancel(botID: String, id: String) async throws -> BotComputerTask
    func retry(botID: String, id: String, retryKey: String) async throws -> BotComputerSubmission
    func tasks(botID: String) async throws -> [BotComputerTask]
    func read(botID: String, ownerID: String, path: String) async throws -> BotComputerFile
    func share(ownerID: String, path: String, with botID: String, approved: Bool) async throws -> BotComputerFile
    func startDesktop(botID: String, name: String) async throws -> BotComputerLink
    func frame(botID: String, name: String) async throws -> Data
    func click(botID: String, name: String, x: Double, y: Double, approved: Bool) async throws
}

struct BotComputerOffice: Equatable {
    var tasks: [BotComputerTask] = []
    var files: [BotComputerFile] = []
    var deliveredKeys: Set<String> = []
    var pendingCancelIDs: Set<String> = []
    var link: BotComputerLink = .pcOffline

    static func validToken(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return (8...80).contains(value.count) && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func validPath(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...80).contains(value.count), !value.contains(".."), value != ".", value != ".." else { return false }
        guard let first = value.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func task(id: String) -> BotComputerTask? { tasks.first { $0.id == id } }
    func task(key: String) -> BotComputerTask? { tasks.first { $0.idempotencyKey == key } }

    mutating func submit(botID: String, name: String, instruction: String, key: String,
                         inputPath: String?, now: TimeInterval) throws -> BotComputerTask {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validToken(botID), Self.validToken(key), (1...40).contains(name.count),
              (1...1000).contains(instruction.count) else {
            throw BotComputerFailure.rejected("Angiv en kort opgave.")
        }
        if let inputPath, !Self.validPath(inputPath) {
            throw BotComputerFailure.rejected("Filnavnet er ikke gyldigt.")
        }
        if let existing = task(key: key) { return existing }
        let task = BotComputerTask(id: UUID().uuidString.lowercased(), botID: botID, botName: name,
                                   idempotencyKey: key, retryKey: nil, instruction: instruction,
                                   inputPath: inputPath, status: .waiting, resultText: nil, resultPath: nil,
                                   error: nil, attempt: 1, created: now, updated: now)
        tasks.append(task)
        return task
    }

    mutating func cancel(id: String, now: TimeInterval) throws -> BotComputerTask {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw BotComputerFailure.rejected("Opgaven findes ikke.")
        }
        switch tasks[index].status {
        case .cancelled:
            return tasks[index]
        case .waiting, .running:
            tasks[index].status = .cancelled
            tasks[index].updated = now
            return tasks[index]
        case .done, .failed:
            throw BotComputerFailure.rejected("Opgaven kan ikke annulleres.")
        }
    }

    mutating func retry(id: String, retryKey: String, now: TimeInterval) throws -> BotComputerTask {
        guard Self.validToken(retryKey), let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw BotComputerFailure.rejected("Opgaven findes ikke.")
        }
        if tasks[index].retryKey == retryKey { return tasks[index] }
        if tasks[index].status == .waiting || tasks[index].status == .running { return tasks[index] }
        guard tasks[index].status == .failed else {
            throw BotComputerFailure.rejected("Kun en mislykket opgave kan prøves igen.")
        }
        tasks[index].status = .waiting
        tasks[index].attempt += 1
        tasks[index].retryKey = retryKey
        tasks[index].error = nil
        tasks[index].resultText = nil
        tasks[index].resultPath = nil
        tasks[index].updated = now
        return tasks[index]
    }

    mutating func adopt(_ task: BotComputerTask) {
        if let index = tasks.firstIndex(where: { $0.idempotencyKey == task.idempotencyKey || $0.id == task.id }),
           tasks[index].status == .cancelled, task.status != .cancelled {
            return
        }
        if task.status == .done, let path = task.resultPath, let text = task.resultText {
            try? writeFile(ownerID: task.botID, ownerName: task.botName, path: path, text: text)
        }
        if let index = tasks.firstIndex(where: { $0.idempotencyKey == task.idempotencyKey || $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
    }

    mutating func merge(_ incoming: [BotComputerTask]) {
        for task in incoming { adopt(task) }
    }

    mutating func writeFile(ownerID: String, ownerName: String, path: String, text: String) throws {
        guard Self.validToken(ownerID), Self.validPath(path), text.count <= 100_000,
              (1...40).contains(ownerName.count) else {
            throw BotComputerFailure.rejected("Filen kan ikke gemmes.")
        }
        if let index = files.firstIndex(where: { $0.ownerID == ownerID && $0.path == path }) {
            files[index].text = text
            files[index].ownerName = ownerName
        } else {
            files.append(BotComputerFile(ownerID: ownerID, ownerName: ownerName, path: path, text: text, sharedWith: []))
        }
    }

    func open(readerID: String, ownerID: String, path: String) throws -> BotComputerFile {
        guard let file = files.first(where: { $0.ownerID == ownerID && $0.path == path }) else {
            throw BotComputerFailure.rejected("Filen findes ikke.")
        }
        if readerID == ownerID || file.sharedWith.contains(readerID) { return file }
        throw BotComputerFailure.isolated
    }

    mutating func share(ownerID: String, path: String, with readerID: String, approved: Bool) throws -> BotComputerFile {
        guard approved else { throw BotComputerFailure.rejected("Deling kræver en eksplicit godkendelse.") }
        guard readerID != ownerID, Self.validToken(readerID) else {
            throw BotComputerFailure.rejected("Vælg en anden bot.")
        }
        guard let index = files.firstIndex(where: { $0.ownerID == ownerID && $0.path == path }) else {
            throw BotComputerFailure.rejected("Filen findes ikke.")
        }
        if !files[index].sharedWith.contains(readerID) { files[index].sharedWith.append(readerID) }
        return files[index]
    }

    func visibleFiles(readerID: String) -> [BotComputerFile] {
        files.filter { $0.ownerID == readerID || $0.sharedWith.contains(readerID) }
    }
}

struct BotComputerRecord: Codable, Equatable {
    var tasks: [BotComputerTask]
    var files: [BotComputerFile]
    var deliveredKeys: [String]
    var link: BotComputerLink
    var pendingCancelIDs: [String]

    init(tasks: [BotComputerTask], files: [BotComputerFile], deliveredKeys: [String], link: BotComputerLink, pendingCancelIDs: [String]) {
        self.tasks = tasks
        self.files = files
        self.deliveredKeys = deliveredKeys
        self.link = link
        self.pendingCancelIDs = pendingCancelIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode([BotComputerTask].self, forKey: .tasks)
        files = try container.decode([BotComputerFile].self, forKey: .files)
        deliveredKeys = try container.decode([String].self, forKey: .deliveredKeys)
        link = try container.decode(BotComputerLink.self, forKey: .link)
        pendingCancelIDs = try container.decodeIfPresent([String].self, forKey: .pendingCancelIDs) ?? []
    }
}

enum BotComputerPointer {
    /// Maps a tap onto the visible picture. Letterbox bars and the padding around a fitted image return nil.
    static func normalized(tapX: Double, tapY: Double, viewWidth: Double, viewHeight: Double,
                           imageWidth: Double, imageHeight: Double, padding: Double = 8) -> (x: Double, y: Double)? {
        guard viewWidth > padding * 2, viewHeight > padding * 2, imageWidth > 0, imageHeight > 0 else { return nil }
        let minX = padding
        let minY = padding
        let width = viewWidth - padding * 2
        let height = viewHeight - padding * 2
        let aspect = imageWidth / imageHeight
        let fittedX: Double
        let fittedY: Double
        let fittedWidth: Double
        let fittedHeight: Double
        if width / height > aspect {
            fittedHeight = height
            fittedWidth = height * aspect
            fittedX = minX + (width - fittedWidth) / 2
            fittedY = minY
        } else {
            fittedWidth = width
            fittedHeight = width / aspect
            fittedX = minX
            fittedY = minY + (height - fittedHeight) / 2
        }
        guard tapX >= fittedX, tapY >= fittedY, tapX <= fittedX + fittedWidth, tapY <= fittedY + fittedHeight,
              fittedWidth > 0, fittedHeight > 0 else { return nil }
        return ((tapX - fittedX) / fittedWidth, (tapY - fittedY) / fittedHeight)
    }
}

enum BotComputerDisk {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FadedAI/BotComputers", directoryHint: .isDirectory)
    }

    static func load(from directory: URL) -> BotComputerOffice {
        let url = directory.appending(path: "computer.json")
        guard let data = try? Data(contentsOf: url), data.count <= 2_000_000,
              let record = try? JSONDecoder().decode(BotComputerRecord.self, from: data) else {
            return BotComputerOffice()
        }
        return BotComputerOffice(tasks: record.tasks, files: record.files,
                                 deliveredKeys: Set(record.deliveredKeys),
                                 pendingCancelIDs: Set(record.pendingCancelIDs), link: record.link)
    }

    static func save(_ office: BotComputerOffice, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = BotComputerRecord(tasks: office.tasks, files: office.files,
                                       deliveredKeys: Array(office.deliveredKeys).sorted(), link: office.link,
                                       pendingCancelIDs: Array(office.pendingCancelIDs).sorted())
        let data = try JSONEncoder().encode(record)
        guard data.count <= 2_000_000 else { throw BotComputerFailure.rejected("Computerens arkiv er for stort.") }
        let url = directory.appending(path: "computer.json")
        try data.write(to: url, options: .atomic)
    }
}

@MainActor final class BotComputerSession {
    private(set) var office: BotComputerOffice
    private let directory: URL
    private let transport: any BotComputerTransport
    private let now: () -> TimeInterval
    private var inFlight: Set<String> = []

    init(directory: URL, transport: any BotComputerTransport, now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.directory = directory
        self.transport = transport
        self.now = now
        office = BotComputerDisk.load(from: directory)
    }

    func give(botID: String, name: String, instruction: String, key: String, inputPath: String?) async -> Result<BotComputerTask, BotComputerFailure> {
        if let existing = office.task(key: key), office.deliveredKeys.contains(key) || inFlight.contains(key) {
            return .success(existing)
        }
        let created: BotComputerTask
        do { created = try office.submit(botID: botID, name: name, instruction: instruction, key: key, inputPath: inputPath, now: now()) }
        catch let error as BotComputerFailure { return .failure(error) }
        catch { return .failure(.rejected("Opgaven kunne ikke gemmes.")) }
        if inFlight.contains(key) { return .success(office.task(key: key) ?? created) }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        persist()
        if office.link != .online {
            await refreshLink()
        }
        guard office.link == .online || office.link == .dockerOffline else {
            persist()
            return .success(office.task(key: key) ?? created)
        }
        do {
            let submission = try await transport.submit(office.task(key: key) ?? created)
            office.link = submission.link
            office.adopt(submission.task)
            office.deliveredKeys.insert(key)
            persist()
            return .success(office.task(key: key) ?? submission.task)
        } catch {
            office.link = Self.link(for: error)
            persist()
            return .success(office.task(key: key) ?? created)
        }
    }

    func refresh(botID: String) async {
        await refreshLink()
        guard office.link == .online || office.link == .dockerOffline else { persist(); return }
        let pending = office.tasks.filter {
            $0.botID == botID && $0.status == .waiting && !office.deliveredKeys.contains($0.idempotencyKey)
        }
        for task in pending {
            if inFlight.contains(task.idempotencyKey) { continue }
            if let retryKey = task.retryKey, inFlight.contains(retryKey) { continue }
            inFlight.insert(task.idempotencyKey)
            do {
                let submission: BotComputerSubmission
                if let retryKey = task.retryKey {
                    submission = try await transport.retry(botID: task.botID, id: task.id, retryKey: retryKey)
                } else {
                    submission = try await transport.submit(task)
                }
                office.link = submission.link
                office.adopt(submission.task)
                office.deliveredKeys.insert(task.idempotencyKey)
            } catch {
                office.link = Self.link(for: error)
                inFlight.remove(task.idempotencyKey)
                persist()
                return
            }
            inFlight.remove(task.idempotencyKey)
        }
        await deliverCancels()
        if let remote = try? await transport.tasks(botID: botID) {
            office.merge(remote.filter { $0.botID == botID })
        }
        persist()
    }

    func cancel(id: String) async -> Result<BotComputerTask, BotComputerFailure> {
        let before = office.task(id: id)?.status
        let updated: BotComputerTask
        do { updated = try office.cancel(id: id, now: now()) }
        catch let error as BotComputerFailure { return .failure(error) }
        catch { return .failure(.rejected("Opgaven kunne ikke annulleres.")) }
        persist()
        if before == .cancelled { return .success(updated) }
        guard let current = office.task(id: id), office.deliveredKeys.contains(current.idempotencyKey) else {
            return .success(office.task(id: id) ?? updated)
        }
        let reachable = office.link == .online || office.link == .dockerOffline
        guard reachable else {
            office.pendingCancelIDs.insert(id)
            persist()
            return .success(office.task(id: id) ?? updated)
        }
        do {
            let remote = try await transport.cancel(botID: current.botID, id: current.id)
            office.pendingCancelIDs.remove(id)
            office.adopt(remote)
            persist()
            return .success(office.task(id: id) ?? remote)
        } catch {
            office.pendingCancelIDs.insert(id)
            office.link = Self.link(for: error)
            persist()
            return .success(office.task(id: id) ?? updated)
        }
    }

    func retry(id: String, retryKey: String) async -> Result<BotComputerTask, BotComputerFailure> {
        if inFlight.contains(retryKey) { return office.task(id: id).map(Result.success) ?? .failure(.rejected("Opgaven findes ikke.")) }
        if office.task(id: id)?.retryKey == retryKey { return .success(office.task(id: id)!) }
        let updated: BotComputerTask
        do { updated = try office.retry(id: id, retryKey: retryKey, now: now()) }
        catch let error as BotComputerFailure { return .failure(error) }
        catch { return .failure(.rejected("Opgaven kunne ikke prøves igen.")) }
        if updated.retryKey != retryKey || updated.status != .waiting {
            return .success(updated)
        }
        inFlight.insert(retryKey)
        defer { inFlight.remove(retryKey) }
        office.deliveredKeys.remove(updated.idempotencyKey)
        persist()
        guard office.link == .online || office.link == .dockerOffline else { return .success(office.task(id: id) ?? updated) }
        do {
            let submission = try await transport.retry(botID: updated.botID, id: updated.id, retryKey: retryKey)
            office.link = submission.link
            office.adopt(submission.task)
            office.deliveredKeys.insert(updated.idempotencyKey)
            persist()
            return .success(office.task(id: id) ?? submission.task)
        } catch {
            office.link = Self.link(for: error)
            persist()
            return .success(office.task(id: id) ?? updated)
        }
    }

    func openFile(readerID: String, ownerID: String, path: String) async throws -> BotComputerFile {
        if office.link == .online {
            do {
                let file = try await transport.read(botID: readerID, ownerID: ownerID, path: path)
                office.remember(file)
                persist()
                return file
            } catch let error as BotComputerFailure where error == .isolated {
                throw BotComputerFailure.isolated
            } catch {
                office.link = Self.link(for: error)
                persist()
            }
        }
        return try office.open(readerID: readerID, ownerID: ownerID, path: path)
    }

    func share(ownerID: String, path: String, with readerID: String, approved: Bool) async throws -> BotComputerFile {
        let file = try office.share(ownerID: ownerID, path: path, with: readerID, approved: approved)
        persist()
        if office.link == .online {
            if let remote = try? await transport.share(ownerID: ownerID, path: path, with: readerID, approved: true) {
                office.remember(remote)
                persist()
                return remote
            }
        }
        return file
    }

    func writeFile(ownerID: String, ownerName: String, path: String, text: String) throws {
        try office.writeFile(ownerID: ownerID, ownerName: ownerName, path: path, text: text)
        persist()
    }

    func note(_ link: BotComputerLink) {
        office.link = link
        persist()
    }

    private func deliverCancels() async {
        for id in office.pendingCancelIDs {
            guard let task = office.task(id: id) else {
                office.pendingCancelIDs.remove(id)
                continue
            }
            do {
                let remote = try await transport.cancel(botID: task.botID, id: task.id)
                office.pendingCancelIDs.remove(id)
                office.adopt(remote)
            } catch {
                office.link = Self.link(for: error)
                return
            }
        }
    }

    private func refreshLink() async {
        do { office.link = try await transport.health() }
        catch { office.link = Self.link(for: error) }
    }

    private func persist() {
        try? BotComputerDisk.save(office, to: directory)
    }

    static func link(for error: Error) -> BotComputerLink {
        switch error as? BotComputerFailure {
        case .dockerOffline: .dockerOffline
        case .moduleMissing: .moduleMissing
        case .pcOffline: .pcOffline
        default: .pcOffline
        }
    }

    static func failure(forHTTPStatus status: Int) -> BotComputerFailure? {
        switch status {
        case 403: .isolated
        case 404: .moduleMissing
        case 503: .dockerOffline
        default: nil
        }
    }

    static func link(forHTTPStatus status: Int) -> BotComputerLink? {
        switch failure(forHTTPStatus: status) {
        case .dockerOffline: .dockerOffline
        case .moduleMissing: .moduleMissing
        case .pcOffline: .pcOffline
        default: nil
        }
    }
}

private extension BotComputerOffice {
    mutating func remember(_ file: BotComputerFile) {
        if let index = files.firstIndex(where: { $0.ownerID == file.ownerID && $0.path == file.path }) {
            files[index] = file
        } else {
            files.append(file)
        }
    }
}

struct OfflineBotComputerTransport: BotComputerTransport {
    func health() async throws -> BotComputerLink { .pcOffline }
    func submit(_ task: BotComputerTask) async throws -> BotComputerSubmission { throw BotComputerFailure.pcOffline }
    func cancel(botID: String, id: String) async throws -> BotComputerTask { throw BotComputerFailure.pcOffline }
    func retry(botID: String, id: String, retryKey: String) async throws -> BotComputerSubmission { throw BotComputerFailure.pcOffline }
    func tasks(botID: String) async throws -> [BotComputerTask] { throw BotComputerFailure.pcOffline }
    func read(botID: String, ownerID: String, path: String) async throws -> BotComputerFile { throw BotComputerFailure.pcOffline }
    func share(ownerID: String, path: String, with botID: String, approved: Bool) async throws -> BotComputerFile { throw BotComputerFailure.pcOffline }
    func startDesktop(botID: String, name: String) async throws -> BotComputerLink { throw BotComputerFailure.pcOffline }
    func frame(botID: String, name: String) async throws -> Data { throw BotComputerFailure.pcOffline }
    func click(botID: String, name: String, x: Double, y: Double, approved: Bool) async throws { throw BotComputerFailure.pcOffline }
}

struct LiveBotComputerTransport: BotComputerTransport {
    let api: LiveAPI

    func health() async throws -> BotComputerLink { try await api.botComputerHealth() }
    func submit(_ task: BotComputerTask) async throws -> BotComputerSubmission { try await api.submitBotComputerTask(task) }
    func cancel(botID: String, id: String) async throws -> BotComputerTask { try await api.cancelBotComputerTask(botID: botID, id: id) }
    func retry(botID: String, id: String, retryKey: String) async throws -> BotComputerSubmission {
        try await api.retryBotComputerTask(botID: botID, id: id, retryKey: retryKey)
    }
    func tasks(botID: String) async throws -> [BotComputerTask] { try await api.botComputerTasks(botID) }
    func read(botID: String, ownerID: String, path: String) async throws -> BotComputerFile {
        try await api.readBotComputerFile(botID: botID, ownerID: ownerID, path: path)
    }
    func share(ownerID: String, path: String, with botID: String, approved: Bool) async throws -> BotComputerFile {
        try await api.shareBotComputerFile(ownerID: ownerID, path: path, with: botID, approved: approved)
    }
    func startDesktop(botID: String, name: String) async throws -> BotComputerLink {
        try await api.startBotComputer(botID: botID, name: name)
    }
    func frame(botID: String, name: String) async throws -> Data { try await api.botComputerFrame(botID, name: name) }
    func click(botID: String, name: String, x: Double, y: Double, approved: Bool) async throws {
        try await api.clickBotComputer(botID: botID, name: name, x: x, y: y, approved: approved)
    }
}
