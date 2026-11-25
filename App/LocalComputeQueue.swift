import Foundation

/// An active native prediction retains its slot until it actually returns, including after cancellation.
struct LocalComputeQueue {
    struct Ticket: Equatable, Sendable { let id: UUID; let revision: UInt64 }
    enum Failure: Error { case full }
    private(set) var running: Ticket?
    private(set) var waiting: [Ticket] = []
    private var revision: UInt64 = 0
    mutating func enqueue() throws -> Ticket {
        guard waiting.count < 4 else { throw Failure.full }
        let ticket = Ticket(id: UUID(), revision: revision); waiting.append(ticket); return ticket
    }
    func valid(_ ticket: Ticket) -> Bool { ticket.revision == revision && waiting.contains(ticket) }
    func canStart(_ ticket: Ticket) -> Bool { valid(ticket) && running == nil && waiting.first == ticket }
    func acceptsResult(_ ticket: Ticket, cancelled: Bool) -> Bool { !cancelled && ticket.revision == revision && running == ticket }
    mutating func start(_ ticket: Ticket) -> Bool {
        guard canStart(ticket) else { return false }; waiting.removeFirst(); running = ticket; return true
    }
    mutating func finish(_ ticket: Ticket) {
        waiting.removeAll { $0 == ticket }; if running == ticket { running = nil }
    }
    mutating func cancelWaiting() { revision &+= 1; waiting.removeAll() }
    static func fits(requiredMiB: UInt64, availableBytes: UInt64) -> Bool {
        let bytes = requiredMiB.multipliedReportingOverflow(by: 1_048_576)
        return !bytes.overflow && availableBytes >= bytes.partialValue
    }
}
