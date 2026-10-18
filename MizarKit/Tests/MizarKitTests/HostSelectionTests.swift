import Foundation
import Testing
@testable import MizarKit

private func pairedHost(_ id: String, pairedAt: TimeInterval, name: String = "computer") -> PairedHost {
    PairedHost(
        hostId: id,
        hostName: name,
        authority: "192.168.1.20:19390",
        deviceId: "device-\(id)",
        deviceToken: "mz_\(id)",
        pairedAt: Date(timeIntervalSince1970: pairedAt),
    )
}

@Suite("Host selection")
struct HostSelectionTests {
    @Test("opens the machine the operator last opened, not the one paired last")
    func rememberedMachineWins() {
        let first = pairedHost("host-a", pairedAt: 1_700_000_000)
        let second = pairedHost("host-b", pairedAt: 1_700_000_500)

        // The second machine was paired later; the operator went back to the
        // first. A launch has to follow the operator, or the app comes up on a
        // computer whose sessions, notifications and Live Activity are not the ones
        // the operator was using.
        let chosen = HostSelection.preferred(in: [second, first], lastOpenedId: "host-a")
        #expect(chosen?.hostId == "host-a")
    }

    @Test("falls back to the most recently paired machine with no memory")
    func fallsBackToLatestPaired() {
        let first = pairedHost("host-a", pairedAt: 1_700_000_000)
        let second = pairedHost("host-b", pairedAt: 1_700_000_500)

        let chosen = HostSelection.preferred(in: [first, second], lastOpenedId: nil)
        #expect(chosen?.hostId == "host-b")
    }

    @Test("falls back when the remembered machine is no longer paired")
    func forgottenMachineFallsBack() {
        let first = pairedHost("host-a", pairedAt: 1_700_000_000)
        let second = pairedHost("host-b", pairedAt: 1_700_000_500)

        let chosen = HostSelection.preferred(in: [first, second], lastOpenedId: "host-gone")
        #expect(chosen?.hostId == "host-b")
    }

    @Test("answers no machine when nothing is paired")
    func noHosts() {
        #expect(HostSelection.preferred(in: [], lastOpenedId: "host-a") == nil)
        #expect(HostSelection.preferred(in: [], lastOpenedId: nil) == nil)
    }

    @Test("remembers, changes and forgets the last opened machine")
    func storeRoundTrip() {
        let name = "mizar.tests.lastOpenedHost.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(LastOpenedHostStore.stored(in: defaults) == nil)
        #expect(LastOpenedHostStore.store("host-a", in: defaults))
        #expect(LastOpenedHostStore.stored(in: defaults) == "host-a")

        // The same machine again is not a change, and posting one would be
        // pointless work on every open of the host list.
        #expect(LastOpenedHostStore.store("host-a", in: defaults) == false)

        #expect(LastOpenedHostStore.store("host-b", in: defaults))
        #expect(LastOpenedHostStore.stored(in: defaults) == "host-b")

        #expect(LastOpenedHostStore.store(nil, in: defaults))
        #expect(LastOpenedHostStore.stored(in: defaults) == nil)
    }

    @Test("treats a blank stored id as no memory")
    func blankIsNoMemory() {
        let name = "mizar.tests.lastOpenedHost.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        LastOpenedHostStore.store("  ", in: defaults)
        #expect(LastOpenedHostStore.stored(in: defaults) == nil)

        defaults.set("  host-a  ", forKey: LastOpenedHostStore.hostIdKey)
        #expect(LastOpenedHostStore.stored(in: defaults) == "host-a")
    }
}
