import Carbon.HIToolbox
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// The panes of Settings, in the sidebar's order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, hud, mini, listening, remote, lyrics, stems, permissions, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .hud: "HUD"
        case .mini: "Mini player"
        case .listening: "Listening"
        case .remote: "Remote"
        case .lyrics: "Lyrics"
        case .stems: "Instruments and vocals"
        case .permissions: "Permissions"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .hud: "rectangle.on.rectangle"
        case .mini: "record.circle"
        case .listening: "ear"
        case .remote: "iphone.and.arrow.forward"
        case .lyrics: "quote.bubble"
        case .stems: "slider.vertical.3"
        case .permissions: "hand.raised"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }

    var hue: SidebarHue {
        switch self {
        case .general: .stone
        case .hud: .skin
        case .mini: .teal
        case .listening: .dustyBlue
        case .remote: .periwinkle
        case .lyrics: .plum
        case .stems: .sage
        case .permissions: .terracotta
        case .updates: .ochre
        case .about: .dustyRose
        }
    }
}

/// A muted, earthy sidebar colour with a light and a dark tone, the palette that every lowtechguys app uses for the
/// tiles of its Settings sidebar (kept in step with Cling, rcmd, Lunar, Clop, Pipiri and Crank).
struct SidebarHue {
    static let sage = rgb(0.39, 0.49, 0.26, 0.60, 0.66, 0.50)
    static let dustyBlue = rgb(0.24, 0.43, 0.63, 0.53, 0.64, 0.75)
    static let periwinkle = rgb(0.41, 0.37, 0.68, 0.62, 0.60, 0.80)
    static let terracotta = rgb(0.74, 0.35, 0.23, 0.82, 0.52, 0.40)
    static let skin = rgb(0.74, 0.47, 0.30, 0.80, 0.64, 0.52)
    static let plum = rgb(0.58, 0.30, 0.55, 0.68, 0.55, 0.67)
    static let stone = rgb(0.45, 0.43, 0.37, 0.66, 0.64, 0.57)
    static let ochre = rgb(0.78, 0.56, 0.16, 0.83, 0.68, 0.40)
    static let dustyRose = rgb(0.76, 0.39, 0.40, 0.80, 0.60, 0.58)
    static let teal = rgb(0.20, 0.49, 0.49, 0.48, 0.67, 0.65)

    let light: Color
    let dark: Color

    func color(for scheme: ColorScheme) -> Color { scheme == .dark ? dark : light }

    private static func rgb(_ lr: Double, _ lg: Double, _ lb: Double, _ dr: Double, _ dg: Double, _ db: Double) -> SidebarHue {
        SidebarHue(light: Color(.sRGB, red: lr, green: lg, blue: lb), dark: Color(.sRGB, red: dr, green: dg, blue: db))
    }
}

/// The glyph of a pane on a soft tile of the same hue.
struct SidebarIcon: View {
    let symbol: String
    let hue: SidebarHue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = hue.color(for: scheme)
        Image(systemName: symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .frame(width: 12, height: 12)
            .frame(width: 20, height: 20)
            .background(color.opacity(scheme == .dark ? 0.22 : 0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A window that isn't a SwiftUI scene opens its sidebar at the split view's default width, whatever the column width
/// asks for, which cuts "Instruments and vocals" short. This sets the width on the split view itself, once, and keeps
/// the sidebar from collapsing, since the toolbar has no button to bring it back.
private struct SidebarWidth: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context _: Context) -> NSView { Probe(width: width) }
    func updateNSView(_: NSView, context _: Context) {}

    private final class Probe: NSView {
        let width: CGFloat
        private var done = false

        init(width: CGFloat) {
            self.width = width
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard !done else { return }
            var view = superview
            for _ in 0 ..< 40 where view != nil && !(view is NSSplitView) { view = view?.superview }
            guard let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first else { return }
            done = true
            for item in controller.splitViewItems { item.canCollapse = false }
            sidebar.minimumThickness = width
            split.setPosition(width, ofDividerAt: 0)
        }
    }
}

/// The pane that Settings shows, which the mini player's menu can pick before Settings opens.
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()
    /// `--settings-pane NAME` opens Settings on that pane, for checking each one without clicks.
    @Published var pane: SettingsPane = TestFlags.value("--settings-pane").flatMap(SettingsPane.init) ?? .general
}

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var hud: HUDModel
    let keyCache: KeyCache
    let setLayout: (Bool) -> Void

    @ObservedObject private var route = SettingsRoute.shared
    private var selection: SettingsPane { route.pane }

    var body: some View {
        NavigationSplitView {
            List(selection: $route.pane) {
                Section {
                    row(.general)
                    row(.hud)
                    row(.mini)
                    row(.listening)
                    row(.remote)
                }
                Section("Music") {
                    row(.lyrics)
                    row(.stems)
                }
                Section("Support") {
                    row(.permissions)
                    row(.updates)
                    row(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralPane(prefs: prefs)
                case .hud: HUDPane(prefs: prefs, hud: hud, setLayout: setLayout)
                case .mini: MiniPlayerPane(prefs: prefs)
                case .listening: ListeningPane(prefs: prefs, keyCache: keyCache)
                case .remote: RemotePane(prefs: prefs)
                case .lyrics: LyricsPane(prefs: prefs)
                case .stems: StemsPane(prefs: prefs)
                case .permissions: PermissionsPane()
                case .updates: UpdatesPane()
                case .about: AboutPane()
                }
            }
            // The toolbar names the pane, as System Settings does.
            .navigationTitle(selection.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SidebarWidth(width: 210))
            .background(WindowTitle(title: selection.title))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, idealWidth: 740, minHeight: 500, idealHeight: 540)
    }

    private func row(_ pane: SettingsPane) -> some View {
        NavigationLink(value: pane) {
            Label { Text(pane.title) } icon: { SidebarIcon(symbol: pane.symbol, hue: pane.hue) }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Keyboard") {
                // A Form sizes a row by its label, so a 24 pt button sticks out above a one-line label and leaves
                // the row with more space below it than above. A label as tall as the button centres both, and the
                // negative padding keeps the row as tall as the others.
                LabeledContent {
                    ShortcutRecorder(shortcut: $prefs.hotkey, recording: $prefs.recordingHotkey, failed: prefs.hotkeyFailed)
                } label: {
                    Text("Hotkey").frame(minHeight: 24)
                }
                .padding(.vertical, -2)
                LabeledContent {
                    ShortcutRecorder(shortcut: $prefs.micHotkey, recording: $prefs.recordingMicHotkey, failed: prefs.micHotkeyFailed, standard: .mic)
                } label: {
                    Text("Microphone hotkey").frame(minHeight: 24)
                }
                .padding(.vertical, -2)
            }
            Section("Trackpad") {
                Toggle(isOn: $prefs.naturalSwipes) {
                    Text("Natural swiping")
                    Text("Swipe left for next song and right for previous song")
                }
            }
            Section("Playback") {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Cut sound adjustments after pausing music", value: $prefs.pauseStopSeconds, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                            .disabled(!prefs.pauseStop)
                        Text("seconds")
                            .foregroundStyle(prefs.pauseStop ? .primary : .secondary)
                        Toggle("Cut sound adjustments after pausing music", isOn: $prefs.pauseStop)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                } label: {
                    Text("Cut sound adjustments after pausing music")
                    Text("If Muskey HUD is hidden and music was paused for \(prefs.pauseStopSeconds) seconds, automatically stop pitch and tempo adjustments")
                }
                .onChange(of: prefs.pauseStopSeconds) { _, seconds in
                    if !(1 ... 3600).contains(seconds) { prefs.pauseStopSeconds = min(max(seconds, 1), 3600) }
                }
            }
            Section("Cache") {
                LabeledContent {
                    Picker("Cache cleanup", selection: $prefs.cacheCleanup) {
                        ForEach(CacheCleanup.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Cache cleanup")
                    Text("Delete cached audio older than the configured period")
                }
            }
            Section("Menu bar icon") {
                MenuBarIconTiles(icon: $prefs.menuBarIcon)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
            }
            Section("Privacy") {
                Toggle(isOn: $prefs.errorReports) {
                    Text("Send error reports")
                    Text("Anonymous crash and hang reports sent to Sentry")
                }
                if prefs.errorReports {
                    LabeledContent("Machine ID") { MachineIDPill() }
                }
            }
            Section("Logs") {
                KeptLogsRow(logs: .shared)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings > Remote: the `muskey` tool, the web remote with its address and pairing code, and the folders whose songs
/// the web remote lists.
private struct RemotePane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var links = WebLinks.shared
    @State private var confirmsHTTPS = false

    var body: some View {
        Form {
            Section {
                CLIToolRow()
            }
            Section("Web remote") {
                Toggle(isOn: $prefs.webRemote) {
                    Text("Web remote")
                    Text("Access Muskey on your Mac from your phone through web interface")
                }
                // Only where Tailscale would issue the certificate: anywhere else the switch could do nothing.
                if prefs.webRemote, let domain = links.certificateDomain {
                    Toggle("HTTPS on Tailscale", isOn: Binding(
                        get: { prefs.remoteHTTPS },
                        set: { on in
                            if on { confirmsHTTPS = true } else { prefs.remoteHTTPS = false }
                        }
                    ))
                    // Asked before the first certificate, since getting one publishes the Mac's name on the tailnet.
                    .alert("Get an HTTPS certificate for this Mac?", isPresented: $confirmsHTTPS) {
                        Button("Get Certificate") { prefs.remoteHTTPS = true }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Tailscale gets it from Let's Encrypt, which lists every certificate in public logs, with this Mac's Tailscale name: \(domain)")
                    }
                }
                if prefs.webRemote {
                    PairingControls(prefs: prefs)
                    Toggle("Hide HUD for phone actions", isOn: $prefs.remoteHeadless)
                }
            }
            if prefs.webRemote {
                Section {
                    RemoteFolders(prefs: prefs)
                } header: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Music folders")
                        Text("Folders in which Muskey will look for audio files for presenting them in the song picker")
                            .font(.subheadline.weight(.regular))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The address that the link carries, the link as a QR code for a phone's camera, the link in a pill that copies it,
/// and Reset Link, which makes a new one and unpairs every device that opened the old one.
private struct PairingControls: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var links = WebLinks.shared
    @State private var link: String?
    @State private var choices = WebAddresses.choices(lookUp: false)
    @State private var copied = false
    @State private var confirmsReset = false

    /// The pick as the menu shows it: a Tailscale address shows as the name that HTTPS is served for, which is the one
    /// that the link carries. The pick itself is kept, for when HTTPS is turned off.
    private var shownPick: String {
        guard let picked = prefs.remoteAddress else { return "" }
        return WebAddresses.reachable(picked, addresses: WebAddresses.current()) ?? picked
    }

    var body: some View {
        LabeledContent("Address") {
            Picker("Address", selection: Binding(get: { shownPick }, set: { prefs.remoteAddress = $0.isEmpty ? nil : $0 })) {
                Text("Automatic").tag("")
                ForEach(choices) { Text(verbatim: $0.title).tag($0.host) }
                // A picked address that went away stays picked, for when it comes back.
                if !shownPick.isEmpty, !choices.contains(where: { $0.host == shownPick }) {
                    Text(verbatim: "Not connected · \(shownPick)").tag(shownPick)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .task(id: links.secureHost) {
            choices = WebAddresses.choices(lookUp: false)
            // Reverse lookups wait on the network's DNS, so the names arrive after the addresses. A lookup that started
            // before the certificate arrived can end after the one that started with it, so its list is dropped.
            let named = await Task.detached(priority: .userInitiated) { WebAddresses.choices(lookUp: true) }.value
            guard !Task.isCancelled else { return }
            choices = named
        }
        .onChange(of: prefs.remoteAddress) { refresh() }
        // The certificate can arrive a minute after HTTPS is turned on, and the link moves to its name then.
        .onChange(of: links.secureHost) { refresh() }

        VStack(spacing: 12) {
            if let link {
                PairingCode(text: link)
                    .frame(width: 168, height: 168)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Text(verbatim: link)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 330)
                        .opacity(copied ? 0 : 1)
                        .overlay { Text("Copied").font(.system(size: 11, weight: .semibold, design: .rounded)).opacity(copied ? 1 : 0) }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.quaternary))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Copy the pairing link")
            } else {
                Text("No network").foregroundStyle(.secondary)
            }
            Button("Reset Link") { confirmsReset = true }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .onAppear(perform: refresh)
        .alert("Reset the pairing link?", isPresented: $confirmsReset) {
            Button("Reset Link", role: .destructive) {
                WebRemote.shared.reset()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Devices that opened the old link lose access to the remote")
        }
    }

    private func refresh() {
        link = WebRemote.shared.pairingLink
    }
}

/// The pairing link as a QR code in the ink of the HUD on a warm white, which phone cameras read as well as black on
/// white. It keeps the light background in dark mode too, since scanners need dark modules on a light ground.
private struct PairingCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .padding(10)
                .background(Color(.sRGB, red: 0.98, green: 0.957, blue: 0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
    }

    private static let context = CIContext()

    private static func image(_ text: String) -> CGImage? {
        let code = CIFilter.qrCodeGenerator()
        code.message = Data(text.utf8)
        code.correctionLevel = "M"
        let colours = CIFilter.falseColor()
        colours.inputImage = code.outputImage
        colours.color0 = CIColor(red: 0.13, green: 0.078, blue: 0.10)
        colours.color1 = CIColor(red: 0.98, green: 0.957, blue: 0.94)
        guard let output = colours.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}

/// The folders whose songs the web remote lists, each with the count of its songs. The count is made off the main
/// thread while the pane shows, which also asks macOS for access to a protected folder while someone is at the Mac.
private struct RemoteFolders: View {
    @ObservedObject var prefs: Preferences
    @State private var counts: [String: Int] = [:]

    /// Past this many songs, a folder shows a count with a plus.
    private static let countLimit = 10000

    var body: some View {
        if prefs.remoteFolders.isEmpty {
            Text("No folders").foregroundStyle(.secondary)
        }
        ForEach(prefs.remoteFolders, id: \.self) { path in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: (path as NSString).lastPathComponent)
                    Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let count = counts[path] {
                    Text(verbatim: Self.songs(count))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                        .fixedSize()
                }
                Button {
                    prefs.remoteFolders.removeAll { $0 == path }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove the folder")
            }
            .task(id: path) {
                let count = await Task.detached(priority: .utility) { Self.count(path) }.value
                counts[path] = count
            }
        }
        HStack {
            Spacer()
            Button("Add Folder…", action: add)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Folders whose songs the web remote lists"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path).filter { !prefs.remoteFolders.contains($0) }
        prefs.remoteFolders.append(contentsOf: paths)
    }

    /// The audio files in a folder and the folders inside it, up to `countLimit` and one more.
    nonisolated private static func count(_ path: String) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var found = 0
        for case let url as URL in walker {
            guard !Task.isCancelled else { break }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) {
                found += 1
                if found > countLimit { break }
            }
        }
        return found
    }

    /// `124 songs`, `10 000+ songs`, with a narrow no-break space in a count of five digits and more.
    private static func songs(_ count: Int) -> String {
        let shown = min(count, countLimit)
        var digits = String(shown)
        if digits.count >= 5 {
            var groups: [String] = []
            while digits.count > 3 {
                groups.insert(String(digits.suffix(3)), at: 0)
                digits.removeLast(3)
            }
            groups.insert(digits, at: 0)
            digits = groups.joined(separator: "\u{202F}")
        }
        let plus = count > countLimit ? "+" : ""
        return "\(digits)\(plus) \(shown == 1 && plus.isEmpty ? "song" : "songs")"
    }
}

/// Install links the `muskey` tool into `~/.local/bin`, and Add to PATH appears while a shell config lacks that folder.
/// The files are read and written off the main thread, since a shell config can sit on a slow or stalled disk.
private struct CLIToolRow: View {
    @State private var installed = false
    @State private var needsPath = false
    @State private var addedPath = false
    @State private var failure: String?
    @State private var working = false

    var body: some View {
        LabeledContent("Command line tool") {
            HStack(spacing: 8) {
                // The failure takes the place of the pills, so the row stays on one line.
                if installed, failure == nil {
                    pill(ShellIntegration.shownLink, monospaced: true)
                    if addedPath {
                        pill("Added to PATH")
                            .help("Restart the shell to use muskey")
                    } else if needsPath {
                        Button("Add to PATH") { run(ShellIntegration.addToPath) { addedPath = true } }
                            .help("Add ~/.local/bin to the PATH in .zshrc, .bashrc and config.fish")
                    }
                }
                if failure != nil {
                    Button("Retry") { run(ShellIntegration.install) }
                }
                Button(installed ? "Reinstall" : "Install") { run(ShellIntegration.install) }
                    .tint(failure == nil ? nil : .red)
                    .buttonStyle(.borderedProminent)
                    .help(failure ?? "")
                    .overlay(alignment: .topTrailing) {
                        if failure != nil {
                            Button { failure = nil } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                        }
                    }
            }
            .disabled(working)
        }
        .task { await refresh() }
    }

    private func pill(_ text: String, monospaced: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, design: monospaced ? .monospaced : .default))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
    }

    private func refresh() async {
        let state = await Task.detached(priority: .userInitiated) { (ShellIntegration.installed, ShellIntegration.needsPath) }.value
        installed = state.0
        needsPath = state.1
    }

    private func run(_ action: @escaping @Sendable () throws -> Void, then done: @escaping () -> Void = {}) {
        working = true
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try action(); return nil } catch { return error.localizedDescription }
            }.value
            failure = error
            if error == nil { done() }
            await refresh()
            working = false
        }
    }
}

/// The anonymous ID that the error reports of this Mac carry, which a click copies so that it can go in a bug report.
/// "Copied" is drawn over the ID, so the pill keeps its width when it changes.
private struct MachineIDPill: View {
    @State private var copied = false
    private let id = ErrorReports.machineID

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: id)
                    .font(.system(size: 11, design: .monospaced))
                    .opacity(copied ? 0 : 1)
                    .overlay { Text("Copied").font(.system(size: 11, weight: .semibold, design: .rounded)).opacity(copied ? 1 : 0) }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy the ID of this Mac's error reports")
    }
}

private struct MiniPlayerPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Mini player", isOn: $prefs.miniPlayer)
            }
            Section("Fade") {
                // Read only while the pointer is over the player, where a tap of the key fades it.
                Picker(selection: $prefs.miniFadeKey) {
                    ForEach(FadeKey.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Fade key")
                    Text("Fades the mini player and passes clicks to the windows under it, until the pointer leaves it")
                }
                Toggle("Three-finger tap", isOn: $prefs.miniThreeFingerTap)
            }
            Section("Song") {
                Toggle("Track", isOn: $prefs.miniLayout.track)
                Toggle("Artist", isOn: $prefs.miniLayout.artist)
                Toggle("Album", isOn: $prefs.miniLayout.album)
            }
            Section("Record") {
                MiniRecordSizeRow(scale: $prefs.miniRecordScale)
            }
            Section("Layout") {
                MiniDirectionTiles(direction: $prefs.miniDirection)
            }
            Section("Background") {
                MiniBackgroundRows(background: $prefs.miniBackground)
            }
            Section("Elements") {
                MiniLayoutEditor(prefs: prefs)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings > General > Menu bar icon: a picture tile for each choice. It takes a binding so renders can show it
/// without touching the saved settings.
struct MenuBarIconTiles: View {
    @Binding var icon: MenuBarIcon

    var body: some View {
        HStack(spacing: 14) {
            ChoiceTile(title: "Always", selected: icon == .always, wallpaper: true) { icon = .always } preview: {
                MiniMenuBar(idle: true)
            }
            ChoiceTile(title: "During a pitch change", selected: icon == .pitchChange, wallpaper: true) { icon = .pitchChange } preview: {
                MiniMenuBar(idle: false)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Settings > Mini player > Layout: a picture tile for each layout. Automatic and On the record get the first row, each
/// as wide as two of the four sides under them, so both rows share the same columns. It takes a binding so renders can
/// show it without touching the saved settings.
struct MiniDirectionTiles: View {
    @Binding var direction: MiniDirection

    var body: some View {
        VStack(spacing: 12) {
            row([.automatic, .onRecord])
            row([.below, .above, .left, .right])
        }
        .padding(.vertical, 4)
    }

    private func row(_ choices: [MiniDirection]) -> some View {
        HStack(spacing: 8) {
            ForEach(choices, id: \.self) { choice in
                ChoiceTile(title: choice.title, selected: direction == choice, height: 72, wallpaper: true) {
                    direction = choice
                } preview: {
                    MiniDirectionPreview(direction: choice)
                }
            }
        }
    }
}

/// A small record with three lines of song beside it or under it. Automatic shows a screen with one of each: beside the
/// record in a corner, and over it at the bottom edge. On the record shows the lines on a larger record, with a pill
/// hanging from its bottom edge.
private struct MiniDirectionPreview: View {
    let direction: MiniDirection

    var body: some View {
        switch direction {
        case .onRecord:
            record(50, label: 0)
                .overlay { lines(.center, 26) }
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color(red: 0.95, green: 0.62, blue: 0.3))
                        .frame(width: 16, height: 6)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
                        .offset(y: 4)
                }
        case .below:
            VStack(spacing: 4) { record(26); lines(.center, 32) }
        case .above:
            VStack(spacing: 4) { lines(.center, 32); record(26) }
        case .left:
            HStack(spacing: 5) { lines(.trailing, 26); record(26) }
        case .right:
            HStack(spacing: 5) { record(26); lines(.leading, 26) }
        case .automatic:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.white.opacity(0.7), lineWidth: 1.2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.18)))
                .frame(width: 72, height: 50)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 3) { record(12); lines(.leading, 14, small: true) }.padding(4)
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 2) { lines(.center, 16, small: true); record(12) }.padding(.bottom, 3)
                }
        }
    }

    /// The record that carries the song has no label, so its lines read over grooves instead of over the orange label.
    private func record(_ size: CGFloat, label: CGFloat = 0.36) -> some View {
        Circle()
            .fill(Color(white: 0.08))
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5).padding(size * 0.12))
            .overlay(Circle().fill(Color(red: 0.95, green: 0.62, blue: 0.3)).frame(width: size * label, height: size * label))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    private func lines(_ alignment: HorizontalAlignment, _ width: CGFloat, small: Bool = false) -> some View {
        VStack(alignment: alignment, spacing: small ? 1.5 : 2.5) {
            Capsule().fill(.white).frame(width: width, height: small ? 2.5 : 3.5)
            Capsule().fill(.white.opacity(0.8)).frame(width: width * 0.72, height: small ? 2 : 3)
            Capsule().fill(.white.opacity(0.5)).frame(width: width * 0.86, height: small ? 2 : 3)
        }
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

/// Settings > Mini player > Record > Size: a slider from three quarters of the usual record to nearly twice its size,
/// with the size in a pill. It takes a binding so renders can show it without touching the saved settings.
struct MiniRecordSizeRow: View {
    @Binding var scale: Double

    var body: some View {
        LabeledContent("Size") {
            HStack(spacing: 10) {
                Slider(value: $scale, in: MiniPlayerView.scales) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: 7))
                } maximumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: 13))
                }
                .labelsHidden()
                .frame(width: 200)
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .frame(minWidth: 46, alignment: .trailing)
            }
        }
    }
}

/// Settings > Mini player > Background, in three rows at most: the material, its tint or colour with the opacity, and
/// the roundness. Rows that don't apply to the material are left out. It takes a binding so renders can show it
/// without touching the saved settings.
struct MiniBackgroundRows: View {
    @Binding var background: MiniBackground

    var body: some View {
        LabeledContent("Material") {
            Picker("Material", selection: $background.material) {
                ForEach(MiniMaterial.groups.indices, id: \.self) { index in
                    if index > 0 { Divider() }
                    ForEach(MiniMaterial.groups[index], id: \.self) { Text($0.title).tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        if background.material.tintable || background.material == .colour {
            let fill = background.material == .colour
            let on = fill || background.tinted
            LabeledContent(fill ? "Colour" : "Tint") {
                HStack(spacing: 10) {
                    ColorPicker("Colour", selection: $background.color, supportsOpacity: false)
                        .labelsHidden()
                        .disabled(!on)
                    Slider(value: $background.opacity, in: 0 ... 1) { Text("Opacity") }
                        .labelsHidden()
                        .frame(width: 120)
                        .disabled(!on)
                    Text("\(Int((background.opacity * 100).rounded()))%")
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 40, alignment: .trailing)
                        .foregroundStyle(on ? .primary : .secondary)
                    if !fill {
                        Toggle("Tint", isOn: $background.tinted)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
        }
        if background.visible {
            LabeledContent("Roundness") {
                Slider(value: $background.roundness, in: 0 ... 1) {
                    Text("Roundness")
                } minimumValueLabel: {
                    Image(systemName: "square")
                } maximumValueLabel: {
                    Image(systemName: "circle")
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }
}

private struct HUDPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var hud: HUDModel
    let setLayout: (Bool) -> Void

    var body: some View {
        Form {
            Section("Record") {
                LabeledContent {
                    Picker("Rotation speed", selection: $prefs.recordSpeed) {
                        ForEach(RecordSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Rotation speed")
                    Text("Speed of the turning record in the HUD and the mini player")
                }
            }
            Section("Layout") {
                HStack(spacing: 14) {
                    ChoiceTile(title: "Wide", selected: !hud.card, height: 150, wallpaper: true) { setLayout(false) } preview: {
                        HUDSampleView(card: false, relative: prefs.relativeKeys)
                    }
                    ChoiceTile(title: "Card", selected: hud.card, height: 150, wallpaper: true) { setLayout(true) } preview: {
                        HUDSampleView(card: true, relative: prefs.relativeKeys)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Relative keys") {
                HStack(spacing: 14) {
                    ChoiceTile(title: "Song's mode", selected: !prefs.relativeKeys, height: 130, wallpaper: true) { prefs.relativeKeys = false } preview: {
                        HUDSampleView(card: false, relative: false, keysOnly: true)
                    }
                    ChoiceTile(title: "Both modes", selected: prefs.relativeKeys, height: 130, wallpaper: true) { prefs.relativeKeys = true } preview: {
                        HUDSampleView(card: false, relative: true, keysOnly: true)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Waveform") {
                HStack(spacing: 14) {
                    ChoiceTile(title: "Off", selected: !prefs.waveform, height: 130, wallpaper: true) { prefs.waveform = false } preview: {
                        HUDSampleView(card: false, relative: prefs.relativeKeys, keysOnly: true, waveform: (false, .ribbon))
                    }
                    ForEach(WaveformStyle.allCases, id: \.self) { style in
                        ChoiceTile(title: style.name, selected: prefs.waveform && prefs.waveformStyle == style, height: 130, wallpaper: true) {
                            prefs.waveform = true
                            prefs.waveformStyle = style
                        } preview: {
                            HUDSampleView(card: false, relative: prefs.relativeKeys, keysOnly: true, waveform: (true, style))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Behaviour") {
                // The period and the switch sit on one row, as in General > Playback.
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Auto-hide", value: $prefs.autoHideSeconds, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                            .disabled(!prefs.autoHide)
                        Text("seconds")
                            .foregroundStyle(prefs.autoHide ? .primary : .secondary)
                        Toggle("Auto-hide", isOn: $prefs.autoHide)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                } label: {
                    Text("Auto-hide")
                    Text("Close the HUD \(prefs.autoHideSeconds) seconds after showing the key")
                }
                .onChange(of: prefs.autoHideSeconds) { _, seconds in
                    if !(1 ... 3600).contains(seconds) { prefs.autoHideSeconds = min(max(seconds, 1), 3600) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings > Listening > Microphone: Automatic, which follows the input that macOS uses, or one microphone. A picked
/// microphone that isn't connected stays in the list, so the setting doesn't change by itself.
private struct MicrophonePicker: View {
    @ObservedObject var prefs: Preferences
    @State private var devices: [MicDevices.Device] = []
    @State private var standard: String?

    var body: some View {
        Picker("Microphone", selection: Binding(get: { prefs.micDevice }, set: { uid in
            prefs.micDevice = uid
            prefs.micDeviceName = devices.first { $0.uid == uid }?.name ?? ""
        })) {
            Text(standard.map { "Automatic (\($0))" } ?? "Automatic").tag("")
            ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
            if !prefs.micDevice.isEmpty, !devices.contains(where: { $0.uid == prefs.micDevice }) {
                Text("\(prefs.micDeviceName.isEmpty ? "Microphone" : prefs.micDeviceName) (not connected)").tag(prefs.micDevice)
            }
        }
        .onAppear {
            devices = MicDevices.all()
            standard = MicDevices.defaultInput()?.name
        }
    }
}

private struct ListeningPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var keyCache: KeyCache
    @State private var confirmForget = false

    var body: some View {
        let songs = keyCache.songs
        Form {
            Section("Listen") {
                Toggle(isOn: $prefs.alwaysListen) {
                    Text("Always listening")
                    Text("Detect the key of each song in the background")
                }
                Picker(selection: $prefs.listenSeconds) {
                    ForEach(Preferences.listenLengths, id: \.self) { Text("\($0) seconds").tag($0) }
                } label: {
                    Text("Listen length")
                    Text("Audio analysed to detect a key")
                }
            }
            Section("Microphone") {
                MicrophonePicker(prefs: prefs)
            }
            Section("Song keys") {
                Toggle(isOn: $prefs.onlineKeys) {
                    Text("Online key lookup")
                    Text("Fetch keys and tempos from noiseblend.com by song title and artist")
                }
                Toggle(isOn: $prefs.rememberKeys) {
                    Text("Remember song keys")
                    Text("Save detected keys and reuse them for the same song")
                }
            }
            RememberedSongs(songs: songs, forget: { keyCache.forget($0) }, forgetAll: { confirmForget = true })
        }
        .formStyle(.grouped)
        .alert(songs.count == 1 ? "Forget the key of 1 song?" : "Forget the keys of \(songs.count) songs?", isPresented: $confirmForget) {
            Button(songs.count == 1 ? "Forget 1 Key" : "Forget \(songs.count) Keys", role: .destructive) { keyCache.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The songs that have a remembered key, the most recent listen first, each with a button that forgets its key. The
/// header holds the count and Forget All.
/// A grouped Form lays out every row it holds, which took seconds and gigabytes with thousands of songs, so the songs
/// scroll in a List of their own inside one row of the form. Its table makes views only for the rows on screen.
private struct RememberedSongs: View {
    let songs: [KeyCache.Song]
    let forget: (String) -> Void
    let forgetAll: () -> Void
    @State private var search = ""

    /// A short list is read at a glance, so the search bar appears only for a longer one.
    private static let searchFrom = 11
    private static let rowHeight: CGFloat = 44
    private static let visibleRows = 8

    private var shown: [KeyCache.Song] {
        let words = search.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return songs }
        return songs.filter { song in
            let text = [song.title, song.artist, song.album].compactMap { $0 }.joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var body: some View {
        Section {
            if songs.count >= Self.searchFrom {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search songs", text: $search, prompt: Text("Search songs"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                }
            }
            let shown = shown
            if songs.isEmpty {
                Text("No remembered songs").foregroundStyle(.secondary)
            } else if shown.isEmpty {
                Text("No songs match").foregroundStyle(.secondary)
            } else {
                List(shown) { song in
                    SongKeyRow(song: song) { forget(song.id) }
                        .frame(height: Self.rowHeight)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                        // Separators span the text, like the separators between the form's rows.
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(min(shown.count, Self.visibleRows)) * Self.rowHeight)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Remembered songs")
                Pill(text: "\(songs.count)", color: .secondary)
                Spacer()
                Button("Forget All…", action: forgetAll)
                    .controlSize(.small)
                    .disabled(songs.isEmpty)
            }
        }
    }
}

private struct SongKeyRow: View {
    let song: KeyCache.Song
    let forget: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                if let detail = song.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let bpm = song.bpm { Pill(text: "\(Int(bpm.rounded())) BPM", color: .secondary) }
            Pill(text: song.key.name, color: .secondary)
            Button(action: forget) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Forget this song's key")
                .accessibilityLabel("Forget Key")
        }
    }
}

private struct LyricsPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var whisperDownload = ModelDownload.whisper
    @ObservedObject private var stemDownload = ModelDownload.stems
    /// The songs with a fit or a shift kept, counted when the pane opens.
    @State private var timedSongs = 0

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Engine", selection: $prefs.lyricsTranscription) {
                    Text("Apple speech").tag(LyricsTranscription.apple)
                    Text("Whisper server").tag(LyricsTranscription.server)
                    Text("Whisper model").tag(LyricsTranscription.model)
                }
                switch prefs.lyricsTranscription {
                case .apple:
                    EmptyView()
                case .server:
                    TextField("Server URL", text: $prefs.whisperServer, prompt: Text("http://127.0.0.1:8000/v1"))
                case .model:
                    ModelRow(title: "Whisper model", download: whisperDownload)
                }
            }
            Section("Timing") {
                Toggle(isOn: $prefs.lyricsLiveTiming) {
                    Text("Run lyrics timing detection when live listening")
                    Text("When listening on the system audio instead of a local file or URL, the lyrics timing detection can be less reliable, disable it here if it causes problems")
                }
                Picker("Timing detection conditions", selection: $prefs.timingConditions) {
                    Text("Always").tag(TimingConditions.always)
                    Text("Not in Low Power Mode").tag(TimingConditions.notLowPower)
                    Text("On power adapter").tag(TimingConditions.onAdapter)
                }
                LabeledContent("Saved timings") {
                    HStack {
                        Pill(text: timedSongs == 1 ? "1 song" : "\(timedSongs) songs", color: .secondary)
                        Button("Remove All") {
                            LyricsStore.main.removeTimings()
                            timedSongs = LyricsStore.main.timedSongs
                        }
                        .disabled(timedSongs == 0)
                    }
                }
            }
            Section("Karaoke") {
                // Muting the vocals takes the common instruments model, so the toggle waits for it.
                Toggle(isOn: $prefs.karaokeMutesVocals) {
                    Text("Mute vocals")
                    if !stemDownload.installed { Text("Needs the common instruments model") }
                }
                .disabled(!stemDownload.installed)
                Toggle("Start song from beginning", isOn: $prefs.karaokeRestarts)
                Toggle("Blur screen", isOn: $prefs.karaokeBackdrop)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            whisperDownload.refresh()
            stemDownload.refresh()
            timedSongs = LyricsStore.main.timedSongs
        }
    }
}

private struct StemsPane: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var stemDownload = ModelDownload.stems
    @ObservedObject private var windsDownload = ModelDownload.winds
    @ObservedObject private var notesDownload = ModelDownload.dettato
    @ObservedObject private var alignerDownload = ModelDownload.aligner

    var body: some View {
        Form {
            Section("Models") {
                ModelRow(title: "Common instruments model", download: stemDownload)
                // The winds are taken out of the Other stem of the common instruments model, so it needs that model
                // first, and so do the notes, which are transcribed from one stem.
                if stemDownload.installed || windsDownload.installed {
                    ModelRow(title: "Exotic instruments model", download: windsDownload)
                }
                if stemDownload.installed || notesDownload.installed {
                    ModelRow(title: "Transcription model", download: notesDownload)
                }
                // The lyrics are fitted onto the vocals, which the common instruments model separates.
                if stemDownload.installed || alignerDownload.installed {
                    ModelRow(title: "Lyrics timing model", download: alignerDownload)
                }
            }
            // The song steps back seconds when the separated instruments take over, in karaoke and when the lyrics
            // delay starts.
            Section("Playback") {
                Picker("Rewind effect", selection: $prefs.rewindEffect) {
                    Text("Scratch").tag(RewindEffect.scratch)
                    Text("Fade").tag(RewindEffect.fade)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            stemDownload.refresh()
            windsDownload.refresh()
            notesDownload.refresh()
            alignerDownload.refresh()
        }
    }
}

private struct PermissionsPane: View {
    @State private var permission = AudioCapturePermission.status

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("System Audio Recording") {
                    HStack {
                        switch permission {
                        case .granted:
                            Pill(text: "Allowed", color: .green)
                        case .denied:
                            Pill(text: "Not allowed", color: .red)
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                        case .undetermined:
                            Pill(text: "Not asked", color: .secondary)
                            Button("Request Access") {
                                AudioCapturePermission.request { _ in permission = AudioCapturePermission.status }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permission = AudioCapturePermission.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permission = AudioCapturePermission.status }
    }
}

private struct UpdatesPane: View {
    /// Sparkle's own settings, which it reads at each check.
    enum Automatic: Hashable { case off, notify, install }

    @State private var automatic = Self.currentAutomatic
    @State private var interval = Updates.shared.updater.updateCheckInterval
    @AppStorage(Updates.channelKey) private var beta = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    HStack {
                        Pill(text: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", color: .secondary)
                        Button("Check for Updates") { Updates.shared.check() }
                    }
                }
                Picker("Automatic updates", selection: $automatic) {
                    Text("Off").tag(Automatic.off)
                    Text("Check and notify").tag(Automatic.notify)
                    Text("Install silently").tag(Automatic.install)
                }
                .onChange(of: automatic) { _, mode in
                    let updater = Updates.shared.updater
                    updater.automaticallyChecksForUpdates = mode != .off
                    updater.automaticallyDownloadsUpdates = mode == .install
                }
                Picker("Check interval", selection: $interval) {
                    Text("Daily").tag(TimeInterval(86400))
                    Text("Every 3 days").tag(TimeInterval(3 * 86400))
                    Text("Weekly").tag(TimeInterval(7 * 86400))
                }
                .disabled(automatic == .off)
                .onChange(of: interval) { Updates.shared.updater.updateCheckInterval = $1 }
                // A Picker in a Form row keeps room for its label even when the row shows the label on the left, and
                // that room appears as a gap on the right of the segments. The row carries the label instead.
                LabeledContent("Update channel") {
                    Picker("Update channel", selection: $beta) {
                        Text("Release").tag(false)
                        Text("Beta").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .onChange(of: beta) { Updates.shared.updater.resetUpdateCycleAfterShortDelay() }
            } header: {
                Text("Updates")
            } footer: {
                HStack(spacing: 16) {
                    Link("lowtechguys.com/muskey", destination: URL(string: "https://lowtechguys.com/muskey")!)
                    Link("Source code", destination: URL(string: "https://github.com/FuzzyIdeas/Muskey")!)
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            automatic = Self.currentAutomatic
            interval = Self.nearestInterval(Updates.shared.updater.updateCheckInterval)
        }
    }

    private static var currentAutomatic: Automatic {
        let updater = Updates.shared.updater
        return !updater.automaticallyChecksForUpdates ? .off : updater.automaticallyDownloadsUpdates ? .install : .notify
    }

    /// Sparkle's default of one day, or a value set elsewhere, shows as the closest choice.
    private static func nearestInterval(_ seconds: TimeInterval) -> TimeInterval {
        [86400, 3 * 86400, 7 * 86400].min { abs($0 - seconds) < abs($1 - seconds) } ?? 86400
    }
}

// MARK: - Picture tiles

/// A choice drawn as a small picture of what it does, with its name under it. The one not picked steps back,
/// dimmer and nearly grey.
private struct ChoiceTile<Preview: View>: View {
    let title: String
    let selected: Bool
    var height: CGFloat = 112
    /// The Mac's wallpaper behind the picture, as the HUD has it.
    var wallpaper = false
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack { preview() }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background {
                        if wallpaper, let image = Wallpaper.image {
                            // The top of the wallpaper, which is what the menu bar sits on, and close enough for the HUD.
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .clipped()
                        } else {
                            MiniGlass.backdrop(scheme)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .saturation(selected ? 1 : 0.15)
                    .opacity(selected ? 1 : 0.55)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
                    }
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.2), value: selected)
    }
}

/// The warm backdrop of the pictures in Settings, where the wallpaper can't be read.
private enum MiniGlass {
    static func backdrop(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(red: 0.2, green: 0.17, blue: 0.19), Color(red: 0.12, green: 0.1, blue: 0.11)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(red: 0.93, green: 0.87, blue: 0.84), Color(red: 0.86, green: 0.8, blue: 0.79)], startPoint: .top, endPoint: .bottom)
    }
}

/// A strip of the menu bar with Muskey's item, while no pitch change runs and during one. Without a pitch change
/// the item shows only when Settings has it always shown.
private struct MiniMenuBar: View {
    let idle: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            strip(shift: nil).opacity(idle ? 1 : 0.35)
            strip(shift: "+2")
        }
        .padding(.horizontal, 18)
    }

    private func strip(shift: String?) -> some View {
        let ink = Palette.of(scheme).ink
        return HStack(spacing: 6) {
            Spacer(minLength: 0)
            Capsule().fill(ink.opacity(0.2)).frame(width: 14, height: 4)
            if shift != nil || idle {
                Image(nsImage: StatusItem.pill(DetectedKey(pitchClass: 4, minor: true)))
                    .renderingMode(.template)
                    .foregroundStyle(ink)
                if let shift {
                    Text(shift).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
                }
            }
            Capsule().fill(ink.opacity(0.2)).frame(width: 10, height: 4)
            Capsule().fill(ink.opacity(0.2)).frame(width: 22, height: 4)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(scheme == .dark ? Color(white: 0.11).opacity(0.85) : Color.white.opacity(0.88)))
    }
}

/// A model that Muskey downloads on demand: whether it is on the Mac, the download with its progress, and Remove.
private struct ModelRow: View {
    let title: String
    @ObservedObject var download: ModelDownload

    var body: some View {
        LabeledContent(title) {
            HStack {
                switch download.state {
                case let .downloading(fraction):
                    ProgressView(value: fraction)
                        .frame(width: 120)
                    Pill(text: "\(Int(fraction * 100))%", color: .secondary)
                    Button("Cancel") { download.cancel() }
                case .installing:
                    ProgressView().controlSize(.small)
                    Pill(text: "Installing", color: .secondary)
                case .failed:
                    Pill(text: "Download failed", color: .red)
                    Button("Retry") { download.start() }
                case .idle where download.installed:
                    Pill(text: "Installed", color: .green)
                    Button("Remove") { download.remove() }
                case .idle:
                    Pill(text: "Not installed", color: .secondary)
                    Button(download.size >= 1_000_000_000 ? String(format: "Download (%.1f GB)", Double(download.size) / 1e9)
                        : "Download (\(Int((Double(download.size) / 1e6).rounded())) MB)") { download.start() }
                }
            }
        }
    }
}

private struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit().weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Records the next key pressed with ⌘, ⌃ or ⌥. Escape cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @Binding var recording: Bool
    let failed: Bool
    /// The shortcut that the reset button puts back.
    var standard = Shortcut.default
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if shortcut != standard, !recording {
                Button { shortcut = standard } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset to \(standard.symbols)")
            }
            Button(action: recording ? stop : start) {
                Text(recording ? "press a shortcut" : shortcut.symbols)
                    .foregroundStyle(recording ? Color.secondary : failed ? Color.red : Color.primary)
                    .frame(minWidth: 100)
            }
            .tint(failed ? .red : nil)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let new = Shortcut(event: event) {
                shortcut = new
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Names the window after the pane, for the toolbar and the Window menu. A window that SwiftUI doesn't own ignores
/// `navigationTitle`.
private struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context _: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context _: Context) {
        let title = title
        DispatchQueue.main.async { view.window?.title = title }
    }
}

/// The app has no Dock icon, so it shows one while Settings is open, to keep the window in ⌘Tab.
///
/// A closed Settings window is released, not only ordered out. A window that was kept after closing still showed in
/// window switchers as a hidden window of Muskey, and its views kept updating while nobody could see them.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Runs on the turn after the window closed, once AppKit is done with it, so the owner can let go of it.
    var onClosed: () -> Void = {}

    convenience init(view: some View) {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Muskey Settings"
        // The sidebar runs up under the toolbar, and the toolbar shows the name of the pane, as System Settings does.
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.showsBaselineSeparator = false
        window.setContentSize(NSSize(width: 740, height: 540))
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.center()
        // Each opening makes a new window, which opens where the last one was closed.
        window.setFrameAutosaveName("Settings")
    }

    /// ⌘, in the menu bar menu runs while the menu still tracks the keyboard, and the window that opens then ends up
    /// behind the app that was active once the menu closes. So the window opens after the menu is gone, in the
    /// default run loop mode, which menu tracking doesn't run.
    func show() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            self?.window?.orderFrontRegardless()
        }
    }

    func windowWillClose(_: Notification) {
        DispatchQueue.main.async { [self] in
            // Muskey stays in the Dock while the notes window is open.
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) }
            onClosed()
        }
    }
}
