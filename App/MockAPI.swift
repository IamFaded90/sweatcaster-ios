import Foundation

actor MockAPI: SweatAPI {
    private let sample = [
        Clip(id: "demo-arena", name: "Arena.mp4", duration_seconds: 30.5, width: 1920, height: 1080),
        Clip(id: "demo-final", name: "Finale.mp4", duration_seconds: 22, width: 1920, height: 1080),
        Clip(id: "demo-race", name: "Kapløb.mp4", duration_seconds: 45, width: 1920, height: 1080)
    ]
    private var queue: [Job] = []
    private var start: Date?
    private let now: @Sendable () -> Date
    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func health() -> Health { Health(api_version: "1", status: "ok") }
    func capabilities() -> Capabilities {
        Capabilities(moods: Mood.allCases, max_batch_size: 10,
                     features: .init(upload: false, cancel: true, range_preview: true),
                     dependencies: ["ffmpeg", "ffprobe", "tesseract", "ollama", "piper", "whisper", "easyocr"].map {
                         let ready = Capabilities.requiredDependencies.contains($0)
                         return .init(name: $0, ready: ready,
                                      message: ready ? "Simulated as ready in demo mode." : "Off in demo mode.")
                     })
    }
    func clips() -> Clips { Clips(clips: sample) }
    func jobs() -> Jobs { advance(); return Jobs(jobs: Array(queue.reversed())) }
    func job(_ id: String) throws -> Job { advance(); return queue[try index(id)] }
    func submit(_ batch: Batch) throws -> Jobs {
        try batch.validate(limit: 10)
        guard Set(batch.clip_ids).isSubset(of: Set(sample.map(\.id))) else { throw APIError.http(404, nil) }
        advance()
        let date = now()
        let added = batch.clip_ids.map {
            Job(id: UUID().uuidString, clip_id: $0, mood: batch.mood, status: .queued, progress: 0,
                message: "Waiting", warnings: [], created_at: date, updated_at: date)
        }
        if start == nil { start = date }
        queue += added
        return Jobs(jobs: added)
    }
    func cancel(_ id: String) throws -> Job {
        advance()
        let i = try index(id)
        if queue[i].status.active {
            if i == queue.firstIndex(where: { $0.status.active }) { start = now() }
            queue[i].status = .cancelled
            queue[i].message = "Cancelled"
            queue[i].updated_at = now()
        }
        return queue[i]
    }
    func video(_ job: Job) async throws -> URL {
        let current = try self.job(job.id)
        guard current.status == .completed else { throw APIError.http(409, nil) }
        return try await DemoMovie.make()
    }
    private func index(_ id: String) throws -> Int {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { throw APIError.http(404, nil) }
        return i
    }
    private func advance() {
        let date = now()
        let stages: [(Stage, String, Double)] = [
            (.analyzing, "Reading the clip", 0.15),
            (.commentating, "Writing the English reaction", 0.40),
            (.synthesizing, "Creating the voice", 0.60),
            (.rendering, "Building the vertical video", 0.80)
        ]
        while let i = queue.firstIndex(where: { $0.status.active }) {
            let begin = start ?? date
            let elapsed = max(0, date.timeIntervalSince(begin))
            if elapsed >= 8 {
                let finished = begin.addingTimeInterval(8)
                queue[i].status = .completed
                queue[i].message = "Ready"
                queue[i].progress = 1
                queue[i].updated_at = finished
                queue[i].output_url = "/api/v1/jobs/\(queue[i].id)/video"
                start = finished
            } else {
                let (status, message, progress) = stages[Int(elapsed / 2)]
                if queue[i].status == status { return }
                queue[i].status = status
                queue[i].message = message
                queue[i].progress = progress
                queue[i].updated_at = date
                return
            }
        }
        start = nil
    }
}
