//
//  KernelRuntime.swift
//  MizarKit
//
//  The local kernel's host: one JavaScriptCore context running the embedded
//  kernel bundle, with the platform's file system, network, key-value store
//  and timers bridged in behind the kernel's host API.
//
//  Threading model: every touch of the JSContext happens on one serial
//  queue. Host callbacks (`fs`, `kv`, `http`) run their slow work off the
//  queue and deliver results back onto it before invoking the JavaScript
//  callback — a callback that touches JS off-queue is exactly the crash an
//  embedding like this is famous for. The class is `@unchecked Sendable`
//  because that funnel is the whole safety story: nothing but the queue
//  ever reaches the context.
//
//  Swift 6 note: `JSValue` is not Sendable, and closures that cross into the
//  queue are `@Sendable`. Values that cross are boxed in ``JSBox``, whose
//  safety contract is the same funnel — a box is only ever unwrapped on the
//  kernel queue.
//
//  The kernel side of the bridge is `LocalKernel/docs/kernel-api.md`; the
//  host side is the `PlatformHost` shape documented in
//  `LocalKernel/kernel/src/host/host.ts`.
//

import Foundation
import JavaScriptCore
import os

// MARK: - Configuration points

/// A small synchronous string store behind the kernel's `kv` surface.
///
/// The default implementation uses `UserDefaults`, namespaced under
/// `mizar.kernel.`. API keys belong here in v0; a Keychain-backed store is a
/// drop-in replacement for this protocol, not a kernel change.
public protocol KernelKeyValueStore: Sendable {
    func value(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// The default `UserDefaults`-backed store.
public struct UserDefaultsKernelKeyValueStore: KernelKeyValueStore {
    private let prefix: String

    public init(prefix: String = "mizar.kernel.") {
        self.prefix = prefix
    }

    public func value(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    public func set(_ value: String?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }
}

/// One host HTTP request, as the kernel's bridge delivers it.
public struct KernelHTTPRequest: Sendable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let body: String?

    public init(url: String, method: String, headers: [String: String], body: String?) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// The streaming HTTP surface the kernel's engine adapter calls.
///
/// The real implementation streams the body through; a test handler returns
/// scripted bytes, which is how a whole agent turn runs in the unit suite
/// with no network.
public protocol KernelHTTPHandler: Sendable {
    /// Issue the request. Handlers are called in order `onChunk*`, then
    /// exactly one of `onDone`/`onError`. The returned handle aborts.
    func request(
        _ request: KernelHTTPRequest,
        onChunk: @escaping @Sendable (String) -> Void,
        onDone: @escaping @Sendable (Int) -> Void,
        onError: @escaping @Sendable (String) -> Void,
    ) -> KernelHTTPHandle
}

/// The abort handle of an in-flight host request.
public struct KernelHTTPHandle: Sendable {
    private let abortClosure: @Sendable () -> Void

    public init(abort: @escaping @Sendable () -> Void) {
        self.abortClosure = abort
    }

    public func abort() {
        abortClosure()
    }
}

/// The real HTTP handler: `URLSession`, streamed, UTF-8 decoded, delivered
/// line by line — the granularity the kernel's SSE parser consumes, and the
/// one a streaming model answers at.
public struct URLSessionKernelHTTPHandler: KernelHTTPHandler {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func request(
        _ request: KernelHTTPRequest,
        onChunk: @escaping @Sendable (String) -> Void,
        onDone: @escaping @Sendable (Int) -> Void,
        onError: @escaping @Sendable (String) -> Void,
    ) -> KernelHTTPHandle {
        let session = session
        // The kernel checks a URL's shape, not its parseability: the model can
        // hand over `http://[`. Unwrapping here would crash the app on the
        // model's own output, and a URL that does not parse is an error like
        // any other -- onError is the path the engine's caller already knows.
        guard let url = URL(string: request.url) else {
            onError("malformed url: \(request.url)")
            return KernelHTTPHandle {}
        }
        let task = Task.detached(priority: .userInitiated) {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = request.method
            for (name, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            if let body = request.body {
                urlRequest.httpBody = Data(body.utf8)
            }
            do {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                var buffer = [UInt8]()
                for try await byte in bytes {
                    buffer.append(byte)
                    if byte == UInt8(ascii: "\n") {
                        onChunk(String(decoding: buffer, as: UTF8.self))
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    onChunk(String(decoding: buffer, as: UTF8.self))
                }
                onDone(status)
            } catch {
                onError(String(describing: error))
            }
        }
        return KernelHTTPHandle { task.cancel() }
    }
}

// MARK: - The runtime

/// One booted kernel.
///
/// Create with ``init(rootURL:hostName:kv:httpHandler:)``, `await`
/// ``boot()``, then ``openConnection()``. The returned ``KernelSocket`` is
/// the client side of one protocol connection; the GUI-facing wrapper is
/// ``LocalKernelTransport``.
public final class KernelRuntime: @unchecked Sendable {
    /// The kernel's root directory: everything it persists lives under here.
    public let rootURL: URL
    /// The display home string the welcome frame carries.
    public let home: String
    /// The kernel's display name.
    public let hostName: String

    private let queue: DispatchQueue
    // Only ever touched on `queue`.
    private let context: JSContext
    private let kv: any KernelKeyValueStore
    private let httpHandler: any KernelHTTPHandler
    private let logger = Logger(subsystem: "com.shirazu.mizar.kernel", category: "kernel")

    // Queue-confined state.
    private var kernel: JSBox?
    private var booted = false
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimerID = 0

    /// Errors the runtime reports through `boot()` and socket calls.
    public struct RuntimeError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public init(
        rootURL: URL,
        hostName: String,
        kv: any KernelKeyValueStore = UserDefaultsKernelKeyValueStore(),
        httpHandler: any KernelHTTPHandler = URLSessionKernelHTTPHandler(),
    ) {
        let root = rootURL.standardizedFileURL
        self.rootURL = root
        self.home = root.path
        self.rootPathComponents = root.path.split(separator: "/").map(String.init)
        self.hostName = hostName
        self.kv = kv
        self.httpHandler = httpHandler
        self.queue = DispatchQueue(label: "com.shirazu.mizar.kernel.js")
        self.context = JSContext()!
        self.context.name = "MizarKernel"
    }

    // MARK: Boot

    /// Evaluate the bundle and create the kernel.
    public func boot() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            performOnKernelQueue { runtime in
                runtime.bootSync { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func bootSync(_ completion: @escaping @Sendable (Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            context.evaluateScript(KernelBundle.javaScriptSource)
            if let exception = context.exception {
                throw RuntimeError(message: "kernel bundle failed to evaluate: \(exception.toString() ?? "?")")
            }

            // The kernel's createKernel is async; a tiny bridge turns the
            // promise into a callback pair the Swift side can await.
            context.evaluateScript("""
            globalThis.__mizarBootBridge = function (host, onReady, onFail) {
              MizarKernel.createKernel({ host: host }).then(onReady, onFail);
            };
            """)
            if let exception = context.exception {
                throw RuntimeError(message: "boot bridge failed: \(exception.toString() ?? "?")")
            }

            let bridge = context.objectForKeyedSubscript("__mizarBootBridge")
            let host = buildHostObject()
            let onReady: @convention(block) (JSValue) -> Void = { [weak self] kernelValue in
                guard let self else { return }
                self.kernel = JSBox(kernelValue)
                self.booted = true
                self.logger.info("kernel booted")
                completion(nil)
            }
            let onFail: @convention(block) (JSValue) -> Void = { [weak self] error in
                let message = error.toString() ?? "?"
                self?.logger.error("kernel boot failed: \(message, privacy: .public)")
                completion(RuntimeError(message: "kernel boot failed: \(message)"))
            }
            bridge?.call(withArguments: [
                host,
                JSValue(object: onReady, in: context),
                JSValue(object: onFail, in: context),
            ])
        } catch {
            completion(error)
        }
    }

    // MARK: Connections

    /// Open one client connection to the kernel.
    public func openConnection() async throws -> KernelSocket {
        try await withCheckedThrowingContinuation { continuation in
            performOnKernelQueue { runtime in
                runtime.openConnectionSync { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func openConnectionSync(_ completion: @escaping @Sendable (Result<KernelSocket, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard booted, let kernel else {
            completion(.failure(RuntimeError(message: "the kernel is not booted")))
            return
        }
        guard let socketValue = kernel.value.invokeMethod("openConnection", withArguments: []) else {
            completion(.failure(RuntimeError(message: "openConnection returned nothing")))
            return
        }
        let socket = JSBox(socketValue)
        let device = socketValue.objectForKeyedSubscript("deviceId")?.toString() ?? "unknown"

        let sinks = FrameSinks()
        let socketHandle = KernelSocket(deviceID: device, sinks: sinks)

        // The send and close closures hop onto the queue and unwrap the box
        // there; a JSValue never crosses a thread boundary unboxed.
        socketHandle.bind(
            send: { [weak self] text in
                guard let self else { return }
                self.performOnKernelQueue { runtime in
                    socket.value.invokeMethod("send", withArguments: [text])
                    runtime.clearException()
                }
            },
            close: { [weak self] in
                guard let self else { return }
                self.performOnKernelQueue { _ in
                    socket.value.invokeMethod("close", withArguments: [])
                }
            },
        )

        // Frames the kernel pushes arrive here, on the queue.
        let onFrame: @convention(block) (JSValue) -> Void = { text in
            sinks.emit(text.toString() ?? "")
        }
        let onFrameValue = JSValue(object: onFrame, in: context)
        socketValue.invokeMethod("onFrame", withArguments: [onFrameValue])

        completion(.success(socketHandle))
    }

    private func clearException() {
        if let exception = context.exception {
            logger.error("uncaught JS exception: \(exception.toString() ?? "?", privacy: .public)")
            context.exception = nil
        }
    }

    // MARK: The host object

    /// Build the `host` object the kernel's `createKernel` expects.
    /// Called on the queue; every JS-facing closure stays on the queue, and
    /// slow work hops off and back.
    private func buildHostObject() -> JSValue {
        let host = JSValue(newObjectIn: context)!

        func set(_ object: JSValue, _ key: String, _ value: JSValue) {
            object.setObject(value, forKeyedSubscript: key as NSString)
        }

        // The identity strings the welcome frame and `host.info` carry.
        host.setObject(JSValue(object: hostName, in: context), forKeyedSubscript: "hostName" as NSString)
        host.setObject(JSValue(object: home, in: context), forKeyedSubscript: "home" as NSString)
        host.setObject(JSValue(object: "jsc", in: context), forKeyedSubscript: "platformVersion" as NSString)

        // Every function the kernel calls is an ObjC block: plain Swift
        // closures become opaque objects in JS, which is precisely the
        // "not a function" failure a bridge like this earns without them.
        let contextBox = JSContextBox(context)
        let resolveCB: @Sendable (JSValue, JSValue?) -> Void = { cb, value in
            let resolved = value ?? JSValue(nullIn: contextBox.value)
            cb.invokeMethod("ok", withArguments: [resolved])
        }
        let failCB: @Sendable (JSValue, String) -> Void = { cb, message in
            let error = JSValue(newObjectIn: contextBox.value)!
            error.setObject(message, forKeyedSubscript: "message" as NSString)
            cb.invokeMethod("fail", withArguments: [error])
        }

        // -- fs ---------------------------------------------------------------

        let fs = JSValue(newObjectIn: context)!

        let readText: @convention(block) (String, JSValue) -> Void = { [weak self] path, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            self.readOffQueue(path) { text in
                resolveCB(cbBox.value, text.map { JSValue(object: $0, in: self.context) } ?? JSValue(nullIn: self.context))
            }
        }
        set(fs, "readText", JSValue(object: readText, in: context))

        let writeText: @convention(block) (String, String, JSValue) -> Void = { [weak self] path, data, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            self.writeOffQueue(path, data: data) { failure in
                if let failure {
                    failCB(cbBox.value, failure)
                } else {
                    cbBox.value.invokeMethod("ok", withArguments: [])
                }
            }
        }
        set(fs, "writeText", JSValue(object: writeText, in: context))

        let appendText: @convention(block) (String, String, JSValue) -> Void = { [weak self] path, data, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            self.appendOffQueue(path, data: data) { failure in
                if let failure {
                    failCB(cbBox.value, failure)
                } else {
                    cbBox.value.invokeMethod("ok", withArguments: [])
                }
            }
        }
        set(fs, "appendText", JSValue(object: appendText, in: context))

        let deletePath: @convention(block) (String, JSValue) -> Void = { [weak self] path, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            // Deleting a missing file counts as deleted.
            self.deleteOffQueue(path) { cbBox.value.invokeMethod("ok", withArguments: []) }
        }
        set(fs, "deletePath", JSValue(object: deletePath, in: context))

        let listDir: @convention(block) (String, JSValue) -> Void = { [weak self] path, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            self.listOffQueue(path) { entries in
                if let entries {
                    resolveCB(cbBox.value, JSValue(object: entries, in: self.context))
                } else {
                    resolveCB(cbBox.value, JSValue(nullIn: self.context))
                }
            }
        }
        set(fs, "listDir", JSValue(object: listDir, in: context))

        let makeDir: @convention(block) (String, JSValue) -> Void = { [weak self] path, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            self.makeDirOffQueue(path) { failure in
                if let failure {
                    failCB(cbBox.value, failure)
                } else {
                    cbBox.value.invokeMethod("ok", withArguments: [])
                }
            }
        }
        set(fs, "makeDir", JSValue(object: makeDir, in: context))
        set(host, "fs", fs)

        // -- http -------------------------------------------------------------

        let http = JSValue(newObjectIn: context)!
        let request: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] request, handlers in
            guard let self else { return JSValue(undefinedIn: contextBox.value) }
            let url = request.objectForKeyedSubscript("url")?.toString() ?? ""
            let method = request.objectForKeyedSubscript("method")?.toString() ?? "GET"
            var headers: [String: String] = [:]
            if let headerObject = request.objectForKeyedSubscript("headers")?.toDictionary() as? [String: String] {
                headers = headerObject
            }
            let body = request.objectForKeyedSubscript("body")?.toString()
            let kernelRequest = KernelHTTPRequest(url: url, method: method, headers: headers, body: body)

            let settled = SettledFlag()
            let handlersBox = JSBox(handlers)

            // The handlers object itself delivers the callbacks: the same
            // invokeMethod pattern every other bridge callback uses. (A
            // plain `.call` on the handler function from native stalls this
            // embedding; invoking the method on the object that owns it
            // does not — keep the two delivery paths identical.)
            let handle = self.httpHandler.request(kernelRequest, onChunk: { chunk in
                self.performOnKernelQueue { _ in
                    guard !settled.isSettled else { return }
                    handlersBox.value.invokeMethod("onChunk", withArguments: [chunk])
                    self.clearException()
                }
            }, onDone: { status in
                self.performOnKernelQueue { _ in
                    guard settled.settle() else { return }
                    handlersBox.value.invokeMethod("onDone", withArguments: [Int32(status)])
                    self.clearException()
                }
            }, onError: { message in
                self.performOnKernelQueue { _ in
                    guard settled.settle() else { return }
                    handlersBox.value.invokeMethod("onError", withArguments: [message])
                    self.clearException()
                }
            })

            // The kernel calls `handle.abort()`; hand it back as a JS object.
            let abort: @convention(block) () -> Void = { handle.abort() }
            let out = JSValue(newObjectIn: contextBox.value)!
            out.setObject(JSValue(object: abort, in: contextBox.value), forKeyedSubscript: "abort" as NSString)
            return out
        }
        set(http, "request", JSValue(object: request, in: context))
        set(host, "http", http)

        // -- kv ---------------------------------------------------------------

        let kvObject = JSValue(newObjectIn: context)!
        let kvGet: @convention(block) (String, JSValue) -> Void = { [weak self] key, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            let value = self.kv.value(forKey: key)
            self.performOnKernelQueue { _ in
                resolveCB(cbBox.value, value.map { JSValue(object: $0, in: self.context) } ?? JSValue(nullIn: self.context))
            }
        }
        set(kvObject, "get", JSValue(object: kvGet, in: context))
        let kvSet: @convention(block) (String, String, JSValue) -> Void = { [weak self] key, value, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            self.kv.set(value, forKey: key)
            self.performOnKernelQueue { _ in cbBox.value.invokeMethod("ok", withArguments: []) }
        }
        set(kvObject, "set", JSValue(object: kvSet, in: context))
        let kvDelete: @convention(block) (String, JSValue) -> Void = { [weak self] key, cb in
            guard let self else { return }
            let cbBox = JSBox(cb)
            self.kv.set(nil, forKey: key)
            self.performOnKernelQueue { _ in cbBox.value.invokeMethod("ok", withArguments: []) }
        }
        set(kvObject, "delete", JSValue(object: kvDelete, in: context))
        set(host, "kv", kvObject)

        // -- The synchronous surfaces ------------------------------------------

        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            guard let self else { return }
            switch level {
            case "debug": self.logger.debug("\(message, privacy: .public)")
            case "info": self.logger.info("\(message, privacy: .public)")
            case "warn": self.logger.warning("\(message, privacy: .public)")
            default: self.logger.error("\(message, privacy: .public)")
            }
        }
        set(host, "log", JSValue(object: log, in: context))

        let uuid: @convention(block) () -> String = { () in
            UUID().uuidString.lowercased()
        }
        set(host, "uuid", JSValue(object: uuid, in: context))

        let now: @convention(block) () -> Double = { () in
            Date().timeIntervalSince1970 * 1000
        }
        set(host, "now", JSValue(object: now, in: context))

        let setTimeout: @convention(block) (JSValue, Double) -> Double = { [weak self] fn, ms in
            guard let self else { return 0 }
            return Double(self.schedule(fn: fn, ms: ms))
        }
        set(host, "setTimeout", JSValue(object: setTimeout, in: context))

        let clearTimeout: @convention(block) (Double) -> Void = { [weak self] handle in
            guard let self else { return }
            self.cancelTimer(Int(handle))
        }
        set(host, "clearTimeout", JSValue(object: clearTimeout, in: context))

        return host
    }

    // MARK: Queue plumbing

    private func performOnKernelQueue(_ work: @escaping @Sendable (KernelRuntime) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            work(self)
            self.clearException()
        }
    }

    /// The sandbox: every kernel-named path resolves under the root, and a
    /// path that would leave it is refused, never rewritten.
    private func resolve(path: String) -> URL? {
        // Pure string arithmetic on purpose: `URL.appendingPathComponent`
        // touches the file system (a resource lookup per call), and the turn
        // loop resolves a path for every record it writes.
        guard !path.hasPrefix("/") else { return nil }
        let rootParts = rootPathComponents
        var parts = rootParts
        for component in path.split(separator: "/").map(String.init) {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                if parts.count <= rootParts.count { return nil }
                parts.removeLast()
                continue
            }
            parts.append(component)
        }
        guard parts.count > rootParts.count || path == "." else { return nil }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: false)
    }

    /// The root's path split once, at init.
    private let rootPathComponents: [String]

    private func readOffQueue(_ path: String, deliver: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text: String?
            if let self, let url = self.resolve(path: path) {
                text = try? String(contentsOf: url, encoding: .utf8)
            } else {
                text = nil
            }
            self?.performOnKernelQueue { _ in deliver(text) }
        }
    }

    private func writeOffQueue(_ path: String, data: String, deliver: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            deliver(self?.writeSync(path: path, data: data))
        }
    }

    private func appendOffQueue(_ path: String, data: String, deliver: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            deliver(self?.appendSync(path: path, data: data))
        }
    }

    private func deleteOffQueue(_ path: String, deliver: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let self, let url = self.resolve(path: path) {
                try? FileManager.default.removeItem(at: url)
            }
            self?.performOnKernelQueue { _ in deliver() }
        }
    }

    private func listOffQueue(_ path: String, deliver: @escaping @Sendable ([String]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries: [String]?
            if let self, let url = self.resolve(path: path) {
                entries = try? FileManager.default.contentsOfDirectory(atPath: url.path)
            } else {
                entries = nil
            }
            self?.performOnKernelQueue { _ in deliver(entries) }
        }
    }

    private func makeDirOffQueue(_ path: String, deliver: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            deliver(self?.makeDirSync(path: path))
        }
    }

    // Slow fs work; runs off the kernel queue. `nil` failure means success.

    private func writeSync(path: String, data: String) -> String? {
        guard let url = resolve(path: path) else { return "the path escapes the sandbox" }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(data.utf8).write(to: url, options: .atomic)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func appendSync(path: String, data: String) -> String? {
        guard let url = resolve(path: path) else { return "the path escapes the sandbox" }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(data.utf8))
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(data.utf8).write(to: url, options: .atomic)
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func makeDirSync(path: String) -> String? {
        guard let url = resolve(path: path) else { return "the path escapes the sandbox" }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func schedule(fn: JSValue, ms: Double) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        nextTimerID += 1
        let id = nextTimerID
        let box = JSBox(fn)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timers[id] = nil
            box.value.call(withArguments: [])
        }
        timers[id] = work
        queue.asyncAfter(deadline: .now() + ms / 1000, execute: work)
        return id
    }

    private func cancelTimer(_ id: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        timers[id]?.cancel()
        timers[id] = nil
    }
}

// MARK: - Sendability boxes and sinks

/// A JSContext that travels between closures. Same contract as ``JSBox``:
/// only ever unwrapped on the kernel queue.
final class JSContextBox: @unchecked Sendable {
    fileprivate let value: JSContext

    fileprivate init(_ value: JSContext) {
        self.value = value
    }
}

/// A JSValue that travels between closures. The box's contract: the value is
/// only ever unwrapped on the kernel queue.
final class JSBox: @unchecked Sendable {
    fileprivate let value: JSValue

    fileprivate init(_ value: JSValue) {
        self.value = value
    }
}

/// Frame sinks of one connection: every subscriber that awaits kernel frames.
final class FrameSinks: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [(String) -> Void] = []
    private var finishHandler: (() -> Void)?

    func addSink(_ sink: @escaping (String) -> Void) {
        lock.lock()
        sinks.append(sink)
        lock.unlock()
    }

    func onFinish(_ finish: @escaping () -> Void) {
        lock.lock()
        finishHandler = finish
        lock.unlock()
    }

    func emit(_ text: String) {
        lock.lock()
        let current = sinks
        lock.unlock()
        for sink in current { sink(text) }
    }

    func finish() {
        lock.lock()
        let finish = finishHandler
        lock.unlock()
        finish?()
    }
}

/// A once-only settle flag for the HTTP handler contract.
final class SettledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    /// Mark settled; returns whether this call was the one that did it.
    func settle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }
}

// MARK: - The Swift side of one connection

/// The Swift handle of one kernel connection.
public final class KernelSocket: @unchecked Sendable {
    public let deviceID: String
    private let sinks: FrameSinks
    private var sendClosure: (@Sendable (String) -> Void)?
    private var closeClosure: (@Sendable () -> Void)?
    private var frameStream: AsyncStream<String>!
    private var frameIterator: AsyncStream<String>.Iterator!

    fileprivate init(deviceID: String, sinks: FrameSinks) {
        self.deviceID = deviceID
        self.sinks = sinks
        let stream = AsyncStream<String> { continuation in
            sinks.addSink { text in
                continuation.yield(text)
            }
            sinks.onFinish {
                continuation.finish()
            }
        }
        self.frameStream = stream
        self.frameIterator = stream.makeAsyncIterator()
    }

    fileprivate func bind(
        send: @escaping @Sendable (String) -> Void,
        close: @escaping @Sendable () -> Void,
    ) {
        self.sendClosure = send
        self.closeClosure = close
    }

    /// Deliver one client frame to the kernel.
    public func send(text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sendClosure?(text)
            DispatchQueue.global().async { continuation.resume() }
        }
    }

    /// Await the next frame from the kernel, or `nil` when it closed.
    public func nextFrame() async -> String? {
        await frameIterator.next()
    }

    /// Close the connection.
    public func close() async {
        closeClosure?()
        sinks.finish()
    }
}
