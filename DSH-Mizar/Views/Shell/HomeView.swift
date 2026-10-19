//
//  HomeView.swift
//  DSH-Mizar
//
//  The conversation pane with no conversation in it -- which is a place to
//  start one, not an empty screen.
//
//  The computer's name, the mark lighting up dot-outward as if finding it, and the
//  composer, ready: type, choose where the work happens, send. Sending starts a
//  session in that workspace with those words as its first prompt and opens it
//  -- the operator's words flying up into the new conversation as they would in
//  any other.
//

import SwiftUI
import MizarKit

struct HomeView: View {
    @Environment(AppModel.self) private var model
    /// The full workspace picker, for a directory that is not on offer, out of
    /// the workspace chip.
    @State private var choosingElsewhere = false
    @State private var draft = ""
    @State private var workspace: String?
    @State private var sending = false
    @State private var sends = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            greeting
            Spacer(minLength: 24)
            if model.workspaceChoices.isEmpty {
                Text("Start a session on your computer, then refresh.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
            composer
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture { focused = false }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if workspace == nil { workspace = model.workspaceChoices.first?.path } }
        .onChange(of: model.workspaceChoices.map(\.path)) { _, paths in
            if workspace == nil || !paths.contains(workspace ?? "") { workspace = paths.first }
        }
        .mizarFeedback(.impact(weight: .light), trigger: sends)
    }

    private var greeting: some View {
        VStack(spacing: 18) {
            MizarMarkConnecting(accent: .accentColor, ink: .primary)
                .frame(width: 64)
            VStack(spacing: 6) {
                Text(model.host?.displayName ?? model.welcome?.hostName ?? "DSH-Mizar")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Text("What should the agent work on?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .transition(.rise)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Ask your agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 6)
                .accessibilityIdentifier("home.field")

            HStack(spacing: 6) {
                workspaceMenu
                Spacer(minLength: 4)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? Theme.onAccent : .secondary)
                        .symbolEffect(.bounce.up, value: sends)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSend ? Color.accentColor : Color(.tertiarySystemFill)))
                        .scaleEffect(canSend ? 1 : 0.92)
                        .overlay {
                            if sending { ProgressView().controlSize(.small).tint(Theme.onAccent) }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.pressable(scale: 0.88))
                .disabled(!canSend)
                .animation(.mizarBouncy, value: canSend)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("home.send")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Where the new session will work: one button, labelled with its choice,
    /// opening the list of the computer's workspaces.
    private var workspaceMenu: some View {
        Menu {
            ForEach(model.workspaceChoices) { choice in
                Button {
                    withMizarAnimation(.mizarSnappy) { workspace = choice.path }
                } label: {
                    if choice.path == workspace {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
            Divider()
            Button { choosingElsewhere = true } label: {
                Label("Somewhere else…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                Text(workspaceTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(.fill.tertiary, in: Capsule())
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // One element, so the workspace's name on it is not a second static
        // text with that name on the screen.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Workspace, \(workspaceTitle)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home.workspace")
        .mizarPopover(isPresented: $choosingElsewhere, arrowEdge: .bottom) {
            NewSessionView()
                .frame(width: PopoverSize.compact.width, height: 440)
        }
    }

    private var workspaceTitle: String {
        model.workspaceChoices.first { $0.path == workspace }?.title ?? String(localized: "Choose a workspace")
    }

    private var canSend: Bool {
        !sending && workspace != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        guard let workspace, canSend else { return }
        let prompt = draft
        sending = true
        sends += 1
        withMizarAnimation(.mizarSmooth) { draft = "" }
        let started = await model.startSession(cwd: workspace, prompt: prompt)
        if started == nil { draft = prompt }
        sending = false
    }
}
