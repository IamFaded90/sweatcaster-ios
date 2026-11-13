import Contacts
import ContactsUI
import EventKit
import EventKitUI
import Foundation
import MessageUI
import SwiftUI
import UIKit
#if canImport(AlarmKit)
import AlarmKit
#endif

struct AppleConnectionsView: View {
    let onChooseNote: ((String) -> Void)?
    @Environment(\.openURL) private var openURL
    @State private var composer: Composer?

    var body: some View {
        List {
            Section("Planlægning") {
                NavigationLink {
                    AppleScheduleView(kind: .calendar, onChooseNote: onChooseNote)
                } label: { Label("Kalender", systemImage: "calendar") }
                NavigationLink {
                    AppleScheduleView(kind: .reminders, onChooseNote: onChooseNote)
                } label: { Label("Påmindelser", systemImage: "checklist") }
                #if canImport(AlarmKit)
                if #available(iOS 26.0, *) {
                    NavigationLink {
                        FadedAlarmView()
                    } label: { Label("Alarmer", systemImage: "alarm") }
                } else {
                    Label("Alarmer kræver iOS 26", systemImage: "alarm")
                        .foregroundStyle(.secondary)
                }
                #endif
                Button("Åbn Genveje", systemImage: "square.on.square") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
            }
            Section {
                NavigationLink {
                    AppleContactView(onChooseNote: onChooseNote)
                } label: { Label("Kontakter", systemImage: "person.crop.circle") }
                Button("Skriv besked", systemImage: "message") { composer = .message }
                    .disabled(!MFMessageComposeViewController.canSendText())
                Button("Skriv mail", systemImage: "envelope") { composer = .mail }
                    .disabled(!MFMailComposeViewController.canSendMail())
            } header: {
                Text("Kontakter og kladder")
            } footer: {
                Text("Du vælger modtager og sender selv fra Apples skrivevindue.")
                if !MFMailComposeViewController.canSendMail() {
                    Text("Tilføj en mailkonto i Apples Mail for at skrive en mail her.")
                }
                if !MFMessageComposeViewController.canSendText() {
                    Text("Skriv besked kræver en iPhone, der kan sende SMS eller iMessage.")
                }
            }
        }
        .navigationTitle("Apple og iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $composer) { AppleComposer(mode: $0) }
    }

    fileprivate enum Composer: String, Identifiable {
        case message, mail
        var id: Self { self }
    }
}

private struct AppleScheduleView: View {
    enum Kind {
        case calendar, reminders
        var title: String { self == .calendar ? "Kalender" : "Påmindelser" }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    let kind: Kind
    let onChooseNote: ((String) -> Void)?
    @Environment(\.openURL) private var openURL
    @State private var store = EKEventStore()
    @State private var entries: [Entry] = []
    @State private var showCalendarEditor = false
    @State private var reminderTitle = ""
    @State private var reminderHasDate = false
    @State private var reminderDate = Date.now.addingTimeInterval(3_600)
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                if kind == .calendar {
                    Button("Opret aftale", systemImage: "calendar.badge.plus") { showCalendarEditor = true }
                } else {
                    TextField("Ny påmindelse", text: $reminderTitle)
                    Toggle("Med tidspunkt", isOn: $reminderHasDate)
                    if reminderHasDate {
                        DatePicker("Tidspunkt", selection: $reminderDate, in: Date.now...)
                    }
                    Button("Gem påmindelse", systemImage: "plus.circle") { Task { await saveReminder() } }
                        .disabled(busy || reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section(kind == .calendar ? "De næste syv dage" : "Åbne påmindelser") {
                Button("Hent \(kind.title.lowercased())", systemImage: "arrow.clockwise") {
                    Task { await loadEntries() }
                }
                .disabled(busy)
                if busy { ProgressView() }
                if let status { Text(status).foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if let onChooseNote {
                            Button("Vedhæft til chat", systemImage: "paperclip") {
                                onChooseNote([entry.title, entry.detail].filter { !$0.isEmpty }.joined(separator: "\n"))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if canChangeAccessInSettings {
                    Button("Åbn iPhone-indstillinger") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .sheet(isPresented: $showCalendarEditor) {
            AppleCalendarEditor(store: store) { saved in
                showCalendarEditor = false
                if saved {
                    entries = []
                    status = "Aftalen er gemt."
                }
            }
        }
    }

    private func loadEntries() async {
        guard !busy else { return }
        busy = true
        status = nil
        entries = []
        defer { busy = false }
        do {
            switch kind {
            case .calendar:
                guard try await store.requestFullAccessToEvents() else { return showDenied() }
                let today = Calendar.current.startOfDay(for: .now)
                guard let end = Calendar.current.date(byAdding: .day, value: 7, to: today) else { return }
                let predicate = store.predicateForEvents(withStart: today, end: end, calendars: nil)
                entries = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(30).map {
                    let date = $0.startDate?.formatted(date: .abbreviated, time: $0.isAllDay ? .omitted : .shortened) ?? ""
                    return Entry(title: $0.title ?? "Aftale", detail: date)
                }
            case .reminders:
                guard try await store.requestFullAccessToReminders() else { return showDenied() }
                entries = await withCheckedContinuation { continuation in
                    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
                    store.fetchReminders(matching: predicate) { reminders in
                        continuation.resume(returning: (reminders ?? []).prefix(30).map {
                            let date = $0.dueDateComponents?.date?.formatted(date: .abbreviated, time: .omitted) ?? ""
                            return Entry(title: $0.title ?? "Påmindelse", detail: date)
                        })
                    }
                }
            }
            if entries.isEmpty { status = "Der er ingen emner at vise." }
        } catch {
            status = "Kunne ikke hente \(kind.title.lowercased()). Prøv igen."
        }
    }

    private func showDenied() {
        status = "Giv FadedAI adgang i iPhone-indstillinger for at bruge denne funktion."
    }

    private var canChangeAccessInSettings: Bool {
        let access = EKEventStore.authorizationStatus(for: kind == .calendar ? .event : .reminder)
        return access == .denied || access == .restricted || (kind == .calendar && access == .writeOnly)
    }

    private func saveReminder() async {
        let title = reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !title.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await PhoneActions.saveReminder(title: title, due: reminderHasDate ? reminderDate : nil, store: store)
            reminderTitle = ""
            reminderHasDate = false
            entries = []
            status = "Påmindelsen er gemt."
        } catch {
            status = (error as? PhoneActions.Failure)?.message ?? "Påmindelsen kunne ikke gemmes."
        }
    }
}

private struct AppleCalendarEditor: UIViewControllerRepresentable {
    let store: EKEventStore
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = EKEvent(eventStore: store)
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish(action == .saved)
        }
    }
}

private struct AppleContactView: View {
    let onChooseNote: ((String) -> Void)?
    @State private var picking = false
    @State private var name = ""
    @State private var fields: [String] = []

    var body: some View {
        List {
            Button("Vælg kontakt", systemImage: "person.crop.circle") { picking = true }
            if !name.isEmpty {
                Section {
                    Text(name).font(.headline)
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        Text(field).textSelection(.enabled)
                        if let onChooseNote {
                            Button("Vedhæft dette felt", systemImage: "paperclip") {
                                onChooseNote([name, field].joined(separator: "\n"))
                            }
                        }
                    }
                    Button("Fjern valg") {
                        name = ""
                        fields = []
                    }
                }
            }
        }
        .navigationTitle("Kontakter")
        .privacySensitive()
        .sheet(isPresented: $picking) {
            AppleContactPicker { contact in
                if let contact {
                    name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Kontakt"
                    fields = contact.phoneNumbers.map { $0.value.stringValue } +
                        contact.emailAddresses.map { $0.value as String }
                }
                picking = false
            }
        }
    }
}

private struct AppleContactPicker: UIViewControllerRepresentable {
    let onFinish: (CNContact?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let controller = CNContactPickerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onFinish: (CNContact?) -> Void
        init(onFinish: @escaping (CNContact?) -> Void) { self.onFinish = onFinish }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) { onFinish(contact) }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { onFinish(nil) }
    }
}

private struct AppleComposer: UIViewControllerRepresentable {
    let mode: AppleConnectionsView.Composer
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: { dismiss() }) }
    func makeUIViewController(context: Context) -> UIViewController {
        switch mode {
        case .message:
            let controller = MFMessageComposeViewController()
            controller.messageComposeDelegate = context.coordinator
            return controller
        case .mail:
            let controller = MFMailComposeViewController()
            controller.mailComposeDelegate = context.coordinator
            return controller
        }
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish()
        }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}

struct BotPhoneActionReview: View {
    let action: BotPhoneAction
    let jobID: UUID
    let botName: String
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var usesDate: Bool
    @State private var busy = false
    @State private var issue: String?

    init(action: BotPhoneAction, jobID: UUID, botName: String, onApplied: @escaping () -> Void) {
        self.action = action
        self.jobID = jobID
        self.botName = botName
        self.onApplied = onApplied
        let proposed = action.localDate.flatMap { BotPhoneAction.localFormatter().date(from: $0) }
        _title = State(initialValue: action.title)
        _usesDate = State(initialValue: action.kind == .alarm || action.localDate != nil)
        _date = State(initialValue: proposed ?? .now)
        if action.localDate != nil && proposed == nil {
            _issue = State(initialValue: "Bottens tidspunkt kunne ikke læses. Vælg det rigtige tidspunkt.")
        }
    }

    static var supportsAlarms: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    private var dated: Bool { action.kind == .alarm || usesDate }
    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Forslag fra \(botName)") {
                    TextField("Titel", text: $title)
                    if action.kind == .reminder { Toggle("Med tidspunkt", isOn: $usesDate) }
                    if dated {
                        DatePicker("Tidspunkt", selection: $date)
                        if date <= .now { Text("Vælg et tidspunkt frem i tiden.").foregroundStyle(.secondary) }
                    }
                }
                Button("Godkend og opret", systemImage: "checkmark") { Task { await apply() } }
                    .disabled(busy || cleanTitle.isEmpty || cleanTitle.count > 120 || (dated && date <= .now))
                if busy { ProgressView() }
                if let issue { Text(issue).foregroundStyle(.secondary) }
            }
            .navigationTitle(action.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Luk") { dismiss() }.disabled(busy)
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    @MainActor private func apply() async {
        let requestedTitle = cleanTitle
        let requestedDate = dated ? date : nil
        guard !busy, !requestedTitle.isEmpty, requestedTitle.count <= 120 else { return }
        if let requestedDate, requestedDate <= .now {
            issue = "Vælg et tidspunkt frem i tiden."
            return
        }
        busy = true
        issue = nil
        defer { busy = false }
        do {
            switch action.kind {
            case .reminder:
                try await PhoneActions.saveReminder(title: requestedTitle, due: requestedDate, jobID: jobID,
                                                    store: EKEventStore())
            case .alarm:
                #if canImport(AlarmKit)
                if #available(iOS 26.0, *), let requestedDate {
                    try await PhoneActions.scheduleAlarm(title: requestedTitle, date: requestedDate, id: jobID)
                } else {
                    throw PhoneActions.Failure.unsupportedAlarm
                }
                #else
                throw PhoneActions.Failure.unsupportedAlarm
                #endif
            }
            onApplied()
            dismiss()
        } catch {
            issue = (error as? PhoneActions.Failure)?.message ?? "Kunne ikke oprette \(action.kind.title.lowercased()). Prøv igen."
        }
    }
}

@MainActor private enum PhoneActions {
    enum Failure: Error {
        case reminderPermission, reminderList, unsupportedAlarm, alarmPermission, expired

        var message: String {
            switch self {
            case .reminderPermission: "Giv FadedAI adgang til Påmindelser i iPhone-indstillinger."
            case .reminderList: "Opret eller vælg en standardliste i Påmindelser på din iPhone."
            case .unsupportedAlarm: "Alarmer kræver iOS 26 eller nyere."
            case .alarmPermission: "Giv FadedAI alarmadgang i iPhone-indstillinger."
            case .expired: "Vælg et tidspunkt frem i tiden."
            }
        }
    }

    static func saveReminder(title: String, due: Date?, jobID: UUID? = nil, store: EKEventStore) async throws {
        guard try await store.requestFullAccessToReminders() else { throw Failure.reminderPermission }
        guard let calendar = store.defaultCalendarForNewReminders() else { throw Failure.reminderList }
        let reminder = EKReminder(eventStore: store)
        if let jobID, let marker = URL(string: "fadedai://bot-action/\(jobID.uuidString.lowercased())") {
            let alreadySaved = await withCheckedContinuation { continuation in
                let predicate = store.predicateForReminders(in: nil)
                store.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders?.contains { $0.url == marker } == true)
                }
            }
            if alreadySaved { return }
            reminder.url = marker
        }
        if let due {
            guard due > .now else { throw Failure.expired }
            var clock = Calendar(identifier: .gregorian)
            clock.timeZone = .current
            let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second, .calendar, .timeZone]
            reminder.startDateComponents = clock.dateComponents(fields, from: due)
            reminder.dueDateComponents = reminder.startDateComponents
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        reminder.calendar = calendar
        reminder.title = title
        try store.save(reminder, commit: true)
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private struct Metadata: AlarmMetadata {}

    @available(iOS 26.0, *)
    static func scheduleAlarm(title: String, date: Date, id: UUID) async throws {
        let manager = AlarmManager.shared
        guard try await manager.requestAuthorization() == .authorized else { throw Failure.alarmPermission }
        if try manager.alarms.contains(where: { $0.id == id }) { return }
        guard date > .now else { throw Failure.expired }
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill")
        let presentation = AlarmPresentation(alert: AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
                                                                             stopButton: stop))
        let attributes = AlarmAttributes(presentation: presentation, metadata: Metadata(), tintColor: .mint)
        _ = try await manager.schedule(id: id, configuration: .alarm(schedule: .fixed(date), attributes: attributes))
    }
    #endif
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
private struct FadedAlarmView: View {
    @State private var date = Date.now.addingTimeInterval(300)
    @State private var alarms: [Alarm] = []
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Ny alarm") {
                DatePicker("Tidspunkt", selection: $date)
                Button("Sæt alarm", systemImage: "alarm") { Task { await schedule() } }
                    .disabled(busy)
                if let status { Text(status).foregroundStyle(.secondary) }
            }
            Section("FadedAI-alarmer") {
                ForEach(alarms, id: \.id) { alarm in
                    if case .fixed(let time)? = alarm.schedule {
                        LabeledContent("Alarm", value: time.formatted(date: .abbreviated, time: .shortened))
                        Button("Fjern alarm", role: .destructive) {
                            do {
                                try AlarmManager.shared.cancel(id: alarm.id)
                                reload()
                            } catch {
                                status = "Alarmen kunne ikke fjernes."
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Alarmer")
        .task {
            reload()
            for await updated in AlarmManager.shared.alarmUpdates { alarms = updated }
        }
    }

    private func reload() {
        if let scheduled = try? AlarmManager.shared.alarms { alarms = scheduled }
    }

    private func schedule() async {
        guard !busy else { return }
        let selected = date
        guard selected > .now else {
            status = "Vælg et tidspunkt frem i tiden."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await PhoneActions.scheduleAlarm(title: "FadedAI-alarm", date: selected, id: UUID())
            status = "Alarmen er sat."
            reload()
        } catch {
            status = (error as? PhoneActions.Failure)?.message ?? "Alarmen kunne ikke sættes."
        }
    }
}
#endif
