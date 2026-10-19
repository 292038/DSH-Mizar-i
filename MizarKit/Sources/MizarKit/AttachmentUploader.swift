//
//  AttachmentUploader.swift
//  MizarKit
//
//  Carrying a file to the host over the socket that is already open.
//
//  The Mizar protocol has no binary frame, so an attachment travels as four
//  unary calls: `upload.begin`, one `upload.chunk` per 128 KiB slice,
//  `upload.finish`, and `upload.abort` when something goes wrong. That is slower
//  than a second connection would be and it is the right trade: one socket means
//  the attachment shares the connection's authentication and its reconnect, and a
//  phone that moves from Wi-Fi to cellular mid-upload does not have two
//  credentials to keep in sync.
//
//  The uploader is deliberately mechanical. It slices, it sends, it reports
//  progress — it does not decide what is too large, what media type a file is,
//  or whether the account is allowed to attach anything. Those are product rules
//  and they live where the operator is, in the app. What lives here is the wire
//  sequence, and the one promise worth testing: a failed upload leaves no
//  half-open session on the host, because every failure path aborts.
//

import Foundation

/// What kind of attachment this is.
///
/// The host treats the two differently: an image is handed to the model as image
/// content, a file as an uploaded file the session can read. That difference is
/// the only reason the kind exists.
public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    /// A photo, normalised to JPEG or PNG before upload.
    case image
    /// Any file.
    case file
}

/// An attachment the host has finished receiving.
///
/// This is what `upload.finish` returns and what `session.prompt` takes in
/// `attachmentIds`. The size is the host's count of the bytes it stored, not the
/// phone's: the two disagree only when something went wrong, and the host's
/// answer is the authoritative one.
public struct AttachmentRef: Codable, Sendable, Equatable, Identifiable {
    /// The host's id for the stored attachment.
    public let attachmentId: String
    /// Image or file.
    public let kind: AttachmentKind
    /// The file name the host stored.
    public let name: String
    /// The media type.
    public let mediaType: String
    /// The stored byte size.
    public let byteSize: Int

    public init(
        attachmentId: String,
        kind: AttachmentKind,
        name: String,
        mediaType: String,
        byteSize: Int,
    ) {
        self.attachmentId = attachmentId
        self.kind = kind
        self.name = name
        self.mediaType = mediaType
        self.byteSize = byteSize
    }

    public var id: String { attachmentId }
}

/// A chunked upload over the authenticated socket.
///
/// The `call` closure is the bridge method dispatcher — in the app, a thin
/// wrapper over `MizarConnection.request` — so this type has no socket of its own
/// and the tests need no network at all.
public struct AttachmentUploader: Sendable {
    /// The chunk size the protocol documents.
    ///
    /// The host may choose a different one in its `upload.begin` answer; this is
    /// the default and the number the app uses for its size arithmetic before the
    /// host has said anything.
    public static let chunkBytes = 131_072

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

    /// Upload one file and return the host's record of it.
    ///
    /// - Parameters:
    ///   - sessionId: the session the attachment belongs to. The host binds the
    ///     upload to this device *and* this session.
    ///   - kind: image or file.
    ///   - name: the file name to store.
    ///   - mediaType: the IANA media type.
    ///   - data: the bytes.
    ///   - progress: called on each chunk boundary with the fraction sent, from
    ///     `0` to `1`. Called on whatever executor the upload runs on; the app
    ///     hops to the main actor itself.
    /// - Returns: the host's attachment record.
    /// - Throws: ``MizarError`` from the host on any refused step, or
    ///   `CancellationError` when the surrounding task is cancelled. Every path
    ///   that fails after `upload.begin` attempts `upload.abort`, best effort, so
    ///   the host's temp directory does not accumulate half-received files for
    ///   the whole 30-minute TTL.
    public func upload(
        sessionId: String,
        kind: AttachmentKind,
        name: String,
        mediaType: String,
        data: Data,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> AttachmentRef {
        let begin = try await begin(
            sessionId: sessionId,
            kind: kind,
            name: name,
            mediaType: mediaType,
            byteSize: data.count,
        )

        do {
            try await send(
                data: data,
                uploadId: begin.uploadId,
                chunkBytes: begin.chunkBytes > 0 ? begin.chunkBytes : Self.chunkBytes,
                progress: progress,
            )
            let ref = try await finish(uploadId: begin.uploadId)
            progress?(1)
            return ref
        } catch {
            // An abort is not allowed to replace the reason the upload failed:
            // the first error is the one worth showing, and the abort's failure
            // is at best a note for a log nobody is reading here.
            _ = try? await call(
                "upload.abort",
                .object(["uploadId": .string(begin.uploadId)]),
            )
            throw error
        }
    }

    // MARK: - Steps

    /// Start an upload and learn where to put the bytes.
    private func begin(
        sessionId: String,
        kind: AttachmentKind,
        name: String,
        mediaType: String,
        byteSize: Int,
    ) async throws -> BeginResult {
        let value = try await call(
            "upload.begin",
            .object([
                "sessionId": .string(sessionId),
                "kind": .string(kind.rawValue),
                "name": .string(name),
                "mediaType": .string(mediaType),
                "byteSize": .number(Double(byteSize)),
            ]),
        )
        guard let value, value != .null else {
            throw MizarError(
                code: "UPLOAD_FAILED",
                message: "the host did not start the upload",
            )
        }
        return try value.decoded(as: BeginResult.self)
    }

    /// Send the bytes, one chunk at a time.
    private func send(
        data: Data,
        uploadId: String,
        chunkBytes: Int,
        progress: (@Sendable (Double) -> Void)?,
    ) async throws {
        guard !data.isEmpty else { return }
        var offset = 0
        var index = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            let piece = data.subdata(in: offset..<end)
            let value = try await call(
                "upload.chunk",
                .object([
                    "uploadId": .string(uploadId),
                    "index": .number(Double(index)),
                    "data": .string(piece.base64EncodedString()),
                ]),
            )
            // The host reports which chunk it now holds. Checking it turns a
            // silent off-by-one into a clear failure here rather than a corrupt
            // file at the end of a long upload.
            if let received = value?["received"]?.intValue, received != index + 1 {
                throw MizarError(
                    code: "UPLOAD_BAD_CHUNK",
                    message: "the host acknowledged chunk \(received) after chunk \(index)",
                )
            }
            offset = end
            index += 1
            progress?(Double(offset) / Double(data.count))
        }
    }

    /// Close the upload and take the host's record.
    private func finish(uploadId: String) async throws -> AttachmentRef {
        let value = try await call(
            "upload.finish",
            .object(["uploadId": .string(uploadId)]),
        )
        guard let value, value != .null else {
            throw MizarError(
                code: "UPLOAD_INCOMPLETE",
                message: "the host did not report the finished attachment",
            )
        }
        do {
            return try value.decoded(as: AttachmentRef.self)
        } catch {
            throw MizarError(
                code: "UPLOAD_INCOMPLETE",
                message: "the host's attachment record was not readable",
            )
        }
    }

    /// The `upload.begin` answer.
    struct BeginResult: Decodable, Sendable, Equatable {
        /// The id every later call addresses.
        let uploadId: String
        /// The host's preferred chunk size; `0` when it did not say.
        let chunkBytes: Int

        private enum CodingKeys: String, CodingKey {
            case uploadId
            case chunkBytes
        }

        init(uploadId: String, chunkBytes: Int) {
            self.uploadId = uploadId
            self.chunkBytes = chunkBytes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uploadId = try container.decode(String.self, forKey: .uploadId)
            chunkBytes = try container.decodeIfPresent(Int.self, forKey: .chunkBytes) ?? 0
        }
    }
}
