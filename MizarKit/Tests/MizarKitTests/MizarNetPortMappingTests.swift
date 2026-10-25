//
//  MizarNetPortMappingTests.swift
//  MizarKitTests
//
//  Asking a router for a port, against routers that answer, refuse and vanish.
//
//  The three outcomes are not equal in importance: a refusal and a silence are
//  the common cases (UPnP off, a corporate gateway, a guest network), and both
//  have to leave the punch exactly as it was. The grant is the rare one, and it
//  is the only thing that makes a symmetric acceptor reachable at all.
//

import Foundation
import Testing

@testable import MizarKit
import MizarNetNATLab

@Suite("Asking a router for a port")
struct MizarNetPortMappingTests {
    /// A gateway that speaks NAT-PMP and records what it was asked.
    actor FakeGateway {
        private let socket = MizarNetUDPSocket()
        private var loop: Task<Void, Never>?
        private(set) var requests: [(internalPort: UInt16, suggested: UInt16, lifetime: UInt32)] = []

        let resultCode: UInt16

        init(resultCode: UInt16 = 0) {
            self.resultCode = resultCode
        }

        var port: UInt16 {
            get async { await socket.localAddress?.port ?? 0 }
        }

        func start() async throws {
            try await socket.bind(port: nil)
            loop = Task.detached { [socket, resultCode] in
                for await datagram in socket.events {
                    guard datagram.data.count >= 12 else { continue }
                    let internalPort = UInt16(datagram.data[4]) << 8 | UInt16(datagram.data[5])
                    let suggested = UInt16(datagram.data[6]) << 8 | UInt16(datagram.data[7])
                    let lifetime = UInt32(datagram.data[8]) << 24 | UInt32(datagram.data[9]) << 16
                        | UInt32(datagram.data[10]) << 8 | UInt32(datagram.data[11])
                    await self.record(internalPort: internalPort, suggested: suggested, lifetime: lifetime)

                    var response = Data([0, 0x80])
                    response.append(contentsOf: [UInt8(resultCode >> 8), UInt8(resultCode & 0xFF)])
                    response.append(contentsOf: [0, 0, 0, 0]) // epoch
                    response.append(contentsOf: [UInt8(internalPort >> 8), UInt8(internalPort & 0xFF)])
                    // The router's choice, deliberately not the suggested port:
                    // a mapper that echoes the suggestion fails this test.
                    let external: UInt16 = internalPort == 0 ? 0 : 41234
                    response.append(contentsOf: [UInt8(external >> 8), UInt8(external & 0xFF)])
                    response.append(contentsOf: [
                        UInt8((lifetime >> 24) & 0xFF), UInt8((lifetime >> 16) & 0xFF),
                        UInt8((lifetime >> 8) & 0xFF), UInt8(lifetime & 0xFF),
                    ])
                    try? await socket.send(response, to: datagram.from)
                }
            }
        }

        private func record(internalPort: UInt16, suggested: UInt16, lifetime: UInt32) {
            requests.append((internalPort, suggested, lifetime))
        }

        func stop() async {
            loop?.cancel()
            loop = nil
            await socket.close()
        }
    }

    /// An HTTP client that answers from a table and records what it was asked.
    actor FakeHTTP: MizarNetHTTPClient {
        struct Response: Sendable {
            let status: Int
            let body: Data
        }

        private(set) var requests: [URLRequest] = []
        private let handler: @Sendable (URLRequest) -> Response

        init(handler: @escaping @Sendable (URLRequest) -> Response) {
            self.handler = handler
        }

        func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
            requests.append(request)
            let response = handler(request)
            return (response.status, response.body)
        }

        func bodies() -> [String] {
            requests.map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        }
    }

    private func descriptionDocument(serviceType: String = "urn:schemas-upnp-org:service:WANIPConnection:1") -> String {
        """
        <?xml version="1.0"?><root><device><serviceList><service>\
        <serviceType>\(serviceType)</serviceType>\
        <controlURL>/control</controlURL>\
        </service></serviceList></device></root>
        """
    }

    // MARK: - NAT-PMP

    @Test("NAT-PMP asks for the port and reports what the gateway granted")
    func natpmpGrants() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { Task { await gateway.stop() } }

        let mapper = try await MizarNetNATPMPMapper.open(gateway: "127.0.0.1", port: await gateway.port)
        let mapping = try await mapper.map(port: 40001, lifetimeSeconds: 3600)
        #expect(mapping.externalPort == 41234)
        #expect(mapping.lifetimeSeconds == 3600)
        if let request = await gateway.requests.first {
            #expect(request.internalPort == 40001)
            #expect(request.suggested == 40001)
        } else {
            Issue.record("the gateway received nothing")
        }
        await mapper.close()
    }

    @Test("NAT-PMP deletes by asking for a zero lifetime")
    func natpmpDeletes() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { Task { await gateway.stop() } }

        let mapper = try await MizarNetNATPMPMapper.open(gateway: "127.0.0.1", port: await gateway.port)
        _ = try await mapper.map(port: 40002, lifetimeSeconds: 0)
        await mapper.remove()
        if let last = await gateway.requests.last {
            #expect(last.suggested == 0)
            #expect(last.lifetime == 0)
        } else {
            Issue.record("the gateway received nothing")
        }
        #expect(await mapper.current() == nil)
        await mapper.close()
    }

    @Test("NAT-PMP reports a refusal instead of pretending")
    func natpmpRefuses() async throws {
        let gateway = FakeGateway(resultCode: 2) // "not authorized"
        try await gateway.start()
        defer { Task { await gateway.stop() } }

        let mapper = try await MizarNetNATPMPMapper.open(gateway: "127.0.0.1", port: await gateway.port)
        await #expect(throws: MizarNetPortMappingError.refused(code: 2)) {
            _ = try await mapper.map(port: 40003, lifetimeSeconds: 0)
        }
        await mapper.close()
    }

    @Test("NAT-PMP gives up when nothing answers")
    func natpmpSilence() async throws {
        // Port 9 on loopback: bound by nobody, answered by nobody.
        let mapper = try await MizarNetNATPMPMapper.open(gateway: "127.0.0.1", port: 9)
        let started = ContinuousClock.now
        await #expect(throws: MizarNetPortMappingError.gatewaySilent) {
            _ = try await mapper.map(port: 40004, lifetimeSeconds: 0)
        }
        // Three attempts at 250ms, and not a second more: a dial budget cannot
        // afford a router that never answers.
        #expect(started.duration(to: .now) < .seconds(3))
        await mapper.close()
    }

    @Test("a malformed NAT-PMP response is refused, not guessed at")
    func natpmpMalformed() {
        #expect(throws: MizarNetPortMappingError.self) {
            _ = try MizarNetNATPMPMapper.parse(Data([0, 0x80, 0, 0]))
        }
        // A response with the right length but a non-zero version is a different
        // protocol, not this one.
        var wrongVersion = Data(repeating: 0, count: 16)
        wrongVersion[0] = 1
        #expect(throws: MizarNetPortMappingError.self) {
            _ = try MizarNetNATPMPMapper.parse(wrongVersion)
        }
    }

    // MARK: - UPnP

    @Test("the description yields the control endpoint")
    func descriptionParses() throws {
        let location = try #require(URL(string: "http://192.168.1.1:5000/desc.xml"))
        let device = try #require(MizarNetUPnPMapper.parseDescription(descriptionDocument(), location: location))
        #expect(device.serviceType == "urn:schemas-upnp-org:service:WANIPConnection:1")
        // A relative control URL resolves against the description's own URL.
        #expect(device.controlURL.absoluteString == "http://192.168.1.1:5000/control")
    }

    @Test("a description with no IGD service yields nothing")
    func descriptionWithoutService() throws {
        let location = try #require(URL(string: "http://192.168.1.1/desc.xml"))
        let xml = descriptionDocument(serviceType: "urn:schemas-upnp-org:service:ContentDirectory:1")
        #expect(MizarNetUPnPMapper.parseDescription(xml, location: location) == nil)
    }

    @Test("the error code is read out of a UPnP fault")
    func errorCodeParsing() {
        let fault = "<s:Fault><detail><UPnPError><errorCode>718</errorCode></UPnPError></detail></s:Fault>"
        #expect(MizarNetUPnPMapper.errorCode(in: fault) == "718")
        #expect(MizarNetUPnPMapper.errorCode(in: "<ok/>") == "unknown")
    }

    @Test("UPnP sends the mapping a router needs")
    func upnpSendsMapping() async throws {
        let http = FakeHTTP { _ in
            .init(status: 200, body: Data("<ok/>".utf8))
        }
        let location = try #require(URL(string: "http://192.168.1.1/desc.xml"))
        let device = try #require(MizarNetUPnPMapper.parseDescription(descriptionDocument(), location: location))
        let mapper = MizarNetUPnPMapper.create(device: device, localAddress: "192.168.1.10", http: http)

        let mapping = try await mapper.map(port: 40010, lifetimeSeconds: 0)
        #expect(mapping.externalPort == 40010)
        let body = await http.bodies().last ?? ""
        for fragment in [
            "<NewExternalPort>40010</NewExternalPort>",
            "<NewProtocol>UDP</NewProtocol>",
            "<NewInternalPort>40010</NewInternalPort>",
            "<NewInternalClient>192.168.1.10</NewInternalClient>",
            "<NewEnabled>1</NewEnabled>",
            "<NewLeaseDuration>0</NewLeaseDuration>",
            "AddPortMapping",
        ] {
            #expect(body.contains(fragment), "the SOAP body is missing \(fragment)")
        }

        await mapper.remove()
        #expect(await http.bodies().last?.contains("DeletePortMapping") == true)
    }

    @Test("a UPnP refusal surfaces its error code")
    func upnpRefusal() async throws {
        // 718 is ConflictInMappingEntry — what a user hits when something else
        // on the LAN already forwards that port.
        let fault = "<s:Fault><detail><UPnPError><errorCode>718</errorCode></UPnPError></detail></s:Fault>"
        let http = FakeHTTP { _ in
            .init(status: 500, body: Data(fault.utf8))
        }
        let location = try #require(URL(string: "http://192.168.1.1/desc.xml"))
        let device = try #require(MizarNetUPnPMapper.parseDescription(descriptionDocument(), location: location))
        let mapper = MizarNetUPnPMapper.create(device: device, localAddress: "192.168.1.10", http: http)

        await #expect(throws: MizarNetPortMappingError.soapFailed(action: "AddPortMapping", code: "718")) {
            _ = try await mapper.map(port: 40012, lifetimeSeconds: 0)
        }
    }

    // MARK: - The orchestrator

    @Test("the service finds a device through a known description URL")
    func serviceOpensThroughDescription() async throws {
        let http = FakeHTTP { request in
            if request.url?.path == "/desc.xml" {
                return .init(status: 200, body: Data(self.descriptionDocument().utf8))
            }
            return .init(status: 200, body: Data("<ok/>".utf8))
        }
        let url = try #require(URL(string: "http://192.168.1.1/desc.xml"))
        let mapper = await MizarNetPortMappingService.open(
            port: 40020,
            options: .init(descriptionURL: url, localAddress: "192.168.1.10", http: http),
        )
        #expect(mapper?.provider == "upnp-igd")
        #expect(await mapper?.current()?.externalPort == 40020)
    }

    @Test("the service says no when no router agrees")
    func serviceWithoutRouter() async {
        // A description URL nothing answers, and no gateway to try.
        let url = URL(string: "http://127.0.0.1:9/desc.xml")!
        let http = FakeHTTP { _ in .init(status: 404, body: Data()) }
        let mapper = await MizarNetPortMappingService.open(
            port: 40021,
            options: .init(descriptionURL: url, localAddress: "192.168.1.10", http: http),
        )
        #expect(mapper == nil)
    }

    // MARK: - The engine

    /// A mapper that grants whatever it is asked, and records the calls.
    actor StubMapper: MizarNetPortMapper {
        nonisolated let provider = "stub"
        private(set) var calls: [String] = []
        private var mapping: MizarNetPortMapping?

        init(mapping: MizarNetPortMapping? = MizarNetPortMapping(externalPort: 55555, lifetimeSeconds: 0)) {
            self.mapping = mapping
        }

        func current() -> MizarNetPortMapping? { mapping }

        func map(port: UInt16, lifetimeSeconds: UInt32) -> MizarNetPortMapping {
            calls.append("map:\(port)")
            mapping = MizarNetPortMapping(externalPort: 55555, lifetimeSeconds: lifetimeSeconds)
            return mapping!
        }

        func renew() throws -> MizarNetPortMapping {
            calls.append("renew")
            guard let mapping else { throw MizarNetPortMappingError.nothingToRenew }
            return mapping
        }

        func remove() {
            calls.append("remove")
            mapping = nil
        }

        func close() {
            calls.append("close")
        }
    }

    @Test("the engine advertises a forwarded port next to the reflexive address")
    func engineAdvertisesMapping() async throws {
        // A real STUN responder on loopback: with no NAT in front it reports the
        // engine's own port, which is exactly what the engine needs an address
        // for — the mapping supplies the port, STUN supplies the address.
        let stun = try await ObservingSTUNServer()
        await stun.start()
        defer { Task { await stun.stop() } }

        let mapper = StubMapper()
        let engine = MizarNetQUICEngine(
            identity: MizarNetIdentity.generate(),
            policy: .standard,
            stunServers: ["127.0.0.1:\(await stun.address.port)"],
            portMapper: mapper,
        )
        try await engine.start()
        let candidates = await engine.localCandidates()
        let reflexive = candidates.filter { $0.kind == .serverReflexive }
        // Two reflexive candidates: what STUN saw, and the port the router
        // forwards. The forwarded one comes first — it works from places the
        // other does not.
        #expect(reflexive.count == 2)
        #expect(reflexive.first?.port == 55555)
        #expect(reflexive.first?.address == reflexive.last?.address)

        await engine.shutdown()
        let calls = await mapper.calls
        #expect(calls.contains("remove"))
        #expect(calls.contains("close"))
    }

    @Test("the engine drops a mapping it cannot put an address on")
    func engineDropsUnpairedMapping() async throws {
        // No STUN: the router granted a port, but there is no address to pair it
        // with, so advertising it would be advertising half an address.
        let mapper = StubMapper()
        let engine = MizarNetQUICEngine(
            identity: MizarNetIdentity.generate(),
            policy: .standard,
            stunServers: [],
            portMapper: mapper,
        )
        try await engine.start()
        let candidates = await engine.localCandidates()
        #expect(!candidates.contains { $0.port == 55555 })
        #expect(await mapper.calls.contains("remove"))
        await engine.shutdown()
    }

    @Test("a refused mapping leaves the punch exactly as it was")
    func engineSurvivesRefusal() async throws {
        let stun = try await ObservingSTUNServer()
        await stun.start()
        defer { Task { await stun.stop() } }

        let engine = MizarNetQUICEngine(
            identity: MizarNetIdentity.generate(),
            policy: .standard,
            stunServers: ["127.0.0.1:\(await stun.address.port)"],
            portMapper: RefusingMapper(),
        )
        try await engine.start()
        let candidates = await engine.localCandidates()
        #expect(candidates.contains { $0.kind == .serverReflexive })
        #expect(!candidates.contains { $0.port == 55555 })
        await engine.shutdown()
    }
}

/// A mapper that fails every call, the way a router with UPnP off does.
private actor RefusingMapper: MizarNetPortMapper {
    nonisolated let provider = "refusing"
    func current() -> MizarNetPortMapping? { nil }
    func map(port: UInt16, lifetimeSeconds: UInt32) throws -> MizarNetPortMapping {
        throw MizarNetPortMappingError.gatewaySilent
    }
    func renew() throws -> MizarNetPortMapping {
        throw MizarNetPortMappingError.gatewaySilent
    }
    func remove() {}
    func close() {}
}
