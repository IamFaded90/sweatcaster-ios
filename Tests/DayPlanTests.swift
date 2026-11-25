import XCTest
@testable import SweatCaster

final class DayPlanTests: XCTestCase {
    private let zero = Date(timeIntervalSince1970: 0)
    private func date(_ minutes: Int) -> Date { zero.addingTimeInterval(Double(minutes * 60)) }
    func testTasksFitAroundMeetingsWithActualBreaks() throws {
        let a = DayPlan.Task(title: "A", minutes: 30), b = DayPlan.Task(title: "B", minutes: 30)
        let draft = DayPlan.Draft(day: zero, start: date(0), end: date(180), pause: 10, tasks: [a,b])
        let plan = try DayPlan.arrange(draft, busy: [.init(start: date(50), end: date(90), source: "Møde")])
        XCTAssertEqual(plan.slots.map(\.start), [date(0),date(100)])
        XCTAssertEqual(plan.slots.map(\.end), [date(30),date(130)])
    }
    func testShortenMoveAndSkipChangePlacementWithoutChangingSourceIDs() throws {
        var a = DayPlan.Task(title: "A", minutes: 60), b = DayPlan.Task(title: "B", minutes: 30)
        var draft = DayPlan.Draft(day: zero, start: date(0), end: date(70), pause: 10, tasks: [a,b])
        XCTAssertEqual(try DayPlan.arrange(draft, busy: []).unplaced, [b.id])
        a.minutes = 20; a.notBefore = date(40); draft.tasks = [a,b]
        XCTAssertEqual(try DayPlan.arrange(draft, busy: []).slots.first?.task, b.id)
        draft.tasks[0].skip = true; XCTAssertEqual(try DayPlan.arrange(draft, busy: []).slots.map(\.task), [b.id])
        XCTAssertEqual(draft.tasks[0].id, a.id)
    }
    func testPriorityBookedTasksAndMalformedWindows() throws {
        let old = DayPlan.Task(title: "Already booked", receipt: "Gemt i Kalender")
        let low = DayPlan.Task(title: "low", minutes: 10, priority: 0), high = DayPlan.Task(title: "high", minutes: 10, priority: 3)
        var draft = DayPlan.Draft(day: zero, start: date(0), end: date(30), pause: 0, tasks: [old,low,high])
        XCTAssertEqual(try DayPlan.arrange(draft, busy: []).slots.map(\.task), [high.id,low.id])
        draft.end = date(-1); XCTAssertThrowsError(try DayPlan.arrange(draft, busy: []))
        draft.end = date(30); draft.tasks[1].minutes = -10; XCTAssertThrowsError(try DayPlan.arrange(draft, busy: []))
    }
    func testPlanAndReceiptsSurviveReopenAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = DayPlan.Store(botID: UUID(), root: root)
        let draft = DayPlan.Draft(day: zero, start: date(0), end: date(60), tasks: [.init(title: "Call", reminderID: "native-source", receipt: "Booked")])
        try store.save(draft); XCTAssertEqual(try store.load().first?.tasks.first?.reminderID, "native-source")
        XCTAssertEqual(try store.load().first?.tasks.first?.receipt, "Booked"); try store.remove(draft.id); XCTAssertTrue(try store.load().isEmpty)
    }
}
