import Foundation
@testable import GhosttyTerminal
import Testing

/// Collects dispatches from the session's `@Sendable` resize closure and
/// signals a semaphore per delivery so tests can wait for the trailing-edge
/// timer without sleeping.
private final class SignallingResizeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InMemoryTerminalViewport] = []
    let delivered = DispatchSemaphore(value: 0)

    var dispatches: [InMemoryTerminalViewport] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ viewport: InMemoryTerminalViewport) {
        lock.lock()
        storage.append(viewport)
        lock.unlock()
        delivered.signal()
    }
}

@MainActor
struct InMemoryTerminalSessionDebounceTests {
    private func metrics(
        columns: UInt16,
        rows: UInt16,
        widthPixels: UInt32,
        heightPixels: UInt32
    ) -> TerminalGridMetrics {
        TerminalGridMetrics(
            columns: columns,
            rows: rows,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            cellWidthPixels: 17,
            cellHeightPixels: 37
        )
    }

    /// The rb1d.1 contract: during a geometry sweep only the LATEST geometry
    /// is delivered, once, after the quiet period — no intermediate is ever
    /// delivered late. Two back-to-back updates must produce exactly one
    /// dispatch carrying the second geometry.
    @Test
    func `trailing-edge debounce delivers only the latest geometry`() {
        let recorder = SignallingResizeRecorder()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { recorder.record($0) },
            resizeDebounceMilliseconds: 50
        )

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        session.updateViewport(metrics(columns: 120, rows: 40, widthPixels: 2040, heightPixels: 1480))

        #expect(recorder.delivered.wait(timeout: .now() + 2) == .success)
        #expect(recorder.dispatches.count == 1)
        #expect(recorder.dispatches.first?.columns == 120)
        #expect(recorder.dispatches.first?.widthPixels == 2040)

        // Over-fulfill guard: no second delivery may trail in afterwards.
        #expect(recorder.delivered.wait(timeout: .now() + .milliseconds(150)) == .timedOut)
    }

    /// 0 = off = today's behavior: every countable geometry dispatches
    /// synchronously, one per update.
    @Test
    func `zero debounce dispatches synchronously per update`() {
        let recorder = SignallingResizeRecorder()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { recorder.record($0) },
            resizeDebounceMilliseconds: 0
        )

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        session.updateViewport(metrics(columns: 120, rows: 40, widthPixels: 2040, heightPixels: 1480))

        #expect(recorder.dispatches.count == 2)
        #expect(recorder.dispatches.last?.columns == 120)
    }

    /// Default (param omitted) stays byte-for-byte today's contract.
    @Test
    func `debounce defaults to off`() {
        let recorder = SignallingResizeRecorder()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { recorder.record($0) }
        )

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        #expect(recorder.dispatches.count == 1)
    }
}
