import Foundation

/// One ordered queue for external observations, own writes, and sensitive-value barriers.
public actor HistoryIngestor {
    public enum Event: Equatable, Sendable {
        case saved(Int64), skippedSensitive(Int64), failed(Int64), overloaded
    }

    private struct Job: Sendable {
        let sequence: Int64
        let byteCount: Int
        let prepare: @Sendable () async throws -> ClipboardSnapshot
    }

    private enum Command {
        case job(Job)
        case sensitive(Set<ContentDigest>, CheckedContinuation<Void, any Error>)
    }

    private let store: HistoryStore
    private var commands: [Command] = []
    private var sensitive: Set<ContentDigest> = []
    private var active = false
    private var outstandingCount = 0
    private var outstandingBytes = 0
    private var lastSequence: Int64
    private var events: [Event] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var isSuspended = false
    public private(set) var overloadCount: UInt64 = 0

    public init(store: HistoryStore, lastSequence: Int64 = 0) {
        self.store = store
        self.lastSequence = lastSequence
    }

    public func enqueue(_ snapshot: ClipboardSnapshot) throws {
        try enqueue(sequence: snapshot.observedSequence, byteCount: snapshot.content.byteCount) { snapshot }
    }

    /// Reserve the order BEFORE image conversion; the closure runs only in this consumer.
    public func enqueue(sequence: Int64, byteCount: Int,
                        prepare: @escaping @Sendable () async throws -> ClipboardSnapshot) throws {
        guard !isSuspended else { throw CoreError.historySuspended }
        guard sequence > lastSequence else { throw CoreError.sequenceOutOfOrder }
        guard byteCount >= 0, outstandingCount < AppLimits.historyQueueCount,
              byteCount <= AppLimits.historyQueueBytes - outstandingBytes else {
            overloadCount += 1
            record(.overloaded)
            throw CoreError.queueFull
        }
        lastSequence = sequence
        outstandingCount += 1
        outstandingBytes += byteCount
        commands.append(.job(Job(sequence: sequence, byteCount: byteCount, prepare: prepare)))
        start()
    }

    public func registerSensitiveText(_ text: String) async throws {
        guard !text.isEmpty else { return }
        try await registerSensitiveDigest(ContentDigest(data: Data(text.utf8)))
    }

    public func registerSensitiveDigest(_ digest: ContentDigest) async throws {
        sensitive.insert(digest) // Blocks pending/new jobs immediately.
        try await withCheckedThrowingContinuation { continuation in
            commands.append(.sensitive([digest], continuation))
            start()
        }
    }

    public func waitUntilIdle() async {
        if !active { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func takeEvents() -> [Event] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    public func resume() { isSuspended = false }

    private func start() {
        guard !active else { return }
        active = true
        Task { await drain() }
    }

    private func drain() async {
        while !commands.isEmpty {
            // ponytail: at most four payloads; an Array is enough for this queue.
            let command = commands.removeFirst()
            switch command {
            case .sensitive(let digests, let continuation):
                do {
                    try await store.removeText(matching: digests)
                    continuation.resume()
                } catch {
                    isSuspended = true
                    continuation.resume(throwing: error)
                }
            case .job(let job):
                if !isSuspended {
                    do {
                        let snapshot = try await job.prepare()
                        guard snapshot.observedSequence == job.sequence else { throw CoreError.sequenceOutOfOrder }
                        if case .text(let text) = snapshot.content, sensitive.contains(text.plainDigest) {
                            record(.skippedSensitive(job.sequence))
                        } else {
                            try await store.append(snapshot)
                            record(.saved(job.sequence))
                        }
                    } catch {
                        isSuspended = true
                        record(.failed(job.sequence))
                    }
                } else {
                    record(.failed(job.sequence))
                }
                outstandingCount -= 1
                outstandingBytes -= job.byteCount
            }
        }
        active = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func record(_ event: Event) {
        events.append(event)
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
}
