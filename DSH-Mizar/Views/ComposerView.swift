//
//  ComposerView.swift
//  DSH-Mizar
//
//  Sending a prompt, and stopping one.
//
//  One slab of glass: the field on top, growing with the text; the attachments,
//  when there are any; and along the bottom edge the controls -- commands, the
//  model, the context dial -- with the one round button at the end. The button
//  carries both actions, and which one it carries is the whole state machine:
//
//    the session is running, nothing typed, nothing attached     -> stop
//    anything else                                               -> send
//
//  That is DSH's own rule, and it is right for the same reason it is right
//  there: mid-turn the thing an operator most often wants is to interrupt, and
//  the second most common is to queue something up. One button that changes
//  meaning keeps both one tap away; it changes shape as it changes meaning, so
//  the meaning is never a surprise.
//
//  Attachments are part of the paid feature set, which a direct link on the
//  operator's own network also unlocks: nothing there is carried by the relay,
//  which is the commercial reason the two go together. The buttons live in the
//  command popover and draw their own lock when the set is not available;
//  tapping a locked one opens the account screen, because a refusal that
//  explains itself is a refusal the operator can act on.
//

import MizarKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    let sessionId: String
    let stats: SessionStatsFrame?
    /// What has been typed. Owned by the screen, because the command list puts
    /// text in here -- a command is something the operator finishes typing.
    @Binding var text: String
    /// Whether the field holds the keyboard. Owned by the screen so a tap on the
    /// conversation can put it away.
    @FocusState.Binding var focused: Bool
    /// Whether the composer is opened out into its tall, focused-input form.
    /// Owned by the screen: the room the conversation reserves and the dock's
    /// presence both answer to it.
    @Binding var expanded: Bool
    @Binding var showingModel: Bool
    @Binding var showingContext: Bool
    @Binding var showingCommands: Bool
    /// Called the moment a send is tapped, with what is being sent: the screen
    /// puts it in flight towards the conversation before the host has answered.
    var onWillSend: (String) -> Void = { _ in }
    /// Called with the text the host accepted, so the conversation can pick it up.
    let onSent: (String) async -> Void
    /// Called when the host refused it; the text is back in the field.
    var onSendFailed: (String) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @State private var sending = false
    @State private var stopping = false
    /// Bumped on every send, to bounce the arrow.
    @State private var sends = 0

    // MARK: Attachments

    /// What is attached to the next send.
    @State private var attachments: [AttachmentDraft] = []
    /// Where the upload writes its progress, out of the socket's executor.
    @State private var uploadProgress = AttachmentProgress()
    /// The items picked from the photo library, before they are normalised.
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    /// The account screen, when a free account taps a locked attachment button.
    @State private var showingPaywall = false
    /// Why the last attachment attempt failed, or why the send did.
    @State private var attachmentError: String?
    /// Whether an upload is in flight, so the price of a second tap is clear.
    @State private var uploading = false

    private static let buttonSize: CGFloat = 34
    private static let corner: CGFloat = Theme.Radius.xl

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The key, not the Chinese: this string is already in the catalogue.
            //
            // Expanded, the field is the composer: it takes every point between
            // the top edge and the controls, so a long prompt is read whole
            // instead of through an eight-line letterbox. It is one field with
            // two limits, never two fields: a second branch would be a second
            // view, and focus does not survive the swap -- the keyboard dropped
            // on every expand and collapse until this was one TextField.
            TextField("Ask your agent…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(expanded ? nil : 8)
                .focused($focused)
                .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .topLeading)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 6)
                .accessibilityIdentifier("composer.field")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SessionDetailView.space)) } action: { frame in
                    ComposerGeometry.shared.field = frame
                }

            if !attachments.isEmpty {
                AttachmentStrip(drafts: attachments, progress: uploadProgress) { id in
                    remove(id)
                }
            }

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(Theme.failed)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("composer.attachment.error")
            }

            HStack(spacing: 6) {
                ComposerBar(
                    sessionId: sessionId,
                    stats: stats,
                    draft: $text,
                    focused: $focused,
                    showingModel: $showingModel,
                    showingContext: $showingContext,
                    showingCommands: $showingCommands,
                    showingPhotoPicker: $showingPhotoPicker,
                    showingFileImporter: $showingFileImporter,
                    onLockedAttachment: { showingPaywall = true },
                )
                Spacer(minLength: 4)
                // Put the keyboard away. Only there while the keyboard is up:
                // with it down the button has nothing to do, and a control
                // that does nothing reads as a broken one.
                if focused {
                    dismissKeyboardButton
                        .transition(.pop)
                }
                expandButton
                primaryButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .animation(.mizarSmooth, value: text.isEmpty)
        .animation(.mizarSmooth, value: attachments.count)
        // Drives the keyboard button's arrival when the field is tapped into.
        // `expanded` is deliberately not animated here: the expand button
        // already wraps its change in a transaction, and a second implicit
        // animation over the same change double-drove the layout.
        .animation(.mizarSmooth, value: focused)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .mizarFeedback(.impact(weight: .light), trigger: sends)
        // A picker bound to this view rather than to a button: it has to survive
        // the popover closing.
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: max(1, AttachmentLimits.maxImages - imageCount),
            matching: .images,
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
        ) { result in
            switch result {
            case .success(let urls): addFiles(urls)
            case .failure(let error): attachmentError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingPaywall) {
            NavigationStack {
                AccountScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingPaywall = false }
                        }
                    }
            }
        }
    }

    private enum Mode: Equatable { case idle, send, stop }

    private var mode: Mode {
        if showsStop { return .stop }
        return sendEnabled ? .send : .idle
    }

    private var primaryButton: some View {
        Button {
            Task { await primary() }
        } label: {
            ZStack {
                Image(systemName: mode == .stop ? "stop.fill" : "arrow.up")
                    .font(.system(size: mode == .stop ? 13 : 15, weight: .bold))
                    .foregroundStyle(foreground)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce.up, value: sends)
                    .opacity(sending || uploading ? 0 : 1)
                if sending || uploading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                }
            }
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .background {
                Circle()
                    .fill(fill)
                    .shadow(color: mode == .idle ? .clear : fill.opacity(0.4), radius: 8, y: 3)
            }
            .scaleEffect(mode == .idle ? 0.92 : 1)
            .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .disabled(mode == .idle)
        .animation(.mizarBouncy, value: mode)
        .accessibilityLabel(showsStop ? "Stop" : "Send")
        .accessibilityIdentifier(showsStop ? "composer.stop" : "composer.send")
    }

    /// Put the keyboard away, one tap -- and with it the expanded composer:
    /// the tall field exists for typing, and with no keyboard up it is a
    /// screenful of nothing to type into. Sits at the left of the expand
    /// button, and only exists while the keyboard is up -- see the call site.
    private var dismissKeyboardButton: some View {
        Button {
            withMizarAnimation(.mizarSmooth) {
                focused = false
                expanded = false
            }
        } label: {
            // A chevron, not an arrow: next to the send button's arrow.up the
            // two stems read as the same glyph, and these keys are not send.
            //
            // A solid circle, like the send button it sits beside -- not glass.
            // A glass circle nested inside the composer's own glass is morphed
            // by the glass engine whenever the slab changes shape, so the
            // button wandered with the expansion and snapped back after;
            // opaque fills are not morphable, which is why the other keys on
            // this row never moved.
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                }
                .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(Text("Hide keyboard"))
        .accessibilityIdentifier("composer.dismissKeyboard")
    }

    /// Open the composer out to the height of the screen, and back.
    ///
    /// At rest a grey circle with an up chevron -- the field will grow
    /// upwards; open, it takes on the send button's blue, and the same tap
    /// puts the composer back to rest. The expansion itself is laid out by
    /// the screen, which owns the space above; this button only decides.
    private var expandButton: some View {
        Button {
            // One transaction for both: the expansion animates the shape, and
            // the keyboard rises with it, so the first character can follow
            // the tap immediately. Animated separately they drove the layout
            // twice, and the row shuddered.
            withMizarAnimation(.mizarSmooth) {
                expanded.toggle()
                if expanded {
                    focused = true
                }
            }
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(expanded ? Theme.onAccent : .secondary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    Circle()
                        .fill(expanded ? Color.accentColor : Color(.tertiarySystemFill))
                        .shadow(
                            color: expanded ? Color.accentColor.opacity(0.4) : .clear,
                            radius: 8, y: 3,
                        )
                }
                .contentShape(.circle)
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(Text(expanded ? "Collapse the composer" : "Expand the composer"))
        .accessibilityIdentifier("composer.expand")
    }

    private var fill: Color {
        switch mode {
        case .stop: Theme.failed
        case .send: .accentColor
        case .idle: Color(.tertiarySystemFill)
        }
    }

    private var foreground: Color {
        switch mode {
        case .stop: .white
        case .send: Theme.onAccent
        case .idle: .secondary
        }
    }

    /// Whether the session this composer belongs to has a turn in flight.
    private var running: Bool {
        model.sessions.first { $0.sessionId == sessionId }?.running ?? false
    }

    /// Whether the one button is a stop button right now.
    private var showsStop: Bool {
        running && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty && !stopping
    }

    private var sendEnabled: Bool {
        guard !sending, !uploading else { return false }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !attachments.isEmpty
    }

    /// How many of the attached drafts are images.
    private var imageCount: Int {
        attachments.count(where: \.isImage)
    }

    /// Do whichever job the button is currently carrying.
    private func primary() async {
        if showsStop {
            stopping = true
            await model.cancelTurn(sessionId: sessionId)
            stopping = false
        } else {
            await send()
        }
    }

    // MARK: - Sending

    private func send() async {
        let outgoing = text
        let drafts = attachments
        let display = AttachmentDraft.promptText(outgoing, drafts: drafts)
        guard !display.isEmpty else { return }
        // The server's plan is the authority, but the phone can avoid a useless
        // upload: without the advanced feature set nothing can be attached, and
        // the account screen is where that changes. A LAN link unlocks the set
        // as well, so this guard is only reachable off the operator's own
        // network; the sentence still names the plan, because the screen it
        // opens is where a plan is bought.
        if !drafts.isEmpty, !model.advancedFeaturesUnlocked {
            attachmentError = String(localized: "Attachments need a paid account.")
            showingPaywall = true
            return
        }

        sending = true
        sends += 1
        attachmentError = nil
        onWillSend(display)
        // Clear optimistically so the field is ready for the next thought; put
        // everything back if the host refused it, so nothing is silently lost.
        // The attachments stay on screen while they upload, which is the one
        // place the progress is drawn.
        withMizarAnimation(.mizarSmooth) { text = "" }

        let accepted: Bool
        if drafts.isEmpty {
            accepted = await model.sendPrompt(outgoing, to: sessionId)
        } else {
            accepted = await uploadAndSend(drafts: drafts, text: outgoing)
        }

        if accepted {
            withMizarAnimation(.mizarSmooth) { attachments = [] }
            uploadProgress.clear()
            await onSent(display)
        } else {
            text = outgoing
            attachments = drafts
            uploadProgress.clear()
            onSendFailed(display)
        }
        sending = false
        focused = true
    }

    /// Upload every attachment, then send the prompt that names them.
    ///
    /// - Parameters:
    ///   - drafts: the attachments.
    ///   - text: the prompt text, possibly empty.
    /// - Returns: whether the host accepted the prompt.
    private func uploadAndSend(drafts: [AttachmentDraft], text: String) async -> Bool {
        uploading = true
        defer { uploading = false }
        var ids: [String] = []
        do {
            for draft in drafts {
                let draftId = draft.id
                let progress = uploadProgress
                let ref = try await model.uploadAttachment(
                    data: draft.data,
                    kind: draft.kind,
                    name: draft.name,
                    mediaType: draft.mediaType,
                    sessionId: sessionId,
                    progress: { value in
                        Task { @MainActor in
                            progress.set(value, for: draftId)
                        }
                    },
                )
                ids.append(ref.attachmentId)
            }
            return await model.sendPrompt(text, attachmentIds: ids, to: sessionId)
        } catch {
            attachmentError = Self.describeAttachmentFailure(error)
            return false
        }
    }

    /// A failed upload as a sentence.
    ///
    /// `NOT_IMPLEMENTED` is the old-host-plugin case: the computer's DSH predates
    /// the upload methods, and the fix is an update on the computer, not a
    /// retry on the phone. Saying so is the difference between a bug report and
    /// a support answer.
    private static func describeAttachmentFailure(_ error: any Error) -> String {
        if let mizar = error as? MizarError {
            switch mizar.code {
            case "NOT_IMPLEMENTED", "MALFORMED_FRAME", "UPLOAD_UNKNOWN":
                return String(localized: "This computer's DSH plugin is too old to receive attachments. Update DSH on the computer, then try again.")
            default:
                return mizar.message
            }
        }
        return error.localizedDescription
    }

    // MARK: - Attaching

    /// Read picked photos into drafts.
    ///
    /// - Parameter items: the picked items; the picker binding is reset whatever
    ///   happens so picking the same photo twice fires again.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        defer { photoItems = [] }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentProblem.unreadableImage
                }
                add(try AttachmentDraft.image(from: data))
            } catch {
                attachmentError = Self.describe(error)
            }
        }
    }

    /// Read imported files into drafts.
    ///
    /// - Parameter urls: the URLs from `fileImporter`.
    private func addFiles(_ urls: [URL]) {
        for url in urls {
            do {
                add(try AttachmentDraft.file(from: url))
            } catch {
                attachmentError = Self.describe(error)
            }
        }
    }

    /// Add one draft, subject to the limits.
    ///
    /// - Parameter draft: the draft to add.
    private func add(_ draft: AttachmentDraft) {
        var candidate = attachments
        candidate.append(draft)
        do {
            try AttachmentDraft.validate(candidate)
            withMizarAnimation(.mizarSmooth) { attachments = candidate }
            attachmentError = nil
        } catch {
            attachmentError = Self.describe(error)
        }
    }

    /// Remove one draft.
    /// - Parameter id: the draft's identity.
    private func remove(_ id: UUID) {
        withMizarAnimation(.mizarSmooth) {
            attachments.removeAll { $0.id == id }
        }
        uploadProgress.clear()
        attachmentError = nil
    }

    /// A local validation failure as a sentence.
    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Where the field is, for the send's flight to start from.
///
/// A plain object rather than state: the frame changes on every keystroke that
/// wraps a line, and nothing needs to redraw when it does -- it is read once, at
/// the moment of a send.
@MainActor
final class ComposerGeometry {
    static let shared = ComposerGeometry()
    var field: CGRect = .zero
}
