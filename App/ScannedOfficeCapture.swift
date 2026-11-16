import AVFoundation
import RoomPlan
import SwiftUI
import UIKit

@MainActor struct ScannedOfficeCapture: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let onSaved: (ScannedOfficeRoom) -> Void
    @State private var finish = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    FadedEmptyState(icon: "viewfinder", title: "Rummet kunne ikke gemmes", detail: failure,
                                    actionTitle: "Luk") { dismiss() }
                        .padding(FadedSpacing.edge)
                } else {
                    CaptureSurface(finish: finish, saved: { result in
                        do {
                            let room = try ScannedOfficeStore.capture(result.get())
                            onSaved(room)
                            dismiss()
                        } catch {
                            failure = "Prøv at scanne langsomt langs alle væggene i rummet."
                        }
                    })
                    .safeAreaInset(edge: .bottom) {
                        Group {
                            if finish { ProgressView("Gør rummet klar…") }
                            else { FadedPrimaryButton("Gem scanningen", icon: "checkmark") { finish = true } }
                        }
                        .padding(FadedSpacing.edge)
                        .background(.regularMaterial)
                    }
                }
            }
            .navigationTitle("Scan mit værelse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuller") { dismiss() } } }
            .onChange(of: phase) { if phase == .background { dismiss() } }
            .privacySensitive()
        }
    }

    private struct CaptureSurface: UIViewRepresentable {
        let finish: Bool
        let saved: (Result<CapturedRoom, any Error>) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(saved: saved) }

        func makeUIView(context: Context) -> RoomCaptureView {
            let view = RoomCaptureView(frame: .zero)
            view.delegate = context.coordinator
            view.captureSession.run(configuration: RoomCaptureSession.Configuration())
            return view
        }

        func updateUIView(_ view: RoomCaptureView, context: Context) {
            if finish, !context.coordinator.finishing {
                context.coordinator.finishing = true
                view.captureSession.stop(pauseARSession: true)
            }
        }

        static func dismantleUIView(_ view: RoomCaptureView, coordinator: Coordinator) {
            coordinator.cancelled = true
            view.delegate = nil
            if !coordinator.finishing { view.captureSession.stop(pauseARSession: true) }
        }

        final class Coordinator: NSObject, RoomCaptureViewDelegate {
            let saved: (Result<CapturedRoom, any Error>) -> Void
            var finishing = false
            var cancelled = false
            private var delivered = false

            init(saved: @escaping (Result<CapturedRoom, any Error>) -> Void) { self.saved = saved }

            func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
                guard !cancelled else { return false }
                if let error {
                    deliver(.failure(error))
                    return false
                }
                return finishing
            }

            func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
                guard finishing else { return }
                if let error { deliver(.failure(error)) }
                else { deliver(.success(processedResult)) }
            }

            private func deliver(_ result: Result<CapturedRoom, any Error>) {
                guard !cancelled, !delivered else { return }
                delivered = true
                saved(result)
            }
        }
    }
}
