//
//  ToolNames.swift
//  MizarKit
//
//  The bridge between the host's tool vocabulary and the operator's language.
//
//  An approval carries an identifier, not a name: `write`, `edit`, `shell`.
//  Those are protocol data -- the host's own words for its own tools -- and they
//  have no localised form on the wire. The card that asks for permission is
//  unreadable to an operator who does not speak that vocabulary, and the
//  sentence around it ("请求执行 %@") then reads as a sentence about a foreign
//  word.
//
//  So the identifiers this app has met are mapped here, in one place, to keys in
//  the app's `Localizable.strings`. The table is deliberately closed: nothing is
//  guessed from a prefix or a suffix, because an MCP server or a host build from
//  tomorrow may call its tools anything, and inventing a Chinese name for a tool
//  the app has not been told about is the app talking. An identifier that is not
//  in the table is shown exactly as the host wrote it.
//
//  ## Adding a tool
//
//  1. Add the identifier and its key to `localizationKey(for:)` below.
//  2. Add the key to **both** `DSH-Mizar/en.lproj/Localizable.strings` and
//     `DSH-Mizar/zh-Hans.lproj/Localizable.strings`.
//
//  `ToolNamesTests` pins the identifiers the app knows and the fall-through. The
//  key lookup itself is `String(localized:)`, so the app's bundle answers it; in
//  the package's tests there is no app bundle, and the table is what is tested.
//

import Foundation

/// The operator's names for the tool identifiers this app has met.
public enum ToolNames {
    /// The localisation key for a tool identifier, or `nil` when it is unknown.
    ///
    /// Matching is case-insensitive: the host chooses the casing, and `WRITE`
    /// and `write` are one tool rather than two.
    ///
    /// - Parameter identifier: the tool name exactly as the host sent it.
    /// - Returns: the key in the app's `Localizable.strings`, or `nil`.
    public static func localizationKey(for identifier: String) -> String? {
        switch identifier.lowercased() {
        // The file-system tools DSH registers. `write_file` and `read_file` are
        // older spellings still used by hosts and fixtures in the field.
        case "read", "read_file", "readfile": "Read file"
        case "read_image", "readimage": "Read image"
        case "write", "write_file", "writefile": "Write file"
        case "edit", "edit_file", "editfile", "multiedit": "Edit file"

        // A command the agent wants to run.
        case "shell", "bash", "execute", "exec", "run", "run_command": "Shell command"

        // Search and the network.
        case "glob", "find", "list_dir", "list_files", "ls": "Find files"
        case "grep", "search", "search_files": "Search contents"
        case "web_search", "websearch": "Web search"
        case "web_fetch", "webfetch": "Fetch web page"

        // Everything else DSH exposes to a model.
        case "ask_user_question", "ask_user", "question": "Ask operator"
        case "todo_write", "todowrite", "todo": "Update tasks"
        case "task", "subagent": "Subagent task"
        case "apply_patch", "patch": "Apply patch"

        default: nil
        }
    }

    /// What to show for a tool identifier: its localised name, or the identifier.
    ///
    /// - Parameter identifier: the tool name exactly as the host sent it.
    /// - Returns: the operator's name for it, or the identifier unchanged.
    public static func localized(_ identifier: String) -> String {
        guard let key = localizationKey(for: identifier) else { return identifier }
        return String(localized: String.LocalizationValue(key))
    }
}
