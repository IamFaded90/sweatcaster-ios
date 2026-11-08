import ActivityKit
import SwiftUI
import WidgetKit

private struct RenderingWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RenderActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Label(context.attributes.kind == .code ? "FadedAI · Code Bot" : "FadedAI · Video", systemImage: icon(context))
                    .font(.headline)
                Text(context.isStale ? "Åbn FadedAI for ny status" : context.state.phase)
                progress(context)
            }
            .padding().widgetURL(link(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: icon(context)) }
                DynamicIslandExpandedRegion(.trailing) {
                    progressLabel(context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.isStale ? "Åbn FadedAI for ny status" : context.state.phase).font(.caption)
                        progress(context)
                    }
                }
            } compactLeading: {
                Image(systemName: icon(context)).accessibilityLabel("FadedAI")
            } compactTrailing: {
                progressLabel(context)
            } minimal: {
                Image(systemName: icon(context)).accessibilityLabel("FadedAI")
            }
            .widgetURL(link(context))
        }
    }

    private func icon(_ context: ActivityViewContext<RenderActivityAttributes>) -> String {
        context.attributes.kind == .code ? "terminal" : "film"
    }

    private func link(_ context: ActivityViewContext<RenderActivityAttributes>) -> URL? {
        URL(string: context.attributes.kind == .code ? "fadedai://code" : "fadedai://video")
    }

    @ViewBuilder private func progress(_ context: ActivityViewContext<RenderActivityAttributes>) -> some View {
        if context.state.progressIsKnown != false { ProgressView(value: context.state.progress) }
        else if context.state.isRunning == true && !context.isStale { ProgressView().accessibilityLabel(context.state.phase) }
    }

    @ViewBuilder private func progressLabel(_ context: ActivityViewContext<RenderActivityAttributes>) -> some View {
        if context.isStale {
            Text("…").accessibilityLabel("Afventer opdatering")
        } else if context.state.progressIsKnown == false {
            Image(systemName: context.state.isRunning == true ? "ellipsis" : "info.circle")
                .accessibilityLabel(context.state.phase)
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
