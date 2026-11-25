import SwiftUI

@MainActor struct AgentWorkReviewView: View {
    let bot: VillageBot
    let model: String
    let storage: AgentWorkspace
    let jobID: UUID
    var resume: ((UUID) -> Void)?
    @State private var snapshot = AgentWorkspace.Snapshot()
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss
    private var job: AgentWorkspace.Job? { snapshot.jobs.first { $0.id == jobID } }
    private var artifact: AgentWorkspace.File? { job?.fileID.flatMap { id in snapshot.files.first { $0.id == id } } }
    var body: some View {
        List {
            if let job {
                let assessment = AgentWorkReview.assess(job, files: snapshot.files)
                Section("Opgaven") {
                    Text(job.prompt).font(.headline).textSelection(.enabled)
                    LabeledContent("Oprettet", value: job.created.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Status", value: job.state.title)
                    Text(assessment.title).font(.subheadline.bold()); Text(assessment.detail).font(.caption).foregroundStyle(.secondary)
                    if !job.result.isEmpty { Text(job.result).textSelection(.enabled) }
                }
                Section("De gemte kilder") {
                    if let source = job.inputSnapshot, !source.isEmpty { Text(source).textSelection(.enabled) }
                    else if job.inputFileID != nil { Text("Denne ældre opgave har ingen gemt kopi af den anvendte filversion. Den aktuelle fil er ikke bevis for det oprindelige input.").foregroundStyle(.secondary) }
                    else { Text("Opgavens tekst er inputkilden.").foregroundStyle(.secondary) }
                    if let input = job.localInput { DisclosureGroup("Kodeværktøjets faktiske input") { Text(input).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) } }
                    if let code = job.localCode { DisclosureGroup("Koden der blev kørt") { Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) } }
                    if let id = job.inputFileID, let current = snapshot.files.first(where: { $0.id == id }) { Text("Valgt fil-ID: \(id.uuidString) · aktuelt navn: \(current.name)").font(.caption) }
                }
                Section("Hvad er dokumenteret?") {
                    Label("Opgaven er gemt i arbejdsrummet", systemImage: "checkmark.circle")
                    if job.submitted { Label("PC-afsendelse blev journalført før kaldet", systemImage: "desktopcomputer"); Text("Journalføringen alene beviser ikke, at PC’en udførte opgaven.").font(.caption).foregroundStyle(.secondary) }
                    if job.remoteID != nil { Text("PC-kvitteringens job-ID: \(job.remoteID!.uuidString)").font(.caption) }
                    if let artifact {
                        Label("Den gemte resultatfil findes", systemImage: "doc.text")
                        Text("\(artifact.name) · \(artifact.text.utf8.count) byte · \(artifact.updated.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    }
                    if job.state == .checking { Text("Afventer kontrol af den eksisterende opgave. Den sendes ikke igen herfra.").foregroundStyle(.secondary) }
                }
                if let artifact {
                    Section("Resultatet") {
                        Text(artifact.text).textSelection(.enabled)
                        ShareLink(item: artifact.text) { Label("Del resultatets tekst", systemImage: "square.and.arrow.up") }.frame(minHeight: 44)
                        NavigationLink("Åbn og ret resultatfilen") { AgentWorkspaceFileView(file: artifact, storage: storage) }
                        if assessment.canReview {
                            Button("Lad \(bot.name) kontrollere indholdet", systemImage: "checkmark.bubble") { check() }.frame(minHeight: 44).disabled(working || !PhoneModels.isReady(model))
                            Text("En særskilt lokal modelvurdering sammenholder opgaven og de viste input-/resultatuddrag. Den er ikke en garanti for faktuel korrekthed.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let report = job.review {
                        Section("Modelvurdering") {
                            if AgentWorkReview.isCurrent(report, job: job, file: artifact) {
                                Text(report.summary).textSelection(.enabled)
                                Text(report.excerptOnly ? "Kontrollen så uddrag; resten af materialet blev ikke kontrolleret." : "Kontrollen så hele det gemte input og tekstresultat.").font(.caption).foregroundStyle(.secondary)
                                ForEach(report.checks.indices, id: \.self) { index in
                                    let check = report.checks[index]
                                    VStack(alignment: .leading, spacing: 5) {
                                        Label(check.title, systemImage: check.status == .pass ? "checkmark.circle" : check.status == .issue ? "exclamationmark.circle" : "questionmark.circle")
                                        Text(check.reason)
                                        if !check.quote.isEmpty { Text("“\(check.quote)”").font(.subheadline).textSelection(.enabled); Text(check.source == "output" ? "Kilde: resultatuddrag" : "Kilde: inputuddrag").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                Text(report.created.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            } else { Text("Input eller resultat er ændret siden kontrollen. Kør en ny kontrol.").foregroundStyle(.secondary) }
                        }
                    }
                }
                if job.state != .completed && job.state != .cancelled {
                    Section("Fortsæt arbejdet") {
                        if job.kind == .localCode, let code = job.localCode {
                            NavigationLink("Åbn script og input igen") { AgentLocalCodeView(bot: bot, model: model, initial: job.prompt, initialRecipe: .init(name: "Lokalt værktøj", code: code), initialInput: job.localInput, initialJob: job.id) }
                        } else if job.kind != .shortcut, let resume {
                            Button(job.submitted ? "Kontrollér den eksisterende PC-opgave" : "Fortsæt den gemte opgave", systemImage: "arrow.clockwise") { resume(job.id); dismiss() }.frame(minHeight: 44).disabled(working)
                        } else { Text("Genveje genstartes fra arbejdsrummet efter gennemgang af deres kvittering.").font(.caption) }
                    }
                }
            } else { ContentUnavailableView("Opgaven findes ikke længere", systemImage: "tray") }
            if working { ProgressView("Kontrollerer lokalt…"); Button("Stop kontrollen") { operation?.cancel() }.frame(minHeight: 44) }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }.scrollContentBackground(.hidden).background { FadedBackground() }
            .navigationTitle("Kilder og resultat").navigationBarTitleDisplayMode(.inline)
            .onAppear { refresh() }.onDisappear { operation?.cancel() }
    }
    private func refresh() { do { snapshot = try storage.load() } catch { notice = error.localizedDescription } }
    private func check() {
        guard !working, let job, let artifact else { return }; working = true; notice = nil
        let input = String(AgentWorkReview.input(job).prefix(2_000)), output = String(artifact.text.prefix(4_000))
        operation = Task {
            defer { working = false }
            do {
                var response = ""
                try await PhoneModels.reply(modelID: model, prompt: "INPUT (muligvis uddrag):\n\(input)\n\nOUTPUT (muligvis uddrag):\n\(output)", instructions: AgentWorkReview.instructions) { response = $0 }
                try Task.checkCancellation()
                let report = try AgentWorkReview.decode(response, job: job, file: artifact, inputExcerpt: input, outputExcerpt: output)
                let current = try storage.load()
                guard let latestJob = current.jobs.first(where: { $0.id == job.id }), let latestFile = current.files.first(where: { $0.id == artifact.id }),
                      AgentWorkReview.isCurrent(report, job: latestJob, file: latestFile) else { throw AgentWorkReview.Failure.invalid }
                try storage.update(job.id) { $0.review = report }; refresh()
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
}
