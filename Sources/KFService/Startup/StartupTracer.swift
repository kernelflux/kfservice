import Foundation
import os

// MARK: - StartupFailure

/// Record of a task that failed during startup.
public struct StartupFailure: @unchecked Sendable {
    public let moduleID: ModuleID
    public let error: any Error
    public let kind: FailureKind

    public enum FailureKind: Sendable {
        case executionFailed
        case skippedDueToFailedDependency
        case timedOut
    }

    public init(moduleID: ModuleID, error: any Error, kind: FailureKind) {
        self.moduleID = moduleID
        self.error = error
        self.kind = kind
    }
}

// MARK: - StartupTracer

/// Startup performance tracer with real begin/end tracking.
public final class StartupTracer: Sendable {

    public struct Span: Sendable {
        public let moduleID: ModuleID
        public let stage: Stage
        public let layerIndex: Int
        public let actorRequirement: ActorRequirement
        public let start: ContinuousClock.Instant
        public let end: ContinuousClock.Instant
        public var duration: Duration { start.duration(to: end) }
    }

    private struct State {
        var spans: [Span] = []
        var pending: [ModuleID: (start: ContinuousClock.Instant, stage: Stage, layerIndex: Int, actorRequirement: ActorRequirement)] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let clock = ContinuousClock()

    public init() {}

    func begin(_ id: ModuleID, stage: Stage, layerIndex: Int, actorRequirement: ActorRequirement) {
        let now = clock.now
        state.withLock { $0.pending[id] = (now, stage, layerIndex, actorRequirement) }
    }

    func end(_ id: ModuleID, stage: Stage) {
        let now = clock.now
        state.withLock { s in
            guard let (start, _, layerIndex, actor) = s.pending.removeValue(forKey: id) else { return }
            s.spans.append(Span(moduleID: id, stage: stage, layerIndex: layerIndex,
                               actorRequirement: actor, start: start, end: now))
        }
    }

    /// Generate startup report, computing critical path and parallel savings.
    public func report(failures: [StartupFailure] = []) -> StartupReport {
        let snapshot = state.withLock { $0.spans }

        // Group spans by layer
        let byLayer = Dictionary(grouping: snapshot) { $0.layerIndex }
        let maxLayer = byLayer.keys.max() ?? -1

        var criticalPathSpans: [Span] = []
        var criticalPathDuration: Duration = .zero

        for layerIdx in 0...maxLayer {
            guard let layerSpans = byLayer[layerIdx] else { continue }
            let mainActorSpans = layerSpans.filter {
                if case .mainActor = $0.actorRequirement { return true }; return false
            }
            let nonMainSpans = layerSpans.filter {
                if case .mainActor = $0.actorRequirement { return false }; return true
            }

            // All mainActor spans are serial → all on critical path
            criticalPathSpans.append(contentsOf: mainActorSpans)
            criticalPathDuration += mainActorSpans.map(\.duration).reduce(.zero, +)

            // Longest background span is on critical path (others run parallel to it)
            if let maxBg = nonMainSpans.max(by: { $0.duration < $1.duration }) {
                criticalPathSpans.append(maxBg)
                criticalPathDuration += maxBg.duration
            }
        }

        let serialTotal = snapshot.map(\.duration).reduce(.zero, +)
        let parallelSavings = serialTotal - criticalPathDuration

        let total = snapshot.map(\.duration).reduce(.zero, +)
        let initSpans = snapshot.filter {
            if case .initialization = $0.stage { return true }
            return false
        }
        let startSpans = snapshot.filter {
            if case .start = $0.stage { return true }
            return false
        }

        return StartupReport(
            totalDuration: total,
            initDuration: initSpans.map(\.duration).reduce(.zero, +),
            startDuration: startSpans.map(\.duration).reduce(.zero, +),
            criticalPath: criticalPathSpans,
            parallelSavings: parallelSavings,
            bottlenecks: snapshot.filter { $0.duration > .seconds(0.5) },
            spans: snapshot,
            failures: failures
        )
    }
}

// MARK: - StartupReport

/// Startup performance report.
public struct StartupReport: Sendable {
    public let totalDuration: Duration
    public let initDuration: Duration
    public let startDuration: Duration
    public let criticalPath: [StartupTracer.Span]
    public let parallelSavings: Duration
    public let bottlenecks: [StartupTracer.Span]
    public let spans: [StartupTracer.Span]
    public let failures: [StartupFailure]

    public init(
        totalDuration: Duration,
        initDuration: Duration,
        startDuration: Duration,
        criticalPath: [StartupTracer.Span],
        parallelSavings: Duration,
        bottlenecks: [StartupTracer.Span],
        spans: [StartupTracer.Span],
        failures: [StartupFailure] = []
    ) {
        self.totalDuration = totalDuration
        self.initDuration = initDuration
        self.startDuration = startDuration
        self.criticalPath = criticalPath
        self.parallelSavings = parallelSavings
        self.bottlenecks = bottlenecks
        self.spans = spans
        self.failures = failures
    }
}
