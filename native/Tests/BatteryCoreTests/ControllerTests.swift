import Testing
import Foundation
import Darwin
@testable import BatteryCore

final class MockHardware: ChargingHardware {
    var gate: ChargeGate = .allowed
    var writes: [ChargeGate] = []
    var failRead = false, failRelease = false, failBlock = false
    var reads = 0
    func readGate() throws -> ChargeGate {
        reads += 1
        if failRead { throw BatteryError(.hardware, "read failed") }; return gate
    }
    func setGate(_ desired: ChargeGate) throws {
        writes.append(desired)
        if desired == .allowed && failRelease { throw BatteryError(.hardware, "release failed") }
        gate = desired
        if desired == .blocked && failBlock { throw BatteryError(.hardware, "partial write") }
    }
    func diagnostics() -> [String: String] { ["mock": "read-only"] }
}
final class MockMonitor: BatteryMonitoring {
    var value = BatterySnapshot(percentage: 85, externalPower: true)
    var fail = false
    func sample() throws -> BatterySnapshot {
        if fail { throw BatteryError(.hardware, "battery missing") }; return value
    }
}
final class MockStore: ConfigurationStoring {
    var configuration = Configuration()
    var owned = false, failSave = false, failOwnershipSave = false, corrupt = false
    var saved: [Configuration] = []
    var ownershipEvents: [Bool] = []
    func loadConfiguration() throws -> Configuration {
        if corrupt { throw BatteryError(.persistence, "corrupt config") }; return configuration
    }
    func saveConfiguration(_ value: Configuration) throws {
        if failSave { throw BatteryError(.persistence, "disk full") }
        configuration = value; saved.append(value)
    }
    func loadOwnership() throws -> Bool { owned }
    func saveOwnership(_ value: Bool) throws {
        if failOwnershipSave { throw BatteryError(.persistence, "journal unavailable") }
        owned = value; ownershipEvents.append(value)
    }
}

@Suite(.serialized)
final class ControllerTests {
    var hardware: MockHardware!, monitor: MockMonitor!, store: MockStore!
    var clock: Date!
    let machine = Machine(model: "MacTest,1", osBuild: "24G830")
    init() { setUp() }
    func setUp() {
        hardware = MockHardware(); monitor = MockMonitor(); store = MockStore(); clock = Date()
        sample(85)
    }
    func sample(_ percent: Int, external: Bool = true) {
        monitor.value = .init(percentage: percent, externalPower: external, sampledAt: clock)
    }
    func make(supported: Bool = true) -> BatteryController {
        BatteryController(hardware: hardware, monitor: monitor, store: store, machine: machine,
                          profile: supported ? HardwareProfile(model: machine.model, osBuild: machine.osBuild, validated: true, evidence: "unit test fixture") : nil,
                          now: { self.clock })
    }
    @Test func testEnablingBlockingAndResumingWithHysteresis() {
        let c = make(); c.start()
        #expect(hardware.writes.isEmpty)
        #expect((c.handle(Request(.limit, limit: 80), administrator: true).error) == nil)
        #expect((hardware.writes) == ([.blocked])); #expect(store.owned)
        sample(78); c.refresh(); #expect((hardware.writes) == ([.blocked]))
        sample(75); c.refresh(); #expect((hardware.writes) == ([.blocked, .allowed])); #expect(!(store.owned))
        c.refresh(); #expect((hardware.writes.count) == (2))
    }
    @Test func testInvalidOrUnauthorizedRequestPreservesCurrentPolicy() {
        let c = make(); c.start(); _ = c.handle(Request(.limit, limit: 80), administrator: true)
        let reads = hardware.reads, writes = hardware.writes, saved = store.saved.count
        #expect((c.handle(Request(.limit, limit: 101), administrator: true).errorCode) == (.invalidArgument))
        #expect((c.handle(Request(.disable), administrator: false).errorCode) == (.unauthorized))
        #expect((hardware.reads) == (reads)); #expect((hardware.writes) == (writes)); #expect((store.saved.count) == (saved))
    }
    @Test func testUnsupportedHardwareOnlyDiagnoses() {
        let c = make(supported: false); c.start()
        #expect((c.handle(Request(.limit, limit: 80), administrator: true).errorCode) == (.unsupported))
        #expect(store.saved.isEmpty); #expect(hardware.writes.isEmpty)
        #expect((c.handle(Request(.diagnose), administrator: false).status?.mode) == ("unsupported"))
    }
    @Test func testPausePersistsAndResumeReenables() {
        let c = make(); c.start(); _ = c.handle(Request(.limit, limit: 80), administrator: true)
        #expect((c.handle(Request(.pause), administrator: true).error) == nil)
        #expect((hardware.gate) == (.allowed)); #expect(store.configuration.paused)
        let restarted = make(); restarted.start()
        #expect((restarted.status().mode) == ("paused")); #expect((hardware.gate) == (.allowed))
        #expect((restarted.handle(Request(.resume), administrator: true).error) == nil)
        #expect((hardware.gate) == (.blocked))
    }
    @Test func testTopupRestoresPolicyAtFullUnplugAndTimeout() {
        for completion in ["full", "unplug", "timeout"] {
            setUp()
            let c = make(); c.start(); _ = c.handle(Request(.limit, limit: 80), administrator: true)
            #expect((c.handle(Request(.topup), administrator: true).error) == nil)
            #expect((hardware.gate) == (.allowed)); #expect((store.configuration.limit) == (80))
            if completion == "full" { sample(100) }
            if completion == "unplug" { sample(85, external: false) }
            if completion == "timeout" { clock = clock.addingTimeInterval(12 * 3600); sample(85) }
            c.refresh(); #expect((c.status().topupDeadline) == nil)
            #expect((hardware.gate) == (completion == "unplug" ? .allowed : .blocked))
        }
    }
    @Test func testTopupDoesNotSurviveRestart() {
        let c = make(); c.start(); _ = c.handle(Request(.limit, limit: 80), administrator: true)
        _ = c.handle(Request(.topup), administrator: true)
        let restarted = make(); restarted.start()
        #expect((restarted.status().topupDeadline) == nil); #expect((hardware.gate) == (.blocked))
    }
    @Test func testThreeFailuresReleaseAndLatchUntilResume() {
        let c = make(); c.start(); _ = c.handle(Request(.limit, limit: 80), administrator: true)
        monitor.fail = true
        c.refresh(); c.refresh(); #expect((hardware.gate) == (.blocked))
        c.refresh(); #expect((c.status().mode) == ("fault")); #expect((hardware.gate) == (.allowed))
        monitor.fail = false; c.refresh(); #expect((hardware.gate) == (.allowed))
        #expect((c.handle(Request(.resume), administrator: true).error) == nil); #expect((hardware.gate) == (.blocked))
    }
    @Test func testStaleSampleFaultsWithoutWaitingThreeFailures() {
        let c = make(); c.start(); _ = c.handle(Request(.limit, limit: 80), administrator: true)
        clock = clock.addingTimeInterval(91); c.refresh()
        #expect((c.status().mode) == ("fault")); #expect((hardware.gate) == (.allowed))
    }
    @Test func testPartialWriteIsJournaledAndReleased() {
        let c = make(); c.start(); hardware.failBlock = true
        #expect((c.handle(Request(.limit, limit: 80), administrator: true).errorCode) == (.hardware))
        #expect((store.ownershipEvents) == ([true, false]))
        #expect((hardware.writes) == ([.blocked, .allowed])); #expect(!(store.owned))
    }
    @Test func testFailedReleaseRetainsOwnershipForRestart() {
        let c = make(); c.start(); _ = c.handle(Request(.limit, limit: 80), administrator: true)
        hardware.failRelease = true
        #expect((c.handle(Request(.disable), administrator: true).error) != nil)
        #expect(store.owned)
        #expect(hardware.writes.filter { $0 == .allowed }.count == 1)
        hardware.failRelease = false
        let restarted = make(); restarted.start()
        #expect(!(store.owned)); #expect((hardware.gate) == (.allowed))
    }
    @Test func testCorruptStateAndFailedSaveNeverStartControl() {
        store.corrupt = true
        let corrupt = make(); corrupt.start()
        #expect((corrupt.status().mode) == ("fault"))
        #expect((corrupt.handle(Request(.resume), administrator: true).errorCode) == (.persistence))
        #expect(hardware.writes.isEmpty)
        store.corrupt = false; store.failSave = true
        let failedSave = make(); failedSave.start()
        #expect((failedSave.handle(Request(.limit, limit: 80), administrator: true).errorCode) == (.persistence))
        #expect(!(failedSave.status().configuration.enabled)); #expect(hardware.writes.isEmpty)
    }
    @Test func testCrashRecoveryReleasesBeforeApplyingSavedPolicy() {
        store.configuration.enabled = true; store.owned = true; hardware.gate = .blocked
        let c = make(); c.start()
        #expect((hardware.writes) == ([.allowed, .blocked]))
        #expect(store.owned)
    }
    @Test func testUnknownBuildNeverAttemptsRecoveryWrites() {
        store.owned = true; hardware.gate = .blocked
        let c = make(supported: false); c.start()
        #expect(hardware.writes.isEmpty); #expect(c.status().ownsControl)
        #expect((c.status().mode) == ("fault"))
    }
    @Test func testPrepareUninstallQuiescesAndUpgradePreservesPolicy() {
        let c = make(); c.start(); _ = c.handle(Request(.limit, limit: 80), administrator: true)
        #expect((c.handle(Request(.prepareUpgrade), administrator: true).error) == nil)
        #expect(store.configuration.enabled); #expect((hardware.gate) == (.allowed))
        sample(99); c.refresh(); #expect((hardware.gate) == (.allowed))
        let restarted = make(); restarted.start()
        #expect((restarted.handle(Request(.prepareUninstall), administrator: true).error) == nil)
        #expect(!(store.configuration.enabled)); #expect(!(store.owned))
        #expect((restarted.handle(Request(.resume), administrator: true).errorCode) == (.unavailable))
    }
    @Test func testOwnershipMustBeSavedBeforeAnyBlockWrite() {
        let c = make(); c.start(); store.failOwnershipSave = true
        #expect(c.handle(Request(.limit, limit: 80), administrator: true).error != nil)
        #expect(hardware.writes.isEmpty)
        #expect(!store.owned)
    }
    @Test func testNormalShutdownReleasesOnlyOwnedControl() throws {
        let c = make(); c.start()
        try c.shutdown(); #expect(hardware.writes.isEmpty)
        _ = c.handle(Request(.limit, limit: 80), administrator: true)
        try c.shutdown()
        #expect(hardware.gate == .allowed); #expect(!store.owned)
    }
}
