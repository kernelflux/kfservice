import XCTest
@testable import KFService

final class EngineTests: XCTestCase {

    func testEngineRunDoesNotCrash() async throws {
        // Engine.run() in v2 compatibility mode
        try await Engine.run()
    }

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
        Engine.delegate = delegate

        try await Engine.run()

        // In v2 mode, we only get .startupStarted and .startupCompleted
        XCTAssertTrue(delegate.phases.contains(where: { phase in
            if case .startupStarted = phase { return true }
            return false
        }))
        XCTAssertTrue(delegate.phases.contains(where: { phase in
            if case .startupCompleted = phase { return true }
            return false
        }))
    }
}

final class StartupSchedulerTests: XCTestCase {

    func testEmptyLayers() async throws {
        let scheduler = StartupScheduler()
        try await scheduler.executeLayers([], stage: .initialization)
        // should not crash
    }

    func testSingleLayer() async throws {
        var executed = false
        let graph = DependencyGraph {
            ModuleNode(id: "Test", dependencies: []) {
                executed = true
            }
        }
        let layers = try graph.topologicalSort()
        let scheduler = StartupScheduler()
        try await scheduler.executeLayers(layers, stage: .initialization)
        XCTAssertTrue(executed)
    }

    func testOrderedExecution() async throws {
        var order: [String] = []
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: []) {
                order.append("A")
            }
            ModuleNode(id: "B", dependencies: ["A"]) {
                order.append("B")
            }
            ModuleNode(id: "C", dependencies: ["A"]) {
                order.append("C")
            }
        }
        let layers = try graph.topologicalSort()
        let scheduler = StartupScheduler()
        try await scheduler.executeLayers(layers, stage: .initialization)

        // A must be first
        XCTAssertEqual(order.first, "A")
        // B and C both depend on A, order between them is non-deterministic
        XCTAssertTrue(order.contains("B"))
        XCTAssertTrue(order.contains("C"))
    }

    func testTracerRecordsSpans() async throws {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: []) { }
        }
        let layers = try graph.topologicalSort()
        let scheduler = StartupScheduler()
        try await scheduler.executeLayers(layers, stage: .initialization)

        let report = scheduler.tracer.report()
        XCTAssertFalse(report.spans.isEmpty)
    }
}
