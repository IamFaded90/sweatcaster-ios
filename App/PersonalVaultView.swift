import Foundation
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct VaultEntry: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var value = ""
}

private enum PersonalVaultStorage {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dk.fadedai.personal-vault",
        kSecAttrAccount as String: "entries"
    ]

    static func load() throws -> [VaultEntry] {
        var filter = query
        filter[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(filter as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw APIError.storage }
        return try JSONDecoder().decode([VaultEntry].self, from: data)
    }

    static func save(_ entries: [VaultEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw APIError.storage }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
    }
}

struct PersonalVaultView: View {
    @Environment(\.scenePhase) private var phase
    @State private var entries: [VaultEntry] = []
    @State private var editing: VaultEntry? = nil
    @State private var pendingRemoval: VaultEntry? = nil
    @State private var canWrite = false
    @State private var notice: String? = nil

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("Ingen gemte oplysninger", systemImage: "lock.doc")
            }
            ForEach(entries) { entry in
                HStack {
                    Button(entry.title) { editing = entry }
                    Spacer()
                    Button("Kopiér", systemImage: "doc.on.doc") {
                        UIPasteboard.general.setItems(
                            [[UTType.utf8PlainText.identifier: entry.value]],
                            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(60)]
                        )
                        notice = "Kopieret i ét minut."
                    }.labelStyle(.iconOnly)
                        .accessibilityLabel("Kopiér \(entry.title)")
                }
                .buttonStyle(.borderless)
                .swipeActions(allowsFullSwipe: false) {
                    Button("Slet", role: .destructive) { pendingRemoval = entry }
                }
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Vault")
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Tilføj oplysning", systemImage: "plus") { editing = VaultEntry() }
                    .disabled(!canWrite || entries.count >= 40)
            }
        }
        .onChange(of: phase, initial: true) { _, current in
            if current == .active {
                load()
            } else if current == .background {
                editing = nil
                pendingRemoval = nil
                entries = []
                canWrite = false
            }
        }
        .sheet(item: $editing) { entry in
            VaultEntryEditor(entry: entry) { updated in
                var next = entries
                if let index = next.firstIndex(where: { $0.id == updated.id }) {
                    next[index] = updated
                } else {
                    next.append(updated)
                }
                return save(next)
            }
        }
        .confirmationDialog("Slet oplysningen fra Vault?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { entry in
            Button("Slet", role: .destructive) { _ = save(entries.filter { $0.id != entry.id }) }
        }
    }

    private func load() {
        do {
            entries = try PersonalVaultStorage.load()
            canWrite = true
            notice = nil
        } catch {
            canWrite = false
            notice = "Vault kunne ikke åbnes. Lås telefonen op, og prøv igen."
        }
    }

    private func save(_ updated: [VaultEntry]) -> Bool {
        guard canWrite else { return false }
        do {
            try PersonalVaultStorage.save(updated)
            entries = updated
            notice = nil
            return true
        } catch {
            notice = "Oplysningen kunne ikke gemmes."
            return false
        }
    }
}

private struct VaultEntryEditor: View {
    @State var entry: VaultEntry
    let onSave: (VaultEntry) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Navn", text: $entry.title)
                SecureField("Oplysning", text: $entry.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if saveFailed { Text("Oplysningen kunne ikke gemmes. Prøv igen.") }
            }
            .navigationTitle("Oplysning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem") {
                        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if onSave(entry) { dismiss() } else { saveFailed = true }
                    }
                    .disabled(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              entry.title.count > 80 || entry.value.isEmpty || entry.value.utf8.count > 2048)
                }
            }
        }
    }
}
