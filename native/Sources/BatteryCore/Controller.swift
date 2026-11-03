import Foundation

/// All access is serialized by BatteryService. Tests inject time, battery samples, and hardware.
public final class BatteryController {
    private let hardware: ChargingHardware
    private let monitor: BatteryMonitoring
    private let store: ConfigurationStoring
    private let machine: Machine
    private let profile: HardwareProfile?
    private let now: () -> Date
    private let log: (String) -> Void
    private var configuration = Configuration()
    private var policy = ChargingPolicy()
    private var snapshot: BatterySnapshot?
    private var gate: ChargeGate = .unknown
    private var owned = false
    private var deadline: Date?
    private var failures = 0
    private var fault = false
    private var configurationError: String?
    private var lastError: String?
    private var lastTransition: String?
    private var started = false
    private var uninstallPrepared = false

    public init(hardware: ChargingHardware, monitor: BatteryMonitoring, store: ConfigurationStoring,
                machine: Machine, profile: HardwareProfile?, startupError: String? = nil,
                now: @escaping () -> Date = Date.init, log: @escaping (String) -> Void = { _ in }) {
        self.hardware = hardware; self.monitor = monitor; self.store = store
        self.machine = machine; self.profile = profile; self.now = now; self.log = log
        do {
            configuration = try store.loadConfiguration()
            owned = try store.loadOwnership()
        } catch { configurationError = error.localizedDescription }
        if let startupError { configurationError = startupError }
        if let configurationError { fault = true; lastError = configurationError }
    }
    private var supported: Bool { profile?.supports(machine) == true }

    public func start() {
        guard !started else { return }
        started = true
        // Persisted ownership survives SIGKILL. Never reset unowned/system controls on boot.
        if owned && configurationError == nil {
            do { try release() }
            catch { latch(error, attemptRelease: false); return }
        }
        refresh()
    }

    public func refresh() {
        guard !uninstallPrepared else { return }
        do {
            let value = try monitor.sample()
            guard (0...100).contains(value.percentage), now().timeIntervalSince(value.sampledAt) <= 90,
                  value.sampledAt.timeIntervalSince(now()) <= 5 else {
                throw BatteryError(.hardware, "Battery sample is invalid or stale.")
            }
            snapshot = value
            if let end = deadline, !value.externalPower || value.isCharged || value.percentage == 100 || now() >= end {
                deadline = nil; policy.reset(); log("Temporary top-up finished; restoring saved policy.")
            }
            guard supported else { gate = .unknown; return }
            guard !fault else { return }
            gate = try hardware.readGate()
            guard gate != .unknown else { throw BatteryError(.hardware, "Charging state is unknown.") }
            let desired = policy.desired(configuration: configuration, snapshot: value, topup: deadline != nil)
            if configuration.enabled && !configuration.paused || owned {
                try apply(desired)
            }
            failures = 0; lastError = nil
            transition()
        } catch {
            failures += 1; gate = .unknown; lastError = error.localizedDescription
            let stale = snapshot.map { now().timeIntervalSince($0.sampledAt) >= 90 } ?? true
            if failures >= 3 || stale { latch(error) }
        }
    }

    private func apply(_ desired: ChargeGate) throws {
        if desired == .blocked && !owned {
            // Journal BEFORE writing either key, including a possible partial write.
            try store.saveOwnership(true); owned = true
        }
        if gate != desired { try hardware.setGate(desired); gate = desired }
        if desired == .allowed && owned { try store.saveOwnership(false); owned = false }
    }
    private func release() throws {
        guard owned else { return }
        guard supported else {
            throw BatteryError(.unsupported, "Previous control is still owned, but this machine/build has no validated profile. Recovery requires hardware validation.")
        }
        try hardware.setGate(.allowed); gate = .allowed
        try store.saveOwnership(false); owned = false
    }
    private func latch(_ error: Error, attemptRelease: Bool = true) {
        fault = true; deadline = nil; policy.reset()
        lastError = error.localizedDescription
        if attemptRelease {
            do { try release() }
            catch { gate = .unknown; lastError = "\(lastError ?? "Fault"); release failed: \(error.localizedDescription)" }
        } else if owned { gate = .unknown }
        log("Control suspended: \(lastError ?? "unknown error")")
    }
    private func transition() {
        let state = "\(mode): \(gate.rawValue), limit \(configuration.limit)%"
        if state != lastTransition { lastTransition = state; log(state) }
    }
    private var mode: String {
        if fault { return "fault" }
        if !supported { return "unsupported" }
        if !configuration.enabled { return "disabled" }
        if configuration.paused { return "paused" }
        if deadline != nil { return "topup" }
        if gate == .unknown || failures > 0 { return "degraded" }
        return gate == .blocked ? "holding" : "charging-allowed"
    }
    public func status(diagnostics: Bool = false) -> ServiceStatus {
        var details: [String: String]?
        if diagnostics {
            details = hardware.diagnostics()
            details?["profile"] = supported ? "validated legacy-ch0b-ch0c" : "No validated profile for exact model/build. Writes are disabled."
            details?["pollIntervalSeconds"] = "30"
            details?["profilePath"] = Installation.state + "/verified-hardware.json"
            details?["configurationPath"] = Installation.state + "/config.json"
        }
        return ServiceStatus(protocolVersion: 1, version: Installation.version, machine: machine,
                             supported: supported, configuration: configuration, snapshot: snapshot,
                             gate: gate, mode: mode, ownsControl: owned, topupDeadline: deadline,
                             lastError: lastError, diagnostics: details)
    }
    public func handle(_ request: Request, administrator: Bool) -> Response {
        do {
            try request.validate() // Validation and authorization precede ALL state changes and hardware calls.
            if request.operation.mutates && !administrator { throw BatteryError(.unauthorized, "A local administrator is required.") }
            if request.operation == .status || request.operation == .diagnose {
                refresh(); return Response(status: status(diagnostics: request.operation == .diagnose))
            }
            if uninstallPrepared { throw BatteryError(.unavailable, "Uninstall is prepared; the daemon is quiescent.") }
            if let configurationError { throw BatteryError(.persistence, configurationError + " Repair the root-owned state before resuming.") }
            if request.operation == .prepareUpgrade {
                do { try release() } catch { latch(error, attemptRelease: false); throw error }
                deadline = nil; uninstallPrepared = true
                return Response(status: status()) // Keep the persisted policy for the new daemon.
            }
            if [.limit, .resume, .topup].contains(request.operation) && !supported {
                throw BatteryError(.unsupported, "No validated hardware profile for \(machine.model) / \(machine.osBuild). Run diagnose; no control was changed.")
            }
            var next = configuration
            switch request.operation {
            case .limit: next.limit = request.limit!; next.enabled = true; next.paused = false
            case .pause: next.paused = next.enabled
            case .resume: next.enabled = true; next.paused = false
            case .disable, .prepareUninstall: next.enabled = false; next.paused = false
            case .topup:
                guard configuration.enabled, !configuration.paused, !fault else {
                    throw BatteryError(.invalidArgument, "Enable a working limit before requesting a top-up.")
                }
                let sample = try monitor.sample()
                guard sample.externalPower, now().timeIntervalSince(sample.sampledAt) <= 90 else {
                    throw BatteryError(.invalidArgument, "Top-up requires a fresh battery sample and external power.")
                }
                deadline = now().addingTimeInterval(12 * 60 * 60)
                policy.reset(); refresh()
                if fault || failures > 0 { throw BatteryError(.hardware, lastError ?? "Top-up could not be applied.") }
                return Response(status: status())
            default: break
            }
            try store.saveConfiguration(next) // A failed save leaves the current policy intact.
            configuration = next; deadline = nil; policy.reset()
            fault = false; failures = 0; lastError = nil
            if !configuration.enabled || configuration.paused {
                do { try release() } catch { latch(error, attemptRelease: false); throw error }
                if request.operation == .prepareUninstall { uninstallPrepared = true }
            } else { refresh() }
            if fault || failures > 0 { throw BatteryError(.hardware, lastError ?? "Policy was saved but could not be applied.") }
            transition(); return Response(status: status())
        } catch let error as BatteryError {
            // A failed release must remain visible and must not discard its ownership journal.
            if error.code == .hardware && !fault { latch(error) }
            return Response(error: error, status: status())
        } catch {
            return Response(error: BatteryError(.persistence, error.localizedDescription), status: status())
        }
    }
    public func shutdown() throws { deadline = nil; try release() }
}
