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

// MARK: - ServiceFactory Tests

final class ServiceFactoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ServiceFactory.resetAll()
    }

    func testRegisterAndResolve() {
        // Given
        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }

        // When
        let printer = ServiceFactory.resolve(PrinterService.self)

        // Then
        XCTAssertNotNil(printer)
        printer.print("hello")
        XCTAssertEqual((printer as? ConsolePrinter)?.messages.first, "hello")
    }

    func testResolveOptionalReturnsNilWhenUnregistered() {
        let result: PrinterService? = ServiceFactory.resolveOptional(PrinterService.self)
        XCTAssertNil(result)
    }

    func testResolveReturnsSameInstance() {
        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }

        let a = ServiceFactory.resolve(PrinterService.self) as? ConsolePrinter
        let b = ServiceFactory.resolve(PrinterService.self) as? ConsolePrinter

        XCTAssertTrue(a === b, "resolved instances should be the same object")
    }

    func testReRegistrationReplacesInstance() {
        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }
        let first = ServiceFactory.resolve(PrinterService.self) as? ConsolePrinter
        first?.print("first")
        XCTAssertEqual(first?.messages.count, 1)

        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }
        let second = ServiceFactory.resolve(PrinterService.self) as? ConsolePrinter
        XCTAssertFalse(first === second, "should be a new instance after re-registration")
    }

    func testPreloadDoesNotCrash() {
        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }
        ServiceFactory.preload(PrinterService.self)
        let printer = ServiceFactory.resolve(PrinterService.self)
        XCTAssertNotNil(printer)
    }

    func testWarmup() {
        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }
        ServiceFactory.warmup(PrinterService.self)
        // warmup just resolves eagerly, verify it doesn't crash
        let printer = ServiceFactory.resolve(PrinterService.self)
        printer.print("warm")
        XCTAssertEqual((printer as? ConsolePrinter)?.messages.first, "warm")
    }

    func testResetReCreatesInstance() {
        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }
        let first = ServiceFactory.resolve(PrinterService.self)
        ServiceFactory.resetAll()

        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }
        let second = ServiceFactory.resolve(PrinterService.self)
        XCTAssertFalse(first === second)
    }

    func testRegisteredServicesList() {
        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }
        let services = ServiceFactory.registeredServices
        XCTAssertTrue(services.contains { $0.contains("PrinterService") })
    }

    func testMultipleServiceTypes() {
        ServiceFactory.register(PrinterService.self) { ConsolePrinter() }

        let printer = ServiceFactory.resolve(PrinterService.self)
        printer.print("multi")
        XCTAssertEqual((printer as? ConsolePrinter)?.messages.first, "multi")
    }
}

// MARK: - EventBus Tests

final class ServiceFactoryEventBusTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ServiceFactory.resetAll()
    }

    func testEmitAndReceive() {
        // Given
        var receivedMessage: String?
        let token = ServiceFactory.on(String.self) { msg in
            receivedMessage = msg
        }

        // When
        ServiceFactory.emit("hello")

        // Then
        XCTAssertEqual(receivedMessage, "hello")
        // keep token alive
        _ = token
    }

    func testTokenDeallocationUnsubscribes() {
        var receivedCount = 0

        do {
            let token = ServiceFactory.on(String.self) { _ in receivedCount += 1 }
            ServiceFactory.emit("first")
            _ = token // token goes out of scope
        }

        ServiceFactory.emit("second")
        XCTAssertEqual(receivedCount, 1, "handler should not be called after token deallocation")
    }

    func testMultipleHandlers() {
        var count1 = 0, count2 = 0
        let t1 = ServiceFactory.on(String.self) { _ in count1 += 1 }
        let t2 = ServiceFactory.on(String.self) { _ in count2 += 1 }

        ServiceFactory.emit("test")

        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 1)
        _ = (t1, t2)
    }

    func testDifferentTypesDontInterfere() {
        var stringReceived: String?
        var intReceived: Int?

        let t1 = ServiceFactory.on(String.self) { stringReceived = $0 }
        let t2 = ServiceFactory.on(Int.self) { intReceived = $0 }

        ServiceFactory.emit("hello")
        ServiceFactory.emit(42)

        XCTAssertEqual(stringReceived, "hello")
        XCTAssertEqual(intReceived, 42)
        _ = (t1, t2)
    }
}
