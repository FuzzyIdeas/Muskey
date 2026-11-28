import SwiftUI

/// The key name, or Listening before the first estimate, filling with ink from the left as the listen goes on: the
/// title is the listen's progress bar. Once the listen is over it is plain ink.
struct ListenTitle: View {
    let text: String
    let size: CGFloat
    /// Nil once the listen is over.
    let progress: Double?
    let palette: Palette

    var body: some View {
        // The sharp or flat dims once the listen is over, since the fill runs across the whole title until then.
        (progress == nil ? Accidental.text(text, color: palette.ink) : Text(text))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(style)
            .animation(.linear(duration: 0.1), value: progress)
    }

    private var style: AnyShapeStyle {
        guard let progress else { return AnyShapeStyle(palette.ink) }
        let filled = min(1, max(0, progress))
        let faint = palette.ink.opacity(0.28)
        return AnyShapeStyle(LinearGradient(stops: [
            .init(color: palette.ink, location: 0),
            .init(color: palette.ink, location: filled),
            .init(color: faint, location: filled),
            .init(color: faint, location: 1),
        ], startPoint: .leading, endPoint: .trailing))
    }
}

/// The symbol before the title: a waveform that ripples while listening, a note on the result, and the reason
/// when there is no result.
struct HUDSymbol: View {
    @ObservedObject var model: HUDModel
    let size: CGFloat
    let palette: Palette

    var body: some View {
        Image(systemName: name)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: model.shown && model.phase == .listening)
            .symbolEffect(.bounce, value: model.phase == .done)
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(model.phase == .silent || model.phase == .idle ? palette.muted : palette.accent)
    }

    private var name: String {
        switch model.phase {
        case .listening: "waveform"
        case .done: "music.note"
        case .silent: "speaker.slash"
        case .failed: "exclamationmark.triangle"
        case .denied: "lock"
        case .idle: "speaker.slash"
        }
    }
}

/// The title line of both layouts: the symbol, then the key that is heard with its relative on the same line, or
/// Listening before the first estimate. While a new song waits for its key, the kept key that it is going to, faded.
/// A click on the key listens to the song again, and an Option-click names the key in the other mode: the relative
/// key, which has the same notes, so the song doesn't change.
struct TitleLine: View {
    @ObservedObject var model: HUDModel
    let palette: Palette
    var symbolSize: CGFloat = 30
    var keySize: CGFloat = 30
    var relativeSize: CGFloat = 17
    var listeningSize: CGFloat = 40
    /// The hint beside Re-detect key that Option names the relative key, in the wide layout, which has the width for it.
    var optionHint = false

    /// `--render-title-hover` renders the HUD with the pointer over the key.
    @State private var hovering = TestFlags.has("--render-title-hover")

    private var progress: Double? { model.phase == .listening ? model.progress : nil }
    /// A click on the key listens to the song again, once a key shows that isn't the one a new song waits for.
    private var redetectable: Bool { model.pending == nil && (model.phase == .done || model.phase == .listening) }
    /// An Option-click on the key names it in the other mode, once the key of the song is known.
    private var switchable: Bool { model.pending == nil && model.key != nil }
    /// Option is held over the key, so its pill names the relative key that a click switches to.
    private var switching: Bool { hovering && switchable && model.flipped }
    private var pillShown: Bool { switching || hovering && redetectable }

    var body: some View {
        HStack(spacing: 10) {
            HUDSymbol(model: model, size: symbolSize, palette: palette)
            if let key = model.pending ?? model.heard {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    ListenTitle(text: key.name, size: keySize, progress: progress, palette: palette)
                    Accidental.text(key.relative.name, color: palette.muted)
                        .font(.system(size: relativeSize, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.muted)
                        .opacity(pillShown ? 0 : 1)
                        // In the relative key's place, over it, so the title doesn't move when it shows.
                        .overlay(alignment: .leading) {
                            if optionHint, switchable, pillShown {
                                // Both actions of a click on the key, one above the other, centred on the key: the
                                // click, and the Option-click, which takes over while Option is held.
                                VStack(alignment: .leading, spacing: 3) {
                                    TitlePill(symbol: "arrow.clockwise", text: "Re-detect key", palette: palette, small: true)
                                        .opacity(switching || !redetectable ? 0.4 : 1)
                                    TitlePill(symbol: "arrow.left.arrow.right", text: key.relative.name, key: "⌥", palette: palette, small: true, strong: switching)
                                }
                                .fixedSize()
                                .offset(y: -relativeSize * 0.3)
                                .transition(.opacity)
                            } else if switching {
                                TitlePill(symbol: "arrow.left.arrow.right", text: key.relative.name, palette: palette).fixedSize().transition(.opacity)
                            } else if pillShown {
                                TitlePill(symbol: "arrow.clockwise", text: "Re-detect key", palette: palette).fixedSize().transition(.opacity)
                            }
                        }
                }
                // Less faded than before the title filled, since the part that hasn't filled is already faint.
                .opacity(model.pending == nil ? 1 : 0.65)
                .contentTransition(.interpolate)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.option), switchable {
                        model.onShift(model.shift, !model.relative)
                    } else if redetectable {
                        hovering = false
                        model.onRedetect()
                    }
                }
                .animation(.easeOut(duration: 0.12), value: pillShown)
                .animation(.easeOut(duration: 0.12), value: switching)
            } else if model.phase == .listening {
                ListenTitle(text: "Listening", size: listeningSize, progress: progress, palette: palette)
                    .transition(.opacity)
            } else if model.phase == .idle {
                ListenTitle(text: "Nothing playing", size: listeningSize * 0.8, progress: nil, palette: palette)
                    .transition(.opacity)
            }
        }
        .lineLimit(1)
    }
}

/// The pill that shows over the key while the pointer is on it: a click on the key listens to the song again, and
/// with Option held it names the relative key that an Option-click switches to.
private struct TitlePill: View {
    let symbol: String
    let text: String
    /// The modifier that the click needs, in a keycap at the end.
    var key: String? = nil
    let palette: Palette
    /// Two pills stacked beside the key, in the wide layout.
    var small = false
    /// Option is held, and a click does what this pill says.
    var strong = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: small ? 9 : 10, weight: .bold))
            Accidental.text(text, color: palette.ink)
                .font(.system(size: small ? 10.5 : 11.5, weight: .semibold, design: .rounded))
            if let key {
                Spacer(minLength: 0)
                Keycap(text: key, palette: palette, small: true)
            }
        }
        // As wide as the widest pill of the stack, so the stacked pills share both edges.
        .frame(maxWidth: small ? .infinity : nil, alignment: .leading)
        .foregroundStyle(palette.ink)
        .padding(.leading, small ? 7 : 9)
        .padding(.trailing, key == nil ? (small ? 7 : 9) : 3)
        .frame(height: small ? 18 : 22)
        .background(Capsule().fill(palette.ink.opacity(strong ? 0.18 : 0.1)))
        .animation(.easeOut(duration: 0.12), value: strong)
    }
}

/// While nothing plays: open a song file or a link. The empty record beside them plays whatever macOS played last.
struct IdleActions: View {
    @ObservedObject var model: HUDModel
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            IdleButton(symbol: "doc", title: "Open File", key: "⌘O", palette: palette, action: model.onOpenFile)
            IdleButton(symbol: "link", title: "Open URL", key: "⌘L", palette: palette, action: model.onOpenLocation)
            IdleButton(symbol: "mic", title: "Microphone", key: model.micHotkey, palette: palette, action: model.onMic)
                .help("Record from the microphone and find the key of what plays (\(model.micHotkey))")
        }
    }
}

private struct IdleButton: View {
    let symbol: String
    let title: String
    let key: String
    let palette: Palette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.muted)
            }
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(palette.ink.opacity(hovering ? 0.14 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The pills under the title: the song's tempo, then the change of key with its shift (red when Lock Key made it), or
/// the kept key that a new song waits for. A pitch change that failed takes the place of all of them.
struct ShiftPills: View {
    @ObservedObject var model: HUDModel
    let palette: Palette
    @State private var keyExpanded = false
    @Environment(\.keyPillExpanded) private var forcedExpanded

    var body: some View {
        if model.pitchFailed {
            ShiftPill(text: "Pitch change failed", palette: palette)
        } else {
            // One row where it fits, as in the wide layout. The card is narrower, so its pills of the tempo and of the
            // key take a row each there.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    // The key pill widens over the tempo pills beside it while the pointer is over it.
                    tempoPills.opacity(keyExpanded || forcedExpanded ? 0 : 1)
                    keyPills
                }
                VStack(spacing: 5) {
                    HStack(spacing: 6) { tempoPills }
                    HStack(spacing: 6) { keyPills }
                }
            }
            .animation(.snappy(duration: 0.25), value: model.shownTempo)
            .animation(.snappy(duration: 0.2), value: model.speed)
            .animation(.snappy(duration: 0.2), value: model.speedAdjustable)
            .animation(.snappy(duration: 0.2), value: model.slowFailed)
        }
    }

    @ViewBuilder private var tempoPills: some View {
        if model.speedAdjustable || model.shownTempo != nil || model.slowFailed != nil {
            // The tempo pill, and the red speed beside it when slowing a song from another player failed, are one thing
            // to scroll over.
            ScrollLifted(region: .tempo, scroll: model.scroll, depth: 2.5) { inner, _ in
                HStack(spacing: 6) {
                    TempoPill(bpm: model.shownTempo.map { $0.bpm * (model.speedAdjustable ? model.speed : 1) }, adjustable: model.speedAdjustable,
                              speed: model.speedAdjustable && model.slowFailed == nil ? model.speed : 1,
                              slower: model.speed > 0.5, faster: model.speed < model.fastestSpeed, keysShown: model.keysActive, palette: palette, lift: inner, step: model.onSpeed)
                        // The return of a slowed song to 100 %, while the output catches up with the player: the
                        // border fills as the song gets back to its tempo.
                        .overlay {
                            if let progress = model.tempoReturn {
                                Capsule().inset(by: 0.75)
                                    .trim(from: 0, to: progress)
                                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                    .animation(.linear(duration: 0.2), value: progress)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.15), value: model.tempoReturn == nil)
                    if let failed = model.slowFailed {
                        FailedSpeedPill(speed: failed, dismiss: { model.slowFailed = nil }, retry: model.onSlowRetry)
                            .offset(y: inner)
                            .transition(.opacity)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var keyPills: some View {
        if let pending = model.pending {
            // In the red of Lock Key, which turns it into the move once the song's key is found.
            KeyMovePill(from: nil, to: pending, hue: .red, waiting: true, palette: palette, expanded: $keyExpanded)
                .transition(.opacity)
        } else if let moved = model.moved {
            // In the red of Lock Key, which made the change.
            KeyMovePill(from: moved.from, to: moved.to, shift: model.shift, hue: .red, palette: palette, expanded: $keyExpanded)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if model.shift != 0 {
            let hue = model.shift > 0 ? StripColors.up : StripColors.down
            if let key = model.key, let heard = model.heard {
                KeyMovePill(from: key, to: heard, shift: model.shift, hue: hue, palette: palette, expanded: $keyExpanded)
            } else {
                ShiftPill(text: Shift.text(model.shift), hue: hue, palette: palette)
                    .contentTransition(.numericText(value: Double(model.shift)))
            }
        }
    }
}

/// Something that a scroll over it adjusts. While the scroll lasts, it grows a little and rides up or down with the
/// fingers, and its contents ride a little further, like a layer nearer the eye; it springs back once the fingers
/// lift. It tells the scroll where it is, and the scroll finds out whether it can be adjusted now.
struct ScrollLifted<Content: View>: View {
    let region: ScrollRegion
    @ObservedObject var scroll: ScrollFeel
    var scale: CGFloat = 1.08
    /// How far it rides at the most, in points. Its contents ride as far again.
    var depth: CGFloat = 3
    /// Gets the extra lift of the contents in points, and whether a scroll adjusts it now.
    @ViewBuilder let content: (CGFloat, Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var token = UUID()

    var body: some View {
        let active = scroll.region == region
        let lift = active && !reduceMotion ? scroll.lift : 0
        content(-lift * depth, active)
            .scaleEffect(active && !reduceMotion ? scale : 1)
            .offset(y: -lift * depth)
            // The lift follows the fingers closely, and the growth and the return settle with a soft spring.
            .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.82), value: lift)
            .animation(.spring(response: 0.3, dampingFraction: 0.66), value: active)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scroll.place(region, at: $0, by: token) }
            .onDisappear { scroll.remove(by: token) }
    }
}

/// The song's tempo at the speed that it plays. A song in Muskey Player gets keycaps at the ends of the pill, which
/// slow it down or speed it up by 5 %, and a scroll over it changes the speed by 1 % steps. A changed speed shows as a
/// short `0.9×` inside the pill, which plays the song at its original tempo again when clicked, as = does.
struct TempoPill: View {
    let bpm: Double?
    let adjustable: Bool
    /// The speed against the song's original tempo, 1 when it plays at that tempo.
    var speed: Double = 1
    /// The speed can go down or up from here: a song from another player can only be slowed down.
    var slower = true, faster = true
    /// The keys [ and ] work only while the pointer is over the HUD, so their keycaps show only then.
    var keysShown = true
    let palette: Palette
    /// The extra lift of the text and the keycaps while a scroll changes the speed.
    var lift: CGFloat = 0
    let step: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let caps = adjustable && keysShown
        HStack(spacing: 5) {
            if caps, slower { cap("[", help: "Slower ([)", step: -1) }
            Text(bpm.map { "\(Int($0.rounded())) BPM" } ?? "Tempo")
                .contentTransition(.numericText(value: bpm ?? 0))
            if speed != 1 { speedChip.transition(.opacity.combined(with: .scale(scale: 0.6))) }
            if caps, faster { cap("]", help: "Faster (])", step: 1) }
        }
        .animation(.snappy(duration: 0.2), value: speed != 1)
        .offset(y: lift)
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(palette.ink)
        .padding(.leading, caps && slower ? 4 : 8)
        .padding(.trailing, caps && faster ? 4 : 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(palette.ink.opacity(0.1)))
        .fixedSize()
    }

    /// `0.9×` in blue for slower and in honey for faster, like the shift in the key pill beside it.
    private var speedChip: some View {
        let hue = speed < 1 ? StripColors.down : StripColors.up
        return Button { step(0) } label: {
            Text(Self.multiplier(speed))
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .contentTransition(.numericText(value: speed))
                .foregroundStyle(StripColors.text(hue, colorScheme))
                .padding(.horizontal, 5)
                .frame(height: 13)
                .background(Capsule().fill(StripColors.tint(hue, strong: true, colorScheme)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Original tempo (=)")
    }

    /// 0.85 as `0.85×`, 0.9 as `0.9×`: two decimals at most, since the speed changes in 1 % steps.
    static func multiplier(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    private func cap(_ key: String, help: String, step value: Int) -> some View {
        Button { step(value) } label: { Keycap(text: key, palette: palette, small: true) }
            .buttonStyle(.plain)
            .focusable(false)
            .help(help)
    }
}

/// The speed of a song from another player that Muskey had to stop slowing: the speed pill turns red, with an ✕ that
/// dismisses it and Retry beside it, as the stems' label does when they couldn't be separated.
struct FailedSpeedPill: View {
    let speed: Double
    let dismiss: () -> Void
    let retry: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let percent = Int(((speed - 1) * 100).rounded())
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("\(percent < 0 ? "−" : "+")\(abs(percent))% tempo")
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Dismiss")
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(StripColors.text(.red, colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(StripColors.tint(.red, strong: false, colorScheme)))
            .fixedSize()
            Button("Retry", action: retry)
                .controlSize(.mini)
                .focusable(false)
        }
    }
}

/// Lock Key, and Stop Pitch Change while a pitch change runs or a new song waits to be moved.
struct PitchControls: View {
    @ObservedObject var model: HUDModel
    let palette: Palette
    var small = false

    var body: some View {
        HStack(spacing: small ? 6 : 8) {
            HUDButton(title: "Lock Key", symbol: model.keepKey ? "lock.fill" : "lock.open", palette: palette, isOn: model.keepKey, small: small, action: model.onKeep)
                .help(model.heard.map { "Play the next songs in \($0.name) (K)" } ?? "Lock Key (K)")
            // Also while a new song plays in its own key and waits for the move: the pitch change still runs.
            if model.shift != 0 || model.pending != nil {
                HUDButton(title: "Stop Pitch Change", symbol: "stop.fill", palette: palette, small: small, action: model.onStop)
                    .transition(.opacity)
            }
        }
    }
}

/// The single card: the record in the middle, with a ring around it that fills as the listen goes on, and from the
/// first estimate the twelve keys around it by fifths. The title, the pills and the song go under it, and Lock Key and
/// Stop Pitch Change along the bottom, with a ? button for the shortcuts, which take the place of the whole card.
struct HUDCard: View {
    @ObservedObject var model: HUDModel
    let palette: Palette
    let showsKeys: Bool
    let track: NowPlaying.Track?

    /// The rings of keys: the song's mode outside, and the other mode inside, far enough from the outer ring that
    /// the chips of a column don't touch where the rings run diagonally. Without the inner ring, the record is
    /// bigger and the ring of keys is closer to it.
    private var record: CGFloat { model.relativeKeys ? 136 : 160 }
    private var radius: CGFloat { model.relativeKeys ? 132 : 110 }
    private static let innerRadius: CGFloat = 96
    private var ring: CGFloat { radius * 2 + 40 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.lyricsShown, showsKeys {
                    LyricsPanel(state: model.lyrics, line: model.lyricLine, palette: palette, width: ring - 24, height: ring, downloading: model.lyricsDownloading,
                                writing: model.lyricsWriting && !model.lyricsSkipped, waiting: model.lyricsWaiting, retry: model.onLyricsRetry, add: model.onLyricsEdit, edit: model.onLyricsEdit)
                        .transition(.opacity)
                } else {
                    if let track {
                        RecordDisc(track: track, artwork: model.artwork, spinning: model.shown && model.playing, side: record, flash: model.playFlash)
                            .onHover { model.overRecord = $0 }
                            .transition(.opacity)
                    } else {
                        EmptyPlatter(side: record)
                            .transition(.opacity)
                    }
                    if model.phase == .listening {
                        ListenRing(progress: model.progress, palette: palette)
                            .frame(width: record + 14, height: record + 14)
                            .transition(.opacity)
                    }
                }
                // Over the lyrics, which take the place of the record.
                if model.lyricsShown && showsKeys {
                    PlayFlashView(flash: model.playFlash, size: 72)
                }
                if !model.lyricsShown, showsKeys, let key = model.key {
                    FifthsRing(original: key, shift: model.shift, relative: model.relative, palette: palette, radius: radius,
                               innerRadius: Self.innerRadius, showsRelatives: model.relativeKeys, flipped: model.flipped != model.relative,
                               accidentals: model.accidentals, select: model.onShift)
                        // The ring still has the last song's keys while a new song waits for its key.
                        .opacity(model.pending == nil ? 1 : 0.4)
                        .allowsHitTesting(model.pending == nil)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .frame(width: ring, height: ring)

            TitleLine(model: model, palette: palette, symbolSize: 22, keySize: 26, relativeSize: 15, listeningSize: 32)
                .padding(.top, 8)
            ShiftPills(model: model, palette: palette)
                .padding(.top, 5)
            if model.phase == .idle {
                IdleActions(model: model, palette: palette)
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            if let track {
                VStack(spacing: 2) {
                    // The keys of the waveform take the place of the song's lines while the pointer is over it.
                    WaveformKeysSwap(wave: model.wave, alignment: .center, small: true, seek: model.seekable, loop: model.loop != nil, palette: palette) {
                        VStack(spacing: 2) {
                            Text(track.title ?? "")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(palette.ink)
                            let byline = [track.artist, track.album].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                            if !byline.isEmpty {
                                Text(byline)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(palette.muted)
                            }
                        }
                    }
                    // The waveform takes the time bar's place on the card, and seeks the same way.
                    if showsKeys, model.waveformShown, track.duration != nil {
                        CardWaveform(wave: model.wave, track: track, width: ring - 30, ticking: model.shown && model.playing,
                                     bpm: model.shownTempo?.bpm, muted: model.stemsMuted, loop: model.loop, setLoop: model.onLoopSet,
                                     typing: model.onLoopTyping, palette: palette)
                            .overlay(alignment: .bottom) {
                                if let recording = model.recording, model.wave.zoom <= 1, !model.wave.lanes, model.wave.waveform != nil {
                                    RecordingRegionsOverlay(analysis: recording, palette: palette)
                                        .frame(width: ring - 30, height: 30)
                                }
                            }
                        // A recording from the microphone: its parts along the waveform, and how readily each kind is heard.
                        if let recording = model.recording {
                            VStack(spacing: 8) {
                                RecordingStrip(analysis: recording, palette: palette, edit: model.onRecordingEdit)
                                    .frame(width: ring - 30, height: 16)
                                SensitivityRow(sensitivity: recording.sensitivity, palette: palette, compact: true) { sensitivity in
                                    var changed = recording
                                    changed.sensitivity = sensitivity
                                    model.onRecordingEdit(changed)
                                }
                                .frame(width: ring - 30)
                            }
                            .padding(.top, 4)
                            .transition(.opacity)
                        }
                    } else {
                        SongTimeBar(track: track, ticking: model.shown && model.playing, palette: palette, width: 110)
                            .padding(.top, 3)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: ring)
                .onHover { model.overRecord = $0 }
                .padding(.top, 10)
                .id(track.song.map { $0 ?? "" }.joined(separator: "\u{1F}"))
                .transition(.opacity)
            }

            if showsKeys, model.stemsAvailable {
                if model.stemsOpen {
                    StemsRow(model: model, palette: palette, compact: true, card: true)
                        .padding(.top, 14)
                        // The half of the hints pill that hangs below the tray.
                        .padding(.bottom, StemsRow.pillHeight / 2)
                        .transition(.opacity)
                } else {
                    SeparateButton(palette: palette, action: model.onSeparate)
                        // Quiet until the pointer is over it, so the ring and the key read first.
                        .modifier(FocusDim(on: true))
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }

            if showsKeys {
                HStack(spacing: 8) {
                    // As wide as the ? button, so Lock Key and Stop Pitch Change sit in the middle.
                    Color.clear.frame(width: HUDButton.questionSize, height: 1)
                    Spacer(minLength: 0)
                    PitchControls(model: model, palette: palette, small: true)
                        .modifier(FocusDim(on: true))
                    Spacer(minLength: 0)
                    RoundButton(symbol: "questionmark", help: "Shortcuts (?)", isOn: model.shortcuts, size: HUDButton.questionSize, palette: palette) { model.shortcuts.toggle() }
                }
                .padding(.top, 14)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, showsKeys ? 12 : 18)
        // Wide enough for Lock Key and Stop Pitch Change on one line between the two 20-point ends of the bottom row.
        .frame(width: ring + 84)
        .animation(.snappy(duration: 0.25), value: model.lyricsShown)
        .animation(.snappy(duration: 0.3), value: model.relativeKeys)
    }
}

/// The waveform under the song on the card, or the time bar until the waveform of the song is known.
private struct CardWaveform: View {
    @ObservedObject var wave: WaveState
    let track: NowPlaying.Track
    let width: CGFloat
    let ticking: Bool
    let bpm: Double?
    let muted: Set<Stem>
    let loop: LoopRegion?
    let setLoop: (LoopEnd, Double) -> Void
    let typing: (Bool) -> Void
    let palette: Palette

    var body: some View {
        if wave.waveform != nil {
            WaveformHost(wave: wave, track: track, style: .ribbon, width: width, height: 30, ticking: ticking, bpm: bpm, muted: muted,
                         loop: loop, setLoop: setLoop, typing: typing, palette: palette)
                // The tabs of the region loop stand above the waveform, clear of the song's lines.
                .padding(.top, loop == nil ? 8 : 18)
        } else {
            SongTimeBar(track: track, ticking: ticking, palette: palette, width: 110)
                .padding(.top, 3)
        }
    }
}

/// A thin ring around the record of the single card, which fills clockwise from the top as the listen goes on.
private struct ListenRing: View {
    let progress: Double
    let palette: Palette

    var body: some View {
        ZStack {
            Circle().stroke(palette.ink.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(palette.muted, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
        }
    }
}
