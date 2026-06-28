import XCTest
@testable import KFService

final class DependencyGraphTests: XCTestCase {

    // MARK: - Topological Sort

    func testEmptyGraph() throws {
        var graph = DependencyGraph()
        let layers = try graph.topologicalSort()
        XCTAssertTrue(layers.isEmpty)
    }

    func testSingleNode() throws {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", factory: {}))
        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A"])
    }

    func testLinearDependencyChain() throws {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", factory: {}))
        graph.add(ModuleNode(id: "B", dependencies: ["A"], factory: {}))
        graph.add(ModuleNode(id: "C", dependencies: ["B"], factory: {}))
        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A"])
        XCTAssertEqual(layers[1].map(\.id.rawValue), ["B"])
        XCTAssertEqual(layers[2].map(\.id.rawValue), ["C"])
    }

    func testParallelNodes() throws {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "Log", factory: {}))
        graph.add(ModuleNode(id: "KV", factory: {}))
        graph.add(ModuleNode(id: "Crash", dependencies: ["Log"], factory: {}))
        let layers = try graph.topologicalSort()
        // Log and KV are both in layer 0 (no dependencies)
        XCTAssertEqual(layers[0].count, 2)
        XCTAssertTrue(layers[0].contains(where: { $0.id.rawValue == "Log" }))
        XCTAssertTrue(layers[0].contains(where: { $0.id.rawValue == "KV" }))
        // Crash depends on Log, so it's in layer 1
        XCTAssertEqual(layers[1].map(\.id.rawValue), ["Crash"])
    }

    func testComplexDAG() throws {
        // A → B → D
        // A → C → D
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", factory: {}))
        graph.add(ModuleNode(id: "B", dependencies: ["A"], factory: {}))
        graph.add(ModuleNode(id: "C", dependencies: ["A"], factory: {}))
        graph.add(ModuleNode(id: "D", dependencies: ["B", "C"], factory: {}))
        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A"])
        XCTAssertEqual(layers[1].count, 2)
        XCTAssertEqual(layers[2].map(\.id.rawValue), ["D"])
    }

    func testPriorityOrderingWithinLayer() throws {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "B", priority: 200, factory: {}))
        graph.add(ModuleNode(id: "A", priority: 100, factory: {}))
        graph.add(ModuleNode(id: "C", priority: 300, factory: {}))
        let layers = try graph.topologicalSort()
        // Should be sorted by priority: A, B, C
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A", "B", "C"])
    }

    func testDiamondDependency() throws {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "Log", factory: {}))
        graph.add(ModuleNode(id: "Crash", dependencies: ["Log"], factory: {}))
        graph.add(ModuleNode(id: "Analytics", dependencies: ["Log"], factory: {}))
        graph.add(ModuleNode(id: "Report", dependencies: ["Crash", "Analytics"], factory: {}))
        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["Log"])
        XCTAssertEqual(layers[1].count, 2) // Crash + Analytics
        XCTAssertEqual(layers[2].map(\.id.rawValue), ["Report"])
    }

    // MARK: - Cycle Detection

    func testSimpleCycle() {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", dependencies: ["B"], factory: {}))
        graph.add(ModuleNode(id: "B", dependencies: ["A"], factory: {}))
        let cycles = graph.detectCycles()
        XCTAssertFalse(cycles.isEmpty)
        let cycleIDs = cycles[0].map(\.rawValue).sorted()
        XCTAssertEqual(cycleIDs, ["A", "B"])
    }

    func testSelfCycle() {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", dependencies: ["A"], factory: {}))
        let cycles = graph.detectCycles()
        XCTAssertFalse(cycles.isEmpty, "A -> A is a self-cycle")
    }

    func testNoCycle() {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", factory: {}))
        graph.add(ModuleNode(id: "B", dependencies: ["A"], factory: {}))
        let cycles = graph.detectCycles()
        XCTAssertTrue(cycles.isEmpty)
    }

    func testCycleInTopologicalSortThrows() {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", dependencies: ["B"], factory: {}))
        graph.add(ModuleNode(id: "B", dependencies: ["A"], factory: {}))
        XCTAssertThrowsError(try graph.topologicalSort()) { error in
            guard case GraphError.cycleDetected = error else {
                XCTFail("Expected cycleDetected error")
                return
            }
        }
    }

    // MARK: - Validation

    func testDuplicateIDs() {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", factory: {}))
        graph.add(ModuleNode(id: "A", factory: {}))
        XCTAssertThrowsError(try graph.validate()) { error in
            guard case GraphError.duplicateIDs = error else {
                XCTFail("Expected duplicateIDs error")
                return
            }
        }
    }

    func testMissingDependency() {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", dependencies: ["NonExistent"], factory: {}))
        XCTAssertThrowsError(try graph.validate()) { error in
            guard case GraphError.missingDependency = error else {
                XCTFail("Expected missingDependency error")
                return
            }
        }
    }

    func testValidGraphPassesValidation() throws {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "Log", factory: {}))
        graph.add(ModuleNode(id: "Crash", dependencies: ["Log"], factory: {}))
        XCTAssertNoThrow(try graph.validate())
    }

    // MARK: - Add Node

    func testAddNodeDynamically() throws {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", factory: {}))
        graph.add(ModuleNode(id: "B", dependencies: ["A"], factory: {}))

        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A"])
        XCTAssertEqual(layers[1].map(\.id.rawValue), ["B"])
    }
}
