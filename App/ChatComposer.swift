// Owns the fixed chat input surface, staged attachments and send/stop controls.

import Foundation
import SwiftUI

struct ChatComposer<Content: View>: View {
    @Environment(\.fadedPalette) private var palette
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, FadedSpacing.s).padding(.vertical, 5)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(palette.border).allowsHitTesting(false) }
    }
}

extension ChatView {
    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let deleted = removedTurns.last, deleted.expiresAt > ContinuousClock.now { undoBar }
            if let chatNotice { Text(chatNotice).font(.caption).foregroundStyle(palette.secondary) }
            ChatComposer {
                if let attachedNote {
                    HStack {
                        Label("Note: \(String(attachedNote.prefix(80)))", systemImage: "note.text")
                            .lineLimit(1)
                            .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
                        Spacer()
                        Button("Fjern note", systemImage: "xmark") { self.attachedNote = nil }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                }
                if let attachedQuote {
                    HStack {
                        Label("Citat: \(String(attachedQuote.prefix(80)))", systemImage: "quote.opening")
                            .lineLimit(1).font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
                        Spacer()
                        Button("Fjern citat", systemImage: "xmark") { self.attachedQuote = nil }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                }
                HStack(alignment: .bottom, spacing: 4) {
                    Button("Flere handlinger", systemImage: "plus") {
                        composerFocused = false
                        choosingNote = false
                        newNote = ""
                        showComposerTools = true
                    }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(task != nil)
                    TextField("Skriv en besked…", text: $draft, axis: .vertical)
                        .lineLimit(1...4).frame(minHeight: 44).focused($composerFocused)
                        .dropDestination(for: StudioPhotoInput.self) { items, _ in acceptDroppedPhotos(items) }
                        .accessibilityHint("Træk et billede hertil for at analysere det")
                    dictationAction.disabled(task != nil)
                    sendControl
                }
                if let problem = dictation.problem { Text(problem).font(.caption).foregroundStyle(palette.secondary) }
            }

            HStack(alignment: .firstTextBaseline) {
                Label("Sendes til: \(demo ? "Demo" : effectiveReplySource.rawValue)", systemImage: demo ? "testtube.2" : effectiveReplySource.icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(demo || !palette.isDark ? palette.secondary : sourceColor(effectiveReplySource))
                if effectiveReplySource == .phone, phoneBatteryLevel >= 0, phoneBatteryLevel < 0.20,
                   PhoneModels.liteModeActive(for: phoneModel), resolvedRoute.modelID == PhoneModels.effectiveModelID(phoneModel) {
                    Label("Lite Mode", systemImage: "battery.25percent").font(.caption).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 4)
                Text("\(transportMessage.unicodeScalars.count) / 2.000").font(.caption.monospacedDigit())
                    .foregroundStyle(transportMessage.unicodeScalars.count > 2000 ? palette.coralText : palette.secondary)
            }
            if let modelRoutingNotice { FadedDetailText(modelRoutingNotice) }
            if !demo, effectiveReplySource == .phone, !PhoneModels.isReady(resolvedRoute.modelID ?? phoneModel) {
                FadedDetailText("Telefonmodellen er ikke klar. Din kladde bliver gemt.")
                FadedSecondaryButton("Åbn lokale modeller", icon: "iphone") { showPhoneModelSetup = true }
                    .disabled(task != nil)
            }
            if let sourceNote { Text(sourceNote).font(.caption).foregroundStyle(palette.secondary) }
        }
        .padding(.horizontal, FadedSpacing.m).padding(.vertical, 6)
        .background(palette.background)
    }

    private var sendControl: some View {
        let sending = task != nil
        let allowed = sending || (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && transportMessage.unicodeScalars.count <= 2000 && canSendToSource)
        return Button {
            if sending { stop() }
            else { send() }
        } label: {
            Image(systemName: sending ? "stop.fill" : (effectiveReplySource == .pc && canQueuePC ? "tray.and.arrow.down" : "arrow.up"))
                .font(.body.weight(.bold)).foregroundStyle(Color.black)
                .frame(width: 40, height: 40).background(palette.lime.opacity(allowed ? 1 : 0.45), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sending ? "Stop modtagelse" : (demo ? "Send testbesked" :
            (effectiveReplySource == .pc && canQueuePC ? "Sæt besked i udbakke til PC" : "Send til \(effectiveReplySource.rawValue)")))
        .disabled(!allowed)
    }

    private var dictationAction: some View {
        Button {
            if dictation.active { dictation.stop() }
            else {
                let prefix = draft.isEmpty ? "" : draft + " "
                Task { await dictation.start { draft = prefix + $0 } }
            }
        } label: {
            Image(systemName: dictation.active ? "stop.circle" : "mic")
                .frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel(dictation.active ? "Stop diktering" : "Dikter chatbesked")
    }

}
