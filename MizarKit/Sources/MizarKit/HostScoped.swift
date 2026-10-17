//
//  HostScoped.swift
//  MizarKit
//
//  A value that belongs to one Mac and one connection to it.
//
//  The app has shipped this bug three times in different clothes: a value read
//  for one subject and drawn for another. On the session screen it was a page
//  read for session A drawn under session B, and the fix there -- tag the value
//  with the session it came from and refuse to draw it for any other -- is what
//  this is for the machine.
//
//  Two Macs make it easy to see and hard to reproduce: a catalogue, a pending
//  set and a session list are each read once and kept, so a switch that leaves
//  one behind draws the first Mac's models and sessions under the second Mac's
//  name. It is the same defect one level up, and it needs the same answer.
//
//  The connection is part of the tag, not only the host id. A *reconnect* to the
//  same machine is a different conversation with it: a read started over the old
//  socket and answered after the new one opened was answered by a host the app
//  is no longer talking to, and the same machine is exactly the case where a
//  host-id-only tag would let it through.
//

import Foundation

/// The subject a host-scoped value belongs to: the machine, and the one
/// connection to it the value was read over.
public struct HostTag: Sendable, Equatable {
    /// The machine's stable identity, as it reports at pairing.
    public let hostId: String
    /// Which connection to that machine. Counted per app run rather than derived
    /// from anything the host says, because it is a fact about this socket.
    public let epoch: Int

    public init(hostId: String, epoch: Int) {
        self.hostId = hostId
        self.epoch = epoch
    }
}

/// One piece of host-scoped state: a value, and what it is a value *about*.
///
/// Deliberately not a property wrapper. The call sites are few and each wants to
/// say something different on a miss -- a catalogue is absent, a pending set is
/// empty, a session list is unknown -- and `wrappedValue` would have to pick one
/// of those answers for all of them.
///
/// The mutation surface is the point: a value can only be read for the subject it
/// was published for, so forgetting to clear it when the machine changes cannot
/// show up on screen. The clear is still worth doing -- it is what keeps a stale
/// value from being *read* by code that holds a stale tag -- but the screen is
/// safe either way.
public struct HostScoped<Value: Sendable>: Sendable {
    private var value: Value?
    private var tag: HostTag?

    public init() {}

    /// The value, when it belongs to this subject.
    ///
    /// - Parameter tag: the subject to read for.
    /// - Returns: the value, or `nil` when it was read for another Mac or
    ///   another connection to this one.
    public func value(for tag: HostTag) -> Value? {
        self.tag == tag ? value : nil
    }

    /// The value, when there is a subject and it is this one.
    ///
    /// The call site this exists for is a screen that is connected to nothing:
    /// the subject is `nil`, so there is nothing the held value can be an answer
    /// about, and it reads as absent for the same reason a value read for another
    /// machine does.
    ///
    /// - Parameter tag: the subject, or `nil` when there is none.
    /// - Returns: the value, or `nil`.
    public func value(for tag: HostTag?) -> Value? {
        guard let tag else { return nil }
        return value(for: tag)
    }

    /// The value regardless of subject, for writing it down.
    ///
    /// What the log export needs: the archive describes what the phone holds, and
    /// it is built after the connection is gone. Reading it through ``value(for:)``
    /// there would report an empty archive for a phone that is full of answers.
    public var held: Value? { value }

    /// Record a value read for one subject.
    ///
    /// Replaces whatever was held, including a value for another Mac: one piece
    /// of state answers for one machine at a time, and keeping the other one is
    /// how the wrong answer survives a switch.
    ///
    /// - Parameters:
    ///   - value: what was read.
    ///   - tag: the machine and connection it was read for.
    public mutating func publish(_ value: Value, for tag: HostTag) {
        self.value = value
        self.tag = tag
    }

    /// Drop what is held.
    ///
    /// Called when the machine changes or the pairing is forgotten, so a value
    /// nobody may read is not carried forward as though it were an answer.
    public mutating func clear() {
        value = nil
        tag = nil
    }
}
