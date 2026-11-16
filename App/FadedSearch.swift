// Filnavn: App/FadedSearch.swift
import SwiftUI

enum FadedSearchCategory: String, Hashable, Sendable {
    case chat = "Chat"
    case bot = "Bot"
    case video = "Video"
    case file = "Fil"
    case connection = "Forbindelse"
    case note = "Note"
    case settings = "Indstillinger"

    var icon: String {
        switch self {
        case .chat: "bubble.left"
        case .bot: "face.smiling"
        case .video: "play.rectangle"
        case .file: "doc"
        case .connection: "network"
        case .note: "note.text"
        case .settings: "gearshape"
        }
    }

    func accent(in palette: FadedPalette) -> Color {
        switch self {
        case .chat, .connection: palette.cyan
        case .bot, .file: palette.purple
        case .video: palette.lime
        case .note: palette.green
        case .settings: palette.secondary
        }
    }
}

enum FadedSearchSource: String, Hashable, Sendable {
    case phone = "Telefon"
    case pc = "PC"
    case cloud = "Sky"

    func accent(in palette: FadedPalette) -> Color {
        switch self {
        case .phone: palette.green
        case .pc: palette.cyan
        case .cloud: palette.purple
        }
    }
}

enum FadedSearchDestination: Hashable, Sendable {
    case chat(query: String)
    case bot(id: UUID)
    case video(jobID: String?)
    case savedVideo(URL)
    case file(path: String?)
    case connection
    case connections
    case note
    case settings
    case settingsCategory(Home.SettingsCategory)
    case privateStudio
}

struct FadedSearchRecord: Identifiable, Hashable, Sendable {
    let id: String
    let category: FadedSearchCategory
    let title: String
    let detail: String
    let keywords: String
    let source: FadedSearchSource?
    let destination: FadedSearchDestination

    // The caller supplies public-to-the-app records only. The index never loads chats, files, or credentials.
    init(id: String, category: FadedSearchCategory, title: String, detail: String = "", keywords: String = "",
         source: FadedSearchSource? = nil, destination: FadedSearchDestination) {
        self.id = id
        self.category = category
        self.title = String(title.prefix(180))
        self.detail = String(detail.prefix(320))
        self.keywords = String(keywords.prefix(320))
        self.source = source
        self.destination = destination
    }
}

struct FadedSearchIndex: Equatable, Sendable {
    static let limit = 80
    static let queryLimit = 120
    private static let maximumRecords = 2_000
    private let records: [FadedSearchRecord]

    init(records: [FadedSearchRecord]) {
        var seen = Set<String>()
        var unique: [FadedSearchRecord] = []
        unique.reserveCapacity(min(records.count, Self.maximumRecords))
        for record in records where seen.insert(record.id).inserted {
            unique.append(record)
            if unique.count == Self.maximumRecords { break }
        }
        self.records = unique
    }

    func matches(_ input: String) -> [FadedSearchRecord] {
        (try? cancellableMatches(input)) ?? []
    }

    /// Rank only the entries the caller supplied. Private documents and scenes never enter this index.
    func relatedMatches(_ input: String, existing: Set<String>) throws -> [FadedSearchRecord] {
        let query = Self.boundedQuery(input).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = records.filter { !existing.contains($0.id) }
        let texts = candidates.map { [$0.title, $0.detail, $0.keywords].joined(separator: " ") }
        let lexical = try LocalTextRanking.lexicalOrder(query: query, texts: texts)
        let shortlist = LocalTextRanking.fusedOrder(
            [Array(lexical.prefix(28)), Array(candidates.indices.prefix(64))], limit: 64
        )
        var semantic: [(index: Int, score: Float)] = []
        if let model = LocalTextRanking.installedEmbedding() {
            defer { model.unload() }
            if let queryVector = LocalTextRanking.vector(for: query, using: model) {
                for index in shortlist {
                    try Task.checkCancellation()
                    guard let candidate = LocalTextRanking.vector(for: texts[index], using: model),
                          let score = LocalTextRanking.similarity(queryVector, candidate), score >= 0.76 else { continue }
                    semantic.append((index, score))
                }
            }
        }
        let byMeaning = semantic.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map(\.index)
        return LocalTextRanking.fusedOrder([Array(lexical.prefix(16)), Array(byMeaning.prefix(16))], limit: 12)
            .map { candidates[$0] }
    }

    func cancellableMatches(_ input: String) throws -> [FadedSearchRecord] {
        try Task.checkCancellation()
        let query = Self.fold(Self.boundedQuery(input).trimmingCharacters(in: .whitespacesAndNewlines))
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }

        var matches: [(order: Int, score: Int, record: FadedSearchRecord)] = []
        for (order, record) in records.enumerated() {
            try Task.checkCancellation()
            let title = Self.fold(record.title)
            let fullText = Self.fold([record.title, record.detail, record.keywords,
                                      record.category.rawValue, record.source?.rawValue ?? ""].joined(separator: " "))
            guard words.allSatisfy({ fullText.contains($0) }) else { continue }
            let score = title == query ? 0 : title.hasPrefix(query) ? 1 : title.contains(query) ? 2 : 3
            matches.append((order, score, record))
        }
        if matches.isEmpty { return try fuzzyMatches(words) }
        return matches.sorted { left, right in
            left.score == right.score ? left.order < right.order : left.score < right.score
        }.prefix(Self.limit).map { $0.record }
    }

    private func fuzzyMatches(_ words: [Substring]) throws -> [FadedSearchRecord] {
        guard words.count <= 8 else { return [] }
        let terms = words.map(FuzzyWord.init)
        guard terms.contains(where: { !$0.alphabet.isEmpty }) else { return [] }
        var results: [(score: Int, order: Int, record: FadedSearchRecord)] = []
        for (order, record) in records.enumerated() {
            try Task.checkCancellation()
            let title = Self.fold(record.title)
            let fullText = Self.fold([record.title, record.detail, record.keywords,
                                     record.category.rawValue, record.source?.rawValue ?? ""].joined(separator: " "))
            guard let score = Self.fuzzyScore(terms, in: fullText) else { continue }
            let titleScore = Self.fuzzyScore(terms, in: title)
            results.append((score * 2 + (titleScore == score ? 0 : 1), order, record))
        }
        return results.sorted { left, right in
            left.score == right.score ? left.order < right.order : left.score < right.score
        }.prefix(Self.limit).map { $0.record }
    }

    private static func fuzzyScore(_ terms: [FuzzyWord], in text: String) -> Int? {
        var score = 0
        for term in terms where !text.contains(term.text) {
            guard let differences = term.differences(in: text) else { return nil }
            score += differences
        }
        return score
    }

    static func boundedQuery(_ input: String) -> String {
        String(input.prefix(queryLimit))
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "da_DK"))
    }
}

// fuse-swift bruger Bitap. Her søger vi forlæns og begrænser antal tastefejl.
private struct FuzzyWord {
    let text: String
    let alphabet: [UInt16: UInt32]
    private let lastBit: UInt32
    private let tolerance: Int

    init(_ word: Substring) {
        text = String(word)
        let units = Array(word.utf16)
        let allowed = (4...24).contains(units.count) ? (units.count >= 8 ? 2 : 1) : 0
        tolerance = allowed
        lastBit = allowed > 0 ? UInt32(1) << (units.count - 1) : 0
        var letters: [UInt16: UInt32] = [:]
        if allowed > 0 {
            for (position, unit) in units.enumerated() {
                letters[unit, default: 0] |= UInt32(1) << position
            }
        }
        alphabet = letters
    }

    func differences(in candidate: String) -> Int? {
        guard tolerance > 0 else { return nil }
        var previous = (0...tolerance).map { (UInt32(1) << $0) - 1 }
        var current = previous
        var best: Int?
        for character in candidate.utf16 {
            let matching = alphabet[character] ?? 0
            current[0] = matching & ((previous[0] << 1) | 1)
            if current[0] & lastBit != 0 { return 0 }
            for edits in 1...tolerance {
                let fewer = edits - 1
                let same = matching & ((previous[edits] << 1) | 1)
                let substitutionOrDeletion = ((previous[fewer] | current[fewer]) << 1) | 1
                current[edits] = same | substitutionOrDeletion | previous[fewer]
                if current[edits] & lastBit != 0 { best = min(best ?? edits, edits) }
            }
            swap(&previous, &current)
        }
        return best
    }
}

struct FadedSearchSheet: View {
    let index: FadedSearchIndex
    let onSelect: (FadedSearchDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @FocusState private var focused: Bool
    @State private var query: String
    @State private var results: [FadedSearchRecord] = []
    @State private var completedRequest: Request?
    @State private var broadenedRequest: Request?
    @State private var related: [FadedSearchRecord] = []
    @State private var relatedTask: Task<Void, Never>?

    private struct Request: Equatable, Sendable {
        let query: String
        let index: FadedSearchIndex
    }

    private var request: Request {
        Request(query: FadedSearchIndex.boundedQuery(query).trimmingCharacters(in: .whitespacesAndNewlines), index: index)
    }

    init(index: FadedSearchIndex, initialQuery: String = "", onSelect: @escaping (FadedSearchDestination) -> Void) {
        self.index = index
        self.onSelect = onSelect
        _query = State(initialValue: FadedSearchIndex.boundedQuery(initialQuery))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: FadedSpacing.section) {
                searchField.padding(.horizontal, FadedSpacing.edge)
                resultList
            }
            .padding(.top, FadedSpacing.section)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Søg i FadedAI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() } }
            .task(id: request) {
                relatedTask?.cancel()
                related = []
                broadenedRequest = nil
                await search(request)
            }
            .onDisappear { relatedTask?.cancel() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary).accessibilityHidden(true)
            TextField("Søg efter navn eller emne", text: $query)
                .focused($focused).submitLabel(.search).textFieldStyle(.plain)
                .accessibilityLabel("Søgefelt")
                .onSubmit { focused = false }
                .onChange(of: query) { _, value in
                    if value.count > FadedSearchIndex.queryLimit { query = FadedSearchIndex.boundedQuery(value) }
                }
            if !query.isEmpty {
                Button(action: clearQuery) {
                    Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                }.buttonStyle(.plain).foregroundStyle(palette.secondary).accessibilityLabel("Ryd søgning")
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(minHeight: 52)
        .background(palette.raised, in: .rect(cornerRadius: FadedRadius.small))
        .overlay { RoundedRectangle(cornerRadius: FadedRadius.small).strokeBorder(palette.border).allowsHitTesting(false) }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if request.query.isEmpty {
                    FadedEmptyState(icon: "magnifyingglass", title: "Søg på telefonen",
                                    detail: "Find chats, bots, videoer, filer, noter og indstillinger.",
                                    actionTitle: "Søg") { focused = true }
                } else if completedRequest != request {
                    LoadingSkeleton(label: "Søger…")
                } else if results.isEmpty {
                    FadedEmptyState(icon: "magnifyingglass", title: "Ingen resultater",
                                    detail: "Prøv et kortere søgeord eller en anden stavemåde.",
                                    actionTitle: "Ryd søgning", action: clearQuery)
                } else {
                    FadedSectionLabel("Resultater · \(results.count)")
                    ForEach(results, content: resultRow)
                }
                if !request.query.isEmpty && completedRequest == request {
                    relatedResults
                }
            }
            .padding(.horizontal, FadedSpacing.edge).padding(.bottom, FadedSpacing.edge)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var relatedResults: some View {
        if broadenedRequest == request {
            if related.isEmpty {
                FadedDetailText("Ingen relaterede resultater.")
            } else {
                FadedSectionLabel("Relateret til din søgning")
                ForEach(related, content: resultRow)
            }
        } else if relatedTask != nil {
            ProgressView("Leder efter relaterede resultater…")
        } else {
            FadedSecondaryButton("Find relaterede resultater", icon: "sparkle.magnifyingglass") { broadenSearch() }
        }
    }

    private func broadenSearch() {
        let selected = request
        let seen = Set(results.map(\.id))
        focused = false
        relatedTask = Task {
            defer { relatedTask = nil }
            let worker = Task.detached(priority: .utility) {
                try selected.index.relatedMatches(selected.query, existing: seen)
            }
            guard let found = try? await withTaskCancellationHandler(operation: { try await worker.value },
                                                                     onCancel: { worker.cancel() }),
                  !Task.isCancelled, self.request == selected else { return }
            related = found
            broadenedRequest = selected
        }
    }

    private func resultRow(_ record: FadedSearchRecord) -> some View {
        let accent = record.category.accent(in: palette)
        return Button {
            focused = false
            onSelect(record.destination)
        } label: {
            FadedCard(accent: accent) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: record.category.icon)
                        .foregroundStyle(palette.isDark ? accent : palette.text)
                        .frame(width: 36, height: 36).background(palette.raised, in: .rect(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title).font(FadedTypography.action).lineLimit(2)
                        if !record.detail.isEmpty {
                            Text(record.detail).font(.footnote).foregroundStyle(palette.secondary).lineLimit(2)
                        }
                        resultLabels(record, accent: accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.secondary)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }.buttonStyle(.plain)
    }

    private func resultLabels(_ record: FadedSearchRecord, accent: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { categoryLabel(record, accent: accent); sourceLabel(record) }
            VStack(alignment: .leading, spacing: 4) { categoryLabel(record, accent: accent); sourceLabel(record) }
        }
    }

    private func categoryLabel(_ record: FadedSearchRecord, accent: Color) -> some View {
        Text(record.category.rawValue).font(.caption.weight(.semibold)).foregroundStyle(palette.isDark ? accent : palette.text)
    }

    @ViewBuilder private func sourceLabel(_ record: FadedSearchRecord) -> some View {
        if let source = record.source {
            Label(source.rawValue, systemImage: "circle.fill")
                .font(.caption2).foregroundStyle(palette.isDark ? source.accent(in: palette) : palette.secondary)
        }
    }

    private func search(_ request: Request) async {
        guard !Task.isCancelled else { return }
        if request.query.isEmpty {
            results = []
            completedRequest = request
            return
        }
        do { try await Task.sleep(for: .milliseconds(220)) }
        catch { return }
        let worker = Task.detached(priority: .userInitiated) { try request.index.cancellableMatches(request.query) }
        let found: [FadedSearchRecord]
        do {
            found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        } catch { return }
        guard !Task.isCancelled, self.request == request else { return }
        results = found
        completedRequest = request
    }

    private func clearQuery() {
        query = ""
        focused = true
    }
}
