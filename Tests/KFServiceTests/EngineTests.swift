import XCTest
@testable import KFService

final class EngineTests: XCTestCase {

    @MainActor
    func testEngineRunWithEmptyTasksDoesNotCrash() async throws {
        try await Engine.run(tasks: [])
    }

    @MainActor
    func testEngineDelegate() async throws {
        class MockDelegate: StartupDelegate {
            var phases: [StartupPhase] = []
            var completedReport: StartupReport?
            var failedError: Error?

            func startupDidUpdatePhase(_ phase: StartupPhase) {
                phases.append(phase)
            }
            func startupDidComplete(with report: StartupReport) {
                completedReport = report
            }
            func startupDidFail(with error: Error) {
                failedError = error
            }
        }

        let delegate = MockDelegate()
        try await Engine.run(tasks: [], delegate: delegate)
        XCTAssertTrue(delegate.phases.contains { phase in
            if case .startupCompleted = phase { return true }; return false
        })
    }

    @MainActor
    func testEngineRunWithTasks() async throws {
        final class SimpleTask: BaseStartupTask {
            override var identifier: String { "test" }
            override func run() async throws {}
        }

        try await Engine.run(tasks: [SimpleTask()])
    }

    @MainActor
    func testEngineRejectsDuplicateIDs() async throws {
        final class TaskA: BaseStartupTask {
            override var identifier: String { "dup" }
            override func run() async throws {}
        }
        final class TaskB: BaseStartupTask {
            override var identifier: String { "dup" }
            override func run() async throws {}
        }

        do {
            try await Engine.run(tasks: [TaskA(), TaskB()])
            XCTFail("should throw duplicateTaskIDs")
        } catch let error as StartupError {
            guard case .duplicateTaskIDs = error else {
                XCTFail("expected duplicateTaskIDs, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testEngineWithTracing() async throws {
        final class SimpleTask: BaseStartupTask {
            override var identifier: String { "tracing-test" }
            override func run() async throws {}
        }

        class TraceDelegate: StartupDelegate {
            var report: StartupReport?
            func startupDidComplete(with report: StartupReport) { self.report = report }
        }

        let delegate = TraceDelegate()
        try await Engine.run(tasks: [SimpleTask()], config: .init(enableTracing: true), delegate: delegate)
        XCTAssertNotNil(delegate.report)
    }
}
