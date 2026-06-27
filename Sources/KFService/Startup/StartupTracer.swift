import Foundation

// MARK: - StartupTracer

/// 启动性能追踪器。
public final class StartupTracer: @unchecked Sendable {

    public struct Span: Sendable {
        public let moduleID: ModuleID
        public let stage: Stage
        public let start: ContinuousClock.Instant
        public let end: ContinuousClock.Instant
        public var duration: Duration { start.duration(to: end) }
    }

    private var spans: [Span] = []
    private let lock = NSLock()
    private let clock = ContinuousClock()

    public init() {}

    func begin(_ id: ModuleID, stage: Stage) {
        // 记录开始时间 — 由 StartupScheduler 在 execute 前调用
    }

    func end(_ id: ModuleID, stage: Stage) {
        let now = clock.now
        lock.lock()
        // 简化实现：记录结束 span
        let span = Span(
            moduleID: id,
            stage: stage,
            start: .now,
            end: now
        )
        spans.append(span)
        lock.unlock()
    }

    /// 生成启动报告。
    public func report() -> StartupReport {
        lock.lock()
        let snapshot = spans
        lock.unlock()

        let total = snapshot.map(\.duration).reduce(.zero, +)
        let initSpans = snapshot.filter { span in
            if case .init = span.stage { return true }
            return false
        }
        let startSpans = snapshot.filter { span in
            if case .start = span.stage { return true }
            return false
        }

        return StartupReport(
            totalDuration: total,
            initDuration: initSpans.map(\.duration).reduce(.zero, +),
            startDuration: startSpans.map(\.duration).reduce(.zero, +),
            criticalPath: [],
            parallelSavings: 0,
            bottlenecks: snapshot.filter { $0.duration > .seconds(0.5) },
            spans: snapshot
        )
    }
}

// MARK: - StartupReport

/// 启动性能报告。
public struct StartupReport: Sendable {
    public let totalDuration: Duration
    public let initDuration: Duration
    public let startDuration: Duration
    public let criticalPath: [StartupTracer.Span]
    public let parallelSavings: Double
    public let bottlenecks: [StartupTracer.Span]
    public let spans: [StartupTracer.Span]
}
