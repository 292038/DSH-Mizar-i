//
//  Pickers.swift
//  DSH-Mizar
//
//  Changing the model, the reasoning effort, and the permission preset.
//
//  All three are shown as the current value rather than as a menu, because the
//  question an operator actually has is "what is it on now", and that should not
//  require opening anything.
//

import SwiftUI
import MizarKit

/// Model and reasoning effort.
struct ModelPickerView: View {
    let sessionId: String
    /// The host's last report for this session, when the screen has one.
    ///
    /// Passed in because it belongs to the session and is already read and
    /// tagged by the screen that owns it -- reaching for it here would be a
    /// second read of the same thing under a second set of tags.
    let stats: SessionStatsFrame?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosenProvider: String?
    @State private var chosenModel: String?
    @State private var chosenEffort: String?
    /// Why the last switch did not happen, when it did not.
    ///
    /// Shown here as well as in the session list's banner, and not only there:
    /// on a phone the banner is on the *other* screen. The list and the
    /// conversation are one column, so a refusal reported only there would be a
    /// message the operator cannot read until they have given up on this sheet
    /// and gone back.
    @State private var switchError: String?
    @Namespace private var tick

    var body: some View {
        NavigationStack {
            List {
                // What is in force, said in words as well as ticked below.
                //
                // The tick alone was the whole of it, and a tick is a poor answer
                // to "what is it on now" when the row carrying it is a page down.
                // It is also the one thing here that can say a refused switch was
                // refused: it is drawn from what the app and the host have agreed
                // on, never from what was last tapped.
                if let current = currentChoice {
                    Section("In force") {
                        // One `Text` rather than a title with a caption under it,
                        // and that is what makes it readable by anything but a
                        // pair of eyes: SwiftUI exposes a stack of two texts as
                        // two elements, so a test looking for one identifier
                        // finds neither. The name and the level are one sentence
                        // about one model.
                        Text(current.detail.map { "\(current.name) · \($0)" } ?? current.name)
                            .accessibilityIdentifier("model.current.\(current.modelId)")
                    }
                }
                if let switchError {
                    Section("Could not switch model") {
                        // An `HStack` of two views rather than a `Label`, and a
                        // `Text` rather than the pair of them under one
                        // identifier: a `Label` is exposed as a single element
                        // with its image, so the reason is not findable as text
                        // -- by VoiceOver's own search or by anything asserting
                        // on this screen.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(switchError)
                                .font(.caption)
                                .accessibilityIdentifier("model.error")
                        }
                    }
                }
                if let catalog = model.modelCatalog {
                    ForEach(catalog.providers) { provider in
                        Section(provider.name) {
                            ForEach(provider.models) { option in
                                modelRow(provider: provider, option: option)
                            }
                        }
                    }
                    if !catalog.failures.isEmpty {
                        // A provider that could not be listed is shown, not
                        // hidden: its models being absent is information.
                        Section("Unavailable") {
                            ForEach(catalog.failures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.name)
                                    Text(failure.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView().task { await model.loadCatalogs() }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Seed from what this session was last told to use. Without it
                // the picker opened with nothing marked, so there was no way to
                // tell which model was in force -- the row builder has always
                // drawn a checkmark, it just never had anything to draw it on.
                guard chosenModel == nil, let choice = model.modelChoice[sessionId] else { return }
                chosenProvider = choice.provider
                chosenModel = choice.model
                chosenEffort = choice.effort
            }
            // The choice on screen can move without this sheet having moved it. A
            // switch the host refused puts the previous value back on the model,
            // and the tap that caused it is already a frame behind -- so without
            // this the tick and the segmented control would go on showing the
            // refused model, which is the same lie one screen in.
            .onChange(of: model.modelChoice[sessionId]) { _, choice in
                guard let choice else { return }
                chosenProvider = choice.provider
                chosenModel = choice.model
                chosenEffort = choice.effort
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.loadCatalogs() }
    }

    /// The route this session is on, as the app and the host agree on it.
    ///
    /// The app's own record first. The host has no "what is this session using"
    /// read on this side of the protocol, so for a session this phone has
    /// switched, what it asked for is the only account there is. Failing that,
    /// what the host last reported, which is the same thing on a phone that has
    /// switched nothing.
    private var agreedSelection: (provider: String, model: String, effort: String?)? {
        if let choice = model.modelChoice[sessionId] {
            return (choice.provider, choice.model, choice.effort)
        }
        guard let selection = stats?.model?.next ?? stats?.model?.lastUsed else { return nil }
        return (selection.provider, selection.model, selection.reasoningEffort)
    }

    /// That route, with the names the catalogue spells it with.
    ///
    /// - Returns: the model's id, its name, and its reasoning level in words, or
    ///   `nil` when nothing has said what this session is using.
    private var currentChoice: (modelId: String, name: String, detail: String?)? {
        guard let agreed = agreedSelection else { return nil }
        let option = model.modelCatalog?.providers
            .first { $0.id == agreed.provider }?
            .models.first { $0.id == agreed.model }
        let effort = option?.efforts.first { $0.id == agreed.effort }?.name ?? agreed.effort
        return (
            modelId: agreed.model,
            name: option?.name ?? agreed.model,
            detail: effort.map { String(localized: "Thinking: \($0)") },
        )
    }

    @ViewBuilder
    private func modelRow(provider: ProviderGroup, option: ModelOption) -> some View {
        let isChosen = chosenModel == option.id && chosenProvider == provider.id
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withMizarAnimation(.mizarSmooth) {
                    chosenProvider = provider.id
                    chosenModel = option.id
                    chosenEffort = option.defaultEffort
                }
                // A model with no effort levels commits immediately: there is
                // nothing else to choose, and an extra tap would be a formality.
                if option.efforts.isEmpty {
                    Task { await commit(provider: provider.id, model: option.id, effort: nil) }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name)
                            .fontWeight(isChosen ? .semibold : .regular)
                        if let description = option.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isChosen {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .matchedGeometryEffect(id: "tick", in: tick)
                            .transition(.pop)
                    }
                }
            }
            .buttonStyle(.plain)
            .contentShape(.rect)
            .accessibilityIdentifier("model.row.\(option.id)")

            if isChosen && !option.efforts.isEmpty {
                effortPicker(provider: provider.id, option: option)
                    .transition(.rise(distance: -6, blur: 4))
            }
        }
    }

    @ViewBuilder
    private func effortPicker(provider: String, option: ModelOption) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Thinking")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Thinking", selection: Binding(
                get: { chosenEffort ?? "" },
                set: { newValue in
                    chosenEffort = newValue.isEmpty ? nil : newValue
                    Task { await commit(provider: provider, model: option.id, effort: chosenEffort) }
                },
            )) {
                ForEach(option.efforts) { effort in
                    Text(effort.name).tag(effort.id)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.leading, 4)
    }

    /// Send a choice, and close only once the host has taken it.
    ///
    /// Closing on a refusal was the visible half of the bug: the sheet went away,
    /// the bar behind it went on naming the model that had been refused, and
    /// nothing anywhere said the switch had not happened. Staying open on a
    /// refusal is what gives the reason somewhere to be read and the tick
    /// somewhere to go back to.
    ///
    /// - Parameters:
    ///   - provider: the provider id.
    ///   - model: the model id.
    ///   - effort: the reasoning level, or `nil` for the provider default.
    private func commit(provider: String, model: String, effort: String?) async {
        let accepted = await self.model.setModel(
            provider: provider,
            model: model,
            effort: effort,
            sessionId: sessionId,
        )
        guard accepted else {
            switchError = self.model.problem ?? String(localized: "Could not switch model")
            return
        }
        switchError = nil
        dismiss()
    }
}

/// Permission presets.
struct PermissionPickerView: View {
    let sessionId: String
    /// The preset in force, when the screen behind knows it.
    var current: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The dangerous preset being confirmed, inside this window.
    @State private var confirming: PermissionOption?
    /// What was just chosen here, ahead of the host's next report.
    @State private var applied: String?
    @Namespace private var tick

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(title: "Permissions", systemImage: "lock.shield")
            if let catalog = model.permissionCatalog {
                VStack(spacing: 4) {
                    ForEach(catalog.options) { option in
                        VStack(spacing: 0) {
                            Button {
                                if option.isDangerous {
                                    withMizarAnimation(.mizarSmooth) {
                                        confirming = confirming == option ? nil : option
                                    }
                                } else {
                                    Task { await apply(option) }
                                }
                            } label: {
                                optionRow(option)
                            }
                            .buttonStyle(.pressable(scale: 0.98))
                            .accessibilityIdentifier("permission.row.\(option.value)")

                            // A preset that grants unrestricted access to the
                            // machine is never one tap away: the second tap
                            // folds out under the row that asked for it, rather
                            // than an alert in the middle of the screen.
                            if confirming == option {
                                confirmation(for: option)
                                    .transition(.rise(distance: -8, blur: 4))
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                .fill(confirming == option ? Theme.waiting.opacity(0.1) : .clear)
                        }
                    }
                }
                .padding(.horizontal, 8)
                Text("Applies to this session immediately. A running turn is not interrupted.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(30)
                    .task { await model.loadCatalogs() }
            }
        }
        .frame(width: 330)
        .task { await model.loadCatalogs() }
    }

    private func confirmation(for option: PermissionOption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow full access?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.waiting)
            Text("The agent will run commands and change files anywhere on this computer without asking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    withMizarAnimation(.mizarSmooth) { confirming = nil }
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button(role: .destructive) {
                    Task { await apply(option) }
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.waiting)
                .accessibilityIdentifier("permission.confirm")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func optionRow(_ option: PermissionOption) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.name)
                        .font(.body.weight(option.value == (applied ?? current) ? .semibold : .regular))
                    if option.isDangerous {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.waiting)
                            .font(.caption)
                    }
                }
                if let description = option.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            // The one in force, ticked -- and the tick slides to a new choice.
            if option.value == (applied ?? current) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .matchedGeometryEffect(id: "tick", in: tick)
                    .transition(.pop)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    private func apply(_ option: PermissionOption) async {
        withMizarAnimation(.mizarSnappy) {
            applied = option.value
            confirming = nil
        }
        _ = await model.setPermission(option.value, sessionId: sessionId)
        try? await Task.sleep(for: .milliseconds(260))
        dismiss()
    }
}
