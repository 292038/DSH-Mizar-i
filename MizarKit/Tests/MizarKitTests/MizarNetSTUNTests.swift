//
//  MizarNetSTUNTests.swift
//  MizarKitTests
//
//  The binding transaction, without a server.
//
//  The request bytes and the response parsing are pinned here because a
//  subtle mistake in either — a wrong XOR mask, an unaligned attribute
//  walk, a transaction id compared against the wrong slice — produces a
//  candidate list that is silently empty, and a punch that only ever tries
//  host addresses. The fake responder in the engine tests covers the live
//  path; these tests cover the codec.
//

import Foundation
import Testing

@testable import MizarKit

struct MizarNetSTUNTests {
    private let transactionId = Data((0..<12).map { UInt8($0) })

    @Test("a binding request is the twenty bytes the RFC allows")
    func requestShape() {
        let request = MizarNetSTUN.bindingRequest(transactionId: transactionId)
        #expect(request.count == 20)
        #expect(request.subdata(in: 0..<2) == Data([0x00, 0x01])) // Binding Request
        #expect(request.subdata(in: 2..<4) == Data([0x00, 0x00])) // no attributes
        #expect(request.subdata(in: 4..<8) == Data([0x21, 0x12, 0xA4, 0x42])) // magic cookie
        #expect(request.subdata(in: 8..<20) == transactionId)
    }

    @Test("a XOR-MAPPED-ADDRESS response is decoded")
    func responseDecodes() {
        // 198.51.100.23:54321, XOR'd the way RFC 5389 requires.
        let response = xorMappedResponse(ip: [198, 51, 100, 23], port: 54321)
        let mapped = MizarNetSTUN.parseBindingResponse(response, expectedTransactionId: transactionId)
        #expect(mapped?.ip == "198.51.100.23")
        #expect(mapped?.port == 54321)
    }

    @Test("a plain MAPPED-ADDRESS response is accepted as a fallback")
    func plainMappedDecodes() {
        var attribute = Data()
        attribute.appendUInt16(MizarNetSTUN.mappedAddressAttribute)
        attribute.appendUInt16(8)
        attribute.append(0x00) // reserved
        attribute.append(0x01) // family: IPv4
        attribute.appendUInt16(1234)
        attribute.append(contentsOf: [192, 0, 2, 1])
        var message = Data()
        message.appendUInt16(MizarNetSTUN.bindingSuccessResponseType)
        message.appendUInt16(UInt16(attribute.count))
        message.appendUInt32(MizarNetSTUN.magicCookie)
        message.append(transactionId)
        message.append(attribute)
        let mapped = MizarNetSTUN.parseBindingResponse(message, expectedTransactionId: transactionId)
        #expect(mapped?.ip == "192.0.2.1")
        #expect(mapped?.port == 1234)
    }

    @Test("a response for another transaction is somebody else's answer")
    func wrongTransactionIsRejected() {
        let response = xorMappedResponse(ip: [198, 51, 100, 23], port: 54321)
        let other = Data((100..<112).map { UInt8($0) })
        #expect(MizarNetSTUN.parseBindingResponse(response, expectedTransactionId: other) == nil)
    }

    @Test("garbage and short data are rejected, not crashed on")
    func garbageIsRejected() {
        #expect(MizarNetSTUN.parseBindingResponse(Data(), expectedTransactionId: transactionId) == nil)
        #expect(MizarNetSTUN.parseBindingResponse(Data(repeating: 0, count: 19), expectedTransactionId: transactionId) == nil)
        // A binding *request* is not a response.
        #expect(MizarNetSTUN.parseBindingResponse(MizarNetSTUN.bindingRequest(transactionId: transactionId), expectedTransactionId: transactionId) == nil)
        // Ours, not STUN's.
        #expect(MizarNetSTUN.looksLikeSTUN(Data("MZP1".utf8)) == false)
        #expect(MizarNetSTUN.looksLikeSTUN(xorMappedResponse(ip: [1, 2, 3, 4], port: 5)))
    }

    @Test("unknown attributes are skipped, not fatal")
    func unknownAttributesAreSkipped() {
        var unknown = Data()
        unknown.appendUInt16(0x8022) // SOFTWARE, or anything else
        unknown.appendUInt16(4)
        unknown.append(Data("test".utf8))
        var response = Data()
        response.appendUInt16(MizarNetSTUN.bindingSuccessResponseType)
        response.appendUInt16(UInt16(unknown.count + 12))
        response.appendUInt32(MizarNetSTUN.magicCookie)
        response.append(transactionId)
        response.append(unknown)
        response.append(xorMappedAttribute(ip: [203, 0, 113, 9], port: 40000))
        let mapped = MizarNetSTUN.parseBindingResponse(response, expectedTransactionId: transactionId)
        #expect(mapped?.ip == "203.0.113.9")
        #expect(mapped?.port == 40000)
    }

    // MARK: - Helpers

    private func xorMappedAttribute(ip: [UInt8], port: UInt16) -> Data {
        var attribute = Data()
        attribute.appendUInt16(MizarNetSTUN.xorMappedAddressAttribute)
        attribute.appendUInt16(8)
        attribute.append(0x00) // reserved
        attribute.append(0x01) // family: IPv4
        attribute.appendUInt16(port ^ UInt16(MizarNetSTUN.magicCookie >> 16))
        let cookieBytes = [UInt8(0x21), UInt8(0x12), UInt8(0xA4), UInt8(0x42)]
        for (index, byte) in ip.enumerated() {
            attribute.append(byte ^ cookieBytes[index])
        }
        return attribute
    }

    private func xorMappedResponse(ip: [UInt8], port: UInt16) -> Data {
        let attribute = xorMappedAttribute(ip: ip, port: port)
        var message = Data()
        message.appendUInt16(MizarNetSTUN.bindingSuccessResponseType)
        message.appendUInt16(UInt16(attribute.count))
        message.appendUInt32(MizarNetSTUN.magicCookie)
        message.append(transactionId)
        message.append(attribute)
        return message
    }
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
