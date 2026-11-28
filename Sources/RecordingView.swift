import SwiftUI

/// The HUD's view of a recording from the microphone while it records.
struct MicState: Equatable {
    var analysis: RecordingAnalysis
    var seconds: Double = 0
    var key: DetectedKey?
    /// Stop was pressed, and the song file is being written.
    var finishing = false
    /// The microphone didn't start.
    var failed = false
    var hotkey = ""
    /// The microphone that records.
    var device = ""
    /// The microphone picked in Settings that wasn't there or didn't start, while the default one records instead.
    var tried: String?

    /// The kind of the last part that the classifier has heard, nil before its first window.
    var current: SoundKind? {
        guard let last = analysis.music.lastIndex(where: { $0 >= 0 }) else { return nil }
        return analysis.kind(at: last)
    }

    var heardMusic: Bool { analysis.included().contains(true) }

    /// The level of the last quarter second, from 0 to 1.
    var level: Double {
        guard let last = analysis.levels.last else { return 0 }
        return Double(min(1, max(0, (last + 60) / 60)))
    }

    /// For the menu bar: what the recording hears now.
    var status: String { current.map(\.title) ?? "Waiting" }

    /// Where the sound heard last sits on each sensitivity bar: past this value the bar takes it as its kind. Nil
    /// before the classifier's first window.
    var marks: [SoundKind: Double] {
        guard let last = analysis.music.lastIndex(where: { $0 >= 0 }) else { return [:] }
        let level = Double(analysis.levels[last]), music = Double(analysis.music[last]), speech = Double(analysis.speech[last])
        let clamp = { (value: Double) in min(1, max(0, value)) }
        // The inverse of the thresholds in RecordingSensitivity.
        return [.silence: clamp((level + 60) / 30), .noise: clamp((music - 0.3) / 0.5), .speech: clamp((0.8 - speech) / 0.6)]
    }
}

/// The level of the microphone, as fast as the samples come, for the meter and the newest bar of the strip. Kept apart
/// from MicState so that only those redraw at that rate.
final class MicMeter: ObservableObject {
    /// The level of the last samples, and the highest of the last moment, in dBFS.
    @Published var level: Float = -100
    @Published var peak: Float = -100
    /// How far the recording has come, in seconds, with the samples of the last moment.
    @Published var seconds: Double = 0
    private var peakAt = Date.distantPast

    func take(level: Float, seconds: Double) {
        self.level = level
        self.seconds = seconds
        let now = Date()
        // The peak holds for a second, then falls with the level.
        if level >= peak || now.timeIntervalSince(peakAt) > 1 {
            peak = level
            peakAt = now
        }
    }
}

extension SoundKind {
    var title: String {
        switch self {
        case .music: "Music"
        case .speech: "Speech"
        case .noise: "Noise"
        case .silence: "Silence"
        }
    }

    func color(_ palette: Palette, _ scheme: ColorScheme) -> Color {
        switch self {
        case .music: StripColors.solid(.honey, scheme).fill
        case .speech: StripColors.solid(.blue, scheme).fill
        case .noise: palette.ink.opacity(0.38)
        case .silence: palette.ink.opacity(0.16)
        }
    }
}

/// The HUD while the microphone records: a red orb that glows with the level, what is heard now, the key of the music
/// so far, the recording with its parts coloured by kind and the music used for the key behind them, the sensitivity of
/// each kind, and Stop.
struct MicCard: View {
    let mic: MicState
    @ObservedObject var meter: MicMeter
    let palette: Palette
    let stop: () -> Void
    /// Stops and deletes the recording.
    let cancel: () -> Void
    let edit: (RecordingAnalysis) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                MicOrb(level: mic.level, music: mic.current == .music)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Recording")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(palette.ink)
                            .fixedSize()
                        Text(Self.time(mic.seconds))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.muted)
                            .contentTransition(.numericText(value: mic.seconds))
                    }
                    keyLine
                }
                Spacer(minLength: 12)
                if mic.finishing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finishing")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.muted)
                } else {
                    HStack(spacing: 6) {
                        HUDButton(title: mic.failed ? "Close" : "Stop", symbol: mic.failed ? "xmark" : "stop.fill", palette: palette, small: true, action: stop)
                            .help(mic.failed ? "Close" : "Stop recording and play it back (\(mic.hotkey))")
                        if !mic.failed {
                            HUDButton(title: "Cancel", symbol: "trash", palette: palette, isOn: true, small: true, action: cancel)
                                .help("Stop recording and delete it")
                        }
                    }
                }
            }
            deviceLine
                .padding(.top, -6)
            HStack(spacing: 12) {
                LevelMeter(meter: meter, palette: palette)
                    .frame(height: 64)
                RecordingStrip(analysis: mic.analysis, bars: true, meter: meter, palette: palette, edit: edit)
                    .frame(height: 64)
            }
            SensitivityRow(sensitivity: mic.analysis.sensitivity, palette: palette, current: mic.current, marks: mic.marks) { sensitivity in
                var analysis = mic.analysis
                analysis.sensitivity = sensitivity
                edit(analysis)
            }
        }
        .padding(.top, 40)
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
        .frame(width: 560)
        .animation(.snappy(duration: 0.2), value: mic.current)
        .animation(.snappy(duration: 0.2), value: mic.finishing)
    }

    @ViewBuilder private var keyLine: some View {
        if let key = mic.key {
            Accidental.text(key.name, color: palette.ink)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(palette.ink)
                .opacity(mic.heardMusic ? 1 : 0.5)
        } else {
            Text(mic.heardMusic ? "Finding the key" : "Waiting for music")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(palette.muted)
        }
    }

    /// The microphone that records, or the picked one that didn't, in red, with the one that records in its place.
    @ViewBuilder private var deviceLine: some View {
        if mic.failed {
            HStack(spacing: 5) {
                Image(systemName: "mic.slash.fill").font(.system(size: 9, weight: .bold))
                Text("No microphone input")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(StripColors.text(.red, scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(StripColors.tint(.red, strong: false, scheme)))
            .fixedSize()
        } else if let tried = mic.tried {
            HStack(spacing: 5) {
                Image(systemName: "mic.slash.fill").font(.system(size: 9, weight: .bold))
                Text("\(tried) unavailable")
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
                Text(mic.device)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(StripColors.text(.red, scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(StripColors.tint(.red, strong: false, scheme)))
            .help("\(tried) isn't connected or didn't start, so \(mic.device) records")
            .fixedSize()
        } else if !mic.device.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill").font(.system(size: 9, weight: .semibold))
                Text(mic.device)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(palette.muted)
        }
    }

    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) : String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// A red orb that glows brighter with the level, and fuller while music plays.
private struct MicOrb: View {
    let level: Double
    let music: Bool
    private static let red = Color(red: 0.93, green: 0.26, blue: 0.24)

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Self.red.opacity(0.55), Self.red.opacity(0)], center: .center, startRadius: 8, endRadius: 30))
                .scaleEffect(1 + level * 0.35)
                .opacity(0.35 + level * 0.65)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.5), Self.red], center: UnitPoint(x: 0.38, y: 0.32), startRadius: 1, endRadius: 16))
                .frame(width: 26, height: 26)
                .shadow(color: Self.red.opacity(music ? 0.7 : 0.35), radius: 6 + level * 8)
        }
        .frame(width: 52, height: 52)
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(.easeOut(duration: 0.3), value: music)
        .accessibilityLabel("Recording")
    }
}

/// The parts of a recording along its time: each quarter second in the colour of its kind, as a bar as tall as its
/// level when `bars`, and the parts used for the key behind them, with an edge at each end. A click on a part used for
/// the key leaves it out, a click on another part adds it, and a drag of an edge moves it.
struct RecordingStrip: View {
    let analysis: RecordingAnalysis
    var bars = false
    /// While recording: the level of the newest samples, drawn past the last whole quarter second, and the time scale
    /// that doubles each time it fills, so the bars already drawn keep their places.
    var meter: MicMeter? = nil
    let palette: Palette
    let edit: (RecordingAnalysis) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var dragged: (region: ClosedRange<Double>, start: Bool, to: Double)?
    @State private var hovered: Double?

    private static let edgeReach: CGFloat = 6

    var body: some View {
        if let meter {
            LiveStrip(meter: meter) { strip(live: $0) }
        } else {
            strip(live: nil)
        }
    }

    /// The scale of a recording that records: 30 seconds, then 60, 120 and so on.
    static func liveSpan(_ seconds: Double) -> Double {
        var span = 30.0
        while span < seconds { span *= 2 }
        return span
    }

    private func strip(live: (seconds: Double, level: Float)?) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = live.map { Self.liveSpan(max($0.seconds, analysis.duration)) } ?? max(analysis.duration, RecordingAnalysis.cell)
            let regions = shownRegions
            Canvas { context, size in
                let x = { (time: Double) in CGFloat(time / span) * size.width }
                let honey = StripColors.solid(.honey, scheme).fill
                for region in regions {
                    let rect = CGRect(x: x(region.lowerBound), y: 0, width: max(2, x(region.upperBound) - x(region.lowerBound)), height: size.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(honey.opacity(scheme == .dark ? 0.22 : 0.2)))
                }
                let kinds = analysis.kinds()
                if bars {
                    // Bars 2 points wide every 3 points, each as tall as the loudest quarter second in its time. A column
                    // shorter than a quarter second shows the quarter second that it falls in.
                    let columns = max(1, Int(size.width / 3))
                    let secondsPerColumn = span / Double(columns)
                    let height = { (level: Float) in max(2, CGFloat(min(1, max(0, (level + 60) / 60))) * (size.height - 6)) }
                    for column in 0 ..< columns {
                        let from = Double(column) * secondsPerColumn, to = from + secondsPerColumn
                        let first = Int(from / RecordingAnalysis.cell), last = max(first + 1, Int((to / RecordingAnalysis.cell).rounded(.up)))
                        if first < kinds.count {
                            var loudest = first
                            for i in first ..< min(last, kinds.count) where analysis.levels[i] > analysis.levels[loudest] { loudest = i }
                            let h = height(analysis.levels[loudest])
                            context.fill(Path(roundedRect: CGRect(x: CGFloat(column) * 3, y: (size.height - h) / 2, width: 2, height: h), cornerRadius: 1),
                                         with: .color(kinds[loudest].color(palette, scheme)))
                        } else if let live, from < live.seconds {
                            // Past the last whole quarter second: the level of the newest samples, not classified yet.
                            let h = height(live.level)
                            context.fill(Path(roundedRect: CGRect(x: CGFloat(column) * 3, y: (size.height - h) / 2, width: 2, height: h), cornerRadius: 1),
                                         with: .color(palette.ink.opacity(0.3)))
                        } else {
                            break
                        }
                    }
                } else {
                    for segment in analysis.segments() {
                        let rect = CGRect(x: x(segment.start), y: size.height / 2 - 2, width: max(1, x(segment.end) - x(segment.start)), height: 4)
                        context.fill(Path(rect), with: .color(segment.kind.color(palette, scheme)))
                    }
                }
                // An edge at each end of the parts used for the key.
                for region in regions {
                    for edge in [region.lowerBound, region.upperBound] {
                        let rect = CGRect(x: x(edge) - 1.5, y: 2, width: 3, height: size.height - 4)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(honey))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = Double(value.location.x / max(width, 1)) * span
                    if dragged == nil, value.translation == .zero || abs(value.translation.width) < 3 {
                        guard let edge = edge(at: value.startLocation.x, width: width, span: span) else { return }
                        dragged = (edge.region, edge.start, time)
                    } else if let current = dragged {
                        dragged = (current.region, current.start, time)
                    }
                }
                .onEnded { value in
                    var changed = analysis
                    if let dragged, abs(value.translation.width) >= 3 {
                        changed.moveEdge(of: dragged.region, start: dragged.start, to: dragged.to)
                    } else {
                        changed.toggle(at: Double(value.location.x / max(width, 1)) * span)
                    }
                    dragged = nil
                    edit(changed)
                })
            .keepsDrag()
            .onContinuousHover { phase in
                if case let .active(point) = phase { hovered = Double(point.x / max(width, 1)) * span } else { hovered = nil }
            }
            .help(hovered.map { time in analysis.regions().contains { $0.contains(time) } }.map {
                $0 ? "Leave this part out of the key (click), move its edges (drag)" : "Use this part for the key (click)"
            } ?? "")
        }
    }

    /// The parts used for the key, with the edge that is being dragged where the pointer has it.
    private var shownRegions: [ClosedRange<Double>] {
        var regions = analysis.regions()
        if let dragged, let index = regions.firstIndex(of: dragged.region) {
            let region = dragged.region
            regions[index] = dragged.start ? min(dragged.to, region.upperBound - RecordingAnalysis.cell) ... region.upperBound
                : region.lowerBound ... max(dragged.to, region.lowerBound + RecordingAnalysis.cell)
        }
        return regions
    }

    private func edge(at x: CGFloat, width: CGFloat, span: Double) -> (region: ClosedRange<Double>, start: Bool)? {
        let position = { (time: Double) in CGFloat(time / span) * width }
        for region in analysis.regions() {
            if abs(position(region.lowerBound) - x) <= Self.edgeReach { return (region, true) }
            if abs(position(region.upperBound) - x) <= Self.edgeReach { return (region, false) }
        }
        return nil
    }
}

/// How readily silence, noise and speech are heard: a bar for each, with its icon and name inside it, filled up to its
/// value. While recording, the bar of the kind heard now lights up, and a mark on each bar shows where the sound heard
/// now sits: filled past the mark, the bar takes that sound as its kind.
struct SensitivityRow: View {
    let sensitivity: RecordingSensitivity
    let palette: Palette
    /// What the recording hears now, and where it sits on each bar, while it records.
    var current: SoundKind? = nil
    var marks: [SoundKind: Double] = [:]
    /// Icons without names, on the narrower card.
    var compact = false
    let set: (RecordingSensitivity) -> Void

    var body: some View {
        HStack(spacing: 8) {
            bar(.silence, \.silence)
            bar(.noise, \.noise)
            bar(.speech, \.speech)
        }
    }

    private func bar(_ kind: SoundKind, _ path: WritableKeyPath<RecordingSensitivity, Double>) -> some View {
        SensitivityBar(kind: kind, value: sensitivity[keyPath: path], lit: current == kind, mark: marks[kind], compact: compact, palette: palette) { value in
            var changed = sensitivity
            changed[keyPath: path] = value
            set(changed)
        }
    }
}

private struct SensitivityBar: View {
    let kind: SoundKind
    let value: Double
    let lit: Bool
    let mark: Double?
    var compact = false
    let palette: Palette
    let set: (Double) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var symbol: String {
        switch kind {
        case .silence: "speaker.slash.fill"
        case .noise: "aqi.medium"
        case .speech: "text.bubble.fill"
        case .music: "music.note"
        }
    }

    private var tint: Color {
        switch kind {
        case .speech: StripColors.solid(.blue, scheme).fill
        default: palette.ink
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            // The label, then the track that a drag adjusts, in one capsule. The card has room for the icon only.
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                if !compact {
                    Text(kind.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .fixedSize()
                }
            }
            .foregroundStyle(palette.ink.opacity(lit ? 1 : 0.72))
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.ink.opacity(0.1)).frame(height: 5)
                    // Filled up to the value: the share of sounds that the bar takes as its kind.
                    Capsule().fill(tint.opacity(kind == .speech ? 0.85 : 0.55)).frame(width: max(5, width * value), height: 5)
                    // Where the sound heard now sits: filling past it takes the sound as this kind.
                    if let mark {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(StripColors.solid(.red, scheme).fill)
                            .frame(width: 2, height: 14)
                            .offset(x: min(width - 2, max(0, width * mark - 1)))
                            .animation(.easeOut(duration: 0.25), value: mark)
                    }
                    Circle()
                        .fill(Color.white.opacity(scheme == .dark ? 0.9 : 1))
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .frame(width: hovering ? 13 : 11, height: hovering ? 13 : 11)
                        .offset(x: min(width - 11, max(0, width * value - 5.5)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { set(min(1, max(0, Double($0.location.x / max(width, 1))))) })
                .keepsDrag()
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(height: 24)
        .background(Capsule().fill(lit ? tint.opacity(kind == .speech ? 0.22 : 0.14) : palette.ink.opacity(0.05)))
        .overlay(Capsule().strokeBorder(tint.opacity(lit ? 0.5 : 0), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: lit)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityElement()
        .accessibilityLabel("\(kind.title) sensitivity")
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            set(min(1, max(0, value + (direction == .increment ? 0.05 : -0.05))))
        }
    }

    private var help: String {
        switch kind {
        case .silence: "Take louder sounds as silence (drag right)"
        case .noise: "Take less certain music as noise (drag right)"
        case .speech: "Take more sounds as speech (drag right)"
        case .music: ""
        }
    }
}

/// The level meter while recording: bars that light up from the bottom as the level rises, green, then honey, then red
/// near the top, with the peak of the last second held.
struct LevelMeter: View {
    @ObservedObject var meter: MicMeter
    let palette: Palette
    @Environment(\.colorScheme) private var scheme
    private static let segments = 14

    var body: some View {
        VStack(spacing: 2) {
            ForEach((0 ..< Self.segments).reversed(), id: \.self) { index in
                let threshold = Float(-60 + 60 * Double(index) / Double(Self.segments))
                let on = meter.level >= threshold
                let peak = !on && meter.peak >= threshold && meter.peak < threshold + 60 / Float(Self.segments)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(index).opacity(on ? 1 : peak ? 0.7 : 0.12))
            }
        }
        .frame(width: 22)
        .animation(.linear(duration: 0.06), value: meter.level)
        .accessibilityHidden(true)
    }

    private func color(_ index: Int) -> Color {
        if index >= Self.segments - 2 { return StripColors.solid(.red, scheme).fill }
        if index >= Self.segments - 5 { return StripColors.solid(.honey, scheme).fill }
        return StripColors.solid(.sage, scheme).fill
    }
}

/// The strip of a recording that records, redrawn as fast as the meter changes, with its time and level.
private struct LiveStrip<Content: View>: View {
    @ObservedObject var meter: MicMeter
    @ViewBuilder let content: ((seconds: Double, level: Float)) -> Content

    var body: some View { content((meter.seconds, meter.level)) }
}

extension RecordingAnalysis {
    /// A made-up recording for the renders: talk, then a song with a pause in it, then noise and silence.
    static func sample() -> RecordingAnalysis {
        var analysis = RecordingAnalysis(rate: 48000)
        for i in 0 ..< 216 {
            let t = Double(i) * RecordingAnalysis.cell
            let wobble = Float(sin(t * 7) * 4 + sin(t * 2.3) * 3)
            switch t {
            case ..<8: analysis.addCell(level: -30 + wobble); analysis.score(from: t, to: t + 0.25, music: 0.1, speech: 0.85, silence: 0)
            case ..<10: analysis.addCell(level: -58); analysis.score(from: t, to: t + 0.25, music: 0, speech: 0, silence: 0.9)
            case ..<44: analysis.addCell(level: -18 + wobble); analysis.score(from: t, to: t + 0.25, music: 0.92, speech: 0.2, silence: 0)
            case ..<49: analysis.addCell(level: -36 + wobble); analysis.score(from: t, to: t + 0.25, music: 0.25, speech: 0.1, silence: 0)
            default: analysis.addCell(level: -57); analysis.score(from: t, to: t + 0.25, music: 0, speech: 0, silence: 0.8)
            }
        }
        return analysis
    }

}
