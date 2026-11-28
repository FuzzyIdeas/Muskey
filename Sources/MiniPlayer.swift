import os
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// What the mini player can show besides the song: in the line under the song, or as a pill on the top or the bottom
/// of the record.
enum MiniElement: String, Codable, CaseIterable, Identifiable {
    case key, tempo, pitch, speed, loop, timeLeft, vocals, next

    var id: String { rawValue }

    var name: String {
        switch self {
        case .key: "Key"
        case .tempo: "Tempo"
        case .pitch: "Pitch change"
        case .speed: "Speed"
        case .loop: "Region loop"
        case .timeLeft: "Time left"
        case .vocals: "Vocals"
        case .next: "Next in queue"
        }
    }

    /// What the editor in Settings shows for the element, since the song in its preview has no live values.
    var sample: String {
        switch self {
        case .key: "G major"
        case .tempo: "124 BPM"
        case .pitch: "+2"
        case .speed: "0.9×"
        case .loop: "↻ 0:42–0:58"
        case .timeLeft: "−2:41"
        case .vocals: "Vocals off"
        case .next: "⏭ Glass Harbour"
        }
    }

    var hue: StripColors.Hue? {
        switch self {
        case .pitch, .loop: .honey
        case .speed: .blue
        case .vocals: .red
        default: nil
        }
    }
}

/// The three places for the elements: on the top of the record, on its bottom, and in the line under the song.
enum MiniPlace: String, Codable, CaseIterable {
    case top, bottom, line
}

/// Which parts of the song the mini player shows, and where its elements go.
struct MiniLayout: Codable, Equatable {
    var top: MiniElement?
    var bottom: MiniElement?
    var line: [MiniElement] = [.key, .tempo]
    var track = true
    var artist = true
    var album = true

    /// The line under the song stays short, so the player stays small.
    static let lineLimit = 3

    func place(of element: MiniElement) -> MiniPlace? {
        if top == element { return .top }
        if bottom == element { return .bottom }
        return line.contains(element) ? .line : nil
    }

    mutating func put(_ element: MiniElement, at place: MiniPlace) {
        remove(element)
        switch place {
        case .top: top = element
        case .bottom: bottom = element
        case .line: line = Array((line + [element]).suffix(Self.lineLimit))
        }
    }

    mutating func remove(_ element: MiniElement) {
        if top == element { top = nil }
        if bottom == element { bottom = nil }
        line.removeAll { $0 == element }
    }
}

/// What fills the background of the mini player: Liquid Glass, one of the system's blur materials from the thinnest to
/// the thickest, or a flat colour.
enum MiniMaterial: String, Codable, CaseIterable {
    case none, glass, clearGlass, ultraThin, thin, regular, thick, ultraThick, colour

    var title: String {
        switch self {
        case .none: "None"
        case .glass: "Glass"
        case .clearGlass: "Clear glass"
        case .ultraThin: "Ultra thin"
        case .thin: "Thin"
        case .regular: "Regular"
        case .thick: "Thick"
        case .ultraThick: "Ultra thick"
        case .colour: "Colour"
        }
    }

    /// The groups of the picker in Settings, which a divider separates.
    static let groups: [[MiniMaterial]] = [[.none], [.glass, .clearGlass], [.ultraThin, .thin, .regular, .thick, .ultraThick], [.colour]]

    var glass: Glass? {
        switch self {
        case .glass: .regular
        case .clearGlass: .clear
        default: nil
        }
    }

    var material: Material? {
        switch self {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        case .ultraThick: .ultraThickMaterial
        default: nil
        }
    }

    /// Glass and the blur materials take a tint over them. Colour is the tint itself.
    var tintable: Bool { glass != nil || material != nil }
}

/// The background behind the record and the song (Settings > Mini player > Background). The tint and the colour fill
/// share one colour and one opacity, so switching between them keeps the colour that was picked.
struct MiniBackground: Codable, Equatable {
    var material = MiniMaterial.none
    var tinted = false
    var red = 0.09
    var green = 0.07
    var blue = 0.08
    var opacity = 0.4
    /// From 0, a rectangle with square corners, to 1, a circle around the record alone or a capsule with the song.
    var roundness = 1.0

    init() {}

    /// Every field is optional in the saved JSON, so a background saved by an older version still loads.
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MiniBackground()
        material = (try? saved.decodeIfPresent(MiniMaterial.self, forKey: .material)) ?? fallback.material
        tinted = (try? saved.decodeIfPresent(Bool.self, forKey: .tinted)) ?? fallback.tinted
        red = (try? saved.decodeIfPresent(Double.self, forKey: .red)) ?? fallback.red
        green = (try? saved.decodeIfPresent(Double.self, forKey: .green)) ?? fallback.green
        blue = (try? saved.decodeIfPresent(Double.self, forKey: .blue)) ?? fallback.blue
        opacity = (try? saved.decodeIfPresent(Double.self, forKey: .opacity)) ?? fallback.opacity
        roundness = (try? saved.decodeIfPresent(Double.self, forKey: .roundness)) ?? fallback.roundness
    }

    var visible: Bool { material != .none }

    var color: Color {
        get { Color(.sRGB, red: red, green: green, blue: blue) }
        set {
            guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            red = Double(rgb.redComponent)
            green = Double(rgb.greenComponent)
            blue = Double(rgb.blueComponent)
        }
    }

    /// The colour over glass and the materials, or nil when they show untinted.
    var tint: Color? { material == .colour || (material.tintable && tinted) ? color.opacity(opacity) : nil }

    /// About how light the background shows, as a luminance from 0 to 1, over a desktop of luminance `behind`. Nil
    /// without a background, where the song's text keeps its shadow over whatever is behind it.
    func luminance(behind: Double) -> Double? {
        guard visible else { return nil }
        // How much of the desktop each material lets through.
        let through: Double = switch material {
        case .clearGlass: 0.85
        case .glass: 0.55
        case .ultraThin: 0.65
        case .thin: 0.5
        case .regular: 0.35
        case .thick: 0.2
        case .ultraThick: 0.1
        case .colour, .none: 1
        }
        // Clear glass shows in the light scheme, with a faint white haze. The rest is near black.
        let base = behind * through + (material == .clearGlass ? 0.8 : 0.02) * (1 - through)
        guard tint != nil else { return base }
        return opacity * Self.luminance(red: red, green: green, blue: blue) + (1 - opacity) * base
    }

    /// The relative luminance of an sRGB colour.
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The frame of the background around the record and the song, and the radius of its corners, in the coordinates of
/// the frames it is made from.
struct MiniBackdropShape: Equatable {
    var rect: CGRect
    var radius: CGFloat

    /// The space between the song and the edge of the background, the same as the rim around the record.
    static let padding: CGFloat = 12

    /// `record` is the record with its rim, which the background circles. `text` is the frame of the song, `lines` the
    /// frames of its lines and pills, and `side` the side of the record that the song is on. With the song, the
    /// background first takes the rectangle around both, then grows away from the record until each corner of each line
    /// is `padding` inside the rounded corners. A capsule at full roundness would otherwise cut through a line that is
    /// wider than the record. The lines are checked one by one, since the corners of the song's frame are often empty:
    /// a long title is wide at the top while the pills under it are narrow.
    init(record: CGRect, text: CGRect?, lines: [CGRect] = [], side: MiniTextSide, roundness: CGFloat) {
        let roundness = min(max(roundness, 0), 1)
        guard let text, !text.isEmpty else {
            rect = record
            radius = roundness * min(record.width, record.height) / 2
            return
        }
        let padding = Self.padding
        var rect = record.union(text.insetBy(dx: -padding, dy: -padding))
        let corners = (lines.isEmpty ? [text] : lines).filter { !$0.isEmpty }.flatMap { line in
            [CGPoint(x: line.minX, y: line.minY), CGPoint(x: line.maxX, y: line.minY), CGPoint(x: line.minX, y: line.maxY), CGPoint(x: line.maxX, y: line.maxY)]
        }
        let vertical = side == .above || side == .below
        // How far the background has to grow away from the record for every corner to sit `padding` inside corners of
        // this radius.
        func growth(_ rect: CGRect, radius: CGFloat) -> CGFloat {
            let inner = rect.insetBy(dx: radius, dy: radius)
            let reach = max(radius - padding, 0)
            var grow: CGFloat = 0
            for corner in corners {
                let across = vertical ? max(inner.minX - corner.x, corner.x - inner.maxX, 0) : max(inner.minY - corner.y, corner.y - inner.maxY, 0)
                let beyond = switch side {
                case .below: corner.y - inner.maxY
                case .above: inner.minY - corner.y
                case .right: corner.x - inner.maxX
                case .left: inner.minX - corner.x
                }
                grow = max(grow, beyond - max(reach * reach - across * across, 0).squareRoot())
            }
            return grow
        }
        // Above or below the record, a capsule would round off far past the song's last line, since the song is
        // wider than tall. There the corners round only as far as the song allows, and the background stays tight.
        if vertical {
            var low: CGFloat = 0, high = roundness * min(rect.width, rect.height) / 2
            if growth(rect, radius: high) > 0.1 {
                for _ in 0 ..< 20 {
                    let mid = (low + high) / 2
                    if growth(rect, radius: mid) > 0.1 { high = mid } else { low = mid }
                }
                high = low
            }
            self.rect = rect
            radius = high
            return
        }
        // Growing along the side changes the radius while that side is the short one, so this repeats until the
        // corners fit, which takes a few rounds at most.
        for _ in 0 ..< 24 {
            let grow = growth(rect, radius: roundness * min(rect.width, rect.height) / 2)
            guard grow > 0.1 else { break }
            switch side {
            case .below: rect.size.height += grow
            case .above: rect.origin.y -= grow; rect.size.height += grow
            case .right: rect.size.width += grow
            case .left: rect.origin.x -= grow; rect.size.width += grow
            }
        }
        self.rect = rect
        radius = roundness * min(rect.width, rect.height) / 2
    }
}

/// Where the song goes around the record (Settings > Mini player > Layout): wherever the screen suits it, on the record
/// itself with the pills of its line under the record, or always on one side.
enum MiniDirection: String, CaseIterable {
    case automatic, onRecord, below, above, left, right

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .onRecord: "On the record"
        case .below: "Below"
        case .above: "Above"
        case .left: "Left"
        case .right: "Right"
        }
    }

    /// The side that the song keeps, or nil when the screen picks it. On the record, the pills of the song's line stay
    /// under it.
    var side: MiniTextSide? {
        switch self {
        case .automatic: nil
        case .onRecord, .below: .below
        case .above: .above
        case .left: .left
        case .right: .right
        }
    }
}

/// The side of the record that the song goes on.
enum MiniTextSide: Equatable {
    case below, above, left, right

    var opposite: MiniTextSide {
        switch self {
        case .below: .above
        case .above: .below
        case .left: .right
        case .right: .left
        }
    }

    /// A fixed direction always keeps its side: the panel keeps the record far enough from the edge for the song to
    /// fit there (`MiniPlayerPanel.fit`). Automatic puts the song beside the record only in a corner: close to a side edge and in the top or
    /// bottom third, on a landscape screen, on the side away from the edge. Anywhere else it goes below, or above in
    /// the bottom third of the screen, however close the record is to the top or bottom edge. A side without room for
    /// the song gives its place to the next one. `center` is the middle of the record, in points from the top left of
    /// the visible screen.
    static func choose(center: CGPoint, screen: CGSize, record: CGFloat, text: CGSize, direction: MiniDirection = .automatic) -> MiniTextSide {
        let gap: CGFloat = 6
        let half = record / 2
        let fits: [MiniTextSide: Bool] = [
            .below: screen.height - (center.y + half) >= text.height + gap,
            .above: center.y - half >= text.height + gap,
            .right: screen.width - (center.x + half) >= text.width + gap,
            .left: center.x - half >= text.width + gap,
        ]
        let beside: MiniTextSide = center.x < screen.width / 2 ? .right : .left
        let across: MiniTextSide = beside == .right ? .left : .right
        let row = center.y < screen.height / 3 ? -1 : center.y > screen.height * 2 / 3 ? 1 : 0
        let stacked: MiniTextSide = row > 0 ? .above : .below
        if let side = direction.side { return side }
        var order: [MiniTextSide]
        do {
            // Thirds of the width made a corner of a third of a wide screen, so a record far from the side edges
            // turned the song sideways as it neared the top. A corner starts within two records of a side edge.
            let nearSide = min(center.x, screen.width - center.x) < record * 2
            let landscape = screen.width / max(1, screen.height) >= 1.4
            order = nearSide && row != 0 ? (landscape ? [beside, stacked] : [stacked, beside]) : [stacked]
        }
        order += [.below, .above, beside, across]
        return order.first { fits[$0] == true } ?? .below
    }
}

/// What the mini player shows that the HUD's model doesn't keep: the key of the song that plays, and where the song
/// goes around the record.
final class MiniState: ObservableObject {
    @Published var key: DetectedKey?
    @Published var side = MiniTextSide.below
    @Published var layout = Preferences.shared.miniLayout
    @Published var background = Preferences.shared.miniBackground
    /// The luminance of the wallpaper under the player, which shows through glass and the lighter materials.
    @Published var behind = 0.2
    /// The song's title, artist and album on the record, in place of beside it.
    @Published var songOnRecord = Preferences.shared.miniDirection == .onRecord
    /// The size of the record against its usual size, which `MiniPlayerView.record` reads. A change draws the player
    /// again.
    @Published var recordScale = Preferences.shared.miniRecordScale
    /// The size of the song's text, which decides which sides have room for it.
    var textSize = CGSize(width: 180, height: 60) {
        didSet { if abs(textSize.width - oldValue.width) > 1 || abs(textSize.height - oldValue.height) > 1 { onTextSize() } }
    }
    /// A longer title or another pill made the song bigger, which can take it past the edge on a fixed side.
    var onTextSize: () -> Void = {}
    /// The record and the text, in the coordinates of the panel from its top left, which take the pointer. The rest
    /// of the panel lets clicks through to the windows under it.
    var hitFrames: [String: CGRect] = [:]
    /// The frame of the background, which takes the pointer too while a background shows.
    var backdropFrame: CGRect?
    var onHide: () -> Void = {}
    var onShowHUD: () -> Void = {}
    var onSettings: () -> Void = {}
}

/// The floating mini player: the record, with the song beside it on the side that the screen has room for, and the
/// elements that Settings > Mini player places.
struct MiniPlayerView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var mini: MiniState
    /// The editor in Settings: sample values for every element, and the places drawn and taking drops.
    var editing = false
    var onDrop: (MiniElement, MiniPlace) -> Void = { _, _ in }
    var onRemove: (MiniElement) -> Void = { _ in }

    /// The record at the usual size, which Settings > Mini player > Record > Size scales by `scales`.
    static let baseRecord: CGFloat = 132
    static let scales: ClosedRange<Double> = 0.75 ... 1.75
    /// The size that renders draw the record at, without touching the saved setting.
    nonisolated(unsafe) static var renderScale: Double?
    static var record: CGFloat { (baseRecord * (renderScale ?? Preferences.shared.miniRecordScale)).rounded() }
    /// Room around the record for the pills on its rim.
    static let margin: CGFloat = 12
    static var box: CGFloat { record + margin * 2 }
    /// The widest that the song's text gets beside the record, and under or over it.
    static let sideWidth: CGFloat = 190
    static let stackWidth: CGFloat = 230
    static let textHeight: CGFloat = 70
    private static let textGap: CGFloat = 6

    /// The place of the song on each side, from the middle of the record. `box` is the record with its rim, which is
    /// smaller beside the song while the background is nearly round.
    static func textPlace(_ side: MiniTextSide, box: CGFloat = box) -> CGRect {
        let width = side == .left || side == .right ? sideWidth + margin : stackWidth
        let offset = switch side {
        case .below: CGSize(width: 0, height: box / 2 + textGap + textHeight / 2 - margin + 4)
        case .above: CGSize(width: 0, height: -(box / 2 + textGap + textHeight / 2 - margin + 4))
        case .right: CGSize(width: box / 2 + width / 2 - margin + textGap, height: 0)
        case .left: CGSize(width: -(box / 2 + width / 2 - margin + textGap), height: 0)
        }
        return CGRect(x: offset.width - width / 2, y: offset.height - textHeight / 2, width: width, height: textHeight)
    }

    /// As far as the song can reach from the middle of the record, which the background stops at: its place, a little
    /// further away from the record for a line of pills under it, and taller beside the record, where the pills wrap
    /// into rows (three lines and three rows of pills).
    static func textReach(_ side: MiniTextSide, box: CGFloat = box) -> CGRect {
        let place = textPlace(side, box: box)
        switch side {
        case .below: return CGRect(x: place.minX, y: place.minY, width: place.width, height: place.height + 10)
        case .above: return CGRect(x: place.minX, y: place.minY - 10, width: place.width, height: place.height + 10)
        case .left, .right: return place.insetBy(dx: 0, dy: -25)
        }
    }

    /// The record with its rim, from its middle.
    private static var recordBox: CGRect { CGRect(x: -box / 2, y: -box / 2, width: box, height: box) }

    /// The panel has room for the text on every side, so the record stays where it is when the text moves, and for
    /// the background around the widest and tallest song at full roundness, which is the largest it gets. It grows
    /// and shrinks with the record.
    static var panelSize: CGSize {
        var half = CGSize(width: box / 2 + sideWidth + textGap, height: box / 2 + textHeight + textGap)
        for side in [MiniTextSide.below, .above, .left, .right] {
            let reach = textReach(side)
            for fraction in [0.4, 0.6, 0.8, 1.0] {
                let text = side == .left || side == .right
                    ? CGRect(x: side == .right ? reach.minX : reach.maxX - reach.width * fraction, y: reach.minY, width: reach.width * fraction, height: reach.height)
                    : CGRect(x: -reach.width * fraction / 2, y: reach.minY, width: reach.width * fraction, height: reach.height)
                let shape = MiniBackdropShape(record: recordBox, text: text, side: side, roundness: 1)
                half.width = max(half.width, -shape.rect.minX, shape.rect.maxX)
                half.height = max(half.height, -shape.rect.minY, shape.rect.maxY)
            }
        }
        return CGSize(width: (half.width + 1).rounded(.up) * 2, height: (half.height + 1).rounded(.up) * 2)
    }

    @State private var target: MiniPlace?

    private var layout: MiniLayout { mini.layout }

    var body: some View {
        if editing {
            // Settings stacks the song under the record, with the places drawn.
            MiniEditorStack(background: mini.background) {
                vinyl
                    .transformAnchorPreference(key: MiniFrames.self, value: .bounds) { $0["record"] = $1 }
                text
                    .transformAnchorPreference(key: MiniFrames.self, value: .bounds) { $0["text"] = $1 }
            }
            .backgroundPreferenceValue(MiniFrames.self) { frames in backdrop(frames, side: .below) }
            .environment(\.colorScheme, .dark)
        } else {
            player
        }
    }

    private var player: some View {
        ZStack {
            vinyl
                .transformAnchorPreference(key: MiniFrames.self, value: .bounds) { $0["record"] = $1 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mini.hitFrames["record"] = $0 }
            if hasText {
                // A long title is cut at the width of the text's place, so it never runs past the edge of the panel.
                text
                    .fixedSize(horizontal: false, vertical: true)
                    .transformAnchorPreference(key: MiniFrames.self, value: .bounds) { $0["text"] = $1 }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { mini.textSize = $0 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mini.hitFrames["text"] = $0 }
                    // Text that went away leaves no place that takes clicks meant for the window under it.
                    .onDisappear { mini.hitFrames["text"] = nil }
                    .frame(width: textWidth, height: Self.textHeight, alignment: textAlignment)
                    .offset(textOffset)
                    .animation(.easeOut(duration: 0.15), value: mini.side)
                    .animation(.easeOut(duration: 0.15), value: hangs)
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        // The frames come from this same layout pass, so the background follows the song's size and side as they
        // change, with no state in between.
        .backgroundPreferenceValue(MiniFrames.self) { frames in backdrop(frames, side: mini.side) }
        .environment(\.recordActions, RecordActions(playPause: { model.onPlayPause() }, skip: { model.onSkip($0) }, scroll: model.scroll, scrub: model.scrub,
                                                    seek: { model.onSeekFraction($0) }, seekable: model.seekable, seekOff: model.seekOff,
                                                    seekWait: model.seekWait))
        .environment(\.recordPlaying, model.playing)
        .environment(\.recordRewinds, model.rewinds)
        .environment(\.colorScheme, .dark)
    }

    // MARK: The background

    @ViewBuilder private func backdrop(_ frames: [String: Anchor<CGRect>], side: MiniTextSide) -> some View {
        if mini.background.visible, let recordAnchor = frames["record"] {
            GeometryReader { proxy in
                let record = proxy[recordAnchor]
                let center = CGPoint(x: record.midX, y: record.midY)
                // The panel has room for the song as far as its reach, so the background stops there too and never
                // meets the edge of the panel. The editor has no such edge.
                let reach = Self.textReach(side, box: record.width).offsetBy(dx: center.x, dy: center.y)
                // A hanging pill sits higher than the song's place, so it never reaches the edge of the panel.
                let hanging = hangs
                let clamp = { (frame: CGRect) in editing || hanging ? frame : frame.intersection(reach) }
                let text = frames["text"].map { clamp(proxy[$0]) }
                let lines = frames.filter { $0.key.hasPrefix("line ") }.map { clamp(proxy[$0.value]) }
                let shape = MiniBackdropShape(record: record, text: text, lines: lines, side: side, roundness: mini.background.roundness)
                MiniBackdrop(background: mini.background, radius: shape.radius)
                    .frame(width: shape.rect.width, height: shape.rect.height)
                    .contentShape(RoundedRectangle(cornerRadius: shape.radius))
                    .contextMenu { menu }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mini.backdropFrame = $0 }
                    .position(x: shape.rect.midX, y: shape.rect.midY)
                    .animation(.easeOut(duration: 0.15), value: side)
            }
        }
    }

    // MARK: The record

    private var vinyl: some View {
        Group {
            if let track = model.track, track.title?.isEmpty == false {
                MiniRecord(track: track, artwork: model.artwork, spinning: model.playing && !editing, side: recordSide, flash: editing ? nil : model.playFlash,
                           lines: recordLines)
            } else {
                EmptyPlatter(side: recordSide)
            }
        }
        .padding(Self.margin)
        .overlay(alignment: .top) { pill(at: .top).padding(.top, Self.margin - 10) }
        .overlay(alignment: .bottom) { pill(at: .bottom).padding(.bottom, Self.margin - 10) }
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        if !editing {
            Button("Show HUD") { mini.onShowHUD() }
            Button("Mini Player Settings…") { mini.onSettings() }
            Divider()
            Button("Hide Mini Player") { mini.onHide() }
        }
    }

    @ViewBuilder private func pill(at place: MiniPlace) -> some View {
        let element = place == .top ? layout.top : layout.bottom
        if editing {
            slot(place, filled: element != nil) {
                if let element { chip(element, removable: true) }
            }
        } else if let element, let value = value(element) {
            MiniChip(text: value, hue: element.hue)
        }
    }

    // MARK: The song

    /// With the song on the record, only the pills of its line stay beside it.
    private var hasText: Bool {
        editing || (!mini.songOnRecord && ((layout.track && model.track?.title?.isEmpty == false) || (layout.artist && model.track?.artist?.isEmpty == false)
            || (layout.album && model.track?.album?.isEmpty == false))) || layout.line.contains { value($0) != nil }
    }

    /// The song's lines that the record shows, while Settings puts the song on the record.
    private var recordLines: [RecordSongLine] {
        guard mini.songOnRecord, let track = editing ? HUDSample.track : model.track else { return [] }
        func text(_ shown: Bool, _ value: String?) -> String? { shown ? value.flatMap { $0.isEmpty ? nil : $0 } : nil }
        return [text(layout.track, track.title).map { RecordSongLine(text: $0, kind: .title) },
                text(layout.artist, track.artist).map { RecordSongLine(text: $0, kind: .artist) },
                text(layout.album, track.album).map { RecordSongLine(text: $0, kind: .album) }].compactMap { $0 }
    }

    private var alignment: HorizontalAlignment {
        if editing { return .center }
        switch mini.side {
        case .left: return .trailing
        case .right: return .leading
        case .above, .below: return .center
        }
    }

    private var textAlignment: Alignment {
        if editing { return .top }
        switch mini.side {
        case .left: return .trailing
        case .right: return .leading
        case .above: return .bottom
        case .below: return .top
        }
    }

    /// Beside the record, the text may also use the panel's margin on its outer side.
    private var textWidth: CGFloat { Self.textPlace(mini.side).width }

    /// Where the text box sits against the record in the middle of the panel. A hanging pill is lifted until its top
    /// overlaps the record's bottom edge.
    private var textOffset: CGSize {
        if editing { return .zero }
        let place = Self.textPlace(mini.side, box: recordSide + Self.margin * 2)
        let lift = hangs ? place.minY - recordSide / 2 + Self.hangOverlap : 0
        return CGSize(width: place.midX, height: place.midY - lift)
    }

    /// How much of a hanging pill lies over the record.
    private static let hangOverlap: CGFloat = 6

    /// With the song on the record, a single pill under it hangs from the record's bottom edge. Two or more pills (a
    /// line of them, or one in the line and one on the rim) would crowd the edge, so they stay under the record.
    private var hangs: Bool {
        guard !editing, mini.songOnRecord, mini.side == .below else { return false }
        let rim = layout.bottom.flatMap { value($0) } != nil
        return !rim && layout.line.count { value($0) != nil } == 1
    }

    /// The smallest that the record gets beside the song, which still leaves its glyphs room.
    static let smallestRecord: CGFloat = 72

    /// Beside the song, a background that is nearly round turns the record down toward the song's height, so the
    /// background is a slim pill instead of a tall capsule with empty space above and below the song. Above or below
    /// the record the song's width sets the background's, so a smaller record wouldn't take that space away.
    private var recordSide: CGFloat {
        guard !editing, mini.background.visible, mini.side == .left || mini.side == .right, hasText else { return Self.record }
        let t = min(max((mini.background.roundness - 0.5) / 0.5, 0), 1)
        let eased = t * t * (3 - 2 * t)
        let target = min(Self.record, max(Self.smallestRecord, mini.textSize.height))
        return (Self.record - (Self.record - target) * eased).rounded()
    }

    /// Dark text over a light background, and the usual light text with its shadow everywhere else.
    private var darkText: Bool {
        let behind = editing ? Wallpaper.luminance() ?? 0.2 : mini.behind
        return (mini.background.luminance(behind: behind) ?? 0) > 0.4
    }

    private var text: some View {
        let track = editing ? HUDSample.track : model.track
        let dark = darkText
        let ink = dark ? Color(red: 0.08, green: 0.07, blue: 0.07) : Color(red: 0.96, green: 0.95, blue: 0.93)
        // With the song on the record, the record draws its lines.
        let outside = !mini.songOnRecord
        let title = outside && layout.track ? track?.title.flatMap { $0.isEmpty ? nil : $0 } : nil
        let album = outside && layout.album ? track?.album.flatMap { $0.isEmpty ? nil : $0 } : nil
        let artist = outside && layout.artist ? track?.artist.flatMap { $0.isEmpty ? nil : $0 } : nil
        // Beside the record, the pills wrap at the width of the song's text, so they never reach further from the
        // record than the song does.
        let beside = !editing && (mini.side == .left || mini.side == .right)
        // Each line and pill reports its frame, for the background to fit around.
        func line(_ name: String) -> (Anchor<CGRect>) -> [String: Anchor<CGRect>] { { ["line \(name)": $0] } }
        return MiniSongLayout(alignment: alignment, wrap: beside) {
            if let title {
                Text(title).font(.system(size: 13.5, weight: .heavy, design: .rounded))
                    .anchorPreference(key: MiniFrames.self, value: .bounds, transform: line("title"))
            }
            if let artist {
                Text(artist)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.9))
                    .anchorPreference(key: MiniFrames.self, value: .bounds, transform: line("artist"))
            }
            if let album {
                Text(album)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(dark ? 0.7 : 0.62))
                    .anchorPreference(key: MiniFrames.self, value: .bounds, transform: line("album"))
            }
            if editing {
                slot(.line, filled: !layout.line.isEmpty) {
                    HStack(spacing: 4) { ForEach(layout.line) { chip($0, removable: true, small: true) } }
                }
                .anchorPreference(key: MiniFrames.self, value: .bounds, transform: line("places"))
                .padding(.top, 4)
            } else {
                let hanging = hangs
                ForEach(layout.line.compactMap { element in value(element).map { (element, $0) } }, id: \.0) { element, value in
                    // Over the record's edge, a light rim keeps the dark pill apart from the dark vinyl.
                    pill(element, value)
                        .overlay { if hanging { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75) } }
                        .anchorPreference(key: MiniFrames.self, value: .bounds, transform: line(element.rawValue))
                        .layoutValue(key: MiniSongLayout.Pill.self, value: true)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(ink)
        .multilineTextAlignment(alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
        .shadow(color: dark ? .white.opacity(0.25) : .black.opacity(0.75), radius: dark ? 3 : 6, y: dark ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: dark)
    }

    /// A pill of the line under the song. Time left counts down on its own clock, ticking as each second of the
    /// song passes, since the player's view only draws again when something else changes.
    @ViewBuilder private func pill(_ element: MiniElement, _ value: String) -> some View {
        if element == .timeLeft, !editing, let track = model.track, track.playing, let duration = track.duration, let position = track.position(at: Date()) {
            let rate = max(track.rate ?? 1, 0.05)
            let left = max(0, duration - position)
            let next = Date().addingTimeInterval((left - left.rounded(.down)) / rate + 0.02)
            TimelineView(.periodic(from: next, by: 1 / rate)) { context in
                MiniChip(text: self.value(element, at: context.date) ?? value, hue: element.hue, small: true)
            }
        } else {
            MiniChip(text: value, hue: element.hue, small: true)
        }
    }

    // MARK: Elements

    /// The element's live value, or nil when it has nothing to show, like the speed of a song at its own tempo.
    private func value(_ element: MiniElement, at date: Date = Date()) -> String? {
        switch element {
        case .key:
            return mini.key?.name
        case .tempo:
            guard let tempo = model.tempo, tempo.song == nil || tempo.song == model.track?.song else { return nil }
            return "\(Int((tempo.bpm * model.speed).rounded())) BPM"
        case .pitch:
            return model.shift == 0 ? nil : Shift.short(model.shift)
        case .speed:
            return abs(model.speed - 1) < 0.005 ? nil : Self.speed(model.speed) + "×"
        case .loop:
            guard let loop = model.loop, let end = loop.end else { return nil }
            return "↻ \(Self.time(loop.start))–\(Self.time(end))"
        case .timeLeft:
            guard let track = model.track, let duration = track.duration, let position = track.position(at: date) else { return nil }
            return "−" + Self.time(max(0, duration - position))
        case .vocals:
            return model.stemsMuted.contains(.vocals) ? "Vocals off" : nil
        case .next:
            guard let current = model.queueCurrent, let index = model.queue.firstIndex(where: { $0.id == current }), index + 1 < model.queue.count else { return nil }
            return "⏭ " + model.queue[index + 1].title
        }
    }

    /// A speed as a multiple of the song's tempo, with as few decimals as it needs: 0.9, 0.85, 1.25.
    static func speed(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: Editing

    private func chip(_ element: MiniElement, removable: Bool, small: Bool = false) -> some View {
        MiniChip(text: element.sample, hue: element.hue, small: small)
            .draggable(element.rawValue)
            .onTapGesture { if removable { onRemove(element) } }
            .help("Drag to another place, or click to remove")
    }

    private func slot(_ place: MiniPlace, filled: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(minWidth: place == .line ? 120 : 64, minHeight: 20)
            .padding(2)
            .background {
                Capsule()
                    .fill(target == place ? StripColors.solid(.honey, .dark).fill.opacity(0.35) : .white.opacity(filled ? 0 : 0.06))
                    .overlay(Capsule().strokeBorder(.white.opacity(filled && target != place ? 0 : 0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .dropDestination(for: String.self) { items, _ in
                guard let element = items.first.flatMap(MiniElement.init) else { return false }
                onDrop(element, place)
                return true
            } isTargeted: { target = $0 ? place : (target == place ? nil : target) }
            .animation(.easeOut(duration: 0.1), value: target)
    }
}

/// The song's lines, one under the other, and the pills of the line under them. With `wrap`, a row of pills ends where
/// the widest line of the song ends, and the next pill starts a new row; a song shorter than any two pills side by side
/// stacks them all. Without it, the pills share one row.
struct MiniSongLayout: Layout {
    struct Pill: LayoutValueKey {
        static let defaultValue = false
    }

    var alignment: HorizontalAlignment
    var wrap: Bool

    private static let lineSpacing: CGFloat = 1
    private static let pillsTop: CGFloat = 4
    private static let pillSpacing: CGFloat = 4
    private static let rowSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: proposal.width, subviews: subviews)
        let slack = bounds.width - arranged.size.width
        let shift = alignment == .trailing ? slack : alignment == .center ? slack / 2 : 0
        for (subview, frame) in zip(subviews, arranged.frames) {
            subview.place(at: CGPoint(x: bounds.minX + shift + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let limit = width ?? .infinity
        let sizes = subviews.map { $0[Pill.self] ? $0.sizeThatFits(.unspecified) : $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let lines = subviews.indices.filter { !subviews[$0][Pill.self] }
        let pills = subviews.indices.filter { subviews[$0][Pill.self] }
        let textWidth = lines.map { sizes[$0].width }.max() ?? 0

        // Rows of pills, as indices of subviews.
        let rowLimit = wrap && textWidth > 0 ? min(textWidth, limit) : (wrap ? limit : .infinity)
        var rows: [[Int]] = []
        var rowWidth: CGFloat = 0
        for index in pills {
            let pillWidth = sizes[index].width
            if let last = rows.indices.last, rowWidth + Self.pillSpacing + pillWidth <= rowLimit {
                rows[last].append(index)
                rowWidth += Self.pillSpacing + pillWidth
            } else {
                rows.append([index])
                rowWidth = pillWidth
            }
        }
        let rowWidths = rows.map { row in row.map { sizes[$0].width }.reduce(0, +) + Self.pillSpacing * CGFloat(row.count - 1) }
        let contentWidth = max(textWidth, rowWidths.max() ?? 0)

        func x(for itemWidth: CGFloat) -> CGFloat {
            alignment == .trailing ? contentWidth - itemWidth : alignment == .center ? (contentWidth - itemWidth) / 2 : 0
        }

        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        for (n, index) in lines.enumerated() {
            if n > 0 { y += Self.lineSpacing }
            frames[index] = CGRect(origin: CGPoint(x: x(for: sizes[index].width), y: y), size: sizes[index])
            y += sizes[index].height
        }
        for (n, row) in rows.enumerated() {
            y += n > 0 ? Self.rowSpacing : (lines.isEmpty ? 0 : Self.pillsTop)
            let height = row.map { sizes[$0].height }.max() ?? 0
            var left = x(for: rowWidths[n])
            for index in row {
                frames[index] = CGRect(origin: CGPoint(x: left, y: y + (height - sizes[index].height) / 2), size: sizes[index])
                left += sizes[index].width + Self.pillSpacing
            }
            y += height
        }
        return (CGSize(width: contentWidth, height: y), frames)
    }
}

/// A dark pill with the value of an element, against the record or under the song.
struct MiniChip: View {
    let text: String
    var hue: StripColors.Hue?
    /// The pills in the line under the song, smaller than the song's text so they don't outweigh it.
    var small = false

    var body: some View {
        let colors = hue.map { StripColors.solid($0, .dark) }
        Text(text)
            .font(.system(size: small ? 9.5 : 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(hue.map { StripColors.text($0, .dark) } ?? Color(red: 0.96, green: 0.95, blue: 0.93))
            .padding(.horizontal, small ? 6 : 8)
            .padding(.vertical, small ? 2 : 3)
            .background(Capsule().fill(colors.map { $0.fill.mix(with: Color(red: 0.09, green: 0.07, blue: 0.08), by: 0.72) } ?? Color(red: 0.09, green: 0.07, blue: 0.08).opacity(0.92)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .fixedSize()
    }
}

/// The editor of Settings: the record, and the song 2 points under it, as wide as the widest song, in a frame that
/// holds the background around them too. The editor is as tall as the background with its current roundness, so it
/// grows and shrinks at its bottom while the roundness changes, under the rows of Settings that change it.
private struct MiniEditorStack: Layout {
    var background: MiniBackground

    private func frames(_ subviews: Subviews) -> (record: CGRect, text: CGRect, bounds: CGRect) {
        let box = MiniPlayerView.box
        let width = MiniPlayerView.stackWidth
        let record = CGRect(x: -box / 2, y: -box / 2, width: box, height: box)
        let size = subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)) : .zero
        let text = CGRect(x: -size.width / 2, y: record.maxY + 2, width: size.width, height: size.height)
        var bounds = CGRect(x: -width / 2, y: record.minY, width: width, height: text.maxY - record.minY)
        if background.visible {
            bounds = bounds.union(MiniBackdropShape(record: record, text: text, side: .below, roundness: background.roundness).rect)
        }
        return (record, text, bounds)
    }

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        frames(subviews).bounds.size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let frames = frames(subviews)
        let dx = bounds.minX - frames.bounds.minX, dy = bounds.minY - frames.bounds.minY
        for (subview, frame) in zip(subviews, [frames.record, frames.text]) {
            subview.place(at: CGPoint(x: frame.minX + dx, y: frame.minY + dy), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// The frames of the record and the song, which the background is drawn around.
struct MiniFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The background of the mini player in its shape: glass, a blur material, or a flat colour, with the tint over glass
/// and the materials.
struct MiniBackdrop: View {
    let background: MiniBackground
    let radius: CGFloat
    @Environment(\.renderingPreview) private var renderingPreview

    var body: some View {
        // Circular corners, since the space kept around the song is worked out for circular arcs, and at full
        // roundness they make an exact circle or capsule.
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        if renderingPreview {
            standIn(shape)
        } else if let glass = background.material.glass {
            // The glass is applied to a fill of the tint, which tints regular and clear glass alike. Glass.tint gave
            // regular glass a brownish grey here, whatever the colour, while clear glass took it. Clear glass keeps the
            // light scheme, since in the dark one it dims what is behind it, and the song's text turns dark over a
            // light desktop instead.
            shape.fill(background.tint ?? .clear)
                .glassEffect(glass, in: shape)
                .environment(\.colorScheme, background.material == .clearGlass ? .light : .dark)
        } else if let material = background.material.material {
            shape.fill(material).overlay { if let tint = background.tint { shape.fill(tint) } }
        } else {
            shape.fill(background.color.opacity(background.opacity))
        }
    }

    /// ImageRenderer draws neither glass nor materials, so renders get a flat fill that comes close to each over a
    /// dark scheme: frosted white for glass, darker grey for each thicker material.
    private func standIn(_ shape: RoundedRectangle) -> some View {
        let base: Color = switch background.material {
        case .glass: .white.opacity(0.18)
        case .clearGlass: .white.opacity(0.07)
        case .ultraThin: Color(white: 0.14).opacity(0.3)
        case .thin: Color(white: 0.14).opacity(0.45)
        case .regular: Color(white: 0.14).opacity(0.6)
        case .thick: Color(white: 0.14).opacity(0.75)
        case .ultraThick: Color(white: 0.14).opacity(0.88)
        case .colour, .none: .clear
        }
        return shape.fill(base)
            .overlay { if let tint = background.tint { shape.fill(tint) } }
            .overlay { if background.material.glass != nil { shape.strokeBorder(.white.opacity(0.35), lineWidth: 1) } }
    }
}

/// The panel of the mini player, above other windows on every Space. A drag anywhere on the record or the song moves
/// it, and the song moves to the side that the new place has room for once the drag ends.
final class MiniPlayerPanel: NSPanel {
    private let mini: MiniState
    /// The middle of the record, in screen points, which is where the player is kept.
    private(set) var center: CGPoint
    private var pressStart: (mouse: NSPoint, center: CGPoint)?
    private var draggingPanel = false
    private var monitors: [Any] = []
    /// The fingers' travel in a sideways swipe over the record, and whether it skipped already.
    private var swipeTravel: CGFloat = 0
    private var swiped = false
    var onSkip: (Int) -> Void = { _ in }
    var naturalSwipes: () -> Bool = { false }
    var onHover: (Bool) -> Void = { _ in }
    private(set) var hovering = false

    init(model: HUDModel, mini: MiniState) {
        self.mini = mini
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: "miniPlayerCenter") as? [Double], saved.count == 2 {
            center = CGPoint(x: saved[0], y: saved[1])
        } else {
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            center = CGPoint(x: visible.maxX - 130, y: visible.minY + 150)
        }
        let size = MiniPlayerView.panelSize
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The popover role tells window switchers like rcmd that this panel isn't a window to switch to or focus.
        setAccessibilityRole(.popover)
        let hosting = FirstClickHostingView(rootView: MiniPlayerView(model: model, mini: mini))
        hosting.sizingOptions = []
        contentView = hosting
        keepOnScreen()
        place()
        mini.onTextSize = { [weak self] in DispatchQueue.main.async { self?.refit() } }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }

    func show() {
        guard !isVisible else { return }
        keepOnScreen()
        chooseSide()
        place()
        orderFrontRegardless()
        watchPointer(true)
        watchThreeFingerTap()
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        watchPointer(false)
        setHovering(false)
        faded = false
        alphaValue = 1
        watchFadeKey()
        watchThreeFingerTap()
    }

    private func place() {
        let size = MiniPlayerView.panelSize
        setFrame(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), display: true)
    }

    /// A player that was left on a screen that is gone comes back to the main one. A record that hangs over an edge
    /// of its screen, even with its middle past it, stays where it was put.
    private func keepOnScreen() {
        let reach = MiniPlayerView.box
        guard !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -reach, dy: -reach).contains(center) }),
              let visible = NSScreen.main?.visibleFrame
        else { return }
        center = CGPoint(x: visible.maxX - 130, y: visible.minY + 150)
    }

    /// The song's size with the background's padding around it, which needs room on the screen too.
    private var songSize: CGSize {
        let padding = mini.background.visible ? MiniBackdropShape.padding : 0
        return CGSize(width: mini.textSize.width + padding, height: mini.textSize.height + padding)
    }

    /// With a fixed direction, the record stops short of an edge where the song on its side would leave the screen,
    /// so the song never moves to another side. Automatic leaves the record anywhere and moves the song instead. The
    /// bottom edge never stops it, since a player half below the screen keeps out of the way.
    private func fit(_ point: CGPoint) -> CGPoint {
        guard let side = Preferences.shared.miniDirection.side, hasSong,
              let visible = (NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main)?.visibleFrame
        else { return point }
        let half = MiniPlayerView.box / 2, gap: CGFloat = 6, song = songSize
        var x = point.x, y = point.y
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { low > high ? value : min(max(value, low), high) }
        switch side {
        case .below:
            x = clamp(x, visible.minX + song.width / 2, visible.maxX - song.width / 2)
        case .above:
            y = min(y, visible.maxY - half - gap - song.height)
            x = clamp(x, visible.minX + song.width / 2, visible.maxX - song.width / 2)
        case .right:
            x = min(x, visible.maxX - half - gap - song.width)
            y = min(y, visible.maxY - song.height / 2)
        case .left:
            x = max(x, visible.minX + half + gap + song.width)
            y = min(y, visible.maxY - song.height / 2)
        }
        return CGPoint(x: x, y: y)
    }

    /// Whether the player shows any of the song's lines or pills beside the record.
    private var hasSong: Bool {
        let layout = mini.layout
        return (!mini.songOnRecord && (layout.track || layout.artist || layout.album)) || !layout.line.isEmpty
    }

    /// Settings changed the record's size: the panel takes its new size around the same middle.
    func resize() {
        place()
        chooseSide()
    }

    /// Moves the record in from the edge when the song grew past it on a fixed side. Automatic keeps the side it
    /// picked until the next move, since a new side changes the song's size again.
    private func refit() {
        let fitted = fit(center)
        guard fitted != center else { return }
        center = fitted
        UserDefaults.standard.set([Double(center.x), Double(center.y)], forKey: "miniPlayerCenter")
        if isVisible { place() }
    }

    /// The side of the record that the song goes on, by where the record is on its screen. A fixed direction moves the
    /// record in from the edge when the song wouldn't fit on its side.
    func chooseSide() {
        refit()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let point = CGPoint(x: center.x - visible.minX, y: visible.maxY - center.y)
        let side = MiniTextSide.choose(center: point, screen: visible.size, record: MiniPlayerView.box, text: songSize, direction: Preferences.shared.miniDirection)
        if mini.side != side { mini.side = side }
        // The wallpaper around the record, for the colour of the song's text over glass and the lighter materials.
        let around = CGRect(x: center.x - MiniPlayerView.box, y: center.y - MiniPlayerView.box, width: MiniPlayerView.box * 2, height: MiniPlayerView.box * 2)
        if mini.background.visible, let behind = Wallpaper.luminance(under: around, on: screen), abs(behind - mini.behind) > 0.01 { mini.behind = behind }
    }

    // MARK: Clicks through the empty parts

    private func watchPointer(_ on: Bool) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard on else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.updatePassThrough() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited], handler: { [weak self] event in
            self?.updatePassThrough()
            return event
        }) {
            monitors.append(local)
        }
        updatePassThrough()
    }

    /// The panel takes the pointer only over the record, the song and the background around them.
    private func updatePassThrough() {
        guard !draggingPanel else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let record = mini.hitFrames["record"].map { frame in
            hypot(point.x - frame.midX, point.y - frame.midY) <= MiniPlayerView.record / 2 + 4
                || CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height).insetBy(dx: frame.width * 0.3, dy: 0).contains(point)
        } ?? false
        let backdrop = mini.background.visible && mini.backdropFrame.map { frame in
            // CGPath refuses corners wider than half the side, which full roundness reaches exactly.
            let radius = max(0, min(max(mini.background.roundness, 0), 1) * min(frame.width, frame.height) / 2 - 0.01)
            return CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil).contains(point)
        } == true
        let over = record || backdrop || (mini.hitFrames["text"]?.insetBy(dx: -4, dy: -4).contains(point) ?? false)
        // Faded, the player lets every click through until the pointer leaves it.
        if faded {
            if !over { setFaded(false) }
            return
        }
        if ignoresMouseEvents == over { ignoresMouseEvents = !over }
        setHovering(over)
    }

    private func setHovering(_ over: Bool) {
        guard hovering != over else { return }
        hovering = over
        onHover(over)
        watchFadeKey()
    }

    // MARK: Fading with a tap of a modifier

    /// Faded to a tenth of its opacity by a tap of the fade key, to see and click what is under the player.
    private(set) var faded = false
    private var fadeTimer: Timer?
    private var fadeKeyDown: Date?

    /// The modifier keys are read 60 times a second while the pointer is over the player or it is faded. Reading the
    /// state of the keys needs no permission, while watching their events from another app needs Accessibility.
    private func watchFadeKey() {
        let wanted = (hovering || faded) && Preferences.shared.miniFadeKey != .off
        guard wanted != (fadeTimer != nil) else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeKeyDown = nil
        guard wanted else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.readFadeKey() }
    }

    /// A tap is the key going down alone and coming up within 0.35 s, with no other modifier held meanwhile.
    private func readFadeKey() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let key = Preferences.shared.miniFadeKey
        if key.isAlone(flags) {
            if fadeKeyDown == nil { fadeKeyDown = Date() }
        } else if let down = fadeKeyDown {
            fadeKeyDown = nil
            if FadeKey.none(flags), Date().timeIntervalSince(down) < 0.35 { setFaded(!faded) }
        }
    }

    /// A three-finger tap fades the player while the pointer is over it, and brings it back.
    private var threeFingerTap: ThreeFingerTap?

    /// Whether the tap was made with Input Monitoring allowed: macOS hands a tap made without it no trackpad events, and
    /// a tap made before the permission was given stays without them, so it is made again.
    private var tapHasAccess = false

    private func watchThreeFingerTap() {
        let wanted = isVisible && Preferences.shared.miniThreeFingerTap
        let access = CGPreflightListenEventAccess()
        guard wanted != (threeFingerTap != nil) || (wanted && access != tapHasAccess) else { return }
        threeFingerTap?.stop()
        threeFingerTap = nil
        if wanted {
            threeFingerTap = ThreeFingerTap()
            tapHasAccess = access
            Logger(subsystem: LOG_SUBSYSTEM, category: "MiniPlayer").log("three-finger tap \(self.threeFingerTap == nil ? "not allowed by macOS" : "watched", privacy: .public), Input Monitoring \(access ? "allowed" : "not allowed", privacy: .public)")
            threeFingerTap?.onTap = { [weak self] in
                guard let self, isVisible, frame.contains(NSEvent.mouseLocation) else { return }
                setFaded(!faded)
            }
        }
    }

    /// Settings changed the three-finger tap, or Input Monitoring was allowed.
    func syncGestures() { watchThreeFingerTap() }

    func setFaded(_ on: Bool) {
        guard faded != on else { return }
        faded = on
        if on {
            ignoresMouseEvents = true
            setHovering(false)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = on ? 0.1 : 1
        }
        if !on { updatePassThrough() }
        watchFadeKey()
    }

    // MARK: Moving

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressStart = (NSEvent.mouseLocation, center)
            draggingPanel = false
        case .leftMouseDragged:
            guard let start = pressStart else { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
            if !draggingPanel {
                guard hypot(dx, dy) >= 4 else { break }
                draggingPanel = true
            }
            center = fit(CGPoint(x: start.center.x + dx, y: start.center.y + dy))
            place()
            return
        case .leftMouseUp:
            pressStart = nil
            guard draggingPanel else { break }
            draggingPanel = false
            UserDefaults.standard.set([Double(center.x), Double(center.y)], forKey: "miniPlayerCenter")
            chooseSide()
            // The button under the pointer would take this release as a click, so SwiftUI gets it far away instead.
            if let outside = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10000, y: -10000), modifierFlags: event.modifierFlags,
                                                timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
                                                eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: 0)
            {
                super.sendEvent(outside)
            }
            updatePassThrough()
            return
        case .scrollWheel:
            // A sideways swipe over the record plays the next or the previous song, as over the HUD.
            if event.phase == .began { swipeTravel = 0; swiped = false }
            guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { break }
            swipeTravel += event.scrollingDeltaX
            if !swiped, abs(swipeTravel) > 60 {
                swiped = true
                let towardsLeft = swipeTravel < 0
                onSkip(towardsLeft != naturalSwipes() ? 1 : -1)
            }
            return
        default: break
        }
        super.sendEvent(event)
    }
}

/// Settings > Mini player > Elements: the player with its three places, and the elements to drag onto them. A click on
/// an element in the tray adds it to the line under the song, or takes it off the player.
struct MiniLayoutEditor: View {
    @ObservedObject var prefs: Preferences
    @StateObject private var sample: HUDModel = HUDSample.model(card: false, relative: false)
    @StateObject private var mini = MiniState()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            MiniPlayerView(model: sample, mini: mini, editing: true, onDrop: { element, place in
                prefs.miniLayout.put(element, at: place)
            }, onRemove: { element in
                prefs.miniLayout.remove(element)
            })
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            // The Mac's wallpaper behind the player, as it floats over the desktop, which also shows how its background
            // reads there. The image fills a clear view of the editor's size and is clipped to it: clipped on its own,
            // the filled image kept its own height and reached past the editor, under the tray.
            .background {
                if let image = Wallpaper.image {
                    Color.clear
                        .overlay { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0.16, green: 0.13, blue: 0.14))
                }
            }
            FlowRow(spacing: 6) {
                ForEach(MiniElement.allCases) { element in
                    let placed = prefs.miniLayout.place(of: element) != nil
                    let honey = StripColors.solid(.honey, colorScheme)
                    // A toggle: ticked and amber on the player, a plus off it.
                    HStack(spacing: 4) {
                        Image(systemName: placed ? "checkmark" : "plus")
                            .font(.system(size: 9, weight: .heavy))
                        Text(element.name)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(placed ? honey.fill.opacity(colorScheme == .dark ? 0.3 : 0.45) : .primary.opacity(0.07)))
                    .overlay(Capsule().strokeBorder(placed ? honey.fill.opacity(0.8) : .primary.opacity(0.12), lineWidth: 1))
                    .foregroundStyle(placed ? StripColors.text(.honey, colorScheme) : .primary)
                    .contentShape(Capsule())
                    .draggable(element.rawValue)
                    .onTapGesture {
                        if placed { prefs.miniLayout.remove(element) } else { prefs.miniLayout.put(element, at: .line) }
                    }
                    .help(placed ? "Remove from the player" : "Add under the song, or drag onto a place")
                    .animation(.easeOut(duration: 0.12), value: placed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            mini.layout = prefs.miniLayout
            mini.background = prefs.miniBackground
        }
        .onChange(of: prefs.miniLayout) { _, layout in mini.layout = layout }
        .onChange(of: prefs.miniBackground) { _, background in mini.background = background }
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    /// Each row sits in the middle of the width instead of at its start.
    var centred = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        // The subviews in rows first, so that a centred row knows its width.
        var rows: [[(LayoutSubview, CGSize)]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((subview, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for row in rows {
            let width = row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1))
            var x = centred ? bounds.minX + max(0, (bounds.width - width) / 2) : bounds.minX
            for (subview, size) in row {
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += (row.map(\.1.height).max() ?? 0) + spacing
        }
    }
}

/// One line of the song on the mini player's record.
struct RecordSongLine: Equatable {
    enum Kind { case title, artist, album }
    let text: String
    let kind: Kind
}

/// The song's title, artist and album on the mini player's record (Settings > Mini player > Layout > On the record): one
/// line each, centred as a block on the record however many lines there are. Each line stays inside the record's
/// circle: a line wider than the circle at its height is drawn smaller (`RecordLinesFit`), and only cut short at about
/// half its size. The record is dimmed under the lines, which are white with a shadow, like the play glyph over the cover. They
/// fade out while the pointer over the record shows its buttons.
struct RecordSongLines: View {
    let lines: [RecordSongLine]
    let diameter: CGFloat
    @Environment(\.recordButtonsShown) private var buttonsShown

    /// The circle that the lines stay inside, against the record, which leaves the outer grooves clear.
    static let inside: CGFloat = 0.84

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0.42), location: 0.62),
                .init(color: .black.opacity(0.12), location: 1),
            ], center: .center, startRadius: 0, endRadius: diameter / 2))
            let fitted = RecordLinesFit.fit(lines, diameter: diameter * Self.inside) { diameter * size($0) }
            ZStack {
                ForEach(Array(zip(lines, fitted).enumerated()), id: \.offset) { _, pair in
                    let (line, fit) = pair
                    Text(line.text)
                        .font(.system(size: fit.size, weight: line.kind == .title ? .heavy : .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(line.kind == .title ? 1 : line.kind == .artist ? 0.92 : 0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: fit.width)
                        .frame(height: fit.height)
                        .offset(y: fit.y)
                }
            }
            .shadow(color: .black.opacity(0.85), radius: diameter * 0.03, y: 1)
        }
        .frame(width: diameter, height: diameter)
        .opacity(buttonsShown ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: buttonsShown)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// The size of each line's text against the record's diameter: 14 points of title on the usual record.
    private func size(_ kind: RecordSongLine.Kind) -> CGFloat {
        switch kind {
        case .title: 0.105
        case .artist: 0.083
        case .album: 0.078
        }
    }
}

/// The size and place of each line of the song inside a circle. The lines are stacked and centred on the circle's
/// middle. Each line gets the width of the circle at the edge of the line that is furthest from the middle, where the
/// circle is narrowest along it, and its text gets as small as that width needs, down to `lowest`. The title
/// stays the largest line, so a long title never sits under a larger artist. Smaller lines take less height, which
/// moves every line and changes its width, so the sizes are found again a few times.
struct RecordLinesFit {
    struct Line {
        let size: CGFloat
        let width: CGFloat
        let height: CGFloat
        /// The middle of the line, in points below the circle's middle.
        let y: CGFloat
    }

    static let smallest: CGFloat = 8

    /// The smallest that a line of `full` points gets before it is cut short: just over half its size, and never under
    /// 8 points. Smaller text would be hard to read, and a long title took every line down to 8 points on a large
    /// record.
    static func lowest(_ full: CGFloat) -> CGFloat { min(full, max(smallest, full * 0.55)) }

    static func fit(_ lines: [RecordSongLine], diameter: CGFloat, base: (RecordSongLine.Kind) -> CGFloat) -> [Line] {
        let radius = diameter / 2
        let spacing = diameter * 0.015
        let natural = lines.map { width($0.text, size: base($0.kind), kind: $0.kind) }
        var sizes = lines.map { base($0.kind) }
        var placed: [Line] = []
        for _ in 0 ..< 4 {
            let heights = zip(sizes, lines).map { height(size: $0, kind: $1.kind) }
            let total = heights.reduce(0, +) + spacing * CGFloat(max(0, lines.count - 1))
            var top = -total / 2
            placed = []
            for index in lines.indices {
                let far = max(abs(top), abs(top + heights[index]))
                let chord = 2 * max(0, radius * radius - far * far).squareRoot()
                placed.append(Line(size: sizes[index], width: chord, height: heights[index], y: top + heights[index] / 2))
                top += heights[index] + spacing
            }
            var next = lines.indices.map { index in
                let full = base(lines[index].kind)
                let fitting = natural[index] > 0 ? full * placed[index].width / natural[index] : full
                return min(full, max(lowest(full), fitting))
            }
            // The artist and the album never get larger than the title, at the same ratio as their usual sizes.
            if let title = lines.firstIndex(where: { $0.kind == .title }) {
                let ratio = next[title] / base(.title)
                for index in lines.indices where index != title {
                    let full = base(lines[index].kind)
                    next[index] = min(next[index], max(lowest(full), full * ratio))
                }
            }
            if next == sizes { break }
            sizes = next
        }
        return placed
    }

    static func font(size: CGFloat, kind: RecordSongLine.Kind) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: kind == .title ? .heavy : .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    static func width(_ text: String, size: CGFloat, kind: RecordSongLine.Kind) -> CGFloat {
        ((text as NSString).size(withAttributes: [.font: font(size: size, kind: kind)]).width + 2).rounded(.up)
    }

    static func height(size: CGFloat, kind: RecordSongLine.Kind) -> CGFloat {
        let font = font(size: size, kind: kind)
        return (font.ascender - font.descender).rounded(.up)
    }
}

/// A tap of three fingers on the trackpad, read from the session's gesture events: touches never reach the mini
/// player's non-activating panel, and they don't reach it at all while it is faded. The tap only listens, so it
/// holds back no event, and it calls `onTap` on the main queue when three fingers touch and lift within 0.4 s without
/// moving. Nil when macOS doesn't allow the tap.
final class ThreeFingerTap: @unchecked Sendable {
    var onTap: () -> Void = {}
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var started: Date?
    private var moved = false
    private var positions: [Int: CGPoint] = [:]

    init?() {
        // 29 is the gesture event, which isn't in CGEventType.
        let mask: CGEventMask = 1 << 29
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, info in
                                              if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                                                  if let info { Unmanaged<ThreeFingerTap>.fromOpaque(info).takeUnretainedValue().enable() }
                                              } else if type.rawValue == 29, let info, let ns = NSEvent(cgEvent: event) {
                                                  Unmanaged<ThreeFingerTap>.fromOpaque(info).takeUnretainedValue().read(ns)
                                              }
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: me)
        else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread { [weak self] in
            guard let self, let source else { return }
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "muskey.three-finger-tap"
        thread.start()
        self.thread = thread
    }

    private func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
    }

    deinit { stop() }

    private var seen = 0

    /// On the tap's thread.
    private func read(_ event: NSEvent) {
        if seen < 3 {
            seen += 1
            Logger(subsystem: LOG_SUBSYSTEM, category: "MiniPlayer").log("three-finger tap: a gesture with \(event.touches(matching: .any, in: nil).count, privacy: .public) touches")
        }
        // Only trackpad touches have a position; a touch screen's would raise an exception.
        let touches = event.touches(matching: .touching, in: nil).filter { $0.type == .indirect }
        if touches.count == 3 {
            if started == nil {
                started = Date()
                moved = false
                positions = Dictionary(touches.map { ($0.identity.hash, $0.normalizedPosition) }, uniquingKeysWith: { a, _ in a })
            } else if !moved {
                moved = touches.contains { touch in
                    positions[touch.identity.hash].map { hypot(touch.normalizedPosition.x - $0.x, touch.normalizedPosition.y - $0.y) > 0.06 } ?? false
                }
            }
            return
        }
        guard let start = started else { return }
        if touches.count < 3, !moved, Date().timeIntervalSince(start) < 0.4 {
            DispatchQueue.main.async { [weak self] in self?.onTap() }
        }
        started = nil
        moved = false
        positions = [:]
    }
}
