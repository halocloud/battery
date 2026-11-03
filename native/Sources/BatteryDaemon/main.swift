import Foundation
import BatteryCore
import CBatterySupport
import OSLog
import Darwin

let logger = Logger(subsystem: Installation.service, category: "daemon")
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("batteryd must be installed as a system service.\n".utf8)); exit(4)
}

do {
    try SecureFiles.validate(Installation.state, directory: true)
    guard bc_lock_service(Installation.state + "/service.lock") >= 0 else {
        throw BatteryError(.unavailable, "Another service instance is running or the lock is untrusted.")
    }
    let requirement = try SecureFiles.requirement(for: Installation.cli)
    let machine = Machine.current()
    var profile: HardwareProfile?, startupError: String?
    do { profile = try ProfileLoader.load(for: machine) }
    catch { startupError = "Cannot load hardware validation record: \(error.localizedDescription)" }
    let hardware = SMCExecutor(verifyExecutable: SecureFiles.verifySMC)
    let controller = BatteryController(hardware: hardware, monitor: SystemBatteryMonitor(),
                                       store: FileConfigurationStore(), machine: machine,
                                       profile: profile, startupError: startupError,
                                       log: { logger.info("\($0, privacy: .public)") })
    let service = BatteryService(controller: controller, clientRequirement: requirement)
    let listener = NSXPCListener(machServiceName: Installation.service)
    listener.delegate = service
    let notifications = PowerNotifications { service.changed() }
    do { try notifications.start() }
    catch { logger.error("Event subscription failed; 30-second polling remains active: \(error.localizedDescription, privacy: .public)") }
    service.start(); listener.activate()
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    var stopping = false
    let stop = {
        if stopping { return }; stopping = true
        listener.invalidate()
        service.shutdown { released in
            if !released { logger.error("Shutdown could not release control; ownership journal retained.") }
            exit(released ? 0 : 6)
        }
    }
    term.setEventHandler(handler: stop); interrupt.setEventHandler(handler: stop)
    term.resume(); interrupt.resume()
    withExtendedLifetime((service, listener, notifications, term, interrupt)) { CFRunLoopRun() }
} catch {
    logger.fault("Startup failed: \(error.localizedDescription, privacy: .public)")
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(3)
}
