import Foundation

public struct CLICommand {
    public let request: Request?
    public let json: Bool
    public let offline: Bool
    public let uninstall: Bool
    public let help: Bool
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
            return CLICommand(request: nil, json: false, offline: false, uninstall: false, help: true)
        }
        var args = arguments
        let name = args.removeFirst()
        let json = args.last == "--json"
        if json { args.removeLast() }
        let offline = name == "diagnose" && args == ["--offline"]
        if offline { args.removeAll() }
        if name == "uninstall" && args.isEmpty && !json {
            return CLICommand(request: nil, json: false, offline: false, uninstall: true, help: false)
        }
        guard let op = Operation(rawValue: name), op != .prepareUninstall, op != .prepareUpgrade else {
            throw BatteryError(.invalidArgument, "Unknown command. Run batteryctl --help.")
        }
        let value: Int?
        if op == .limit, args.count == 1, !args[0].isEmpty, args[0].allSatisfy({ $0.isASCII && $0.isNumber }) {
            value = Int(args[0])
        } else {
            guard args.isEmpty, op != .limit else { throw BatteryError(.invalidArgument, "Invalid arguments. Run batteryctl --help.") }
            value = nil
        }
        let request = Request(op, limit: value); try request.validate()
        return CLICommand(request: request, json: json, offline: offline, uninstall: false, help: false)
    }
    public static let usage = """
    batteryctl \(Installation.version) — native Apple Silicon battery controller
    Usage:
      batteryctl status [--json]
      batteryctl limit PERCENT[50-100] [--json]
      batteryctl pause|resume|disable [--json]
      batteryctl topup [--json]
      batteryctl diagnose [--offline] [--json]
      batteryctl uninstall

    Default: 80% upper limit, resume at 75%. Installation starts disabled.
    Unsupported model/build combinations are diagnostic-only until hardware validation.
    Exit codes: 2 arguments, 3 service, 4 authorization, 5 unsupported,
                6 hardware, 7 configuration/persistence.
    """
}
