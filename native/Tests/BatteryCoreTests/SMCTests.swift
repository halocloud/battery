import Testing
import Foundation
import Darwin
@testable import BatteryCore

final class FakeRunner: ProcessRunning {
    var values: [String: UInt8] = ["CH0B": 0, "CH0C": 0, "CH0I": 0]
    var calls: [[String]] = []
    var result: ProcessResult?
    var fail = false
    var ignoreWrites = false
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        calls.append(arguments)
        if fail { throw BatteryError(.hardware, "simulated timeout") }
        if let result { return result }
        let key = arguments[1]
        if arguments[2] == "-w" {
            if !ignoreWrites { values[key] = UInt8(arguments[3], radix: 16)! }
            return ProcessResult(exitCode: 0)
        }
        return ProcessResult(exitCode: 0, stdout: "  \(key) [hex_] (bytes \(String(format: "%02x", values[key]!)))\n")
    }
}

@Suite(.serialized)
final class SMCTests {
    @Test func testParseTypesWhitespaceAndZeroByte() throws {
        let a = try SMCValue.parse(" CH0B [hex_] (bytes 00)\n", key: "CH0B")
        #expect((a.bytes) == ([0])); #expect((a.type) == ("hex_"))
        let b = try SMCValue.parse(" CH0B [ui8 ] 2 (bytes 02)", key: "CH0B")
        #expect((b.type) == ("ui8")); #expect((b.bytes) == ([2]))
    }
    @Test func testRejectMalformedMissingMultipleLinesAndWrongKey() {
        for output in ["", "CH0B [] no data", "CH0C [hex_] (bytes 00)", "CH0B [hex_] (bytes 0)",
                       "CH0B [hex_] (bytes zz)", "CH0B [hex_] (bytes 00)\nError: failed"] {
            #expect(throws: (any Error).self) { try SMCValue.parse(output, key: "CH0B") }
        }
    }
    @Test func testWriteAllowListReadbackAndNoRedundantRetries() throws {
        let runner = FakeRunner()
        let smc = SMCExecutor(runner: runner, verifyExecutable: {}, retryDelay: {})
        #expect((try smc.readGate()) == (.allowed))
        try smc.setGate(.blocked)
        #expect((try smc.readGate()) == (.blocked))
        let writes = runner.calls.filter { $0.contains("-w") }
        #expect((writes) == ([["-k", "CH0B", "-w", "02"], ["-k", "CH0C", "-w", "02"]]))
        #expect(throws: (any Error).self) { try smc.setGate(.unknown) }
        #expect(runner.calls.allSatisfy { $0[0] == "-k" })
    }
    @Test func testSilentWriteFailureIsCaughtByReadbackWithBoundedRetries() {
        let runner = FakeRunner(); runner.ignoreWrites = true
        let smc = SMCExecutor(runner: runner, verifyExecutable: {}, retryDelay: {})
        #expect(throws: (any Error).self) { try smc.setGate(.blocked) }
        #expect((runner.calls.filter { $0.contains("-w") }.count) == (6))
    }
    @Test func testExitErrorsStderrAndReadFailureAreNeverNormalStates() {
        let runner = FakeRunner(), smc = SMCExecutor(runner: FakeRunner(), verifyExecutable: {})
        let tested = SMCExecutor(runner: runner, verifyExecutable: {})
        for result in [ProcessResult(exitCode: 1), ProcessResult(exitCode: 0, stderr: "permission denied"),
                       ProcessResult(exitCode: 0, stdout: "Error: IOServiceOpen()"),
                       ProcessResult(exitCode: 0, stdout: "CH0B [hex_] (bytes ff)")] {
            runner.result = result
            #expect(throws: (any Error).self) { try tested.readGate() }
        }
        #expect(throws: Never.self) { try smc.readGate() }
        runner.result = nil; runner.fail = true
        #expect(throws: (any Error).self) { try tested.readGate() }
    }
    @Test func testMismatchedPairCanBeReleasedButNotReportedAsAllowed() throws {
        let runner = FakeRunner(); runner.values["CH0B"] = 2
        let smc = SMCExecutor(runner: runner, verifyExecutable: {}, retryDelay: {})
        #expect(throws: (any Error).self) { try smc.readGate() }
        try smc.setGate(.allowed)
        #expect((try smc.readGate()) == (.allowed))
    }
    @Test func testIntegrityFailurePreventsExecutingAnyCommand() {
        let runner = FakeRunner()
        let smc = SMCExecutor(runner: runner, verifyExecutable: { throw BatteryError(.unauthorized, "bad hash") })
        #expect(throws: (any Error).self) { try smc.readGate() }; #expect(runner.calls.isEmpty)
    }
    @Test func testBoundedRunnerDrainsBothPipesAndPreservesArguments() throws {
        let result = try BoundedProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$1\"; printf error >&2", "fixture", "$(touch /not-executed); literal"], timeout: 2)
        #expect((result.stdout) == ("$(touch /not-executed); literal"))
        #expect((result.stderr) == ("error")); #expect((result.exitCode) == (0))
    }
    @Test func testBoundedRunnerKillsTimeoutAndRejectsExcessOutput() {
        let runner = BoundedProcessRunner(), start = Date()
        #expect(throws: (any Error).self) { try runner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.05) }
        #expect((Date().timeIntervalSince(start)) < (2))
        #expect(throws: (any Error).self) { try runner.run(executable: "/usr/bin/yes", arguments: [], timeout: 1) }
    }
}
