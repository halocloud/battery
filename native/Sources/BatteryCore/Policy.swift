import Foundation

public struct ChargingPolicy {
    private var hysteresis: ChargeGate = .unknown
    public init() {}
    public mutating func reset() { hysteresis = .unknown }
    public mutating func desired(configuration: Configuration, snapshot: BatterySnapshot,
                                 topup: Bool) -> ChargeGate {
        guard configuration.enabled, !configuration.paused, snapshot.externalPower, !topup else {
            hysteresis = .unknown
            return .allowed
        }
        if snapshot.percentage >= configuration.limit { hysteresis = .blocked }
        else if snapshot.percentage <= configuration.limit - 5 { hysteresis = .allowed }
        else if hysteresis == .unknown { hysteresis = .allowed }
        return hysteresis
    }
}
