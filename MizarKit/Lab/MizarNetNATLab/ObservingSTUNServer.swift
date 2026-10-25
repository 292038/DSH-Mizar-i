//
//  ObservingSTUNServer.swift
//  MizarNetNATLab
//
//  A STUN server that tells the truth.
//
//  A real STUN server reports the address a request *arrived from* — which,
//  for a client behind a NAT, is that NAT's mapping. This one does exactly
//  that and nothing more: it answers a binding request with the datagram's
//  source address as the XOR-MAPPED-ADDRESS. No fixed fake address, no
//  configuration: whatever mapping the simulated NAT put on the packet is
//  what the engine learns, which is the whole point of the exercise.
//

import Foundation
import MizarKit

/// A minimal RFC 5389 responder that echoes the observed address.
public actor ObservingSTUNServer {
    private let socket: MizarNetUDPSocket
    private var task: Task<Void, Never>?

    public init() async throws {
        socket = MizarNetUDPSocket()
        try await socket.bind(port: nil)
    }

    /// The address to configure as the engine's STUN server.
    public var address: MizarNetSocketAddress {
        get async {
            await socket.localAddress ?? MizarNetSocketAddress(ip: "127.0.0.1", port: 0)
        }
    }

    public func start() {
        guard task == nil else { return }
        let socket = self.socket
        task = Task.detached {
            for await datagram in socket.events {
                await self.answer(datagram)
            }
        }
    }

    public func stop() async {
        task?.cancel()
        task = nil
        await socket.close()
    }

    private func answer(_ datagram: MizarNetDatagram) async {
        guard MizarNetSTUN.looksLikeSTUN(datagram.data),
              datagram.data.count >= MizarNetSTUN.headerLength,
              bigEndianUInt16(datagram.data, at: 0) == MizarNetSTUN.bindingRequestType,
              let transactionId = MizarNetSTUN.transactionId(of: datagram.data) else {
            return
        }

        // XOR-MAPPED-ADDRESS carrying the observed source — the address a
        // real server would report for this client.
        var attribute = Data()
        attribute.appendUInt16(MizarNetSTUN.xorMappedAddressAttribute)
        attribute.appendUInt16(8)
        attribute.append(0x00) // reserved
        attribute.append(0x01) // family: IPv4
        attribute.appendUInt16(datagram.from.port ^ UInt16(MizarNetSTUN.magicCookie >> 16))
        let cookieBytes = [UInt8(0x21), UInt8(0x12), UInt8(0xA4), UInt8(0x42)]
        for (index, part) in datagram.from.ip.split(separator: ".").prefix(4).enumerated() {
            attribute.append((UInt8(part) ?? 0) ^ cookieBytes[index])
        }

        var message = Data()
        message.appendUInt16(MizarNetSTUN.bindingSuccessResponseType)
        message.appendUInt16(UInt16(attribute.count))
        message.appendUInt32(MizarNetSTUN.magicCookie)
        message.append(transactionId)
        message.append(attribute)
        try? await socket.send(message, to: datagram.from)
    }
}

private func bigEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
