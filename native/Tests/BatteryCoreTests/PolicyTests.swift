import Testing
import Foundation
import Darwin
@testable import BatteryCore

@Suite(.serialized)
final class PolicyTests {
    @Test func testHysteresisAndInitialState() {
        var policy = ChargingPolicy(), config = Configuration()
        config.enabled = true
        func sample(_ percent: Int) -> BatterySnapshot { .init(percentage: percent, externalPower: true) }
        #expect((policy.desired(configuration: config, snapshot: sample(78), topup: false)) == (.allowed))
        #expect((policy.desired(configuration: config, snapshot: sample(80), topup: false)) == (.blocked))
        #expect((policy.desired(configuration: config, snapshot: sample(78), topup: false)) == (.blocked))
        #expect((policy.desired(configuration: config, snapshot: sample(75), topup: false)) == (.allowed))
        #expect((policy.desired(configuration: config, snapshot: sample(78), topup: false)) == (.allowed))
        policy.reset()
        #expect((policy.desired(configuration: config, snapshot: sample(95), topup: false)) == (.blocked))
    }
    @Test func testPauseDisabledBatteryPowerAndTopupAllowSystemCharging() {
        var policy = ChargingPolicy(), config = Configuration()
        let full = BatterySnapshot(percentage: 95, externalPower: true)
        #expect((policy.desired(configuration: config, snapshot: full, topup: false)) == (.allowed))
        config.enabled = true; config.paused = true
        #expect((policy.desired(configuration: config, snapshot: full, topup: false)) == (.allowed))
        config.paused = false
        #expect((policy.desired(configuration: config, snapshot: full, topup: true)) == (.allowed))
        #expect((policy.desired(configuration: config, snapshot: .init(percentage: 95, externalPower: false), topup: false)) == (.allowed))
    }
    @Test func testAllLimitsAndPercentagesProduceExpectedBoundaryDecisions() {
        for limit in 50...100 {
            var config = Configuration(); config.enabled = true; config.limit = limit
            for percentage in 0...100 {
                var policy = ChargingPolicy()
                let desired = policy.desired(configuration: config, snapshot: .init(percentage: percentage, externalPower: true), topup: false)
                #expect((desired) == (percentage >= limit ? .blocked : .allowed))
            }
        }
    }
    @Test func testProfileRequiresExactMachineBuildAndEvidence() {
        let machine = Machine(model: "MacTest,1", osBuild: "24G830")
        #expect(HardwareProfile(model: machine.model, osBuild: machine.osBuild, validated: true, evidence: "manual test").supports(machine))
        #expect(!(HardwareProfile(model: machine.model, osBuild: "24G831", validated: true, evidence: "test").supports(machine)))
        #expect(!(HardwareProfile(model: machine.model, osBuild: machine.osBuild, validated: false, evidence: "test").supports(machine)))
        #expect(!(HardwareProfile(model: machine.model, osBuild: machine.osBuild, validated: true, evidence: "").supports(machine)))
    }
}
