import SwiftUI

extension Home {
    // Keep each overloaded modifier in its own expression for Swift's type checker.
    private var homeNavigationFeedback: some View {
        let trigger: String = appHaptics ? (selectedModuleTab ?? space.rawValue) : ""
        return homeLifecycle
            .sensoryFeedback(SensoryFeedback.impact(weight: .light), trigger: trigger)
    }

    private var homeCompletedFeedback: some View {
        let completed: [String] = model.jobs.filter { $0.status == .completed }.map(\.id)
        return homeNavigationFeedback
            .sensoryFeedback(SensoryFeedback.success, trigger: completed, condition: shouldPlayJobFeedback)
    }

    private var homeRenderingFeedback: some View {
        let rendering: [String] = model.jobs.filter { $0.status == .rendering }.map(\.id)
        return homeCompletedFeedback
            .sensoryFeedback(SensoryFeedback.impact(weight: .light), trigger: rendering, condition: shouldPlayJobFeedback)
    }

    var homeFeedback: some View {
        let failed: [String] = model.jobs.filter { $0.status == .failed }.map(\.id)
        return homeRenderingFeedback
            .sensoryFeedback(SensoryFeedback.error, trigger: failed, condition: shouldPlayJobFeedback)
    }

    private func shouldPlayJobFeedback(_ old: [String], _ new: [String]) -> Bool {
        appHaptics && !Set<String>(new).subtracting(old).isEmpty
    }
}
