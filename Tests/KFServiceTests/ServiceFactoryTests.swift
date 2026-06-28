import XCTest
@testable import KFService

// MARK: - Test Protocols

private protocol PrinterService: AnyObject {
    func print(_ message: String)
}

private final class ConsolePrinter: PrinterService {
    var messages: [String] = []
    func print(_ message: String) {
        messages.append(message)
    }
}

private final class MockPrinter: PrinterService {
    var printedMessages: [String] = []
    func print(_ message: String) {
        printedMessages.append(message)
    }
}

// MARK: - ServiceContainer Tests

final class ServiceContainerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ServiceContainer.shared.resetAll()
    }

    func testRegisterAndResolve() throws {
        // Given
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }

        // When
        let printer = try ServiceContainer.shared.resolve(PrinterService.self)

        // Then
        XCTAssertNotNil(printer)
        printer.print("hello")
        XCTAssertEqual((printer as? ConsolePrinter)?.messages.first, "hello")
    }

    func testResolveOptionalReturnsNilWhenUnregistered() {
        let result: PrinterService? = ServiceContainer.shared.resolveOptional(PrinterService.self)
        XCTAssertNil(result)
    }

    func testResolveReturnsSameInstance() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }

        let a = try ServiceContainer.shared.resolve(PrinterService.self) as? ConsolePrinter
        let b = try ServiceContainer.shared.resolve(PrinterService.self) as? ConsolePrinter

        XCTAssertTrue(a === b, "resolved instances should be the same object")
    }

    func testReRegistrationReplacesInstance() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let first = try ServiceContainer.shared.resolve(PrinterService.self) as? ConsolePrinter
        first?.print("first")
        XCTAssertEqual(first?.messages.count, 1)

        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let second = try ServiceContainer.shared.resolve(PrinterService.self) as? ConsolePrinter
        XCTAssertFalse(first === second, "should be a new instance after re-registration")
    }

    func testPreloadDoesNotCrash() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        ServiceContainer.shared.preload(PrinterService.self)
        let printer = try ServiceContainer.shared.resolve(PrinterService.self)
        XCTAssertNotNil(printer)
    }

    func testWarmup() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        try ServiceContainer.shared.warmup(PrinterService.self)
        // warmup just resolves eagerly, verify it doesn't crash
        let printer = try ServiceContainer.shared.resolve(PrinterService.self)
        printer.print("warm")
        XCTAssertEqual((printer as? ConsolePrinter)?.messages.first, "warm")
    }

    func testResetReCreatesInstance() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let first = try ServiceContainer.shared.resolve(PrinterService.self)
        ServiceContainer.shared.resetAll()

        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let second = try ServiceContainer.shared.resolve(PrinterService.self)
        XCTAssertFalse(first === second)
    }

    func testRegisteredServicesList() {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let services = ServiceContainer.shared.registeredServices
        XCTAssertTrue(services.contains { $0.contains("PrinterService") })
    }

    func testMultipleServiceTypes() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }

        let printer = try ServiceContainer.shared.resolve(PrinterService.self)
        printer.print("multi")
        XCTAssertEqual((printer as? ConsolePrinter)?.messages.first, "multi")
    }

    // MARK: - Named registration

    func testNamedRegistrationSameTypeDifferentInstances() throws {
        ServiceContainer.shared.register(PrinterService.self, name: "a") { ConsolePrinter() }
        ServiceContainer.shared.register(PrinterService.self, name: "b") { MockPrinter() }

        let a = try ServiceContainer.shared.resolve(PrinterService.self, name: "a")
        let b = try ServiceContainer.shared.resolve(PrinterService.self, name: "b")

        XCTAssertTrue(a is ConsolePrinter)
        XCTAssertTrue(b is MockPrinter)
        XCTAssertFalse((a as AnyObject) === (b as AnyObject))
    }

    func testNamedRegistrationDoesNotConflictWithUnnamed() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        ServiceContainer.shared.register(PrinterService.self, name: "mock") { MockPrinter() }

        let unnamed = try ServiceContainer.shared.resolve(PrinterService.self)
        let named = try ServiceContainer.shared.resolve(PrinterService.self, name: "mock")

        XCTAssertTrue(unnamed is ConsolePrinter)
        XCTAssertTrue(named is MockPrinter)
    }

    func testWarmupWithName() throws {
        ServiceContainer.shared.register(PrinterService.self, name: "test") { ConsolePrinter() }
        try ServiceContainer.shared.warmup(PrinterService.self, name: "test")
        let printer = try ServiceContainer.shared.resolve(PrinterService.self, name: "test")
        XCTAssertNotNil(printer)
    }

    // MARK: - Scopes

    func testTransientScopeCreatesNewInstanceEachTime() throws {
        ServiceContainer.shared.register(PrinterService.self, scope: .transient) { ConsolePrinter() }
        let a = try ServiceContainer.shared.resolve(PrinterService.self) as? ConsolePrinter
        let b = try ServiceContainer.shared.resolve(PrinterService.self) as? ConsolePrinter
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertFalse(a === b)
    }

    func testWeakScopeRecreatesAfterDealloc() throws {
        ServiceContainer.shared.register(PrinterService.self, scope: .weak) { ConsolePrinter() }
        var a: ConsolePrinter? = try ServiceContainer.shared.resolve(PrinterService.self) as? ConsolePrinter
        XCTAssertNotNil(a)
        weak var weakA = a
        a = nil // dealloc
        XCTAssertNil(weakA, "weak ref should be nil after dealloc")
        let b = try ServiceContainer.shared.resolve(PrinterService.self) as? ConsolePrinter
        XCTAssertNotNil(b)
    }

    // MARK: - Parameterized resolve

    func testParameterizedResolveOneArg() throws {
        ServiceContainer.shared.register(PrinterService.self,
            factory: { (_: ServiceContainer, _: String) in ConsolePrinter() })
        let p = try ServiceContainer.shared.resolve(PrinterService.self, argument: "debug")
        XCTAssertNotNil(p)
    }

    func testParameterizedResolvePassesCorrectArg() throws {
        final class TaggedPrinter: PrinterService {
            let tag: String
            init(tag: String) { self.tag = tag }
            func print(_ message: String) {}
        }
        ServiceContainer.shared.register(PrinterService.self,
            factory: { (_: ServiceContainer, tag: String) in TaggedPrinter(tag: tag) })
        let p = try ServiceContainer.shared.resolve(PrinterService.self, argument: "my-tag")
        XCTAssertEqual((p as? TaggedPrinter)?.tag, "my-tag")
    }

    func testParameterizedResolveTwoArgs() throws {
        final class DualPrinter: PrinterService {
            let a: String; let b: Int
            init(a: String, b: Int) { self.a = a; self.b = b }
            func print(_ message: String) {}
        }
        ServiceContainer.shared.register(PrinterService.self,
            factory: { (_: ServiceContainer, a: String, b: Int) in DualPrinter(a: a, b: b) })
        let p = try ServiceContainer.shared.resolve(PrinterService.self, arg1: "x", arg2: 42)
        XCTAssertEqual((p as? DualPrinter)?.a, "x")
        XCTAssertEqual((p as? DualPrinter)?.b, 42)
    }

    func testParameterizedResolveCreatesNewInstanceEachTime() throws {
        ServiceContainer.shared.register(PrinterService.self,
            factory: { (_: ServiceContainer, _: String) in ConsolePrinter() })
        let a = try ServiceContainer.shared.resolve(PrinterService.self, argument: "a") as? ConsolePrinter
        let b = try ServiceContainer.shared.resolve(PrinterService.self, argument: "b") as? ConsolePrinter
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertFalse(a === b, "parameterized resolve should create new instance each time")
    }

    func testParameterizedAndPlainCoexist() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        ServiceContainer.shared.register(PrinterService.self,
            factory: { (_: ServiceContainer, _: String) in ConsolePrinter() })
        let plain = try ServiceContainer.shared.resolve(PrinterService.self)
        let param = try ServiceContainer.shared.resolve(PrinterService.self, argument: "test")
        XCTAssertNotNil(plain)
        XCTAssertNotNil(param)
    }

    func testParameterizedResolveThrowsWhenNotRegistered() {
        XCTAssertThrowsError(try ServiceContainer.shared.resolve(PrinterService.self, argument: "missing"))
    }

    // MARK: - Child containers

    func testChildContainerResolvesOwnRegistration() throws {
        let child = ServiceContainer.shared.newChild()
        child.register(PrinterService.self) { ConsolePrinter() }
        let p = try child.resolve(PrinterService.self)
        XCTAssertNotNil(p)
    }

    func testChildContainerFallsBackToParent() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let child = ServiceContainer.shared.newChild()
        let p = try child.resolve(PrinterService.self)
        XCTAssertNotNil(p)
    }

    func testChildContainerOverridesParent() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let child = ServiceContainer.shared.newChild()
        child.register(PrinterService.self) { MockPrinter() }
        let p = try child.resolve(PrinterService.self)
        XCTAssertTrue(p is MockPrinter)
    }

    func testChildResetAllDoesNotAffectParent() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let child = ServiceContainer.shared.newChild()
        child.register(PrinterService.self, name: "child-only") { MockPrinter() }
        child.resetAll()

        let parentInstance = try ServiceContainer.shared.resolve(PrinterService.self)
        XCTAssertNotNil(parentInstance)
    }

    func testGrandchildFallsBackThroughChain() throws {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        let child = ServiceContainer.shared.newChild()
        let grandchild = child.newChild()
        let p = try grandchild.resolve(PrinterService.self)
        XCTAssertNotNil(p)
    }

    // MARK: - Assembly

    func testAssembly() throws {
        struct TestAssembly: ServiceAssembly {
            func assemble(container: ServiceContainer) {
                container.register(PrinterService.self) { ConsolePrinter() }
                container.register(PrinterService.self, name: "mock") { MockPrinter() }
            }
        }
        ServiceContainer.shared.install(TestAssembly())
        let p = try ServiceContainer.shared.resolve(PrinterService.self)
        let m = try ServiceContainer.shared.resolve(PrinterService.self, name: "mock")
        XCTAssertTrue(p is ConsolePrinter)
        XCTAssertTrue(m is MockPrinter)
    }
}

// MARK: - Inject Wrapper Tests

final class InjectTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ServiceContainer.shared.resetAll()
    }

    func testInjectResolves() {
        ServiceContainer.shared.register(PrinterService.self) { ConsolePrinter() }
        struct TestView {
            @Inject(PrinterService.self) var printer: any PrinterService
        }
        let view = TestView()
        XCTAssertNotNil(view.printer)
    }

    func testInjectWithName() {
        ServiceContainer.shared.register(PrinterService.self, name: "mock") { MockPrinter() }
        struct TestView {
            @Inject(PrinterService.self, name: "mock") var printer: any PrinterService
        }
        let view = TestView()
        XCTAssertTrue(view.printer is MockPrinter)
    }
}

// MARK: - EventBus Tests

final class ServiceEventBusTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ServiceEventBus.shared.reset()
    }

    func testEmitAndReceive() {
        // Given
        var receivedMessage: String?
        let token = ServiceEventBus.shared.on(String.self) { msg in
            receivedMessage = msg
        }

        // When
        ServiceEventBus.shared.emit("hello")

        // Then
        XCTAssertEqual(receivedMessage, "hello")
        // keep token alive
        _ = token
    }

    func testTokenDeallocationUnsubscribes() {
        var receivedCount = 0

        do {
            let token = ServiceEventBus.shared.on(String.self) { _ in receivedCount += 1 }
            ServiceEventBus.shared.emit("first")
            _ = token // token goes out of scope
        }

        ServiceEventBus.shared.emit("second")
        XCTAssertEqual(receivedCount, 1, "handler should not be called after token deallocation")
    }

    func testMultipleHandlers() {
        var count1 = 0, count2 = 0
        let t1 = ServiceEventBus.shared.on(String.self) { _ in count1 += 1 }
        let t2 = ServiceEventBus.shared.on(String.self) { _ in count2 += 1 }

        ServiceEventBus.shared.emit("test")

        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 1)
        _ = (t1, t2)
    }

    func testDifferentTypesDontInterfere() {
        var stringReceived: String?
        var intReceived: Int?

        let t1 = ServiceEventBus.shared.on(String.self) { stringReceived = $0 }
        let t2 = ServiceEventBus.shared.on(Int.self) { intReceived = $0 }

        ServiceEventBus.shared.emit("hello")
        ServiceEventBus.shared.emit(42)

        XCTAssertEqual(stringReceived, "hello")
        XCTAssertEqual(intReceived, 42)
        _ = (t1, t2)
    }

    // MARK: - Dispatch modes

    func testEmitAsyncMain() {
        let exp = expectation(description: "main async delivery")
        var received = false
        let token = ServiceEventBus.shared.on(String.self) { _ in received = true }

        DispatchQueue.global(qos: .default).async {
            ServiceEventBus.shared.emit("test", mode: .main)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(received)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
        _ = token
    }

    func testEmitAsyncBackground() {
        let exp = expectation(description: "background async delivery")
        var threadIsMain = true
        let token = ServiceEventBus.shared.on(String.self, mode: .posting) { _ in
            threadIsMain = Thread.isMainThread
            exp.fulfill()
        }

        ServiceEventBus.shared.emit("test", mode: .background)
        wait(for: [exp], timeout: 1)
        XCTAssertFalse(threadIsMain)
        _ = token
    }

    func testSubscriberThreadModeOverridesEmitter() {
        let exp = expectation(description: "subscriber forces main")
        var threadIsMain = false
        let token = ServiceEventBus.shared.on(String.self, mode: .main) { _ in
            threadIsMain = Thread.isMainThread
            exp.fulfill()
        }

        DispatchQueue.global(qos: .default).async {
            ServiceEventBus.shared.emit("test", mode: .posting)
        }
        wait(for: [exp], timeout: 1)
        XCTAssertTrue(threadIsMain)
        _ = token
    }
}

// MARK: - StartupModule Tests

final class StartupModuleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ServiceContainer.shared.resetAll()
    }

    func testAdHocStartupModule() {
        final class TestTask: BaseStartupTask {
            override var identifier: String { "test.task" }
            override func run() async throws {}
        }
        let task = TestTask()
        let module = AdHocStartupModule(task)
        XCTAssertEqual(module.tasks.count, 1)
        XCTAssertEqual(module.tasks.first?.identifier, "test.task")
    }

    func testAdHocStartupModuleMultiple() {
        final class TaskA: BaseStartupTask {
            override var identifier: String { "a" }
            override func run() async throws {}
        }
        final class TaskB: BaseStartupTask {
            override var identifier: String { "b" }
            override var dependencies: [String] { ["a"] }
            override func run() async throws {}
        }
        let module = AdHocStartupModule([TaskA(), TaskB()])
        XCTAssertEqual(module.tasks.count, 2)
    }

    @MainActor
    func testEngineRunWithModules() async throws {
        final class SimpleTask: BaseStartupTask {
            let id: String
            init(id: String) { self.id = id }
            override var identifier: String { id }
            override func run() async throws {}
        }

        struct TestModule: StartupModule {
            let tasks: [any StartupTask]
            init(ids: String...) {
                tasks = ids.map { SimpleTask(id: $0) }
            }
        }

        try await Engine.run(modules: [TestModule(ids: "a", "b")])
    }

    @MainActor
    func testEngineRunWithModulesFailsOnDuplicateIDs() async throws {
        final class SimpleTask: BaseStartupTask {
            let id: String
            init(id: String) { self.id = id }
            override var identifier: String { id }
            override func run() async throws {}
        }

        struct TestModule: StartupModule {
            let tasks: [any StartupTask]
            init(ids: String...) {
                tasks = ids.map { SimpleTask(id: $0) }
            }
        }

        do {
            try await Engine.run(modules: [
                TestModule(ids: "dup"),
                TestModule(ids: "dup"),
            ])
            XCTFail("should throw")
        } catch let error as StartupError {
            guard case .duplicateTaskIDs = error else { XCTFail("expected duplicateTaskIDs"); return }
        }
    }

    @MainActor
    func testEngineRunWithModuleDependencies() async throws {
        actor Recorder {
            var order: [String] = []
            func record(_ id: String) { order.append(id) }
        }
        let recorder = Recorder()

        final class TaskA: BaseStartupTask {
            let recorder: Recorder
            init(recorder: Recorder) { self.recorder = recorder }
            override var identifier: String { "a" }
            override func run() async throws { await recorder.record("a") }
        }
        final class TaskB: BaseStartupTask {
            let recorder: Recorder
            init(recorder: Recorder) { self.recorder = recorder }
            override var identifier: String { "b" }
            override var dependencies: [String] { ["a"] }
            override func run() async throws { await recorder.record("b") }
        }

        struct TestModule: StartupModule {
            let tasks: [any StartupTask]
        }

        try await Engine.run(modules: [
            TestModule(tasks: [TaskA(recorder: recorder), TaskB(recorder: recorder)]),
        ])
        let order = await recorder.order
        XCTAssertEqual(order, ["a", "b"])
    }
}
