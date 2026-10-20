//
//  RelayHeadersTests.swift
//  MizarKitTests
//
//  Where the relay identity headers are actually attached.
//
//  ``RelayIdentity`` builds the two headers; these tests are about the two
//  transports carrying them: the WebSocket upgrade that the host connection uses
//  and the HTTP requests pairing makes. Both are easy to lose in a refactor
//  because nothing on the phone fails when they are missing — the relay simply
//  meters the traffic as anonymous, which is visible only from the admin screen.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Relay headers")
struct RelayHeadersTests {
    private static let identity = RelayIdentity(clientId: "install-1234", accountToken: "mza_abc")

    @Test("carries the identity headers on the socket upgrade")
    func socketUpgradeHeaders() async throws {
        let transport = StubTransport(responder: { text in
            frameType(of: text) == "hello" ? [welcomeFrame()] : []
        })
        let connection = MizarConnection(
            configuration: .init(
                authority: "127.0.0.1:19390",
                token: "mz_device",
                relayHeaders: Self.identity.headers,
            ),
            makeTransport: { transport },
        )

        _ = try await connection.connect()

        let headers = try #require(await transport.dialedHeaders.first)
        #expect(headers[RelayIdentity.clientIdHeader] == "install-1234")
        #expect(headers[RelayIdentity.accountHeader] == RelayIdentity.hash(of: "mza_abc"))
    }

    @Test("sends no extra headers for a direct connection")
    func directConnectionHasNoHeaders() async throws {
        let transport = StubTransport(responder: { text in
            frameType(of: text) == "hello" ? [welcomeFrame()] : []
        })
        let connection = MizarConnection(
            configuration: .init(authority: "127.0.0.1:19390", token: "mz_device"),
            makeTransport: { transport },
        )
        _ = try await connection.connect()
        #expect(await transport.dialedHeaders.first?.isEmpty == true)
    }

    @Test("keeps the session token out of the plain identity headers")
    func sessionTokenIsSeparate() {
        // The hash is what the free relay meters by; the token is what the paid
        // relay verifies. Merging them would send a credential to every host.
        #expect(Self.identity.headers[RelayIdentity.sessionHeader] == nil)
        #expect(Self.identity.sessionHeaders[RelayIdentity.sessionHeader] == "mza_abc")
        #expect(RelayIdentity(clientId: "install-1234").sessionHeaders.isEmpty)
    }

    @Test("only the account host is offered the session token")
    func accountHostRecognition() {
        #expect(AccountClient.isAccountHost("https://dshmizar-1.shirazu-nagisa.com"))
        #expect(AccountClient.isAccountHost("https://DSHMIZAR-1.shirazu-nagisa.com/r/ABCD"))
        #expect(!AccountClient.isAccountHost("https://dshmizar-0.example.com"))
        #expect(!AccountClient.isAccountHost("http://127.0.0.1:8787"))
        #expect(!AccountClient.isAccountHost(""))
    }

    @Test("attaches the identity headers to pairing requests")
    func pairingHeaders() async throws {        let transport = ScriptedHTTPTransport()
        await transport.on(
            "hello",
            body: #"{"hostId":"h1","hostName":"mac","protocolVersion":1,"pairingOpen":true,"paired":false}"#,
        )
        await transport.on(
            "pair",
            body: #"{"deviceToken":"mz_t","deviceId":"d1","hostId":"h1","hostName":"mac","protocolVersion":1}"#,
        )
        let client = PairingClient(transport: transport, headers: Self.identity.headers)

        _ = try await client.hello(authority: "127.0.0.1:19390")
        _ = try await client.pair(
            authority: "127.0.0.1:19390",
            code: "AB2C-D3EF",
            deviceName: "iPhone",
            deviceModel: "iPhone18,1",
        )

        let requests = await transport.recorded()
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: RelayIdentity.clientIdHeader) == "install-1234")
            #expect(request.value(forHTTPHeaderField: RelayIdentity.accountHeader) == RelayIdentity.hash(of: "mza_abc"))
        }
    }
}
