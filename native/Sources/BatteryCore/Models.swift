import Foundation
import CBatterySupport

public enum Installation {
    public static let service = "local.batterycore.daemon"
    public static let root = "/Library/PrivilegedHelperTools/local.batterycore"
    public static let state = "/Library/Application Support/BatteryCore"
    public static let cli = root + "/batteryctl"
    public static let daemon = root + "/batteryd"
    public static let smc = root + "/smc"
    public static let version = "0.1.0"
}

public enum FailureCode: Int, Codable {
    case invalidArgument = 2, unavailable = 3, unauthorized = 4
    case unsupported = 5, hardware = 6, persistence = 7
}

public struct BatteryError: Error, LocalizedError {
    public let code: FailureCode
    public let message: String
    public init(_ code: FailureCode, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public enum ChargeGate: String, Codable { case allowed, blocked, unknown }

public struct BatterySnapshot: Codable, Equatable {
    public let percentage: Int
    public let externalPower: Bool
    public let isCharging: Bool
    public let isCharged: Bool
    public let sampledAt: Date
    public init(percentage: Int, externalPower: Bool, isCharging: Bool = false,
                isCharged: Bool = false, sampledAt: Date = Date()) {
        self.percentage = percentage; self.externalPower = externalPower
        self.isCharging = isCharging; self.isCharged = isCharged; self.sampledAt = sampledAt
    }
}

public struct Configuration: Codable, Equatable {
    public var schemaVersion = 1
    public var limit = 80
    public var enabled = false
    public var paused = false
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1, (50...100).contains(limit), !paused || enabled else {
            throw BatteryError(.persistence, "Invalid or unsupported configuration; control is suspended.")
        }
    }
}

public struct Machine: Codable, Equatable {
    public var model: String
    public var osBuild: String
    public init(model: String, osBuild: String) { self.model = model; self.osBuild = osBuild }
    public static func current() -> Machine {
        var model = [CChar](repeating: 0, count: 256)
        var build = [CChar](repeating: 0, count: 256)
        let m = bc_machine_model(&model, model.count)
        let b = bc_os_build(&build, build.count)
        return Machine(model: m == 0 ? String(cString: model) : "unknown",
                       osBuild: b == 0 ? String(cString: build) : "unknown")
    }
}

public struct HardwareProfile: Codable, Equatable {
    public let model: String
    public let osBuild: String
    public let backend: String
    public let validated: Bool
    public let evidence: String
    public init(model: String, osBuild: String, backend: String = "legacy-ch0b-ch0c",
                validated: Bool, evidence: String) {
        self.model = model; self.osBuild = osBuild; self.backend = backend
        self.validated = validated; self.evidence = evidence
    }
    public func supports(_ machine: Machine) -> Bool {
        validated && backend == "legacy-ch0b-ch0c" && model != "unknown" && osBuild != "unknown" &&
        model == machine.model && osBuild == machine.osBuild && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum Operation: String, Codable {
    case status, limit, pause, resume, topup, disable, diagnose, prepareUninstall, prepareUpgrade
    public var mutates: Bool { self != .status && self != .diagnose }
}

public struct Request: Codable {
    public var protocolVersion = 1
    public let operation: Operation
    public let limit: Int?
    public init(_ operation: Operation, limit: Int? = nil) { self.operation = operation; self.limit = limit }
    public func validate() throws {
        guard protocolVersion == 1 else { throw BatteryError(.invalidArgument, "Unsupported protocol version.") }
        if operation == .limit {
            guard let limit, (50...100).contains(limit) else {
                throw BatteryError(.invalidArgument, "Limit must be an integer from 50 to 100.")
            }
        } else if limit != nil {
            throw BatteryError(.invalidArgument, "This operation does not accept a limit.")
        }
    }
}

public struct ServiceStatus: Codable {
    public let protocolVersion: Int
    public let version: String
    public let machine: Machine
    public let supported: Bool
    public let configuration: Configuration
    public let snapshot: BatterySnapshot?
    public let gate: ChargeGate
    public let mode: String
    public let ownsControl: Bool
    public let topupDeadline: Date?
    public let lastError: String?
    public let diagnostics: [String: String]?
}

public struct Response: Codable {
    public let status: ServiceStatus?
    public let errorCode: FailureCode?
    public let error: String?
    public init(status: ServiceStatus) { self.status = status; errorCode = nil; error = nil }
    public init(error: BatteryError, status: ServiceStatus? = nil) {
        self.status = status; errorCode = error.code; self.error = error.message
    }
}

public enum Wire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
