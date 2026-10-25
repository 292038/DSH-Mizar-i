//
//  MizarNetPortMapping.swift
//  MizarKit
//
//  Asking the router to open a door.
//
//  The NAT matrix settles one thing for good: a symmetric acceptor cannot be
//  punched. Its mapping changes per destination, so nothing a peer learns about
//  it is true for the peer itself, and no number of punch rounds changes that.
//
//  What does change it is not asking the NAT at all. A port mapping is a
//  request to the gateway — "forward this UDP port to me" — and a router that
//  grants it makes the endpoint reachable from anywhere, cone or symmetric.
//
//  Two protocols, because home routers speak one or the other:
//
//    - UPnP-IGD: SSDP discovery, then SOAP. What most consumer routers ship.
//    - NAT-PMP: a twelve-byte binary request to the gateway's port 5351.
//
//  Neither returns the external address (NAT-PMP does not, and IGD's is a
//  separate call), so a mapping is only half an address: the port is the
//  router's, the address still comes from STUN. The engine pairs them.
//
//  Failing is normal and cheap: a router with UPnP off, a network that blocks
//  multicast, a gateway somebody else administers. Every failure here returns
//  `nil` and the punch proceeds exactly as it would have.
//

import Foundation

/// A granted forwarding.
public struct MizarNetPortMapping: Sendable, Equatable {
    /// The port the router forwards to this host.
    public let externalPort: UInt16
    /// How long the router promised to keep it, in seconds. Zero means forever.
    public let lifetimeSeconds: UInt32

    public init(externalPort: UInt16, lifetimeSeconds: UInt32) {
        self.externalPort = externalPort
        self.lifetimeSeconds = lifetimeSeconds
    }
}

/// A thing that can ask a router for a port.
public protocol MizarNetPortMapper: Sendable {
    /// Which protocol answered; for logs.
    var provider: String { get }
    /// The mapping in force, or `nil` before ``map(port:lifetimeSeconds:)``.
    func current() async -> MizarNetPortMapping?
    /// Ask for the mapping.
    func map(port: UInt16, lifetimeSeconds: UInt32) async throws -> MizarNetPortMapping
    /// Ask again, extending the lease.
    func renew() async throws -> MizarNetPortMapping
    /// Remove the mapping.
    func remove() async
    /// Release anything the mapper itself holds.
    func close() async
}

/// The HTTP a UPnP mapper needs, behind a seam so a test can answer it.
public protocol MizarNetHTTPClient: Sendable {
    /// Send one request.
    /// - Returns: the status code and the body.
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// The real client: URLSession, with a deadline so a dead router cannot hang a
/// dial.
public struct MizarNetURLSessionClient: MizarNetHTTPClient {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 4) {
        self.timeout = timeout
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        var timed = request
        timed.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: timed)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

/// The port NAT-PMP listens on, at the gateway.
public let mizarNetNATPMPPort: UInt16 = 5351

/// How many times a NAT-PMP request is retried, and how long between.
private let natpmpAttempts = 3
private let natpmpRetry: Duration = .milliseconds(250)

/// NAT-PMP, over a dedicated UDP socket.
public actor MizarNetNATPMPMapper: MizarNetPortMapper {
    public nonisolated var provider: String { "nat-pmp" }

    private let socket: MizarNetUDPSocket
    private let gateway: MizarNetSocketAddress
    private var internalPort: UInt16 = 0
    private var lifetimeSeconds: UInt32 = 0
    private var mapping: MizarNetPortMapping?

    private init(socket: MizarNetUDPSocket, gateway: MizarNetSocketAddress) {
        self.socket = socket
        self.gateway = gateway
    }

    /// Open a mapper.
    /// - Parameters:
    ///   - gateway: the gateway's address.
    ///   - port: its NAT-PMP port. Fixed at 5351 by the RFC; the override
    ///     exists so a test can stand in for a gateway without binding a
    ///     well-known number.
    public static func open(
        gateway: String,
        port: UInt16 = mizarNetNATPMPPort,
    ) async throws -> MizarNetNATPMPMapper {
        let socket = MizarNetUDPSocket()
        try await socket.bind(port: nil)
        return MizarNetNATPMPMapper(socket: socket, gateway: MizarNetSocketAddress(ip: gateway, port: port))
    }

    public func current() -> MizarNetPortMapping? {
        mapping
    }

    public func map(port: UInt16, lifetimeSeconds: UInt32) async throws -> MizarNetPortMapping {
        self.internalPort = port
        self.lifetimeSeconds = lifetimeSeconds
        let mapping = try await request(internalPort: port, suggested: port, lifetime: lifetimeSeconds)
        self.mapping = mapping
        return mapping
    }

    public func renew() async throws -> MizarNetPortMapping {
        guard let mapping else { throw MizarNetPortMappingError.nothingToRenew }
        let renewed = try await request(internalPort: internalPort, suggested: mapping.externalPort, lifetime: lifetimeSeconds)
        self.mapping = renewed
        return renewed
    }

    public func remove() async {
        guard mapping != nil else { return }
        // A zero lifetime is the delete: NAT-PMP has no separate opcode for it.
        _ = try? await request(internalPort: internalPort, suggested: 0, lifetime: 0)
        mapping = nil
    }

    public func close() async {
        await socket.close()
    }

    /// One request/response exchange, retried.
    ///
    /// NAT-PMP runs over UDP with no session, so the first packet can be lost
    /// to a busy router. Three attempts at 250ms survives one drop and stays
    /// inside a dial budget.
    private func request(internalPort: UInt16, suggested: UInt16, lifetime: UInt32) async throws -> MizarNetPortMapping {
        var request = Data()
        request.append(0) // version
        request.append(0) // opcode 0: a UDP mapping
        request.append(contentsOf: [0, 0]) // reserved
        request.appendUInt16BE(internalPort)
        request.appendUInt16BE(suggested)
        request.appendUInt32BE(lifetime)

        for _ in 0..<natpmpAttempts {
            try await socket.send(request, to: gateway)
            guard let reply = await socket.receive(timeout: natpmpRetry) else { continue }
            return try MizarNetNATPMPMapper.parse(reply.data)
        }
        throw MizarNetPortMappingError.gatewaySilent
    }

    /// Parse a mapping response.
    ///
    /// The external port sits after the epoch and the internal port — and it is
    /// the router's choice, not the one we suggested. Echoing the suggestion
    /// would look right on most routers and be wrong on every router that
    /// refuses to hand out the port it was asked for.
    static func parse(_ data: Data) throws -> MizarNetPortMapping {
        guard data.count >= 16 else { throw MizarNetPortMappingError.malformed("short NAT-PMP response") }
        guard data[0] == 0 else { throw MizarNetPortMappingError.malformed("not a NAT-PMP v0 response") }
        guard data[1] & 0x7F == 0 else { throw MizarNetPortMappingError.malformed("unexpected NAT-PMP opcode") }
        let result = UInt16(data[2]) << 8 | UInt16(data[3])
        guard result == 0 else {
            throw MizarNetPortMappingError.refused(code: result)
        }
        let externalPort = UInt16(data[10]) << 8 | UInt16(data[11])
        let lifetime = UInt32(data[12]) << 24 | UInt32(data[13]) << 16 | UInt32(data[14]) << 8 | UInt32(data[15])
        return MizarNetPortMapping(externalPort: externalPort, lifetimeSeconds: lifetime)
    }
}

/// UPnP-IGD, over HTTP and SOAP.
public actor MizarNetUPnPMapper: MizarNetPortMapper {
    public nonisolated var provider: String { "upnp-igd" }

    /// A gateway's control endpoint.
    public struct Device: Sendable, Equatable {
        /// The SOAP endpoint.
        public let controlURL: URL
        /// The service type that endpoint implements.
        public let serviceType: String

        public init(controlURL: URL, serviceType: String) {
            self.controlURL = controlURL
            self.serviceType = serviceType
        }
    }

    /// The service types that can add a mapping, in preference order.
    public static let serviceTypes = [
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    private let device: Device
    private let localAddress: String
    private let http: any MizarNetHTTPClient
    private var internalPort: UInt16 = 0
    private var lifetimeSeconds: UInt32 = 0
    private var mapping: MizarNetPortMapping?

    private init(device: Device, localAddress: String, http: any MizarNetHTTPClient) {
        self.device = device
        self.localAddress = localAddress
        self.http = http
    }

    /// Open a mapper.
    /// - Parameters:
    ///   - device: the IGD's control endpoint.
    ///   - localAddress: the address to forward to; the router must be able to
    ///     reach it, which is why it is the LAN address and not loopback.
    ///   - http: the transport; tests inject one.
    public static func create(
        device: Device,
        localAddress: String,
        http: any MizarNetHTTPClient = MizarNetURLSessionClient(),
    ) -> MizarNetUPnPMapper {
        MizarNetUPnPMapper(device: device, localAddress: localAddress, http: http)
    }

    public func current() -> MizarNetPortMapping? {
        mapping
    }

    public func map(port: UInt16, lifetimeSeconds: UInt32) async throws -> MizarNetPortMapping {
        self.internalPort = port
        self.lifetimeSeconds = lifetimeSeconds
        let mapping = try await addPortMapping(externalPort: port, lifetime: lifetimeSeconds)
        self.mapping = mapping
        return mapping
    }

    public func renew() async throws -> MizarNetPortMapping {
        guard internalPort != 0 else { throw MizarNetPortMappingError.nothingToRenew }
        // Re-adding the same external port is how UPnP renews: there is no
        // renew action, and a refresh with the same tuple is idempotent.
        let mapping = try await addPortMapping(externalPort: internalPort, lifetime: lifetimeSeconds)
        self.mapping = mapping
        return mapping
    }

    public func remove() async {
        guard internalPort != 0 else { return }
        _ = try? await soap(action: "DeletePortMapping", arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(internalPort)),
            ("NewProtocol", "UDP"),
        ])
        mapping = nil
    }

    public func close() async {
        // Nothing held: the mapping belongs to the router until it is deleted
        // or the lease runs out.
    }

    private func addPortMapping(externalPort: UInt16, lifetime: UInt32) async throws -> MizarNetPortMapping {
        _ = try await soap(action: "AddPortMapping", arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", "UDP"),
            ("NewInternalPort", String(internalPort)),
            ("NewInternalClient", localAddress),
            ("NewEnabled", "1"),
            ("NewPortMappingDescription", "mizar-net"),
            // Zero asks for a permanent mapping. A router that insists on a
            // lease grants a shorter one, which is what `renew` is for.
            ("NewLeaseDuration", String(lifetime)),
        ])
        return MizarNetPortMapping(externalPort: externalPort, lifetimeSeconds: lifetime)
    }

    /// One SOAP call.
    ///
    /// A UPnP refusal arrives as HTTP 500 with a `UPnPError` body, so the status
    /// code alone is not enough — the code inside is what says whether the port
    /// is taken (718) or UPnP is disabled (401).
    private func soap(action: String, arguments: [(String, String)]) async throws -> Data {
        let body = """
        <?xml version="1.0"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="\(device.serviceType)">\
        \(arguments.map { "<\($0.0)>\(Self.escapeXML($0.1))</\($0.0)>" }.joined())\
        </u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: device.controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(device.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)

        let (status, data) = try await http.send(request)
        guard (200..<300).contains(status) else {
            let text = String(decoding: data, as: UTF8.self)
            let code = Self.errorCode(in: text)
            throw MizarNetPortMappingError.soapFailed(action: action, code: code)
        }
        return data
    }

    /// The `errorCode` inside a UPnP fault, when there is one.
    static func errorCode(in xml: String) -> String {
        guard let start = xml.range(of: "<errorCode>")?.upperBound,
              let end = xml.range(of: "</errorCode>", range: start..<xml.endIndex)?.lowerBound else {
            return "unknown"
        }
        return String(xml[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escape the five characters XML cares about.
    static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Find the control endpoint in an IGD description document.
    ///
    /// Two tags out of a large document — a real XML parser would be a
    /// dependency for a two-tag job, and the document comes from a router we
    /// have already decided to trust with a port.
    ///
    /// - Parameters:
    ///   - xml: the description document.
    ///   - location: the URL it was fetched from, so a relative control path
    ///     resolves the way the spec says and not relative to nothing.
    /// - Returns: the device, or `nil` when no usable service is declared.
    public static func parseDescription(_ xml: String, location: URL) -> Device? {
        for serviceType in serviceTypes {
            guard let typeRange = xml.range(of: "<serviceType>\(serviceType)</serviceType>") else { continue }
            // The control URL belongs to the same <service> block, so search a
            // window that starts at the type and ends at the block's close.
            let searchEnd = xml.range(of: "</service>", range: typeRange.upperBound..<xml.endIndex)?.upperBound ?? xml.endIndex
            guard let start = xml.range(of: "<controlURL>", range: typeRange.upperBound..<searchEnd)?.upperBound,
                  let end = xml.range(of: "</controlURL>", range: start..<searchEnd)?.lowerBound else { continue }
            let path = String(xml[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: path, relativeTo: location)?.absoluteURL else { continue }
            return Device(controlURL: url, serviceType: serviceType)
        }
        return nil
    }
}

/// What can go wrong asking a router for a port.
public enum MizarNetPortMappingError: Error, Sendable, Equatable {
    /// The gateway answered, and said no.
    case refused(code: UInt16)
    /// The gateway did not answer at all.
    case gatewaySilent
    /// The answer was not a NAT-PMP mapping response.
    case malformed(String)
    /// A SOAP call failed; `code` is the UPnP error code when there was one.
    case soapFailed(action: String, code: String)
    /// `renew` before `map`.
    case nothingToRenew
}

/// Try every protocol this host can, and return the first mapper that works.
public enum MizarNetPortMappingService {
    /// What the caller can tell the orchestrator.
    public struct Options: Sendable {
        /// A known IGD description URL, skipping SSDP.
        public var descriptionURL: URL?
        /// The gateway's IPv4 address, when NAT-PMP should be tried.
        public var gateway: String?
        /// The address the router should forward to; defaults to the LAN address.
        public var localAddress: String?
        /// How long to ask for. Zero means permanent.
        public var lifetimeSeconds: UInt32
        /// The HTTP transport, for tests.
        public var http: any MizarNetHTTPClient

        public init(
            descriptionURL: URL? = nil,
            gateway: String? = nil,
            localAddress: String? = nil,
            lifetimeSeconds: UInt32 = 0,
            http: any MizarNetHTTPClient = MizarNetURLSessionClient(),
        ) {
            self.descriptionURL = descriptionURL
            self.gateway = gateway
            self.localAddress = localAddress
            self.lifetimeSeconds = lifetimeSeconds
            self.http = http
        }
    }

    /// Open a mapping, or say that no router agreed.
    ///
    /// UPnP first — that is what consumer routers actually ship; NAT-PMP
    /// second, because when it is there it is one round trip.
    ///
    /// - Parameters:
    ///   - port: the local port to forward.
    ///   - options: what the caller already knows.
    /// - Returns: a working mapper, or `nil`.
    public static func open(port: UInt16, options: Options) async -> (any MizarNetPortMapper)? {
        let localAddress = options.localAddress ?? MizarNetUDPSocket.hostAddresses().first { address in
            address != "127.0.0.1" && !address.hasPrefix("169.254.")
        }
        guard let localAddress else { return nil }

        if let url = options.descriptionURL {
            if let device = await describe(url: url, http: options.http) {
                let mapper = MizarNetUPnPMapper.create(device: device, localAddress: localAddress, http: options.http)
                if (try? await mapper.map(port: port, lifetimeSeconds: options.lifetimeSeconds)) != nil {
                    return mapper
                }
            }
        } else if let device = await discover(http: options.http) {
            let mapper = MizarNetUPnPMapper.create(device: device, localAddress: localAddress, http: options.http)
            if (try? await mapper.map(port: port, lifetimeSeconds: options.lifetimeSeconds)) != nil {
                return mapper
            }
        }

        if let gateway = options.gateway, let mapper = try? await MizarNetNATPMPMapper.open(gateway: gateway) {
            if (try? await mapper.map(port: port, lifetimeSeconds: options.lifetimeSeconds)) != nil {
                return mapper
            }
            await mapper.close()
        }
        return nil
    }

    /// Read a description document into a device.
    static func describe(url: URL, http: any MizarNetHTTPClient) async -> MizarNetUPnPMapper.Device? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let (status, data) = try? await http.send(request), (200..<300).contains(status) else { return nil }
        return MizarNetUPnPMapper.parseDescription(String(decoding: data, as: UTF8.self), location: url)
    }

    /// Find a gateway's IGD control endpoint over SSDP.
    ///
    /// Multicast discovery is best-effort by nature: a network that blocks it, a
    /// router with UPnP off, or a guest Wi-Fi all produce nothing, and the punch
    /// proceeds without a mapping.
    static func discover(http: any MizarNetHTTPClient) async -> MizarNetUPnPMapper.Device? {
        guard let socket = try? await openSSDPSocket() else { return nil }
        defer { Task { await socket.close() } }

        let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(MizarNetUPnPMapper.serviceTypes[1])\r\n\r\n"
        try? await socket.send(Data(search.utf8), to: MizarNetSocketAddress(ip: "239.255.255.250", port: 1900))

        var locations: [URL] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            guard let reply = await socket.receive(timeout: .milliseconds(200)) else { continue }
            guard let text = String(data: reply.data, encoding: .utf8),
                  let location = Self.ssdpLocation(in: text),
                  !locations.contains(location) else { continue }
            locations.append(location)
        }
        for location in locations {
            if let device = await describe(url: location, http: http) { return device }
        }
        return nil
    }

    /// The `LOCATION` header of an SSDP reply.
    static func ssdpLocation(in text: String) -> URL? {
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "location" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return URL(string: value)
        }
        return nil
    }

    private static func openSSDPSocket() async throws -> MizarNetUDPSocket {
        let socket = MizarNetUDPSocket()
        try await socket.bind(port: nil)
        return socket
    }
}

private extension Data {
    mutating func append(_ byte: UInt8) {
        append(contentsOf: [byte])
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}
