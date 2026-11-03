import Foundation
import Darwin
import CryptoKit
import Security

public enum SecureFiles {
    public static func validate(_ path: String, directory: Bool = false) throws {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw BatteryError(.unauthorized, "Expected a canonical absolute installation path.")
        }
        var current = ""
        let components = path.split(separator: "/")
        for (index, component) in components.enumerated() {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0 else {
                throw BatteryError(.unauthorized, "Untrusted ownership or permissions: \(current)")
            }
            let expected = index == components.count - 1 && !directory ? S_IFREG : S_IFDIR
            guard info.st_mode & S_IFMT == expected else {
                throw BatteryError(.unauthorized, "Symlinks and unexpected file types are not allowed: \(current)")
            }
        }
    }

    public static func read(_ path: String, limit: Int = 1_048_576) throws -> Data {
        try validate(path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BatteryError(.persistence, "Cannot open \(path).") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else {
            throw BatteryError(.unauthorized, "Untrusted or oversized file: \(path)")
        }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }

    public static func requirement(for executable: String) throws -> String {
        try validate(executable)
        var code: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: executable) as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw BatteryError(.unauthorized, "Installed executable has no valid signature: \(executable)")
        }
        return text as String
    }

    public static func verifySMC() throws {
        let manifestPath = Installation.root + "/manifest.json"
        let manifest = try JSONDecoder().decode([String: String].self, from: read(manifestPath))
        guard let expected = manifest["smcSHA256"], expected.count == 64 else {
            throw BatteryError(.unauthorized, "Missing installed SMC integrity manifest.")
        }
        let bytes = try read(Installation.smc, limit: 4_194_304)
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw BatteryError(.unauthorized, "Installed SMC checksum does not match its manifest.") }
    }
}

public protocol ConfigurationStoring {
    func loadConfiguration() throws -> Configuration
    func saveConfiguration(_ configuration: Configuration) throws
    func loadOwnership() throws -> Bool
    func saveOwnership(_ owned: Bool) throws
}

public final class FileConfigurationStore: ConfigurationStoring {
    private let directory: URL
    private let secure: Bool
    public init(directory: URL = URL(fileURLWithPath: Installation.state), secure: Bool = true) {
        self.directory = directory; self.secure = secure
    }
    private func load<T: Decodable>(_ type: T.Type, name: String, fallback: T) throws -> T {
        let path = directory.appendingPathComponent(name).path
        if secure { try SecureFiles.validate(directory.path, directory: true) }
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return fallback }
            throw BatteryError(.persistence, "Cannot inspect state file \(name).")
        }
        do {
            let data = secure ? try SecureFiles.read(path) : try Data(contentsOf: URL(fileURLWithPath: path))
            return try Wire.decode(type, data)
        } catch { throw BatteryError(.persistence, "Cannot load \(name): \(error.localizedDescription)") }
    }
    private func save<T: Encodable>(_ value: T, name: String) throws {
        if secure { try SecureFiles.validate(directory.path, directory: true) }
        let target = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let data = try Wire.encode(value)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BatteryError(.persistence, "Cannot create state transaction.") }
        defer { close(fd); unlink(temporary.path) }
        do {
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
            guard fsync(fd) == 0, rename(temporary.path, target.path) == 0 else {
                throw BatteryError(.persistence, "Cannot commit state transaction.")
            }
            let dirFD = open(directory.path, O_RDONLY | O_CLOEXEC)
            if dirFD >= 0 { _ = fsync(dirFD); close(dirFD) }
        } catch { throw BatteryError(.persistence, "Cannot save \(name): \(error.localizedDescription)") }
    }
    public func loadConfiguration() throws -> Configuration {
        let config = try load(Configuration.self, name: "config.json", fallback: Configuration())
        try config.validate(); return config
    }
    public func saveConfiguration(_ configuration: Configuration) throws {
        try configuration.validate(); try save(configuration, name: "config.json")
    }
    public func loadOwnership() throws -> Bool { try load(Bool.self, name: "ownership.json", fallback: false) }
    public func saveOwnership(_ owned: Bool) throws { try save(owned, name: "ownership.json") }
}

public enum ProfileLoader {
    public static func load(for machine: Machine) throws -> HardwareProfile? {
        let path = Installation.state + "/verified-hardware.json"
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw BatteryError(.persistence, "Cannot inspect hardware profiles.") }
            return nil
        }
        let profiles = try Wire.decode([HardwareProfile].self, SecureFiles.read(path))
        return profiles.first { $0.supports(machine) }
    }
}
