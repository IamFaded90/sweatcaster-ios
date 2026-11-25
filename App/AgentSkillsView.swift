import SwiftUI
import UniformTypeIdentifiers

@MainActor struct AgentSkillsView: View {
    let bot: VillageBot
    var onResult: (String) -> Void = { _ in }
    @State private var skills: [AgentSkillLibrary.Skill] = []
    @State private var importing = false
    @State private var showContacts = false
    @State private var notice: String?
    @State private var context: [AgentPhoneContext.Item] = []
    @Environment(\.dismiss) private var dismiss
    private let store = AgentSkillLibrary.Store()
    var body: some View {
        NavigationStack {
            List {
                Section("Værktøjer på telefonen") {
                    Button("Find en kontakt", systemImage: "person.crop.circle") { showContacts = true }.frame(minHeight: 44)
                    Text("Kalender, Påmindelser og alarmer bruges fra chatten. Browser, kamera og filer ligger også i agentens værktøjsmenu. En Skill tilføjer en arbejdsmetode til de værktøjer, appen allerede har.").font(.footnote).foregroundStyle(.secondary)
                }
                if !context.isEmpty {
                    Section("Valgt til næste opgave") {
                        ForEach(Array(context.enumerated()), id: \.offset) { _, item in VStack(alignment: .leading) { Text(item.title); Text(item.source).font(.caption).foregroundStyle(.secondary) } }
                        Button("Ryd opfølgningskontekst", systemImage: "trash", role: .destructive) { do { try AgentPhoneContext.Store().clear(bot.id); load() } catch { notice = error.localizedDescription } }
                    }
                }
                Section("Færdigheder til \(bot.name)") {
                    if skills.isEmpty { Text("Importér en SKILL.md-fil. Du kan gennemgå teksten og slå den til for denne agent.") }
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(skill.name, isOn: Binding(get: { skill.enabledFor.contains(bot.id) }, set: { value in change(skill.id) { if value { $0.enabledFor.insert(bot.id) } else { $0.enabledFor.remove(bot.id) } } })).disabled(!skill.unsupported.isEmpty)
                            Text(skill.description).font(.subheadline).foregroundStyle(.secondary)
                            if !skill.unsupported.isEmpty { Text("Disse værktøjer findes ikke her: " + skill.unsupported.joined(separator: ", ")).font(.caption) }
                            DisclosureGroup("Se instruktionerne") { Text(verbatim: skill.instructions).font(.footnote).textSelection(.enabled) }
                            Text("Kun relevante, aktiverede færdigheder bruges, højst to ad gangen.").font(.caption).foregroundStyle(.secondary)
                            Button("Slet færdigheden", systemImage: "trash", role: .destructive) { save(skills.filter { $0.id != skill.id }) }.frame(minHeight: 44)
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    Button("Importér SKILL.md", systemImage: "square.and.arrow.down") { importing = true }.frame(minHeight: 44)
                    PasteButton(payloadType: String.self) { values in if let text = values.first { importSkill(Data(text.utf8)) } }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }
            }.scrollContentBackground(.hidden).background { FadedBackground() }.navigationTitle("Færdigheder og telefonværktøjer").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { dismiss() } }.onAppear(perform: load)
                .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text]) { result in
                    do {
                        let url = try result.get(), scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 24_000 else { throw AgentSkillLibrary.Failure.format }
                        importSkill(try Data(contentsOf: url))
                    } catch { notice = error.localizedDescription }
                }
                .sheet(isPresented: $showContacts, onDismiss: load) { AgentContactsView(bot: bot, onResult: onResult) }
        }
    }
    private func load() { do { skills = try store.load(); context = try AgentPhoneContext.Store().load(bot.id) } catch { notice = error.localizedDescription } }
    private func save(_ next: [AgentSkillLibrary.Skill]) { do { try store.save(next); load(); notice = nil } catch { notice = error.localizedDescription } }
    private func change(_ id: UUID, _ update: (inout AgentSkillLibrary.Skill) -> Void) { var next = skills; if let i = next.firstIndex(where: { $0.id == id }) { update(&next[i]); save(next) } }
    private func importSkill(_ data: Data) { do { let skill = try store.importFile(data); load(); notice = "\(skill.name) er importeret. Gennemgå den og slå den til for \(bot.name)." } catch { notice = error.localizedDescription } }
}
