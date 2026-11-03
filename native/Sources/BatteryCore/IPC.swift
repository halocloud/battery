import Foundation
import CBatterySupport

@objc public protocol BatteryServiceProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public final class BatteryService: NSObject, NSXPCListenerDelegate {
    private let controller: BatteryController
    private let queue = DispatchQueue(label: "local.batterycore.control")
    private let clientRequirement: String
    private var timer: DispatchSourceTimer?
    private let eventLock = NSLock()
    private var eventPending = false
    public init(controller: BatteryController, clientRequirement: String) {
        self.controller = controller; self.clientRequirement = clientRequirement
    }
    public func start() {
        queue.async { self.controller.start() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.controller.refresh() }
        timer.resume(); self.timer = timer
    }
    public func changed() {
        eventLock.lock()
        if eventPending { eventLock.unlock(); return }
        eventPending = true; eventLock.unlock()
        queue.async {
            self.eventLock.lock(); self.eventPending = false; self.eventLock.unlock()
            self.controller.refresh()
        }
    }
    public func shutdown(completion: @escaping (Bool) -> Void) {
        timer?.cancel()
        queue.async {
            do { try self.controller.shutdown(); completion(true) }
            catch { completion(false) }
        }
    }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Requirements are derived from root-owned installed files, including exact identifiers.
        // With ad-hoc development signatures the designated requirement pins the code hash.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: BatteryServiceProtocol.self)
        connection.exportedObject = Session(service: self, uid: connection.effectiveUserIdentifier)
        connection.activate(); return true
    }
    func perform(_ data: Data, uid: uid_t, reply: @escaping (Data) -> Void) {
        queue.async {
            let response: Response
            do {
                guard data.count <= 4096 else { throw BatteryError(.invalidArgument, "Request exceeds size limit.") }
                let request = try Wire.decode(Request.self, data)
                if [.prepareUninstall, .prepareUpgrade].contains(request.operation) && uid != 0 {
                    throw BatteryError(.unauthorized, "Installer operations require root.")
                }
                response = self.controller.handle(request, administrator: bc_is_admin(uid) != 0)
            } catch let error as BatteryError { response = Response(error: error) }
            catch { response = Response(error: BatteryError(.invalidArgument, "Invalid request encoding.")) }
            reply((try? Wire.encode(response)) ?? Data())
        }
    }
}

private final class Session: NSObject, BatteryServiceProtocol {
    private let service: BatteryService
    private let uid: uid_t
    init(service: BatteryService, uid: uid_t) { self.service = service; self.uid = uid }
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        service.perform(request, uid: uid, reply: reply)
    }
}

public final class BatteryClient {
    public init() {}
    public func perform(_ request: Request, timeout: TimeInterval = 45) throws -> Response {
        try request.validate()
        guard FileManager.default.fileExists(atPath: Installation.daemon) else {
            throw BatteryError(.unavailable, "Background service is not installed. Install the package, or use diagnose --offline.")
        }
        let requirement = try SecureFiles.requirement(for: Installation.daemon)
        let connection = NSXPCConnection(machServiceName: Installation.service, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: BatteryServiceProtocol.self)
        let result = PendingReply()
        connection.invalidationHandler = { result.finish(.failure(BatteryError(.unavailable, "Background service connection was rejected or is unavailable."))) }
        connection.interruptionHandler = { result.finish(.failure(BatteryError(.unavailable, "Background service connection was interrupted."))) }
        connection.activate()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            result.finish(.failure(BatteryError(.unavailable, error.localizedDescription)))
        }) as? BatteryServiceProtocol else { throw BatteryError(.unavailable, "Cannot connect to background service.") }
        proxy.perform(try Wire.encode(request)) { data in
            do { result.finish(.success(try Wire.decode(Response.self, data))) }
            catch { result.finish(.failure(BatteryError(.unavailable, "Invalid response from background service."))) }
        }
        guard result.semaphore.wait(timeout: .now() + timeout) == .success else {
            throw BatteryError(.unavailable, "Service response timed out. The request may still complete; check status before retrying.")
        }
        return try result.value()
    }
}

private final class PendingReply {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Response, Error>?
    func finish(_ value: Result<Response, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }
        result = value; semaphore.signal()
    }
    func value() throws -> Response {
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw BatteryError(.unavailable, "Missing service response.") }
        return try result.get()
    }
}
