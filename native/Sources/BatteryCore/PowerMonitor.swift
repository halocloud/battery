import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import CBatterySupport

public protocol BatteryMonitoring { func sample() throws -> BatterySnapshot }

public final class SystemBatteryMonitor: BatteryMonitoring {
    public init() {}
    public func sample() throws -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw BatteryError(.hardware, "Cannot read power source information.")
        }
        for source in sources {
            guard let value = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  value[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  value[kIOPSIsPresentKey] as? Bool == true,
                  let current = value[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = value[kIOPSMaxCapacityKey] as? Int, maximum > 0,
                  let state = value[kIOPSPowerSourceStateKey] as? String,
                  [kIOPSACPowerValue, kIOPSBatteryPowerValue].contains(state),
                  let charging = value[kIOPSIsChargingKey] as? Bool else { continue }
            let percentage = Int((Double(current) / Double(maximum) * 100).rounded())
            guard (0...100).contains(percentage) else { throw BatteryError(.hardware, "Invalid battery percentage.") }
            return BatterySnapshot(percentage: percentage, externalPower: state == kIOPSACPowerValue,
                                   isCharging: charging, isCharged: value[kIOPSIsChargedKey] as? Bool ?? (percentage == 100))
        }
        throw BatteryError(.hardware, "No valid internal battery was found.")
    }
}

/// Sources are scheduled on the daemon's main run loop; the callback only queues work.
public final class PowerNotifications {
    private let changed: () -> Void
    private var source: CFRunLoopSource?
    private var powerPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    public init(changed: @escaping () -> Void) { self.changed = changed }
    public func start() throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerNotifications>.fromOpaque(context).takeUnretainedValue().changed()
        }, context)?.takeRetainedValue() else { throw BatteryError(.hardware, "Cannot subscribe to power changes.") }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        rootPort = IORegisterForSystemPower(context, &powerPort, { context, _, type, argument in
            guard let context else { return }
            let monitor = Unmanaged<PowerNotifications>.fromOpaque(context).takeUnretainedValue()
            // Always acknowledge sleep immediately; hardware I/O never delays or vetoes sleep.
            if type == bc_can_sleep() || type == bc_will_sleep() {
                IOAllowPowerChange(monitor.rootPort, Int(bitPattern: argument))
            } else if type == bc_has_woken() { monitor.changed() }
        }, &notifier)
        if rootPort == 0 { throw BatteryError(.hardware, "Cannot subscribe to sleep/wake changes.") }
        if let powerPort, let source = IONotificationPortGetRunLoopSource(powerPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let powerPort { IONotificationPortDestroy(powerPort) }
    }
}
