import Foundation

// MARK: - Simple AsyncSemaphore

/// A simple async semaphore for controlling concurrency.
actor AsyncSemaphore {
    private let limit: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.limit = value
    }

    func wait() {
        count += 1
        if count > limit {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        count -= 1
        if count < 0 { count = 0 }
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }
}

// MARK: - Stage

public enum Stage: Sendable {
    case init
    case start
}

// MARK: - StartupConfig

public struct StartupConfig: Sendable {
    public var maxBackgroundConcurrency: Int

    public init(maxBackgroundConcurrency: Int = 4) {
        self.maxBackgroundConcurrency = maxBackgroundConcurrency
    }

    public static let `default` = StartupConfig()
}

// MARK: - Unit of work

public enum ExecutorKind: Sendable {
    case mainActor
    case background
}

// MARK: - StartupScheduler

/// 启动调度器：分层并行执行 + 超时降级。
@MainActor
public final class StartupScheduler {

    public let config: StartupConfig
    public let tracer = StartupTracer()

    private let bgSemaphore: AsyncSemaphore

    public init(config: StartupConfig = .default) {
        self.config = config
        self.bgSemaphore = AsyncSemaphore(value: config.maxBackgroundConcurrency)
    }

    /// 逐层执行（同层内 MainActor 串行 + 后台并行）。
    public func executeLayers(_ layers: [[ModuleNode]], stage: Stage) async throws {
        for layer in layers {
            try await executeLayer(layer, stage: stage)
        }
    }

    private func executeLayer(_ nodes: [ModuleNode], stage: Stage) async throws {
        // Step 1: MainActor 串行
        for node in nodes.filter({ $0.actorRequirement == .mainActor })
            .sorted(by: { $0.priority < $1.priority }) {
            try await executeWithTimeout(node, stage: stage, executor: .mainActor)
        }

        // Step 2: 后台并行
        try await withThrowingDiscardingTaskGroup { group in
            for node in nodes.filter({ $0.actorRequirement != .mainActor }) {
                group.addTask {
                    await self.bgSemaphore.wait()
                    defer { self.bgSemaphore.signal() }
                    try await self.executeWithTimeout(node, stage: stage, executor: .background)
                }
            }
        }
    }

    private func executeWithTimeout(
        _ node: ModuleNode, stage: Stage, executor: ExecutorKind
    ) async throws {
        tracer.begin(node.id, stage: stage)

        if let maxTime = node.maxExecTime {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await node.factory() }
                group.addTask {
                    try await Task.sleep(for: .seconds(maxTime))
                    throw StartupError.timeout(node.id, maxTime)
                }
                try await group.next()
                group.cancelAll()
            }
        } else {
            await node.factory()
        }

        tracer.end(node.id, stage: stage)
    }
}
