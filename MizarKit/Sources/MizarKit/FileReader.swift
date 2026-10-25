//
//  FileReader.swift
//  MizarKit
//
//  Carrying a delivered file from the computer to the phone.
//
//  The mirror of ``AttachmentUploader``, and deliberately its mirror: the same
//  injected `call` closure, the same "the wire sequence lives here, the product
//  rules live in the app" split, the same promise that the tests need no network.
//  What differs is the direction and the shape of the state — a download has no
//  handle to open and close. `file.read` is a pure function of
//  (path, offset, length), so a phone that loses its socket half way through a
//  document reconnects and asks for the next slice instead of starting over.
//
//  Slicing is not a preference either. The listener refuses a frame over 512 KiB
//  and base64 costs a third on top, so 256 KiB of bytes is the largest piece that
//  fits with room for the envelope. The host enforces the same ceiling; this
//  type simply never asks for more.
//

import Foundation

/// A file's facts, as `file.stat` answers them.
public struct FileFacts: Decodable, Sendable, Equatable {
    /// The path as the request named it, echoed.
    public let path: String
    /// The file's name, without its directory.
    public let name: String
    /// Size in bytes.
    public let byteSize: Int
    /// Last modification, epoch milliseconds.
    public let modifiedAt: Double
    /// The media type the host associates with the extension.
    public let mediaType: String
    /// Whether the host thinks the app can draw this type. A hint: the app
    /// decides again from the extension, because a host and a client can
    /// disagree about a new format without either being wrong.
    public let previewable: Bool

    public init(
        path: String,
        name: String,
        byteSize: Int,
        modifiedAt: Double,
        mediaType: String,
        previewable: Bool,
    ) {
        self.path = path
        self.name = name
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.mediaType = mediaType
        self.previewable = previewable
    }
}

/// One slice of a file, as `file.read` answers it.
public struct FileSlice: Decodable, Sendable, Equatable {
    /// Where the slice starts.
    public let offset: Int
    /// How many bytes it holds.
    public let length: Int
    /// The whole file's size.
    public let byteSize: Int
    /// The slice, standard base64.
    public let data: String
    /// Whether this slice ends the file.
    public let eof: Bool

    /// The decoded bytes, or `nil` when the host's base64 was not.
    public var bytes: Data? { Data(base64Encoded: data) }

    public init(offset: Int, length: Int, byteSize: Int, data: String, eof: Bool) {
        self.offset = offset
        self.length = length
        self.byteSize = byteSize
        self.data = data
        self.eof = eof
    }
}

/// Reading a delivered file over the authenticated socket.
public struct FileReader: Sendable {
    /// The slice size this client asks for.
    ///
    /// The host's own ceiling, so the two never disagree about what fits in a
    /// frame. A host that lowered its limit answers `MALFORMED_FRAME`, which the
    /// app reports as a failure rather than retrying forever.
    public static let chunkBytes = 262_144

    /// Dispatch one bridge method.
    ///
    /// - Parameters:
    ///   - method: the wire method name.
    ///   - payload: the method's arguments.
    /// - Returns: the `result` of the answer.
    public typealias Call = @Sendable (_ method: String, _ payload: JSONValue) async throws -> JSONValue?

    private let call: Call

    /// - Parameter call: how to reach the host, injectable for tests.
    public init(call: @escaping Call) {
        self.call = call
    }

    /// Ask what a path is.
    ///
    /// - Parameters:
    ///   - sessionId: the session whose working directory the path is read in.
    ///   - path: the path the model wrote, relative or absolute.
    /// - Returns: the file's facts.
    /// - Throws: ``MizarError`` from the host — `FILE_UNKNOWN`,
    ///   `FILE_FORBIDDEN`, `FILE_TOO_LARGE`, or `NOT_IMPLEMENTED` when the
    ///   computer's plugin is older than this feature.
    public func stat(sessionId: String, path: String) async throws -> FileFacts {
        let value = try await call(
            "file.stat",
            .object(["sessionId": .string(sessionId), "path": .string(path)]),
        )
        guard let value, value != .null else {
            throw MizarError(code: "FILE_UNKNOWN", message: "the host did not answer for \(path)")
        }
        return try value.decoded(as: FileFacts.self)
    }

    /// Read a whole file, slice by slice.
    ///
    /// - Parameters:
    ///   - sessionId: the session whose working directory the path is read in.
    ///   - path: the path the model wrote.
    ///   - expectedSize: what `file.stat` said, for progress before the first
    ///     slice arrives; `nil` when the caller has not asked.
    ///   - progress: called after each slice with the fraction read, from `0` to
    ///     `1`. Called on whatever executor the read runs on; the app hops to the
    ///     main actor itself.
    /// - Returns: the file's bytes.
    /// - Throws: ``MizarError`` from the host, or `CancellationError` when the
    ///   surrounding task is cancelled. A slice that neither advances the offset
    ///   nor ends the file is a failure here rather than a loop that never ends.
    public func read(
        sessionId: String,
        path: String,
        expectedSize: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> Data {
        var data = Data()
        var offset = 0
        var total = expectedSize
        while true {
            try Task.checkCancellation()
            let slice = try await slice(sessionId: sessionId, path: path, offset: offset)
            total = slice.byteSize
            guard let bytes = slice.bytes else {
                throw MizarError(
                    code: "FILE_SLICE_INVALID",
                    message: "the host's slice was not valid base64",
                )
            }
            data.append(bytes)
            offset += slice.length
            if let total, total > 0 {
                progress?(min(1, Double(offset) / Double(total)))
            }
            if slice.eof { break }
            guard slice.length > 0 else {
                // Neither advancing nor finished: the next request would ask for
                // the same offset forever.
                throw MizarError(
                    code: "FILE_SLICE_STALLED",
                    message: "the host answered an empty slice before the end of the file",
                )
            }
        }
        progress?(1)
        return data
    }

    /// Ask for one slice.
    private func slice(sessionId: String, path: String, offset: Int) async throws -> FileSlice {
        let value = try await call(
            "file.read",
            .object([
                "sessionId": .string(sessionId),
                "path": .string(path),
                "offset": .number(Double(offset)),
                "length": .number(Double(Self.chunkBytes)),
            ]),
        )
        guard let value, value != .null else {
            throw MizarError(code: "FILE_UNKNOWN", message: "the host answered no slice for \(path)")
        }
        return try value.decoded(as: FileSlice.self)
    }
}
