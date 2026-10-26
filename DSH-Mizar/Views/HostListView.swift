//
//  HostListView.swift
//  DSH-Mizar
//
//  The machines this phone is paired with, and the way to add another.
//
//  This is the first screen once anything is paired, and the only screen when
//  nothing is. A phone that manages one computer is the common case and gets a list
//  of one; a phone that manages three should not have to unpair to switch, which
//  is what the first version required.
//
//  Naming lives here rather than on the host. `Shirazus-Mac-mini.local` is fine
//  once and useless three times, and a name the operator typed on this phone is
//  theirs to change without touching a machine.
//

import SwiftUI
import MizarKit

/// Every paired machine, with a way to add more.
///
/// The window that drops out of the computer's name at the top of the sidebar.
/// Choosing a row switches to that computer, and renaming one goes deeper inside
/// the same window rather than opening another on top of it. Adding one is the
/// exception: the pairing card is a sheet, because it has to grow for its
/// camera and a popover cannot (see ``PairingSheet``).
struct HostListView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [HostRoute] = []
    /// Whether the pairing card is up. A sheet rather than a page pushed into
    /// this window: the camera it opens is as tall as the screen is wide, and
    /// only a sheet can grow for it. See ``PairingSheet``.
    @State private var pairing = false

    enum HostRoute: Hashable {
        case rename(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.hosts, id: \.hostId) { host in
                        Button {
                            Task { await model.open(hostId: host.hostId) }
                        } label: {
                            HostRow(host: host, isOpen: model.host?.hostId == host.hostId, live: model.isConnected)
                        }
                        .buttonStyle(.pressable(scale: 0.98))
                        .accessibilityIdentifier("host.row.\(host.hostId)")
                        .contextMenu {
                            Button {
                                path.append(.rename(host.hostId))
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                Task { await model.forget(hostId: host.hostId) }
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        pairing = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text("Add a computer")
                                .font(.body.weight(.medium))
                            Spacer(minLength: 0)
                            Image(systemName: "qrcode.viewfinder")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.pressable(scale: 0.98))
                    .accessibilityIdentifier("hosts.add")
                    .padding(.top, 4)

                    Text("Long-press a computer to rename or forget it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Computers")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HostRoute.self) { route in
                switch route {
                case .rename(let hostId):
                    if let host = model.hosts.first(where: { $0.hostId == hostId }) {
                        RenameForm(host: host, skipTitle: "Cancel") { name in
                            if let name { Task { await model.rename(hostId: host.hostId, to: name) } }
                            path.removeAll()
                        }
                    }
                }
            }
            .sheet(isPresented: $pairing) {
                PairingSheet()
            }
        }
    }
}

/// One machine.
private struct HostRow: View {
    let host: PairedHost
    let isOpen: Bool
    let live: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.body.weight(.medium))
                .foregroundStyle(isOpen ? Theme.onAccent : Color.secondary)
                .frame(width: 34, height: 34)
                .background(
                    isOpen ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.fill.tertiary),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body.weight(isOpen ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // The host's own name is shown under a chosen one, so a machine
                // renamed to something memorable can still be identified.
                Text(host.label == nil ? host.pairedAt.formatted(.relative(presentation: .named)) : host.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isOpen {
                HStack(spacing: 5) {
                    Circle()
                        .fill(live ? Theme.running : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(live ? "connected" : "offline")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.fill.quaternary, in: Capsule())
                .transition(.pop)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isOpen {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.selectionFill)
            }
        }
        .contentShape(.rect)
        .animation(.mizarSmooth, value: isOpen)
    }
}

/// The name prompt, as the contents of a small window.
///
/// Offered once, immediately after pairing, because that is the moment the
/// operator still knows which machine they just scanned -- out of the
/// computer's name at the top of the sidebar, where the name will be. Offered
/// again from the row's menu when they have thought of a better one.
struct RenameForm: View {
    let host: PairedHost
    /// "Skip" right after pairing, "Cancel" from the menu.
    var skipTitle: LocalizedStringKey = "Skip"
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this computer")
                .font(.headline)
            TextField(host.hostName, text: $name)
                .textInputAutocapitalization(.words)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { save() }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .accessibilityIdentifier("rename.field")
            Text("Shown only on this phone. Leave it empty to use the machine's own name, \(host.hostName).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // "Skip", not "Cancel", after a pairing: naming is optional, and
                // a pairing that has already succeeded must not look like
                // something the operator can back out of from here.
                Button {
                    onSave(nil)
                    dismiss()
                } label: {
                    Text(skipTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("rename.skip")
                Button {
                    save()
                } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("rename.save")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 320)
        .onAppear {
            name = host.label ?? ""
            focused = true
        }
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

extension PairedHost: @retroactive Identifiable {
    /// Identity for `popover(item:)`.
    public var id: String { hostId }
}

/// The screen a phone shows when it has never been paired.
///
/// It says what to do rather than showing an empty list, and it is the whole of
/// the first-run experience: there is nothing else this app can usefully do
/// without a machine on the other end. Drawn in the icon's own navy, with the
/// mark sending its signal up and out -- looking for a computer to answer it.
///
/// The mark is injectable so the snapshot suite can pin its resting state
/// (`MizarMark(lit: 3)`, the state reduce motion rests on): the searching
/// arcs animate on a repeating keyframe animator, which no render transaction
/// stops, and `accessibilityReduceMotion` is a get-only environment key the
/// harness cannot set. On screen it is always the searching mark; see the
/// convenience initialiser.
struct UnpairedView<Mark: View>: View {
    @State private var showingPairing = false
    /// The mark above the copy. Always the searching mark on screen.
    private let mark: Mark

    init(mark: Mark) {
        self.mark = mark
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.navy, Theme.navyDeep],
                startPoint: .top,
                endPoint: .bottom,
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [Color.accentColor.opacity(0.22), .clear],
                center: .init(x: 0.5, y: 0.34),
                startRadius: 10,
                endRadius: 320,
            )
            .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()
                    mark
                        .frame(width: 112)
                        .padding(.bottom, 36)
                    Text("Install the plugin, then scan")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Text("In DSH's plugin panel, enter dsh-mizar to install the plugin, then restart DSH. When the panel shows a code, come back here and scan it.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                        .padding(.horizontal, 30)
                    Text("dsh plugin --profile desktop add dsh-mizar")
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.62))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.08), in: Capsule())
                        .padding(.top, 14)
                    Spacer()
                    Button {
                        showingPairing = true
                    } label: {
                        Label("Scan the code", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .accessibilityIdentifier("unpaired.scan")
                    // A card over the navy, which can grow for the camera; see
                    // ``PairingSheet``.
                    .sheet(isPresented: $showingPairing) {
                        PairingSheet()
                    }
                    .padding(.horizontal, 28)
                    Text("Once it is installed, there is nothing else to set up.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                }
        }
        .environment(\.colorScheme, .dark)
    }
}

extension UnpairedView where Mark == MizarMarkSearching {
    /// The screen as it ships: the searching mark, sending its pulse up and
    /// out for as long as it is on screen.
    init() {
        self.init(mark: MizarMarkSearching(accent: Color(red: 0.235, green: 0.796, blue: 0.957), ink: .white))
    }
}
