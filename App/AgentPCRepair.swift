import SwiftUI
import UIKit

/// Fixed PC image checks and scoped repairs, presented directly from agent chat.
@MainActor struct AgentPCRepair: View {
    let api: LiveAPI?
    var initialPrompt = ""
    var onResult: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var diagnosis: Diagnosis?
    @State private var job: Job?
    @State private var imageData: Data?
    @State private var busy = false
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    @State private var reported = Set<String>()

    private struct Check: Decodable, Identifiable {
        let id: String
        let title: String
        let state: String
        let detail: String
    }
    private struct Action: Decodable, Identifiable {
        let id: String
        let title: String
        let detail: String
    }
    private struct FailedJob: Decodable, Identifiable {
        let id: String
        let title: String
        let detail: String
    }
    private struct Job: Decodable, Identifiable {
        let id: String
        let state: String
        let summary: String
        let steps: [String]
        let imageAvailable: Bool
        var working: Bool { state == "working" }
    }
    private struct Diagnosis: Decodable {
        let state: String
        let summary: String
        let checks: [Check]
        let actions: [Action]
        let failedJobs: [FailedJob]
        let jobs: [Job]
        let detail: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Jeg tjekker billedmotoren", systemImage: "wrench.and.screwdriver")
                                .font(.title2.bold())
                            Text("Forbindelse, modeller og hukommelse samlet her. Vælg en rettelse, så tjekker jeg resultatet bagefter.")
                            if !initialPrompt.isEmpty {
                                Text(initialPrompt).font(.footnote).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if api == nil {
                        ContentUnavailableView("Forbind din PC", systemImage: "desktopcomputer",
                            description: Text("Åbn FadedAI på PC’en, og vælg din PC-forbindelse i appen."))
                    }
                    if let diagnosis {
                        ForEach(diagnosis.checks) { check in
                            FadedCard {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: check.state == "ready" ? "checkmark.circle.fill" : check.state == "busy" ? "hourglass" : "exclamationmark.circle")
                                        .foregroundStyle(check.state == "ready" ? Color.green : Color.cyan)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(check.title).font(.headline)
                                        Text(check.detail).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        if !diagnosis.actions.isEmpty {
                            Text("Det kan jeg ordne her").font(.headline)
                            ForEach(diagnosis.actions) { action in
                                VStack(alignment: .leading, spacing: 8) {
                                    FadedPrimaryButton(action.title, icon: action.id == "start" ? "power" : "memorychip") {
                                        recover(action.id)
                                    }.disabled(busy || job?.working == true)
                                    Text(action.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !diagnosis.failedJobs.isEmpty {
                            Text("Fortsæt med dit billede").font(.headline)
                            ForEach(diagnosis.failedJobs) { failed in
                                FadedCard {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(failed.detail).font(.subheadline)
                                        FadedSecondaryButton(failed.title, icon: "arrow.clockwise") {
                                            recover("retryImage", promptID: failed.id)
                                        }.disabled(busy || job?.working == true)
                                    }
                                }
                            }
                        }
                        Text(diagnosis.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let job { result(job) }
                    if let diagnosis {
                        ForEach(diagnosis.jobs.filter { $0.id != job?.id }) { previous in
                            Button {
                                open(previous)
                            } label: {
                                Label(previous.summary, systemImage: previous.imageAvailable ? "photo" : "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(FadedButtonStyle(kind: .secondary)).disabled(busy)
                        }
                    }
                    if busy { ProgressView(job?.working == true ? "PC’en arbejder og kontrollerer resultatet…" : "Tjekker PC’en…") }
                    if let notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
                    if api != nil {
                        FadedSecondaryButton("Tjek PC’en igen", icon: "arrow.clockwise") { reload() }
                            .disabled(busy)
                    }
                }.padding(FadedSpacing.edge)
            }.background { FadedBackground() }
                .navigationTitle("Hjælp til PC-billeder").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        }
        .task { reload() }
        .onChange(of: phase) { _, value in if value == .active, !busy { reload() } }
        .onDisappear { operation?.cancel() }
    }

    @ViewBuilder private func result(_ job: Job) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(job.working ? "Rettelsen er i gang" : job.state == "ready" ? "Kontrolleret resultat" : "Det kræver et nyt forsøg",
                      systemImage: job.working ? "gearshape.2" : job.state == "ready" ? "checkmark.seal" : "info.circle")
                    .font(.headline)
                Text(job.summary).textSelection(.enabled)
                ForEach(Array(job.steps.enumerated()), id: \.offset) { _, step in
                    Label(step, systemImage: "checkmark").font(.footnote)
                }
                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Billede fra PC’en", image: Image(uiImage: image))) {
                        Label("Del billedet", systemImage: "square.and.arrow.up")
                    }.buttonStyle(FadedButtonStyle(kind: .secondary))
                }
                if job.working {
                    Text("Du kan lukke denne side. Rettelsen fortsætter på PC’en, og resultatet kan åbnes her igen.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    HStack {
                        FadedSecondaryButton("Tjek resultat", icon: "arrow.clockwise") { open(job) }.disabled(busy)
                        Button(role: .destructive) { remove(job) } label: { Label("Slet", systemImage: "trash") }
                            .buttonStyle(FadedButtonStyle(kind: .secondary)).disabled(busy)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reload() {
        guard !busy, let api else { return }
        busy = true
        notice = nil
        operation = Task {
            defer { busy = false }
            do {
                let result: Diagnosis = try await api.moduleJSON("pc-repair", timeout: 35)
                try Task.checkCancellation()
                diagnosis = result
                if let previous = job, let fresh = result.jobs.first(where: { $0.id == previous.id }) { job = fresh }
                else if job == nil { job = result.jobs.first }
                if let job {
                    if job.working { try await watch(job, api: api) }
                    else if job.imageAvailable { try await loadImage(job, api: api) }
                }
            } catch is CancellationError { return }
            catch { notice = message(error) }
        }
    }

    private func recover(_ action: String, promptID: String? = nil) {
        guard !busy, let api else { return }
        busy = true
        notice = nil
        imageData = nil
        operation = Task {
            defer { busy = false }
            do {
                var body = ["id": UUID().uuidString.lowercased(), "action": action]
                if let promptID { body["promptID"] = promptID }
                let started: Job = try await api.moduleJSON("pc-repair/recover", upload: JSONEncoder().encode(body), timeout: 15)
                try Task.checkCancellation()
                job = started
                try await watch(started, api: api)
            } catch is CancellationError { return }
            catch { notice = message(error) }
        }
    }

    private func open(_ selected: Job) {
        guard !busy, let api else { return }
        busy = true
        imageData = nil
        notice = nil
        job = selected
        operation = Task {
            defer { busy = false }
            do {
                let fresh: Job = try await api.moduleJSON("pc-repair/jobs/" + selected.id + "/refresh", upload: Data("{}".utf8), timeout: 20)
                try Task.checkCancellation()
                job = fresh
                try await watch(fresh, api: api)
            } catch is CancellationError { return }
            catch { notice = message(error) }
        }
    }

    private func watch(_ first: Job, api: LiveAPI) async throws {
        var latest = first
        while latest.working {
            try await Task.sleep(for: .seconds(2))
            latest = try await api.moduleJSON("pc-repair/jobs/" + first.id, timeout: 15)
            try Task.checkCancellation()
            job = latest
        }
        if latest.imageAvailable { try await loadImage(latest, api: api) }
        if reported.insert(latest.id).inserted {
            let outcome = latest.state == "ready" ? "Kontrolleret" : latest.state == "needsInput" ? "Afventer et nyt valg" : "Kunne ikke fuldføres"
            onResult(outcome + ": " + latest.summary)
        }
    }

    private func loadImage(_ job: Job, api: LiveAPI) async throws {
        struct File: Decodable { let png: Data }
        let file: File = try await api.moduleJSON("pc-repair/jobs/" + job.id + "/image", timeout: 25, maximumBytes: 21_000_000)
        try Task.checkCancellation()
        guard file.png.count <= 15_000_000, UIImage(data: file.png) != nil else { throw APIError.malformed }
        imageData = file.png
    }

    private func remove(_ selected: Job) {
        guard !busy, let api else { return }
        busy = true
        notice = nil
        operation = Task {
            defer { busy = false }
            do {
                struct Deleted: Decodable { let deleted: Bool }
                let receipt: Deleted = try await api.moduleJSON("pc-repair/jobs/" + selected.id + "/remove", upload: Data("{}".utf8), timeout: 20)
                guard receipt.deleted else { throw APIError.malformed }
                try Task.checkCancellation()
                job = nil
                imageData = nil
                diagnosis = try await api.moduleJSON("pc-repair", timeout: 35)
            } catch is CancellationError { return }
            catch { notice = message(error) }
        }
    }

    private func message(_ error: Error) -> String {
        if case APIError.http(_, let problem) = error, let detail = problem?.message { return detail }
        return "PC’en kunne ikke svare. Tjek forbindelsen, og tryk Tjek PC’en igen."
    }
}
