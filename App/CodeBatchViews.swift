// Batch jobs, multi-file proposals and explicit approval on the paired PC.

import Foundation
import SwiftUI

struct BatchReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let api: LiveAPI

    var body: some View {
        NavigationStack {
            BatchReviewView(api: api)
                .toolbar { Button("Luk") { dismiss() } }
        }
    }
}

struct BatchReviewView: View {
    let api: LiveAPI
    @State private var jobs: [CodeBatchList.Job] = []
    @State private var repo = ""
    @State private var goal = ""
    @State private var paths = ""
    @State private var failure: String?
    @State private var busy = false
    @State private var loadingJobs = false
    @State private var loadedJobs = false

    private var batchFiles: [String] {
        paths.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var batchBlocker: String? {
        if busy { return "Vent på PC’en." }
        if repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || batchFiles.isEmpty {
            return "Udfyld repo, opgave og filstier."
        }
        if batchFiles.count > 5 { return "Vælg højst fem filstier." }
        return nil
    }

    var body: some View {
        Form {
            Section("Ny opgave") {
                TextField("Repo (ejer/projekt)", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Klon GitHub-repo til PC’en") { Task { await clone() } }
                    .disabled(busy || repo.trimmingCharacters(in: .whitespaces).isEmpty)
                TextField("Hvad skal ændres?", text: $goal, axis: .vertical)
                TextField("Op til fem filstier, én pr. linje", text: $paths, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                FadedPrimaryButton("Sæt i kø", icon: "terminal") { Task { await enqueue() } }
                    .disabled(batchBlocker != nil)
                if let batchBlocker { FadedDetailText(batchBlocker) }
            }
            Section("Kodejob") {
                if let failure { Text(failure) }
                Button("Opdatér liste") { Task { await reload() } }.disabled(loadingJobs)
                if loadingJobs && jobs.isEmpty {
                    LoadingSkeleton(label: "Henter kodejob…")
                } else if loadedJobs && jobs.isEmpty {
                    FadedDetailText("Ingen kodejob endnu. Sæt en opgave i kø ovenfor.")
                }
                ForEach(jobs) { job in
                    NavigationLink {
                        BatchProposalView(api: api, id: job.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(job.goal)
                            Text(batchStatus(job.status)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground(variant: .terminal))
        .navigationTitle("Forslag til flere filer")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard !loadingJobs else { return }
        loadingJobs = true
        defer { loadingJobs = false }
        do {
            let received = try await api.codeBatches().jobs
            try Task.checkCancellation()
            jobs = received
            loadedJobs = true
            failure = nil
        } catch is CancellationError { return }
        catch { AppDiagnostics.record(error); failure = pcBusyMessage(error) ?? "Kodekøen kunne ikke hentes. Kontrollér forbindelsen til PC’en." }
    }

    private func enqueue() async {
        guard batchBlocker == nil else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.enqueueCodeBatch(repo: repo.trimmingCharacters(in: .whitespaces), goal: goal, files: batchFiles)
            goal = ""
            await reload()
        } catch { AppDiagnostics.record(error); failure = pcBusyMessage(error) ?? "Opgaven kunne ikke sættes i kø. Tjek repo og filstier." }
    }

    private func clone() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.cloneCodeRepository(repo.trimmingCharacters(in: .whitespaces))
            failure = nil
        } catch { AppDiagnostics.record(error); failure = pcBusyMessage(error) ?? "Repoet kunne ikke klones. Tjek navnet og PC’ens adgang til GitHub." }
    }
}

private func batchStatus(_ status: String) -> String {
    switch status {
    case "queued": "I kø"
    case "running": "Arbejder"
    case "review": "Afventer godkendelse"
    case "applied": "Gemt på lokal gren"
    case "declined": "Intet forslag"
    default: "Jobbet stoppede"
    }
}

struct BatchProposalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    let api: LiveAPI
    let id: String
    @State private var detail: CodeBatchDetail?
    @State private var fileDiffs: [CodeBatchDiff] = []
    @State private var confirm = false
    @State private var busy = false
    @State private var reloading = false
    @State private var approvalNeedsReload = false
    @State private var failure: String?
    @State private var notice: String?

    var body: some View {
        List {
            if let detail { FadedSectionHeader(batchStatus(detail.status)) }
            if detail == nil && failure == nil { LoadingSkeleton(label: "Henter forslaget…") }
            if let failure { RetryNotice(message: failure) { Task { await reload() } }.disabled(busy || reloading) }
            if let notice { Text(notice) }
            if let reason = detail?.result?.reason { Text(verbatim: reason) }
            if !fileDiffs.isEmpty {
                Section("Ændringer pr. fil") {
                    ForEach(fileDiffs) { file in
                        VStack(alignment: .leading, spacing: FadedSpacing.s) {
                            if let path = file.path { Text(verbatim: path).font(FadedTypography.code) }
                            FadedDiff(diff: file.diff)
                        }
                    }
                }
            }
            if let tests = detail?.result?.tests {
                Section("Testplan") {
                    ForEach(Array(tests.enumerated()), id: \.offset) { entry in Text(verbatim: entry.element) }
                }
            }
            if let checks = detail?.result?.checks, !checks.isEmpty {
                Section("Kontroller kørt på PC’en") {
                    ForEach(Array(checks.enumerated()), id: \.offset) { entry in Text(verbatim: entry.element) }
                }
            }
            if let branch = detail?.result?.branch { Text(verbatim: branch).textSelection(.enabled) }
            Button("Opdatér") { Task { await reload() } }.disabled(busy || reloading)
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground(variant: .terminal))
        .navigationTitle("Gennemgå forslag")
        .safeAreaInset(edge: .bottom) {
            if detail?.status == "review" { approvalBar }
        }
        .interactiveDismissDisabled(busy)
        .task { await reload() }
        .confirmationDialog("Godkend ændringerne?", isPresented: $confirm) {
            Button("Opret lokal Git-gren") { Task { await approve() } }
        } message: { Text("Forslaget gemmes på en separat gren i Agent Workspace på PC’en.") }
    }

    private var approvalBlocker: String? {
        if busy { return "Venter på PC’ens bekræftelse…" }
        if reloading { return "Opdaterer forslagets status…" }
        if approvalNeedsReload { return "Opdatér forslaget, før du prøver igen." }
        if fileDiffs.isEmpty { return "PC’en har ikke sendt en diff, du kan gennemgå." }
        return nil
    }

    private var approvalBar: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            if let approvalBlocker { FadedDetailText(approvalBlocker) }
            else { FadedDetailText("Luk uden godkendelse for at lade forslaget blive i PC’ens kø.") }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FadedSpacing.s) { approvalActions }
                VStack(spacing: FadedSpacing.s) { approvalActions }
            }
        }
        .padding(.horizontal, FadedSpacing.edge).padding(.vertical, FadedSpacing.s)
        .background(palette.background)
    }

    @ViewBuilder private var approvalActions: some View {
        FadedSecondaryButton("Luk uden godkendelse") { dismiss() }.disabled(busy)
        FadedPrimaryButton("Godkend ændringer", icon: "checkmark") { confirm = true }
            .disabled(approvalBlocker != nil)
    }

    private func reload() async {
        guard !reloading else { return }
        reloading = true
        defer { reloading = false }
        do {
            let received = try await api.codeBatch(id)
            try Task.checkCancellation()
            guard received.id == id else { throw V2Failure.invalidResponse }
            detail = received
            fileDiffs = CodeBatchDiff.sections(received.result?.diff ?? "")
            approvalNeedsReload = false
            failure = nil
        } catch is CancellationError { return }
        catch {
            AppDiagnostics.record(error)
            failure = "Forslaget kunne ikke hentes. Tjek PC’en, og prøv igen."
        }
    }

    private func approve() async {
        guard detail?.status == "review", approvalBlocker == nil else { return }
        busy = true
        approvalNeedsReload = true
        defer { busy = false }
        do {
            let applied = try await api.approveCodeBatch(id)
            await reload()
            if let branch = applied.branch { notice = "Ændringerne er gemt på \(branch)." }
        } catch {
            AppDiagnostics.record(error)
            notice = "PC’en kunne ikke bekræfte godkendelsen. Opdatér for at se den aktuelle status."
        }
    }
}

private struct CodeBatchDiff: Identifiable {
    let id: Int
    let path: String?
    let diff: String

    static func sections(_ diff: String) -> [Self] {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let fallback = [Self(id: 0, path: nil, diff: diff)]
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var files: [(start: Int, path: String)] = []
        var oldRemaining = 0
        var newRemaining = 0
        for index in lines.indices {
            let line = lines[index]
            if oldRemaining > 0 || newRemaining > 0 {
                if line.first == " " || line.first == "-" { oldRemaining -= 1 }
                if line.first == " " || line.first == "+" { newRemaining -= 1 }
                guard oldRemaining >= 0, newRemaining >= 0 else { return fallback }
            } else if line.hasPrefix("@@ ") {
                let fields = line.split(separator: " ")
                guard fields.count >= 4, let old = lineCount(fields[1]), let new = lineCount(fields[2]) else { return fallback }
                oldRemaining = old
                newRemaining = new
            } else if line.hasPrefix("--- a/"), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ b/") {
                files.append((index, String(lines[index + 1].dropFirst(6))))
            }
        }
        guard files.first?.start == 0, oldRemaining == 0, newRemaining == 0 else { return fallback }
        return files.enumerated().map { index, file in
            let end = index + 1 < files.count ? files[index + 1].start : lines.count
            return Self(id: file.start, path: file.path, diff: lines[file.start..<end].joined(separator: "\n"))
        }
    }

    private static func lineCount(_ field: Substring) -> Int? {
        let parts = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let start = parts.first.flatMap({ Int($0) }), start >= 0 else { return nil }
        if parts.count == 1 { return 1 }
        guard parts.count == 2, let count = Int(parts[1]), count >= 0 else { return nil }
        return count
    }
}
