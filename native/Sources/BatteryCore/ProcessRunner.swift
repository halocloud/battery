import Foundation
import Darwin

public struct ProcessResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

public protocol ProcessRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessResult
}

/// No shell, inherited stdin, unbounded output buffer, or unbounded wait.
public final class BoundedProcessRunner: ProcessRunning {
    public init() {}
    public func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        defer {
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { throw BatteryError(.hardware, "Cannot start hardware tool: \(error.localizedDescription)") }
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        let outFD = stdout.fileHandleForReading.fileDescriptor, errFD = stderr.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK); _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
        var out = Data(), err = Data(), overflow = false
        func drain(_ fd: Int32, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            // Bound each drain as well as the total buffer: a noisy child must not starve the timeout.
            for _ in 0..<16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                let remaining = max(0, 65_536 - data.count)
                data.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining { overflow = true }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        var timedOut = false
        while process.isRunning {
            drain(outFD, into: &out); drain(errFD, into: &err)
            if ProcessInfo.processInfo.systemUptime >= deadline || overflow {
                timedOut = !overflow
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(5_000) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                let reapDeadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < reapDeadline { usleep(5_000) }
                break
            }
            usleep(5_000)
        }
        drain(outFD, into: &out); drain(errFD, into: &err)
        if timedOut { throw BatteryError(.hardware, "Hardware tool timed out and was terminated.") }
        if overflow { throw BatteryError(.hardware, "Hardware tool exceeded the output limit.") }
        guard !process.isRunning else { throw BatteryError(.hardware, "Hardware tool could not be reaped.") }
        process.waitUntilExit()
        return ProcessResult(exitCode: process.terminationStatus,
                             stdout: String(decoding: out, as: UTF8.self),
                             stderr: String(decoding: err, as: UTF8.self))
    }
}
