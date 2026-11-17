import CastBrowserFeature
import SwiftUI

struct EntertainmentView<Content: View>: View {
    @State private var castWakeID = UUID()
    let isSelected: Bool
    let background: AnyView
    let showsPlaybackControls: Bool
    let api: LiveAPI?
    let onOpen: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let homeAPI = api.flatMap { $0.server.profile == .home ? $0 : nil }
        let relay: CastPCRelay? = homeAPI.map { connection in
            { source, page in try await connection.castRelayURL(source: source, page: page) }
        }
        CastBrowserHost(isSelected: isSelected, background: background,
                        showsPlaybackControls: showsPlaybackControls, onOpen: onOpen,
                        onPhoneCastWake: { ChatScreenWake.hold(castWakeID, whileReplying: $0) },
                        pcRelayID: homeAPI?.queueTargetID, pcRelay: relay, content: content)
    }
}
