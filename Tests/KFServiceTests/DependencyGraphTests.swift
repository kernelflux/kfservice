import XCTest
@testable import KFService

final class DependencyGraphTests: XCTestCase {

    // MARK: - Topological Sort

    func testEmptyGraph() throws {
        let graph = DependencyGraph()
        let layers = try graph.topologicalSort()
        XCTAssertTrue(layers.isEmpty)
    }

    func testSingleNode() throws {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: [])
        }
        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A"])
    }

    func testLinearDependencyChain() throws {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: [])
            ModuleNode(id: "B", dependencies: ["A"])
            ModuleNode(id: "C", dependencies: ["B"])
        }
        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A"])
        XCTAssertEqual(layers[1].map(\.id.rawValue), ["B"])
        XCTAssertEqual(layers[2].map(\.id.rawValue), ["C"])
    }

    func testParallelNodes() throws {
        let graph = DependencyGraph {
            ModuleNode(id: "Log", dependencies: [])
            ModuleNode(id: "KV", dependencies: [])
            ModuleNode(id: "Crash", dependencies: ["Log"])
        }
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
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: [])
            ModuleNode(id: "B", dependencies: ["A"])
            ModuleNode(id: "C", dependencies: ["A"])
            ModuleNode(id: "D", dependencies: ["B", "C"])
        }
        let layers = try graph.topologicalSort()
        // Layer 0: A
        // Layer 1: B, C (parallel)
        // Layer 2: D
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A"])
        XCTAssertEqual(layers[1].count, 2)
        XCTAssertEqual(layers[2].map(\.id.rawValue), ["D"])
    }

    func testPriorityOrderingWithinLayer() throws {
        let graph = DependencyGraph {
            ModuleNode(id: "B", dependencies: [], priority: 200)
            ModuleNode(id: "A", dependencies: [], priority: 100)
            ModuleNode(id: "C", dependencies: [], priority: 300)
        }
        let layers = try graph.topologicalSort()
        // Should be sorted by priority: A, B, C
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A", "B", "C"])
    }

    func testDiamondDependency() throws {
        // Log → Crash
        // Log → Analytics
        // Crash → Report
        // Analytics → Report
        let graph = DependencyGraph {
            ModuleNode(id: "Log", dependencies: [])
            ModuleNode(id: "Crash", dependencies: ["Log"])
            ModuleNode(id: "Analytics", dependencies: ["Log"])
            ModuleNode(id: "Report", dependencies: ["Crash", "Analytics"])
        }
        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["Log"])
        XCTAssertEqual(layers[1].count, 2) // Crash + Analytics
        XCTAssertEqual(layers[2].map(\.id.rawValue), ["Report"])
    }

    // MARK: - Cycle Detection

    func testSimpleCycle() {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: ["B"])
            ModuleNode(id: "B", dependencies: ["A"])
        }
        let cycles = graph.detectCycles()
        XCTAssertFalse(cycles.isEmpty)
        let cycleIDs = cycles[0].map(\.rawValue).sorted()
        XCTAssertEqual(cycleIDs, ["A", "B"])
    }

    func testSelfCycle() {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: ["A"])
        }
        let cycles = graph.detectCycles()
        XCTAssertFalse(cycles.isEmpty, "A -> A is a self-cycle")
    }

    func testNoCycle() {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: [])
            ModuleNode(id: "B", dependencies: ["A"])
        }
        let cycles = graph.detectCycles()
        XCTAssertTrue(cycles.isEmpty)
    }

    func testCycleInTopologicalSortThrows() {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: ["B"])
            ModuleNode(id: "B", dependencies: ["A"])
        }
        XCTAssertThrowsError(try graph.topologicalSort()) { error in
            guard case GraphError.cycleDetected = error else {
                XCTFail("Expected cycleDetected error")
                return
            }
        }
    }

    // MARK: - Validation

    func testDuplicateIDs() {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: [])
            ModuleNode(id: "A", dependencies: [])
        }
        XCTAssertThrowsError(try graph.validate()) { error in
            guard case GraphError.duplicateIDs = error else {
                XCTFail("Expected duplicateIDs error")
                return
            }
        }
    }

    func testMissingDependency() {
        let graph = DependencyGraph {
            ModuleNode(id: "A", dependencies: ["NonExistent"])
        }
        XCTAssertThrowsError(try graph.validate()) { error in
            guard case GraphError.missingDependency = error else {
                XCTFail("Expected missingDependency error")
                return
            }
        }
    }

    func testValidGraphPassesValidation() throws {
        let graph = DependencyGraph {
            ModuleNode(id: "Log", dependencies: [])
            ModuleNode(id: "Crash", dependencies: ["Log"])
        }
        XCTAssertNoThrow(try graph.validate())
    }

    // MARK: - Add Node

    func testAddNodeDynamically() throws {
        var graph = DependencyGraph()
        graph.add(ModuleNode(id: "A", dependencies: []))
        graph.add(ModuleNode(id: "B", dependencies: ["A"]))

        let layers = try graph.topologicalSort()
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0].map(\.id.rawValue), ["A"])
        XCTAssertEqual(layers[1].map(\.id.rawValue), ["B"])
    }
}
