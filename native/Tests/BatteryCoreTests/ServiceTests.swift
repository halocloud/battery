import Testing
import Foundation
import Darwin
@testable import BatteryCore

private final class ConcurrencyHardware: ChargingHardware {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0
    private var gate: ChargeGate = .allowed
    func readGate() throws -> ChargeGate {
        lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
        Thread.sleep(forTimeInterval: 0.001)
        lock.lock(); defer { active -= 1; lock.unlock() }; return gate
    }
    func setGate(_ desired: ChargeGate) throws {
        lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
        Thread.sleep(forTimeInterval: 0.001)
        lock.lock(); gate = desired; active -= 1; lock.unlock()
    }
    func diagnostics() -> [String: String] { [:] }
}

@Suite(.serialized)
final class ServiceTests {
    @Test func testConcurrentRequestsAreSerializedAndAllReceiveReplies() throws {
        let hardware = ConcurrencyHardware(), store = MockStore(), monitor = MockMonitor()
        let machine = Machine(model: "MacTest,1", osBuild: "test")
        let c = BatteryController(hardware: hardware, monitor: monitor, store: store, machine: machine,
                                  profile: .init(model: machine.model, osBuild: machine.osBuild, validated: true, evidence: "fixture"))
        let service = BatteryService(controller: c, clientRequirement: "unused in direct queue test")
        let completed = DispatchGroup()
        for index in 0..<40 {
            completed.enter()
            let data = try Wire.encode(Request(.limit, limit: index % 2 == 0 ? 70 : 90))
            DispatchQueue.global().async {
                service.perform(data, uid: 0) { response in
                    do { #expect(try Wire.decode(Response.self, response).errorCode == nil) }
                    catch { Issue.record("Invalid service response: \(error)") }
                    completed.leave()
                }
            }
        }
        #expect(completed.wait(timeout: .now() + 10) == .success)
        #expect((hardware.maximum) == (1))
        #expect((store.saved.count) == (40))
    }
    @Test func testOversizedMalformedAndUnauthorizedMessagesDoNotTouchHardware() throws {
        let hardware = MockHardware(), store = MockStore()
        let c = BatteryController(hardware: hardware, monitor: MockMonitor(), store: store,
                                  machine: .init(model: "test", osBuild: "test"), profile: nil)
        let service = BatteryService(controller: c, clientRequirement: "unused")
        let requests: [(Data, uid_t, FailureCode)] = [
            (Data(repeating: 0, count: 4097), 0, .invalidArgument),
            (Data("broken".utf8), 0, .invalidArgument),
            (try Wire.encode(Request(.disable)), 65_534, .unauthorized),
            (try Wire.encode(Request(.prepareUpgrade)), 501, .unauthorized)
        ]
        let done = DispatchGroup()
        for (data, uid, expected) in requests {
            done.enter()
            service.perform(data, uid: uid) { reply in
                #expect((try? Wire.decode(Response.self, reply).errorCode) == (expected))
                done.leave()
            }
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect((hardware.reads) == (0)); #expect(hardware.writes.isEmpty); #expect(store.saved.isEmpty)
    }
}
