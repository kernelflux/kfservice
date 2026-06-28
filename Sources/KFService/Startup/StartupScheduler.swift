import Foundation
import os

// MARK: - Simple AsyncSemaphore

/// A simple semaphore for controlling concurrency (iOS 16 compatible).
///
/// Uses `OSAllocatedUnfairLock` for Sendable safety.
/// Remains `@unchecked Sendable` because `CheckedContinuation`
/// is not Sendable in Swift 5.9.
final class AsyncSemaphore: @unchecked Sendable {
    private let limit: Int

    private struct State {
        var count = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(value: Int) {
        self.limit = value
    }

    func wait() async {
        let shouldSuspend = state.withLock { s -> Bool in
            s.count += 1
            return s.count > limit
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                state.withLock { $0.waiters.append(continuation) }
            }
        }
    }

    func signal() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.count -= 1
            if s.count < 0 { s.count = 0 }
            guard let first = s.waiters.first else { return nil }
            s.waiters.removeFirst()
            return first
        }
        next?.resume()
    }
}

// MARK: - Stage

public enum Stage: Sendable {
    case initialization
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

/// Startup scheduler: layered parallel execution with timeout degradation.
///
/// A task failure only skips its dependents — non-dependent tasks continue.
/// All failures are collected and surfaced in the final `StartupReport`.
@MainActor
public final class StartupScheduler {

    public let config: StartupConfig
    public let tracer = StartupTracer()

    private let bgSemaphore: AsyncSemaphore

    private struct DegradationState {
        var failedIDs: Set<ModuleID> = []
    }
    private let degradationState = OSAllocatedUnfairLock(initialState: DegradationState())

    public init(config: StartupConfig = .default) {
        self.config = config
        self.bgSemaphore = AsyncSemaphore(value: config.maxBackgroundConcurrency)
    }

    /// Execute all layers, collecting failures.
    public func executeLayers(_ layers: [[ModuleNode]], stage: Stage) async -> [StartupFailure] {
        var allFailures: [StartupFailure] = []
        for (index, layer) in layers.enumerated() {
            let failures = await executeLayer(layer, layerIndex: index, stage: stage)
            allFailures.append(contentsOf: failures)
        }
        return allFailures
    }

    /// Execute one layer: MainActor serial → background parallel.
    /// Returns failures instead of throwing so degradation keeps the startup going.
    public func executeLayer(_ nodes: [ModuleNode], layerIndex: Int, stage: Stage) async -> [StartupFailure] {
        var failures: [StartupFailure] = []

        // Step 1: MainActor serial (sorted by priority)
        for node in nodes.filter({ $0.actorRequirement == .mainActor })
            .sorted(by: { $0.priority < $1.priority }) {
            if let failure = await executeNode(node, layerIndex: layerIndex, stage: stage) {
                failures.append(failure)
            }
        }

        // Step 2: Background parallel
        await withTaskGroup(of: [StartupFailure].self) { group in
            for node in nodes.filter({ $0.actorRequirement != .mainActor }) {
                group.addTask {
                    await self.bgSemaphore.wait()
                    defer { self.bgSemaphore.signal() }
                    if let failure = await self.executeNode(node, layerIndex: layerIndex, stage: stage) {
                        return [failure]
                    }
                    return []
                }
            }
            for await result in group {
                failures.append(contentsOf: result)
            }
        }

        return failures
    }

    /// Execute a single node with degradation:
    /// - Skip if a dependency already failed
    /// - Catch errors and record as failures
    /// Returns nil on success, or a StartupFailure.
    private func executeNode(_ node: ModuleNode, layerIndex: Int, stage: Stage) async -> StartupFailure? {
        // Check if any dependency failed — skip if so
        let depsFailed = degradationState.withLock { state in
            state.failedIDs.intersection(node.dependencies)
        }
        if !depsFailed.isEmpty {
            return StartupFailure(
                moduleID: node.id,
                error: StartupError.initFailed(node.id,
                    NSError(domain: "KFService", code: -1,
                            userInfo: [NSLocalizedDescriptionKey:
                                "Skipped: dependency failed — \(depsFailed.map(\.rawValue).joined(separator: ", "))"])),
                kind: .skippedDueToFailedDependency
            )
        }

        tracer.begin(node.id, stage: stage, layerIndex: layerIndex,
                     actorRequirement: node.actorRequirement)

        do {
            if let maxTime = node.maxExecTime {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await node.factory() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(maxTime))
                        throw StartupError.timeout(node.id, maxTime)
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } else {
                try await node.factory()
            }
            tracer.end(node.id, stage: stage)
            return nil
        } catch let error as StartupError {
            _ = degradationState.withLock { $0.failedIDs.insert(node.id) }
            tracer.end(node.id, stage: stage)
            if case .timeout = error {
                return StartupFailure(moduleID: node.id, error: error, kind: .timedOut)
            }
            return StartupFailure(moduleID: node.id, error: error, kind: .executionFailed)
        } catch {
            _ = degradationState.withLock { $0.failedIDs.insert(node.id) }
            tracer.end(node.id, stage: stage)
            return StartupFailure(moduleID: node.id, error: error, kind: .executionFailed)
        }
    }
}
