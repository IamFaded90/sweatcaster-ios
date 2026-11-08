import ActivityKit
import SwiftUI
import WidgetKit

private struct RenderingWidget: Widget {
    private let link = URL(string: "fadedai://video")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RenderActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label("FadedAI · Video", systemImage: "film").font(.headline)
                Text(context.isStale ? "Åbn FadedAI for ny status" : context.state.phase)
                ProgressView(value: context.state.progress)
            }
            .padding().widgetURL(link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "film") }
                DynamicIslandExpandedRegion(.trailing) {
                    progressLabel(context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.isStale ? "Åbn FadedAI for ny status" : context.state.phase).font(.caption)
                        ProgressView(value: context.state.progress)
                    }
                }
            } compactLeading: {
                Image(systemName: "film").accessibilityLabel("FadedAI-video")
            } compactTrailing: {
                progressLabel(context)
            } minimal: {
                Image(systemName: "film").accessibilityLabel("FadedAI-video")
            }
            .widgetURL(link)
        }
    }

    @ViewBuilder private func progressLabel(_ context: ActivityViewContext<RenderActivityAttributes>) -> some View {
        if context.isStale {
            Text("…").accessibilityLabel("Afventer opdatering")
        } else {
            Text(context.state.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
        }
    }
}

@main struct FadedAIWidgets: WidgetBundle {
    var body: some Widget {
        RenderingWidget()
    }
}
