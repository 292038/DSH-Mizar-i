//
//  Deliverables.swift
//  MizarKit
//
//  The files a turn handed over, and how to tell one the app can draw.
//
//  The computer draws a card under a turn's summary when the model called
//  `present` — "declare existing files as final deliverables for the user" — and
//  the plugin now carries that list to the phone on the turn's `turn/end`
//  (`mizarDeliverables`). Before it, the only way to learn that a report had
//  been written was to read its name in prose: `session.messages` drops every
//  `tool/call` on purpose, and the call is where the fact lives.
//
//  Two shapes have to be understood here, and they are different things:
//
//    - **A deliverable** is a path plus the one line the model wrote about it.
//      The path is the model's own — relative to the session's working directory,
//      or absolute — and nothing here resolves it: the host does that, inside the
//      fence that keeps a preview from reading outside the workspace.
//    - **A link** is what the same file looks like inside the prose, which is the
//      other way the computer shows a delivered file. Those arrive as Markdown
//      links whose target is a bare path — measured over 290 session logs, 1825
//      relative (`<Sources/App/A.swift#L139-L159>`) and 97 absolute, and not one
//      `file://` URL — so telling "a file this app can preview" from "a web page"
//      is a matter of reading the target, not of trusting a scheme.
//

import Foundation

/// A file a turn declared as a deliverable.
public struct DeliveredFile: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// The path as the model wrote it.
    ///
    /// Relative to the session's working directory unless it starts with `/`.
    /// Never resolved on the phone: resolving it here would mean guessing at a
    /// directory the phone does not own.
    public let path: String
    /// The one line the model wrote for the operator, when it wrote one.
    ///
    /// Named `detail` in Swift and `description` on the wire: a stored property
    /// called `description` shadows `CustomStringConvertible` for every type that
    /// contains one, and the resulting `String(describing:)` is a debugging trap
    /// nobody finds until they need it.
    public let detail: String?

    /// The file's name, without its directory.
    public var name: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    /// What kind of file it is, as far as a viewer is concerned.
    public var kind: PreviewKind { PreviewKind(fileName: name) }

    /// Identity within a turn: the path is what the host would read.
    public var id: String { path }

    /// - Parameters:
    ///   - path: the path the model wrote.
    ///   - detail: the model's line about it, if any.
    public init(path: String, detail: String? = nil) {
        self.path = path
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case detail = "description"
    }
}

/// The kinds of file the preview page can draw.
///
/// Deliberately small: the first release of the preview draws Markdown, PDF and
/// Word. Everything else is still *delivered* — the card appears, because the
/// operator should see that a file exists — but opening it says so rather than
/// pretending a viewer exists.
public enum PreviewKind: String, Sendable, Equatable, CaseIterable, Codable {
    case markdown
    case pdf
    case word
    case other

    /// The kind a file name implies, by extension.
    ///
    /// - Parameter fileName: a file's name, with or without its directory.
    public init(fileName: String) {
        let name = (fileName as NSString).lastPathComponent
        let dot = name.lastIndex(of: ".")
        let suffix = dot.map { name[name.index(after: $0)...].lowercased() } ?? ""
        switch suffix {
        case "md", "markdown", "mdown", "mkd":
            self = .markdown
        case "pdf":
            self = .pdf
        case "docx":
            self = .word
        default:
            self = .other
        }
    }

    /// Whether the preview page has a viewer for this kind.
    public var isPreviewable: Bool { self != .other }

    /// The two-or-three letter badge the card shows in its icon.
    public var badge: String {
        switch self {
        case .markdown: return "MD"
        case .pdf: return "PDF"
        case .word: return "DOC"
        case .other: return "FILE"
        }
    }
}

/// Reading the deliverable list out of a `turn/end` record.
public enum DeliverablePayload {
    /// The key the plugin attaches to a turn's `turn/end`.
    public static let key = "mizarDeliverables"

    /// The files one `turn/end` carries.
    ///
    /// An absent key is "this turn presented nothing", which is the ordinary
    /// case and the reason the plugin omits it rather than sending an empty
    /// array. A malformed entry is dropped rather than failing the turn: the
    /// answer above it is still the operator's answer.
    ///
    /// - Parameter data: the record's `data` object.
    /// - Returns: the files, in the order the model declared them.
    public static func parse(_ data: JSONValue?) -> [DeliveredFile] {
        guard let entries = data?[key]?.arrayValue else { return [] }
        var files: [DeliveredFile] = []
        for entry in entries {
            guard let path = entry["path"]?.stringValue else { continue }
            let trimmed = trimmedPath(path)
            guard !trimmed.isEmpty else { continue }
            let detail = entry["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            files.append(DeliveredFile(path: trimmed, detail: detail?.isEmpty == true ? nil : detail))
        }
        return files
    }

    /// A path with the noise a model writes around one removed.
    ///
    /// - Parameter path: the raw path.
    /// - Returns: the path without surrounding spaces or a leading `./`.
    static func trimmedPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("./") { value.removeFirst(2) }
        return value
    }
}

/// Recognising a local file inside a Markdown link's target.
public enum LocalFileLink {
    /// The path a link points at, when it points at a file on the computer.
    ///
    /// Three shapes have to be read, because all three are in the wild:
    /// a `file://` URL (which DSH does not produce, but a hand-written link can),
    /// an absolute path, and a path relative to the session's working directory.
    /// A link with a scheme other than `file` is somebody else's — `https`,
    /// `mailto` — and is not this app's business.
    ///
    /// - Parameter target: the URL the Markdown parser produced.
    /// - Returns: the path, or `nil` when the target is not a local file.
    public static func path(in target: URL) -> String? {
        let scheme = target.scheme?.lowercased()
        if let scheme, scheme != "file" { return nil }
        if scheme == "file" {
            return target.path.isEmpty ? nil : target.path
        }
        // A relative target comes back with no scheme, and the parser keeps the
        // angle brackets a model writes around a path that may contain spaces.
        return path(inRawTarget: target.relativeString)
    }

    /// The path a raw Markdown link target names, when it names a local file.
    ///
    /// Kept separate from ``path(in:)`` because the system's Markdown parser is
    /// not the only thing that produces these: the fallback renderer passes the
    /// text it read, brackets and all.
    ///
    /// - Parameter raw: the text between the parentheses of a Markdown link.
    /// - Returns: the path, or `nil` when the target is not a local file.
    public static func path(inRawTarget raw: String) -> String? {
        var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("<"), target.hasSuffix(">") {
            target = String(target.dropFirst().dropLast())
        }
        if target.isEmpty { return nil }
        if let url = URL(string: target), let scheme = url.scheme?.lowercased() {
            // `C:/…` reads as a scheme named `c`. A single-letter scheme is a
            // drive letter, not a protocol.
            if scheme.count > 1 { return scheme == "file" ? url.path : nil }
        }
        // A fragment is a line range in the computer's editor (`#L12-L30`), not
        // part of the name.
        if let hash = target.firstIndex(of: "#") {
            target = String(target[..<hash])
        }
        target = target.removingPercentEncoding ?? target
        return target.isEmpty ? nil : target
    }

    /// Whether a link's target is a file this app can preview.
    ///
    /// - Parameter target: the URL the Markdown parser produced.
    /// - Returns: whether tapping it should open the preview page.
    public static func isPreviewable(_ target: URL) -> Bool {
        guard let path = path(in: target) else { return false }
        return PreviewKind(fileName: path).isPreviewable
    }
}
