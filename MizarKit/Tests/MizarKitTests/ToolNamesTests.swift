//
//  ToolNamesTests.swift
//  MizarKitTests
//
//  The bridge between the host's tool vocabulary and the operator's language.
//
//  A `PendingApproval` carries an identifier, not a name: `write`, `edit`,
//  `shell`. Those are protocol data with no localised form, and the card that
//  asks for permission is unreadable to an operator who does not speak the
//  host's vocabulary. The mapping is one table, and everything it does not
//  know falls through untouched.
//

import Testing
@testable import MizarKit

@Suite("Tool names")
struct ToolNamesTests {
    @Test("maps the identifiers an operator can meet to one localisation key")
    func knownIdentifiersHaveKeys() {
        // The file-system tools DSH registers, the approval fixture's older
        // spelling of the same idea, and the shell a command request goes to.
        #expect(ToolNames.localizationKey(for: "read") == "Read file")
        #expect(ToolNames.localizationKey(for: "read_image") == "Read image")
        #expect(ToolNames.localizationKey(for: "write") == "Write file")
        #expect(ToolNames.localizationKey(for: "write_file") == "Write file")
        #expect(ToolNames.localizationKey(for: "edit") == "Edit file")
        #expect(ToolNames.localizationKey(for: "shell") == "Shell command")

        // Case is the host's choice, not a second identifier.
        #expect(ToolNames.localizationKey(for: "WRITE") == "Write file")
    }

    @Test("leaves an unknown tool identifier exactly as the host sent it")
    func unknownIdentifiersFallThrough() {
        // An MCP tool or a host build from tomorrow: inventing a name for it
        // would be the app talking about something it has not been told.
        #expect(ToolNames.localizationKey(for: "mcp__some_server__do_thing") == nil)
        #expect(ToolNames.localized("mcp__some_server__do_thing") == "mcp__some_server__do_thing")
    }
}
