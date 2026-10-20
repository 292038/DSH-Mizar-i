//
//  LocalKernelTransport.swift
//  MizarKit
//
//  The local kernel as a `WebSocketTransport`.
//
//  The whole point of the local kernel's protocol fidelity is on display
//  here: `MizarConnection` needs four methods — connect, send, receive,
//  close — and a socket that behaves like the wire. This actor provides them
//  against an in-process ``KernelRuntime``, so the same connection layer,
//  reconnection plan, correlation and event stream that serve a desktop host
//  serve the kernel too, and the GUI switches between "remote" and "local"
//  by choosing a transport.
//
//  The `url` and `headers` of `connect` are accepted and ignored: a local
//  kernel has no socket to dial. Callers pass whatever endpoint the
//  connection's configuration carries (typically the loopback authority a
//  real host would use), and the frames travel in process.
//

import Foundation

/// A `WebSocketTransport` backed by an in-process kernel.
public actor LocalKernelTransport: WebSocketTransport {
    private let runtime: KernelRuntime
    private var socket: KernelSocket?
    private var opened = false

    public init(runtime: KernelRuntime) {
        self.runtime = runtime
    }

    public func connect(url: URL, headers: [String: String]) async throws {
        guard socket == nil else {
            throw MizarError(code: "SOCKET_CLOSED", message: "the transport is already connected", retryable: true)
        }
        let connection = try await runtime.openConnection()
        socket = connection
        opened = true
    }

    public func send(text: String) async throws {
        guard opened, let socket else {
            throw MizarError(code: "SOCKET_CLOSED", message: "the socket is not open", retryable: true)
        }
        await socket.send(text: text)
    }

    public func receive() async throws -> String? {
        guard opened, let socket else { return nil }
        let frame = await socket.nextFrame()
        return frame
    }

    public func close() async {
        guard let socket else { return }
        opened = false
        self.socket = nil
        await socket.close()
    }
}
