import CastBrowserFeature
import SwiftUI

struct EntertainmentView<Content: View>: View {
    let isSelected: Bool
    let background: AnyView
    let showsPlaybackControls: Bool
    let onOpen: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        CastBrowserHost(isSelected: isSelected, background: background,
                        showsPlaybackControls: showsPlaybackControls, onOpen: onOpen, content: content)
    }
}
