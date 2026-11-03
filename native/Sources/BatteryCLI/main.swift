import Foundation
import BatteryCore
import Darwin

func writeError(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
let jsonOutput = CommandLine.arguments.last == "--json"
func reportFailure(_ error: BatteryError) -> Never {
    if jsonOutput, let data = try? Wire.encode(Response(error: error)) { print(String(decoding: data, as: UTF8.self)) }
    else { writeError(error.message) }
    exit(Int32(error.code.rawValue))
}

do {
    if CommandLine.arguments.count == 2,
       ["--prepare-uninstall", "--prepare-upgrade"].contains(CommandLine.arguments[1]) {
        guard geteuid() == 0 else { throw BatteryError(.unauthorized, "Installer operation requires root.") }
        let operation: BatteryCore.Operation = CommandLine.arguments[1] == "--prepare-upgrade" ? .prepareUpgrade : .prepareUninstall
        let response = try BatteryClient().perform(Request(operation))
        if let error = response.error { throw BatteryError(response.errorCode ?? .hardware, error) }
        guard response.status?.ownsControl == false else { throw BatteryError(.hardware, "Control was not released; installation/removal aborted.") }
        exit(0)
    }
    let command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
    if command.help { print(CLICommand.usage); exit(0) }
    if command.offline {
        let machine = Machine.current()
        let snapshot = try? SystemBatteryMonitor().sample()
        let report: [String: String] = [
            "version": Installation.version, "model": machine.model, "osBuild": machine.osBuild,
            "batteryPercentage": snapshot.map { String($0.percentage) } ?? "unknown",
            "serviceInstalled": FileManager.default.fileExists(atPath: Installation.daemon) ? "yes" : "no",
            "note": "Read-only local report; no SMC process was launched. Use installed diagnose for hardware/profile details."
        ]
        if command.json { print(String(decoding: try Wire.encode(report), as: UTF8.self)) }
        else { for key in report.keys.sorted() { print("\(key): \(report[key]!)") } }
        exit(0)
    }
    if command.uninstall {
        // Only the trusted, installed script is elevated, with no caller-provided arguments.
        let path = Installation.root + "/uninstall"
        try SecureFiles.validate(path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [path]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit(); exit(process.terminationStatus)
    }
    let response = try BatteryClient().perform(command.request!)
    if command.json { print(String(decoding: try Wire.encode(response), as: UTF8.self)) }
    else {
        if let s = response.status {
            print("Mode: \(s.mode); limit: \(s.configuration.limit)% (resume at \(s.configuration.limit - 5)%)")
            if let b = s.snapshot {
                print("Battery: \(b.percentage)%; external power: \(b.externalPower); actually charging: \(b.isCharging)")
            }
            print("Charging control: \(s.gate.rawValue); owns control: \(s.ownsControl)")
            print("Machine: \(s.machine.model); build: \(s.machine.osBuild); validated: \(s.supported)")
            if let end = s.topupDeadline { print("Top-up deadline: \(end)") }
            if let error = s.lastError { writeError("Last error: \(error)") }
            if let values = s.diagnostics { for key in values.keys.sorted() { print("\(key): \(values[key]!)") } }
        }
    }
    if let error = response.error { if !command.json { writeError(error) }; exit(Int32(response.errorCode?.rawValue ?? 3)) }
} catch let error as BatteryError { reportFailure(error) }
catch { reportFailure(BatteryError(.unavailable, error.localizedDescription)) }
