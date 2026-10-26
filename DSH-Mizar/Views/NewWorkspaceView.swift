//
//  NewWorkspaceView.swift
//  DSH-Mizar
//
//  Making a workspace, from the phone.
//
//  A workspace is DSH's own idea: a directory on the computer that sessions
//  belong to, and the thing the computer's sidebar is grouped by. Until now the
//  phone could only start sessions in workspaces that already existed, so a
//  project the operator had not opened on the computer was unreachable from
//  here -- the folder picker listed the host's registry and a text field that
//  could start a session somewhere DSH did not list.
//
//  Creating one is a directory the operator names. The plugin has no
//  `workspace.create` of its own, but `session.create` with a `cwd` resolves
//  that directory to a workspace and *creates* the registry entry when DSH has
//  none -- the same thing the desktop does when somebody opens a folder. So
//  this screen asks for the directory, and the workspace it makes arrives with
//  a session already in it, which is what "start working here" means anyway.
//

import SwiftUI

struct NewWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var path = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder on the computer, for example /Users/you/projects/thing", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .accessibilityIdentifier("workspace.new.path")
                } header: {
                    Text("Workspace folder")
                } footer: {
                    // What actually happens, including the part the operator
                    // could otherwise only find out by trying: the directory is
                    // the computer's, and it is not created for them.
                    Text("Makes this folder a workspace on the computer and starts a session in it. The folder has to exist there already.")
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        ZStack {
                            Text("Create workspace").opacity(creating ? 0 : 1)
                            if creating { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(trimmed.isEmpty || creating)
                    .accessibilityIdentifier("workspace.new.create")
                }
            }
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("workspace.new.cancel")
                }
            }
            .disabled(creating)
        }
        .frame(width: PopoverSize.compact.width, height: 320)
    }

    /// The path as typed, without the whitespace a paste leaves behind.
    private var trimmed: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ask the computer for a session in that directory.
    ///
    /// One request, because that is the request that exists: it is what makes
    /// the workspace on the host (see the file's own note). The window closes on
    /// the way back either way -- a refusal is on the sidebar's problem line,
    /// which is where every other failed request in this app is said.
    private func create() async {
        guard !trimmed.isEmpty else { return }
        creating = true
        _ = await model.createSession(cwd: trimmed)
        creating = false
        dismiss()
    }
}
