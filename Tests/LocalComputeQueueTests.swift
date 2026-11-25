import XCTest
@testable import SweatCaster

final class LocalComputeQueueTests: XCTestCase {
    func testFIFOAndCancellationKeepNativeOperationExclusiveUntilItReturns() throws {
        var queue = LocalComputeQueue()
        let first = try queue.enqueue(), second = try queue.enqueue()
        XCTAssertFalse(queue.start(second)); XCTAssertTrue(queue.start(first))
        XCTAssertTrue(queue.acceptsResult(first, cancelled: false)); XCTAssertFalse(queue.acceptsResult(first, cancelled: true))
        queue.cancelWaiting()
        XCTAssertFalse(queue.acceptsResult(first, cancelled: false))
        XCTAssertFalse(queue.valid(second)); XCTAssertEqual(queue.running, first)
        let fresh = try queue.enqueue(); XCTAssertFalse(queue.start(fresh))
        queue.finish(second); XCTAssertEqual(queue.running, first)
        queue.finish(first); XCTAssertTrue(queue.start(fresh))
        queue.finish(first); XCTAssertEqual(queue.running, fresh)
    }
    func testCancelledAndLowMemoryTicketsDoNotBlockNextOne() throws {
        var queue = LocalComputeQueue()
        let removed = try queue.enqueue(), next = try queue.enqueue()
        queue.finish(removed); XCTAssertTrue(queue.canStart(next))
        XCTAssertFalse(LocalComputeQueue.fits(requiredMiB: 2_000, availableBytes: 1_000 * 1_048_576))
        queue.finish(next); XCTAssertTrue(queue.waiting.isEmpty)
        XCTAssertFalse(LocalComputeQueue.fits(requiredMiB: .max, availableBytes: .max))
    }
    func testQueueIsBoundedAndOldTicketCannotRejoinAfterReset() throws {
        var queue = LocalComputeQueue(); let old = try queue.enqueue()
        for _ in 0..<3 { _ = try queue.enqueue() }
        XCTAssertThrowsError(try queue.enqueue()); queue.cancelWaiting()
        _ = try queue.enqueue(); XCTAssertFalse(queue.start(old)); XCTAssertEqual(queue.waiting.count, 1)
    }
}
