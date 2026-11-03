import Testing
import Foundation
import Darwin
@testable import BatteryCore

@Suite(.serialized)
final class InterfaceTests {
    @Test func testCLIValidationAndDecimalLeadingZeros() throws {
        #expect((try CLICommand.parse(["limit", "080"]).request?.limit) == (80))
        #expect(try CLICommand.parse(["diagnose", "--offline", "--json"]).offline)
        for args in [["limit"], ["limit", "49"], ["limit", "101"], ["limit", "abc"],
                     ["limit", "80; echo bad"], ["limit", "８０"], ["status", "extra"],
                     ["wat"], ["prepareUninstall"], ["prepareUpgrade"], ["--prepare-upgrade"]] {
            #expect(throws: (any Error).self) { try CLICommand.parse(args) }
        }
    }
    @Test func testWireVersionsAndRoundTrip() throws {
        let request = Request(.limit, limit: 80)
        #expect((try Wire.decode(Request.self, Wire.encode(request)).limit) == (80))
        var wrongVersion = request; wrongVersion.protocolVersion = 2
        #expect(throws: (any Error).self) { try wrongVersion.validate() }
        #expect(throws: (any Error).self) { try Wire.decode(Request.self, Data("{}".utf8)) }
    }
    @Test func testFileStoreRoundTripAndCorruptionRefusesDefaultFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileConfigurationStore(directory: directory, secure: false)
        #expect(!(try store.loadConfiguration().enabled))
        var config = Configuration(); config.enabled = true; config.paused = true; config.limit = 85
        try store.saveConfiguration(config); try store.saveOwnership(true)
        #expect((try store.loadConfiguration()) == (config)); #expect(try store.loadOwnership())
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("config.json").path)[.posixPermissions] as! NSNumber
        #expect((mode.intValue) == (0o600))
        try Data("broken".utf8).write(to: directory.appendingPathComponent("config.json"))
        #expect(throws: (any Error).self) { try store.loadConfiguration() }
        try Data("\"invalid\"".utf8).write(to: directory.appendingPathComponent("ownership.json"))
        #expect(throws: (any Error).self) { try store.loadOwnership() }
    }
    @Test func testSecurePathsRejectUserOwnedFilesAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("trusted-looking")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")
        #expect(throws: (any Error).self) { try SecureFiles.validate(link.path) }
    }
}
