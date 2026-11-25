import Contacts
import SwiftUI
import UIKit

@MainActor struct AgentContactsView: View {
    struct Person: Identifiable, Sendable {
        let id, name: String
        let phones, emails: [String]
        var facts: String { (["Navn: " + name] + phones.prefix(2).map { "Telefon: " + $0 } + emails.prefix(2).map { "E-mail: " + $0 } + (phones.count > 1 || emails.count > 1 ? ["Flere adresser/numre: afklar hvilket der skal bruges."] : [])).joined(separator: "\n") }
    }
    let bot: VillageBot
    var initialQuery = ""
    var onResult: (String) -> Void = { _ in }
    @State private var query = ""
    @State private var people: [Person] = []
    @State private var busy = false
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Find en person på din iPhone") {
                    TextField("Navn på kontakt", text: $query).textInputAutocapitalization(.words)
                    Button("Søg i Kontakter", systemImage: "person.crop.circle.badge.magnifyingglass") { search() }.frame(minHeight: 44).disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if busy { ProgressView("Læser matchende kontakter…"); Button("Stop") { operation?.cancel() } }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }
                ForEach(people) { person in
                    Section(person.name) {
                        ForEach(person.phones, id: \.self) { number in
                            HStack { Text(number).textSelection(.enabled); Spacer(); if let url = phoneURL(number) { Link("Ring", destination: url).frame(minHeight: 44) } }
                        }
                        ForEach(person.emails, id: \.self) { address in Text(address).textSelection(.enabled) }
                        Button("Brug kontakten i chatten", systemImage: "person.crop.circle.badge.checkmark") {
                            do {
                                try AgentPhoneContext.Store().add(.init(id: person.id, title: person.name, facts: person.facts, source: "Kontakter på iPhone", date: .now), bot: bot.id)
                                onResult(person.facts + "\n\nKilde: Kontakter på iPhone. Ingen besked er sendt eller opkald foretaget.")
                                notice = "Kontakten er valgt til \(bot.name)s næste opgave. Ved flere numre/adresser skal du vælge, hvilken der skal bruges."
                            } catch { notice = error.localizedDescription }
                        }.frame(minHeight: 44)
                    }
                }
            }.scrollContentBackground(.hidden).background { FadedBackground() }.navigationTitle("Kontakter").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { operation?.cancel(); dismiss() } }
                .onAppear { if query.isEmpty { query = initialQuery; if !query.isEmpty { search() } } }
                .onDisappear { operation?.cancel() }
        }
    }
    private func phoneURL(_ value: String) -> URL? {
        let digits = value.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty, digits.count <= 24 else { return nil }; return URL(string: "tel:" + digits)
    }
    private func search() {
        guard !busy else { return }; busy = true; people = []; notice = nil
        let requested = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        operation = Task {
            defer { busy = false }
            do {
                let store = CNContactStore()
                guard try await store.requestAccess(for: .contacts) else { notice = "Giv FadedAI adgang til de kontakter, du vil bruge, i iPhones indstillinger."; return }
                try Task.checkCancellation()
                let work = Task.detached(priority: .userInitiated) { () throws -> [Person] in
                    let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
                    let request = CNContactFetchRequest(keysToFetch: keys); request.predicate = CNContact.predicateForContacts(matchingName: requested)
                    var found: [Person] = []
                    try CNContactStore().enumerateContacts(with: request) { contact, stop in
                        if Task.isCancelled || found.count >= 12 { stop.pointee = true; return }
                        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                        found.append(.init(id: contact.identifier, name: String((name.isEmpty ? contact.organizationName : name).prefix(100)),
                            phones: Array(Set(contact.phoneNumbers.map { $0.value.stringValue })).filter { $0.count <= 80 }.sorted().prefix(4).map { $0 },
                            emails: Array(Set(contact.emailAddresses.map { String($0.value) })).filter { $0.count <= 254 }.sorted().prefix(4).map { $0 }))
                    }
                    return found
                }
                people = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                if people.isEmpty { notice = "Ingen kontakt matcher i de kontakter, FadedAI har adgang til." }
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
}
