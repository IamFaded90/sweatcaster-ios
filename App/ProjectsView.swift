import SwiftUI

private struct FadedProject: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var content = ""
    var updatedAt = Date.now
}

struct FadedProjectsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @State private var projects: [FadedProject] = []
    @State private var editing: FadedProject?
    @State private var deleting: FadedProject?
    @State private var query = ""
    @State private var loaded = false
    @State private var failure: String?

    private let root = URL.applicationSupportDirectory.appending(path: "FadedAI", directoryHint: .isDirectory)
    private var file: URL { root.appending(path: "projects.json", directoryHint: .notDirectory) }
    private var store: LocalFileStore { LocalFileStore(root: root) }

    private var matching: [FadedProject] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                $0.content.localizedCaseInsensitiveContains(search)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let failure {
                        FadedDetailText(failure)
                        if !loaded { Button("Prøv igen", action: load) }
                    }
                    if loaded && projects.isEmpty {
                        FadedEmptyState(icon: "folder", title: "Ingen projekter endnu",
                                        detail: "Gem en idé eller en kladde til senere.",
                                        actionTitle: "Nyt projekt") { editing = FadedProject() }
                    } else if loaded && matching.isEmpty {
                        FadedDetailText("Ingen projekter matcher søgningen.")
                    }
                    ForEach(matching) { project in projectRow(project) }
                } header: {
                    Text("Et sted til det, du skaber")
                }
            }
            .scrollContentBackground(.hidden)
            .background(FadedBackground())
            .navigationTitle("Dine projekter")
            .searchable(text: $query, prompt: "Søg i dine projekter")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Luk") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Nyt projekt", systemImage: "plus") { editing = FadedProject() }
                        .disabled(!loaded)
                }
            }
        }
        .task { if !loaded { load() } }
        .sheet(item: $editing) { project in
            FadedProjectEditor(project: project, isNew: !projects.contains { $0.id == project.id }) { draft in
                var next = projects.filter { $0.id != draft.id }
                next.append(draft)
                return save(next)
            }
        }
        .confirmationDialog("Slet projekt?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { project in
            Button("Slet", role: .destructive) { _ = save(projects.filter { $0.id != project.id }) }
        } message: { project in
            Text(project.title)
        }
    }

    private func projectRow(_ project: FadedProject) -> some View {
        Button { editing = project } label: {
            VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                Text(project.title).font(.headline).foregroundStyle(palette.text)
                if !project.content.isEmpty {
                    Text(project.content).font(.subheadline).foregroundStyle(palette.secondary).lineLimit(2)
                }
                Text(project.updatedAt, format: .dateTime.day().month().year())
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.card)
        .swipeActions(allowsFullSwipe: false) {
            Button("Slet", role: .destructive) { deleting = project }
        }
        .contextMenu {
            ShareLink(item: project.title + "\n\n" + project.content, subject: Text(project.title)) {
                Label("Del som tekst", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func load() {
        do {
            projects = try store.read([FadedProject].self, from: file)
            loaded = true
            failure = nil
        } catch let error where LocalFileStore.isMissing(error) {
            loaded = true
            failure = nil
        } catch {
            AppDiagnostics.record(error)
            failure = "Projekterne kunne ikke åbnes."
        }
    }

    private func save(_ updated: [FadedProject]) -> Bool {
        guard loaded else { return false }
        do {
            try store.write(updated, to: file)
            projects = updated
            failure = nil
            return true
        } catch {
            AppDiagnostics.record(error)
            failure = "Projekterne kunne ikke gemmes. Tjek ledig plads, og prøv igen."
            return false
        }
    }
}

private struct FadedProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var project: FadedProject
    let isNew: Bool
    let save: (FadedProject) -> Bool
    @State private var failed = false

    private let maximumContentLength = 10_000
    private var title: String { project.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(project: FadedProject, isNew: Bool, save: @escaping (FadedProject) -> Bool) {
        _project = State(initialValue: project)
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Titel", text: $project.title)
                    .onChange(of: project.title) {
                        if project.title.count > 120 { project.title = String(project.title.prefix(120)) }
                    }
                Section("Indhold") {
                    TextEditor(text: $project.content)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Indhold")
                        .onChange(of: project.content) {
                            if project.content.count > maximumContentLength {
                                project.content = String(project.content.prefix(maximumContentLength))
                            }
                        }
                    Text("\(project.content.count) / \(maximumContentLength) tegn")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if failed { FadedDetailText("Kladden kunne ikke gemmes. Prøv igen.") }
            }
            .navigationTitle(isNew ? "Nyt projekt" : "Redigér projekt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Behold kladde") {
                        project.title = title
                        project.updatedAt = .now
                        if save(project) { dismiss() } else { failed = true }
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}
