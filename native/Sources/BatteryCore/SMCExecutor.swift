import Foundation

public struct SMCValue: Equatable {
    public let type: String
    public let bytes: [UInt8]
    public static func parse(_ output: String, key: String) throws -> SMCValue {
        let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: key) +
            #"\s+\[([^\]]+)\]\s*[^\r\n]*?\(bytes((?:\s+[0-9a-fA-F]{2}){1,32})\)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else {
            throw BatteryError(.hardware, "Malformed or missing SMC value for \(key).")
        }
        let bytes = text.substring(with: match.range(at: 2)).split(whereSeparator: \.isWhitespace).compactMap { UInt8($0, radix: 16) }
        return SMCValue(type: text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces), bytes: bytes)
    }
}

public protocol ChargingHardware {
    func readGate() throws -> ChargeGate
    func setGate(_ desired: ChargeGate) throws
    func diagnostics() -> [String: String]
}

public final class SMCExecutor: ChargingHardware {
    private let runner: ProcessRunning
    private let path: String
    private let verifyExecutable: () throws -> Void
    private let timeout: TimeInterval
    private let retryDelay: () -> Void
    public init(runner: ProcessRunning = BoundedProcessRunner(), path: String = Installation.smc,
                timeout: TimeInterval = 2, verifyExecutable: @escaping () throws -> Void,
                retryDelay: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.1) }) {
        self.runner = runner; self.path = path; self.timeout = timeout
        self.verifyExecutable = verifyExecutable; self.retryDelay = retryDelay
    }
    private func execute(key: String, write: String? = nil) throws -> String {
        let readKeys = ["CH0B", "CH0C", "CH0I"]
        guard readKeys.contains(key), write == nil || (["CH0B", "CH0C"].contains(key) && ["00", "02"].contains(write!)) else {
            throw BatteryError(.invalidArgument, "SMC operation is not allowed.")
        }
        try verifyExecutable()
        let arguments = ["-k", key] + (write.map { ["-w", $0] } ?? ["-r"])
        let result = try runner.run(executable: path, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.stdout.lowercased().contains("error"), !result.stdout.lowercased().contains("no data") else {
            throw BatteryError(.hardware, "SMC \(key) failed (exit \(result.exitCode)): \((result.stderr + result.stdout).prefix(512))")
        }
        return result.stdout
    }
    private func read(_ key: String) throws -> SMCValue {
        try SMCValue.parse(execute(key: key), key: key)
    }
    private func validate(_ value: SMCValue) throws {
        guard ["hex_", "ui8", "flag"].contains(value.type), value.bytes.count == 1,
              value.bytes[0] == 0 || value.bytes[0] == 2 else {
            throw BatteryError(.hardware, "Unexpected SMC type, size, or charging value; refusing control.")
        }
    }
    public func readGate() throws -> ChargeGate {
        let b = try read("CH0B"), c = try read("CH0C")
        try validate(b); try validate(c)
        guard b.bytes == c.bytes else { throw BatteryError(.hardware, "Charging control keys disagree.") }
        return b.bytes[0] == 0 ? .allowed : .blocked
    }
    public func setGate(_ desired: ChargeGate) throws {
        guard desired != .unknown else { throw BatteryError(.invalidArgument, "Cannot write unknown state.") }
        // Read/validate before either write. A mismatched pair is recoverable if each key is valid.
        try validate(read("CH0B")); try validate(read("CH0C"))
        let bytes = desired == .allowed ? "00" : "02"
        var last: Error = BatteryError(.hardware, "SMC write failed.")
        for attempt in 0..<3 {
            do {
                _ = try execute(key: "CH0B", write: bytes)
                _ = try execute(key: "CH0C", write: bytes)
                guard try readGate() == desired else { throw BatteryError(.hardware, "SMC write did not persist.") }
                return
            } catch { last = error; if attempt < 2 { retryDelay() } }
        }
        throw last
    }
    public func diagnostics() -> [String: String] {
        var values: [String: String] = [:]
        for key in ["CH0B", "CH0C", "CH0I"] {
            do {
                let value = try read(key)
                values[key] = "\(value.type): " + value.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            } catch { values[key] = "unknown: \(error.localizedDescription)" }
        }
        return values
    }
}
