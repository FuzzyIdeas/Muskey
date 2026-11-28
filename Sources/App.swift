import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import Network
import os
import ServiceManagement
import SwiftUI
import SystemConfiguration

private let appLog = Logger(subsystem: LOG_SUBSYSTEM, category: "App")

struct DetectedKey: Equatable {
    /// Each key spelled the way it is usually written, indexed by pitch class from C.
    private static let majorNames = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    private static let minorNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"]

    let pitchClass: Int
    let minor: Bool

    init?(_ result: EKResult) {
        guard (0 ..< 12).contains(result.pitchClass) else { return nil }
        pitchClass = Int(result.pitchClass)
        minor = result.minor != 0
    }

    init(pitchClass: Int, minor: Bool) {
        self.pitchClass = pitchClass
        self.minor = minor
    }

    /// Semitones that move this key onto `target`, the shorter way, from six down to five up. A pitch change keeps
    /// the mode, so a target in the other mode is reached through its relative, which has the same notes: from
    /// A major, C minor is E♭ major. A key mistaken for its relative gives the same shift.
    func shift(to target: DetectedKey) -> Int {
        let goal = target.minor == minor ? target : target.relative
        return ((goal.pitchClass - pitchClass + 6) % 12 + 12) % 12 - 6
    }

    var tonic: String { minor ? Self.minorNames[pitchClass] : Self.majorNames[pitchClass] }

    /// The pitch class whose name in this mode is `letter`, plain or with the sharp or flat that the key strip
    /// shows: in C♯ minor, E with an accidental is E♭ and D has none.
    static func pitchClass(letter: Character, accidental: Bool, minor: Bool) -> Int? {
        (minor ? minorNames : majorNames).firstIndex { $0.first == letter && ($0.count == 2) == accidental }
    }
    /// A sharp or flat key, which a letter picks with Shift held.
    var accidental: Bool { (minor ? Self.minorNames : Self.majorNames)[pitchClass].count == 2 }
    var name: String { "\(tonic) \(minor ? "minor" : "major")" }
    /// The name written short, as in the menu bar and the pills under the key: `Cm`, `F♯`, `E♭m`.
    var short: String { tonic + (minor ? "m" : "") }

    /// Same notes, other mode: a minor third up from minor, down from major.
    var relative: DetectedKey { DetectedKey(pitchClass: (pitchClass + (minor ? 3 : 9)) % 12, minor: !minor) }

    /// The key's code on the Camelot wheel that DJs mix by: `8A` is A minor, `8B` is C major, and neighbouring
    /// numbers are a fifth apart.
    var camelot: String {
        let major = minor ? (pitchClass + 3) % 12 : pitchClass
        return "\((major * 7 % 12 + 7) % 12 + 1)\(minor ? "A" : "B")"
    }

    func transposed(by semitones: Int) -> DetectedKey {
        DetectedKey(pitchClass: ((pitchClass + semitones) % 12 + 12) % 12, minor: minor)
    }

    /// A key written like `Cm`, `F#` or `Eb`, for the `--keep` test flag.
    init?(name: String) {
        guard let letter = name.first, letter != " ", let natural = "C D EF G A B".firstIndex(of: letter) else { return nil }
        var pitchClass = "C D EF G A B".distance(from: "C D EF G A B".startIndex, to: natural)
        var rest = name.dropFirst()
        if let accidental = rest.first, "#♯b♭".contains(accidental) {
            pitchClass += "#♯".contains(accidental) ? 1 : -1
            rest = rest.dropFirst()
        }
        guard rest.isEmpty || rest == "m" else { return nil }
        self.init(pitchClass: (pitchClass + 12) % 12, minor: rest == "m")
    }

    /// Stands in for a detected key in the `--pick` and `--shift` test flags.
    static let sample = DetectedKey(pitchClass: 4, minor: true)
}

/// Text and icon colours: warm near-black ink in light mode, warm near-white in dark mode.
struct Palette {
    let ink: Color
    let muted: Color
    let accent: Color

    static func of(_ scheme: ColorScheme) -> Palette {
        scheme == .dark
            ? Palette(
                ink: Color(red: 1.0, green: 0.97, blue: 0.96),
                muted: Color(red: 0.91, green: 0.85, blue: 0.86),
                accent: Color(red: 0.96, green: 0.85, blue: 0.89)
            )
            : Palette(
                ink: Color(red: 0.13, green: 0.08, blue: 0.10),
                muted: Color(red: 0.29, green: 0.20, blue: 0.24),
                accent: Color(red: 0.33, green: 0.19, blue: 0.26)
            )
    }
}

/// Runs Essentia's KeyExtractor again over everything heard so far, once a second, off the IO queue.
final class KeyAnalyzer {
    static let profile = "shaath"
    static let firstEstimateAfter = 4.0

    private let queue = DispatchQueue(label: "muskey.analysis", qos: .userInitiated)
    /// The rate that the samples are read at: the tap's rate, divided by the speed of a song that Muskey Player plays
    /// faster or slower, which brings its key and its tempo back to the song's own.
    private var rate: Double
    private let tapRate: Double
    private var samples: [Float] = []
    private var analyzedCount = 0
    private var peak: Float = 0
    private var finished = false
    private let wavPath: String?

    /// `recordTo` writes everything heard to a mono Float32 WAV on finish, for checking the capture by ear or with another tool.
    init(sampleRate: Double, speed: Double = 1, recordTo wavPath: String? = nil) {
        tapRate = sampleRate
        rate = sampleRate / speed
        self.wavPath = wavPath
        samples.reserveCapacity(Int(sampleRate * 32))
    }

    func append(_ chunk: [Float], update: @escaping (EKResult, Float) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            samples += chunk
            for sample in chunk { peak = max(peak, abs(sample)) }
            guard samples.count >= Int(rate * Self.firstEstimateAfter), samples.count - analyzedCount >= Int(rate) else { return }
            let result = analyze()
            let peak = peak
            DispatchQueue.main.async { update(result, peak) }
        }
    }

    /// The song plays at another speed: what was heard at the old one is dropped, and the rest is read at the new one.
    func play(at speed: Double) {
        queue.async { [self] in
            guard !finished, rate != tapRate / speed else { return }
            rate = tapRate / speed
            samples.removeAll(keepingCapacity: true)
            analyzedCount = 0
            peak = 0
        }
    }

    /// The final key, the peak, and the tempo of everything heard, which only the final estimate looks for.
    func finish(_ completion: @escaping (EKResult, Float, (bpm: Double, confidence: Float)?) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            let result = analyze()
            let tempo = peak >= 0.0005 ? TempoDetector.bpm(samples, sourceRate: rate) : nil
            if let wavPath { writeWAV(samples, rate: UInt32(rate.rounded()), to: wavPath) }
            let peak = peak
            DispatchQueue.main.async { completion(result, peak, tempo) }
        }
    }

    private func analyze() -> EKResult {
        analyzedCount = samples.count
        return samples.withUnsafeBufferPointer { ek_key($0.baseAddress, UInt32($0.count), rate, Self.profile) }
    }
}

/// Float32 WAV; `samples` are interleaved when there is more than one channel.
func writeWAV(_ samples: [Float], rate: UInt32, channels: UInt16 = 1, to path: String) {
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 4)
    data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16))
    put(UInt16(3)); put(channels); put(rate); put(rate * 4 * UInt32(channels)); put(4 * channels); put(UInt16(32))
    data.append(contentsOf: Array("data".utf8)); put(bytes)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try? data.write(to: URL(fileURLWithPath: path))
}

final class HUDModel: ObservableObject {
    enum Phase { case listening, done, silent, failed, denied, idle }
    @Published var phase: Phase = .listening
    @Published var key: DetectedKey?
    @Published var progress: Double = 0
    // A repeating symbol effect keeps rendering in an ordered-out window, so effects run only while the HUD is up.
    @Published var shown = false

    /// Semitones the pitch change moves the song by; the HUD shows the key that is heard.
    @Published var shift = 0
    /// The picked key is in the other mode than the detected key: from A major, Option-C plays E♭ major and the HUD
    /// shows it as C minor.
    @Published var relative = false
    /// The HUD waits for a key to be picked, and stays up until closed.
    @Published var picking = false
    @Published var pitchFailed = false
    /// A key is locked, and every song that starts playing gets moved to it. Lock Key shows red only then.
    @Published var keepKey = false
    /// The key that Lock Key moved a new song from, and the key it moved it to: G♯ minor to C minor.
    @Published var moved: KeyMove?
    /// The kept key that a new song is going to. Until the first estimate of the song's own key, the song plays in
    /// that key, and the HUD shows where it is going with a spinner.
    @Published var pending: DetectedKey?
    /// The song that the Mac plays and its cover, for the record beside the key.
    @Published var track: NowPlaying.Track?
    /// The tempo of a song, from a listen or from Noiseblend. It shows while that song plays.
    @Published var tempo: SongTempo?
    var shownTempo: SongTempo? { tempo.flatMap { $0.song == track?.song ? $0 : nil } }
    /// The speed that Muskey Player plays its song at, against the song's own tempo.
    @Published var speed = 1.0
    /// The song plays in Muskey Player, whose speed the tempo keys and the tempo pill change.
    @Published var speedAdjustable = false
    /// The fastest speed of the song that plays: 150 % in Muskey Player, and 100 % for another player's song, which can
    /// only be slowed down.
    @Published var fastestSpeed = 1.5
    /// Muskey had to stop slowing another player's song, which was asked for at this speed. The speed shows in a red
    /// pill with Retry until the slowing works again, the pill is dismissed or another player plays.
    @Published var slowFailed: Double?
    /// How far a slowed song has come back to 100 %, 0 to 1, while the output catches up with the player.
    @Published var tempoReturn: Double?
    var onOpenFile: () -> Void = {}
    /// A click on the key listens to the song again.
    var onRedetect: () -> Void = {}
    var onSeekFraction: (Double) -> Void = { _ in }
    /// The pointer is over the record and its time bar, where ← → and 0 move the song.
    @Published var overRecord = false
    var onOpenLocation: () -> Void = {}
    /// The microphone records, and the HUD shows the recording in place of either layout.
    @Published var mic: MicState?
    /// Microphone in Nothing playing, and the microphone hotkey.
    var onMic: () -> Void = {}
    var onMicStop: () -> Void = {}
    var onMicCancel: () -> Void = {}
    /// A change of sensitivity, or a part added to the key or left out, while the microphone records.
    var onMicEdit: (RecordingAnalysis) -> Void = { _ in }
    @Published var micHotkey = ""
    /// What was heard in the recording from the microphone that Muskey Player plays, with its parts under the waveform.
    @Published var recording: RecordingAnalysis?
    var onRecordingEdit: (RecordingAnalysis) -> Void = { _ in }
    /// A seek would be instant: the stems aren't separated live, the lyrics don't play behind, and the player took
    /// the last seek. The seek keys and their hints exist only then.
    @Published var seekable = false
    /// Why the time bar and the waveform can't move the song, for their tooltips.
    @Published var seekOff = "Seeking is off"
    /// A seek that waits for the stems of the new place, which the time bar and the waveform show as they travel there
    /// and pulse.
    @Published var seekWait: SeekWait?
    /// The key 0 starts the song over in karaoke: the player took the last seek and the lyrics don't play behind.
    @Published var restartable = false
    /// The key, the stems or the tempo is changed, and the song can be saved with the changes.
    @Published var savable = false
    /// A save in progress, which the HUD shows in place of everything else until it ends.
    @Published var saving: SavingState?
    /// A link or a file on a network volume that opens, which takes the HUD until the song plays.
    @Published var opening: OpeningState?
    /// A song plays while another one opens, so its record stays and keeps turning beside the step that runs. It
    /// holds until the song has opened, so a pause doesn't change the layout.
    @Published var openingOverSong = false
    /// The size of the glass when a song started to open over the record of the song that plays, which the glass
    /// keeps until the song has opened.
    @Published var openingGlass: CGSize?
    var onOpenCancel: () -> Void = {}
    var onOpenBackground: () -> Void = {}
    var onOpenRetry: () -> Void = {}
    var onOpenInstall: () -> Void = {}
    /// The song plays, as the record and its tonearm show it. Space changes it before the player reports the change.
    @Published var playing = false
    /// The last play or pause, for the glyph on the record or over the lyrics.
    @Published var playFlash: PlayFlash?
    @Published var artwork: NSImage?
    /// The single card instead of the wide layout. Muskey remembers the layout.
    @Published var card = UserDefaults.standard.string(forKey: "layout") == "card"
    /// The second row of keys, or the inner ring of the card, with the keys in the other mode.
    @Published var relativeKeys = false
    /// Option is held over the keys: they show the other mode.
    @Published var flipped = false
    /// Shift is held over the keys: the sharp and flat keys that a letter with Shift picks stand out.
    @Published var accidentals = false
    /// The card shows the keyboard shortcuts in place of the record and its keys.
    @Published var shortcuts = false
    /// The lyrics of the song in place of the key in the wide layout, and in place of the record on the card.
    @Published var lyricsShown = false
    /// Karaoke: the lyrics large, in a glass as tall as the screen, for singing along, with the vocals muted when
    /// Settings has it (Return while the lyrics show).
    @Published var lyricsFocus = false
    /// The backspins that the output played when it stepped back in the song, for the records to turn back with them.
    @Published var rewinds = 0
    /// A new song that the stems or the lyrics delay play only seconds later: from when it started to when it is heard.
    @Published var songArriving: ClosedRange<Date>?
    /// The size of the glass when the song changed under a HUD with a key. The listen of the new song shows no key
    /// until its first estimate, and the glass keeps this size until then, so the record stays under the pointer.
    @Published var heldGlass: CGSize?
    /// The HUD takes keys: the pointer is over it, or it has the keyboard. The key hints are faint otherwise, since the
    /// keys do nothing then, but they keep their place and some weight in the layout.
    @Published var keysActive = false
    /// The hints are already lighter than the buttons, so 0.45 of that comes close to the buttons that FocusDim dims.
    var hintsOpacity: Double { keysActive ? 1 : 0.45 }
    /// The pointer is over the key at the top of karaoke, which shows the key row in its place.
    @Published var karaokeKeys = false
    /// The pointer is over the cover in the middle of karaoke's record, which shows the instruments and vocals.
    @Published var karaokeStems = false
    /// The height of the visible part of the screen that the HUD is on, which the large lyrics never outgrow.
    @Published var screenHeight: CGFloat = 900
    /// Where the glass is in the panel, in points from its top left corner, for keeping it on the screen.
    @Published var glassFrame: CGRect = .zero
    @Published var lyrics: LyricsState = .none
    /// The line of the lyrics sung now.
    @Published var lyricLine: Int?
    /// The speech model that times lyrics without times is downloading.
    @Published var lyricsDownloading = false
    /// The Fix timing pill over lyrics with times, nil for other lyrics.
    @Published var lyricsTiming: LyricsTimingFix?
    /// The seconds that lyrics with times show moved by, from the Fix timing pill.
    @Published var lyricsShift = 0.0
    /// A fit or a shift is kept for the song whose lyrics show.
    @Published var lyricsTimingKept = false
    /// Renders show the Fix timing pill as the pointer over it shows it.
    var lyricsTimingHover = false
    var onLyricsTiming: () -> Void = {}
    var onLyricsTimingDismiss: () -> Void = {}
    var onLyricsNudge: (Double) -> Void = { _ in }
    var onLyricsForget: () -> Void = {}
    var timingPill: LyricsTimingPill? {
        lyricsTiming.map {
            LyricsTimingPill(fix: $0, shift: lyricsShift, kept: lyricsTimingKept, press: onLyricsTiming, dismiss: onLyricsTimingDismiss,
                             nudge: onLyricsNudge, forget: onLyricsForget, hover: lyricsTimingHover)
        }
    }
    /// Whisper listens to a song that LRCLIB has no lyrics for, and writes them.
    @Published var lyricsWriting = false
    /// Whisper skips the part of the song that plays, since it was transcribed in an earlier play.
    @Published var lyricsSkipped = false
    /// Seconds until the song steps back 30 seconds, so the lines that Whisper writes come before they are sung.
    @Published var lyricsWaiting: Int?
    /// Karaoke's countdown while the vocals are separated, before the song rewinds or starts over.
    @Published var karaokeCountdown: KaraokeCountdown?

    /// The model that separates the stems is on the Mac, so the HUD offers to separate the song.
    @Published var stemsAvailable = false
    /// Stems that don't play. While any is muted, the Mac plays the other stems a few seconds behind the song.
    @Published var stemsMuted: Set<Stem> = []
    /// The stems are separated and played, while any is muted and while the HUD shows them after that.
    @Published var stemsEngaged = false
    /// What the stems wait for after a stem is muted, while the song still plays whole.
    @Published var stemsProgress: StemsProgress?
    /// The stems couldn't be separated, and every stem plays again.
    @Published var stemsFailed = false
    /// How loud each stem plays, in their own object so that the meters redraw without the rest of the HUD.
    let stemMeters = StemMeters()
    /// The scroll over the tempo or a stem.
    let scroll = ScrollFeel()
    /// Where a scroll over the time bar moves the song, from 0 to 1, shown on the bar until the player reports it.
    @Published var scrub: Double?
    /// The volume of each stem that a scroll over it set, from 0 to 1.5. A stem that isn't in it plays at 1.
    @Published var stemVolumes: [Stem: Double] = [:]
    /// A stem is muted, or plays louder or softer than the others, so the stems play in place of the song.
    var stemsAdjusted: Bool { !stemsMuted.isEmpty || !stemVolumes.isEmpty }
    /// The stems show in place of the Separate instruments and vocals button: while they play, while any is muted,
    /// and while their failure shows.
    var stemsOpen: Bool { stemsEngaged || stemsFailed || stemsAdjusted }

    func shown(_ key: DetectedKey) -> DetectedKey { relative ? key.relative : key }
    /// The key that is heard, as the HUD names it.
    var heard: DetectedKey? { key.map { shown($0.transposed(by: shift)) } }
    /// Holds off the automatic dismissal of a result while the pointer is over the HUD, and turns on the keys
    /// that pick a key by its letter.
    var hovering = false {
        didSet { if hovering != oldValue { onHoverChange() } }
    }
    var onHoverChange: () -> Void = {}

    /// A key picked in the rows or on the rings: its shift, and whether it is in the other mode than the song.
    var onShift: (Int, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    var onStop: () -> Void = {}
    var onKeep: () -> Void = {}
    var onLayout: () -> Void = {}
    var onSave: () -> Void = {}
    var onSaveCancel: () -> Void = {}
    var onSaveStop: () -> Void = {}
    var onLyrics: () -> Void = {}
    var onKaraoke: () -> Void = {}
    /// Slower with -1, faster with 1, and the song's own tempo with 0.
    var onSpeed: (Int) -> Void = { _ in }
    var onLyricsRetry: () -> Void = {}
    var onLyricsEdit: () -> Void = {}
    /// A stem chip or its key: mute it or play it again, or with Option play only that stem.
    var onStem: (Stem, Bool) -> Void = { _, _ in }
    /// The V key and karaoke's Vocals pill: the vocals muted, or playing again.
    var onVocals: () -> Void = {}
    var onStemsReset: () -> Void = {}
    /// The Separate instruments and vocals button.
    var onSeparate: () -> Void = {}
    /// The ✕ on the stems: every stem plays again, and the Separate button takes their place.
    var onStemsClose: () -> Void = {}
    var onStemsRetry: () -> Void = {}
    var onSlowRetry: () -> Void = {}
    /// Files or links dropped on the HUD, which Muskey plays.
    var onOpen: ([URL]) -> Void = { _ in }
    /// A click on the record: play or pause.
    var onPlayPause: () -> Void = {}
    /// The previous (-1) or next (1) song, from the buttons beside the record.
    var onSkip: (Int) -> Void = { _ in }
    /// A link in the HUD, like the credit under the lyrics, opens in the browser.
    var onLink: (URL) -> Void = { _ in }
    /// A file or a link is dragged over the HUD.
    @Published var dropTargeted = false
    /// The zone under a drag of songs while the queue has songs: Play Now or Add to Queue.
    @Published var dropZone: DropZone?

    /// The queue of Muskey Player (Q), on the back of the record in the wide layout and on the back of the card.
    @Published var queue: [QueueItem] = []
    @Published var queueCurrent: UUID?
    @Published var queueShown = false
    /// The song plays in another app. The queue belongs to Muskey Player, so Q, the queue's menu items and the Add to
    /// Queue zone are left out, and songs added from the keys or a drop play now.
    @Published var otherPlayer = false
    @Published var queueSelection: Set<UUID> = []
    /// Where the list of the queue is, in the coordinates of the HUD's window from its top left. Scrolls and drags
    /// there stay in the list, instead of skipping songs and moving the panel.
    var queueFrame: CGRect?
    var onQueuePlay: (UUID) -> Void = { _ in }
    /// The songs that Muskey Player played last, on the back of the record while nothing plays.
    @Published var recents: [QueueItem] = []
    @Published var recentsShown = false
    /// The recent song that Return plays, which ↑ and ↓ move.
    @Published var recentsSelection: UUID?
    /// The record shows the recents: nothing plays and the queue doesn't show.
    var recentsFlipped: Bool { recentsShown && phase == .idle && !queueShown }
    /// The record shows the queue or the recents on its back.
    var backShown: Bool { queueShown || recentsFlipped }
    var onRecentPlay: (QueueItem) -> Void = { _ in }
    var onRecentAdd: (QueueItem) -> Void = { _ in }
    var onRecentRemove: (QueueItem) -> Void = { _ in }
    var onQueueRemove: (Set<UUID>) -> Void = { _ in }
    var onQueueMove: (Set<UUID>, Int) -> Void = { _, _ in }
    var onQueuePlayNext: (UUID) -> Void = { _ in }
    var onQueueToggle: () -> Void = {}
    /// Songs dropped on Add to Queue, after the song that plays with `next`.
    var onAdd: ([URL], Bool) -> Void = { _, _ in }
    /// The ⋯ button in the corner.
    var onMore: () -> Void = {}

    /// The waveform of the song, with its zoom, its lanes and the region loop, in their own object so that the
    /// waveform redraws without the rest of the HUD.
    let wave = WaveState()
    /// Settings > HUD > Waveform, and W over the HUD.
    @Published var waveformShown = Preferences.shared.waveform
    @Published var waveformStyle = Preferences.shared.waveformStyle
    /// The region loop (R), on the waveform, the time bar and the lyrics.
    @Published var loop: LoopRegion?
    /// The chords of a song in Muskey Player, in its own key, over the lyrics. Empty while they aren't known.
    @Published var chords: [ChordMark] = []
    /// ⌥← and ⌥→ over the chords: the fret of a capo, which moves the chords shown down by as many semitones and leaves
    /// the song as it is.
    @Published var capo = 0
    var onLoopSet: (LoopEnd, Double) -> Void = { _, _ in }
    var onLoopTyping: (Bool) -> Void = { _ in }
    /// T over the HUD: the stems that can be transcribed into notes, in place of the key column.
    @Published var notesPicking: NotesPicking?
    var onNotesSelect: (Stem) -> Void = { _ in }
    var onNotesStart: () -> Void = {}
    var onNotesStartFull: () -> Void = {}
    /// The whole song (true) or the region loop (false), in T's picker while a region loop is set.
    var onNotesPart: (Bool) -> Void = { _ in }
}

/// The waveform of the song that plays: whole for a file, and drawn while it plays for a song from another player.
final class WaveState: ObservableObject {
    @Published var waveform: SongWaveform?
    /// 1 shows the whole song, and more shows a close-up of the moments around the playhead (⌘+ and ⌘−, a pinch, ⌘
    /// with a scroll).
    @Published var zoom = 1.0
    /// ⌥W: one lane per picked stem, while the stems of the whole song are known.
    @Published var lanes = false
    /// The share of the song separated while ⌥W waits for the stems of the whole song, nil when it doesn't wait.
    @Published var lanesSeparating: Double?
    /// The stems that get a lane, picked with the chips under the lanes and kept for the next songs.
    @Published var laneStems = Preferences.shared.waveformLanes
    /// The pointer is over the waveform, and its keys take the place of the hints row, or of the song's lines on the card.
    @Published var hovered = false
    /// The end of the region loop whose tab is under the pointer, which ← and → nudge. An end that a nudge moved out
    /// from under a pointer that stayed still stays the one that they nudge until the pointer moves, so that the
    /// arrows don't start moving the song instead.
    @Published var loopEnd: LoopEnd?
    /// The end whose tab is under the pointer, as the tab's hover says.
    private var pointerEnd: LoopEnd?
    /// Where the pointer was when an end of the loop last moved.
    var endMovedUnder: NSPoint?

    static let zoomLimit = 40.0

    /// The tab of an end got the pointer or lost it. A tab that moved away from a pointer that stayed where it was when
    /// the end moved keeps its end.
    func hoverEnd(_ end: LoopEnd?) {
        pointerEnd = end
        if end == nil, loopEnd != nil, endMovedUnder == NSEvent.mouseLocation { return }
        if loopEnd != end { loopEnd = end }
    }

    /// The pointer moved, so an end kept after a nudge gives way to the one under the pointer.
    func pointerMoved() {
        if loopEnd != pointerEnd { loopEnd = pointerEnd }
    }

    func clearEnd() {
        pointerEnd = nil
        endMovedUnder = nil
        if loopEnd != nil { loopEnd = nil }
    }

    func toggleLane(_ stem: Stem) {
        if laneStems.contains(stem) { laneStems.remove(stem) } else { laneStems.insert(stem) }
        Preferences.shared.waveformLanes = laneStems
    }

    func zoom(by factor: Double) {
        let next = min(Self.zoomLimit, max(1, zoom * factor))
        // Close to 1 means the whole song, so the last step out lands on it exactly. Only a step out snaps: a pinch
        // and a ⌘ scroll zoom in by 1–3% an event, which snapped back to the whole song on every event.
        zoom = factor < 1 && next < 1.08 ? 1 : next
    }
}

/// The level of each stem, in the order of `Stem`, 20 times a second while the stems play and the HUD shows.
/// A flag that the main thread sets and another thread reads, such as Stop Here for a transcription that runs.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

final class StemMeters: ObservableObject {
    @Published var levels = [Float](repeating: 0, count: Stem.allCases.count)
}

/// What a scroll over the HUD adjusts: the tempo of a song in Muskey Player, the volume of a stem, or the place in
/// the song, over the time bar.
enum ScrollRegion: Hashable {
    case tempo
    case stem(Stem)
    case timeBar
    /// The waveform, where a scroll moves the song as over the time bar, and ⌘ with a scroll zooms.
    case waveform

    /// A scroll here moves the song, sideways as well as up and down.
    var seeks: Bool { self == .timeBar || self == .waveform }
}

/// The scroll that adjusts the tempo or a stem, in its own object so that the lift redraws only what it moves.
final class ScrollFeel: ObservableObject {
    /// What the scroll that goes on adjusts.
    @Published var region: ScrollRegion?
    /// How far the fingers moved since the scroll began, from −1 down to 1 up, which lifts what they adjust.
    @Published var lift: CGFloat = 0
    /// Where each adjustable thing is in the HUD, in the coordinates of the HUD's window from its top left, by the
    /// view that shows it. The stems that fade out under the lyrics and the ones that fade in under the keys are both
    /// there for a moment, and each takes only its own place away.
    private(set) var frames: [UUID: (region: ScrollRegion, frame: CGRect)] = [:]

    func place(_ region: ScrollRegion, at frame: CGRect, by owner: UUID) { frames[owner] = (region, frame) }
    func remove(by owner: UUID) { frames[owner] = nil }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var tint = Tint.current
    @Environment(\.colorScheme) private var colorScheme
    /// Hides the key row or the instruments of karaoke a moment after the pointer leaves them.
    @State private var keysCollapse: Task<Void, Never>?
    @State private var stemsCollapse: Task<Void, Never>?

    /// The key strip shows with the first estimate and stays on the result. Using it pins the HUD open.
    private var showsStrip: Bool { model.key != nil && (model.picking || model.phase == .done || model.phase == .listening) }

    /// How much taller the card gets when the stems take the place of the Separate instruments and vocals button.
    private static let cardStemsGrowth: CGFloat = 79.5
    /// The wide glass with the key row and the Separate instruments and vocals button, whose top edge stays where it was
    /// while the glass was centred in the panel.
    private static let wideUsualHeight: CGFloat = 322

    private var cardStemsOpen: Bool { model.card && model.saving == nil && (model.opening == nil || model.openingGlass != nil) && !focus && showsStrip && model.stemsAvailable && model.stemsOpen && !model.shortcuts }

    /// The ✕ closes the HUD while it stays up: with the key row, a listen, its result, or nothing playing. A failed
    /// listen closes by itself.
    private var closable: Bool { model.mic != nil || model.picking || model.opening != nil || [.listening, .done, .idle].contains(model.phase) }
    private var showsSave: Bool { model.mic == nil && showsStrip && model.saving == nil && model.opening == nil && !model.shortcuts && !focus && model.savable && !(model.card && model.queueShown) }

    /// The large lyrics take the place of either layout.
    private var focus: Bool { model.saving == nil && model.opening == nil && !model.shortcuts && model.lyricsFocus && model.lyricsShown && showsStrip }

    /// The record shows while a song with a title plays, from the start of a listen.
    private var deckTrack: NowPlaying.Track? {
        // Nothing plays: an empty record, which plays whatever macOS played last.
        if model.phase == .idle { return NowPlaying.Track() }
        guard model.phase == .listening || model.phase == .done, let track = model.track, track.title?.isEmpty == false else { return nil }
        return track
    }

    /// The record of the song that plays while another one opens.
    private var openingDeck: OpeningDeck? {
        guard model.openingOverSong, let track = model.track, track.title?.isEmpty == false else { return nil }
        return OpeningDeck(track: track, artwork: model.artwork, playing: model.playing, spinning: model.shown && model.playing, flash: model.playFlash,
                           glass: model.openingGlass, relativeKeys: model.relativeKeys)
    }

    /// The timing of karaoke's lyrics while they don't come with times, for the status in its top row. The key row
    /// covers the top row while it shows.
    private var karaokeTiming: Lyrics.Timing? {
        guard focus, !model.karaokeKeys, case let .found(lyrics) = model.lyrics, lyrics.timing == .estimated || lyrics.timing == .written else { return nil }
        return lyrics.timing
    }

    var body: some View {
        let palette = Palette.of(colorScheme)
        Group {
            if let mic = model.mic {
                // A recording from the microphone takes the whole HUD until it stops.
                MicCard(mic: mic, palette: palette, stop: model.onMicStop, cancel: model.onMicCancel, edit: model.onMicEdit)
                    .transition(.opacity)
            } else if let saving = model.saving {
                // A save takes the whole HUD until it ends, in a compact layout with the record, so nothing else
                // changes while the song is saved.
                SavingCard(saving: saving, track: model.track?.title?.isEmpty == false ? model.track : nil, artwork: model.artwork,
                           spinning: model.shown && (saving.left == nil || model.playing), palette: palette,
                           cancel: model.onSaveCancel, stop: model.onSaveStop)
                    .transition(.opacity)
            } else if let opening = model.opening {
                // A song that opens takes the HUD until it plays, in the shape of the layout that it plays in.
                OpeningView(opening: opening, card: model.card, palette: palette, deck: openingDeck, cancel: model.onOpenCancel,
                            background: model.onOpenBackground, retry: model.onOpenRetry, install: model.onOpenInstall, dismiss: model.onOpenCancel)
                    .transition(.opacity)
            } else if model.shortcuts {
                // Every key and gesture, in place of the layout that they work on, until ?, Escape or the ✕ closes
                // them. A key opens them, so they show at once.
                ShortcutsSheet(card: model.card, otherMode: model.key.map { $0.minor != model.relative ? "major" : "minor" } ?? "major",
                               hotkey: Preferences.shared.hotkey.symbols, palette: palette) { model.shortcuts = false }
            } else if focus {
                lyricsFocus(palette)
            } else if model.card, let picking = model.notesPicking {
                // T shows the stems to transcribe in place of the card.
                NotesStemPicker(picking: picking, palette: palette, select: model.onNotesSelect, start: model.onNotesStart, startFull: model.onNotesStartFull,
                                pickPart: model.onNotesPart)
                    .padding(.horizontal, 22)
                    .padding(.top, 44)
                    .padding(.bottom, 18)
            } else if model.card {
                // Q turns the card over to the queue, and Nothing playing turns it over to the recents.
                FlipCard(flipped: model.backShown) {
                    HUDCard(model: model, palette: palette, showsKeys: showsStrip, track: deckTrack)
                } back: {
                    back(palette)
                        .padding(.top, 12)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 14)
                }
            } else {
                wide(palette)
            }
        }
        // Sized to its content: the main column fills only the width that the hint bar adds.
        // A glass held at its size gives the layout its whole width, which keeps the record at the same place.
        .fixedSize(horizontal: model.heldGlass == nil, vertical: true)
        .frame(width: model.heldGlass?.width)
        .frame(minWidth: 180, minHeight: max(92, model.heldGlass?.height ?? 0), alignment: .top)
        .overlay(alignment: .topLeading) {
            // In karaoke, the close button, the timing of the lyrics, the key, the lyrics' source and the karaoke button
            // sit in one row.
            if closable || karaokeTiming != nil || showsSave {
                HStack(spacing: 10) {
                    if closable {
                        // Over the shortcuts, the ✕ closes them and leaves the HUD open, as Escape does.
                        // A song that opens covers the shortcuts, so there the ✕ closes the HUD.
                        CloseButton(size: focus ? 16 : 14, action: { if model.shortcuts, model.opening == nil { model.shortcuts = false } else { model.onClose() } })
                            .transition(.opacity)
                    }
                    // Beside the ✕ rather than in the row at the top right, where the card's record reached under it.
                    if showsSave {
                        RoundButton(symbol: "square.and.arrow.down", help: "Save the song with its changes (⌘S)", label: "Save", key: "⌘S",
                                    labelAfter: true, palette: palette, action: model.onSave)
                            .transition(.opacity)
                    }
                    if let timing = karaokeTiming {
                        LyricsTimingStatus(timing: timing, downloading: model.lyricsDownloading, writing: model.lyricsWriting && !model.lyricsSkipped,
                                           palette: palette, large: true)
                            .padding(.leading, model.picking ? 0 : 3)
                            .transition(.opacity)
                    }
                }
                .frame(height: focus ? 16 : 14)
                .padding(focus ? 15 : 12)
                .modifier(FocusDim(on: focus))
            }
        }
        .overlay(alignment: .topTrailing) {
            // The queue has its own button in this corner, and the other buttons wait until it turns back.
            if showsStrip, model.mic == nil, model.saving == nil, model.opening == nil, !model.shortcuts, !model.queueShown {
                HStack(spacing: 6) {
                    // Karaoke keeps only its own button, which closes it.
                    if !focus {
                        RoundButton(symbol: "quote.bubble", help: model.lyricsShown ? "Close the lyrics (L)" : "Show the lyrics (L)", label: "Lyrics", key: "L",
                                    isOn: model.lyricsShown, palette: palette, action: model.onLyrics)
                            .transition(.opacity)
                    }
                    // Karaoke's lyrics name their source before its button, within reach of the pointer, and the Fix timing
                    // pill before it.
                    if focus, !model.karaokeKeys, case let .found(lyrics) = model.lyrics, lyrics.timing == .synced, let pill = model.timingPill {
                        LyricsTimingButton(pill: pill, palette: palette, large: true)
                            .transition(.opacity)
                    }
                    if focus, !model.karaokeKeys, case let .found(lyrics) = model.lyrics, let source = lyrics.source {
                        LyricsCredit(source: source, palette: palette, large: true)
                            .padding(.trailing, 4)
                            .transition(.opacity)
                    }
                    // Karaoke has a button too, besides Return and ⌘K, so that it can be found and clicked like the lyrics.
                    // Return opens it while the lyrics show, and ⌘K from the keys.
                    RoundButton(symbol: "music.microphone", help: focus ? "Close karaoke (↩)" : model.lyricsShown ? "Open karaoke (↩)" : "Open karaoke (⌘K)",
                                label: "Karaoke", key: model.lyricsShown ? "↩" : "⌘K", isOn: focus, size: focus ? 26 : 20, palette: palette,
                                action: model.onKaraoke)
                    // The layout is in the ⋯ menu, with S.
                    if !focus {
                        RoundButton(symbol: "ellipsis", help: model.otherPlayer ? "Waveform, layout and more" : "Queue, waveform and more", palette: palette,
                                    action: model.onMore)
                            .transition(.opacity)
                    }
                }
                .padding(focus ? 10 : 9)
                .modifier(FocusDim(on: focus))
                .transition(.opacity)
            }
        }
        // Songs dragged over the HUD blur it, and the zones where they can go show over it.
        .blur(radius: model.dropTargeted ? 8 : 0)
        // In light mode the dark record would show through the pale zones and under their text, so the HUD fades too.
        .opacity(model.dropTargeted && colorScheme == .light ? 0.45 : 1)
        .overlay {
            if model.dropTargeted {
                // While the queue has songs, a drag shows where the songs can go. With no queue to add to (an empty
                // one, or a song from another app), Play Now covers the whole HUD.
                DropZones(zone: model.dropZone, palette: Palette.of(colorScheme))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.dropTargeted)
        .animation(.smooth(duration: 0.3), value: model.saving == nil)
        // Opened by a key or a drop, so the step shows almost at once, and its changes don't animate the layout.
        .animation(.easeOut(duration: 0.12), value: model.opening == nil)
        .modifier(HUDBackground(tint: tint, scheme: colorScheme))
        .onDrop(of: SongDrop.types, delegate: SongDrop(model: model))
        .environment(\.recordRewinds, model.rewinds)
        .environment(\.songArriving, model.songArriving)
        .environment(\.recordActions, RecordActions(playPause: { model.onPlayPause() }, skip: { model.onSkip($0) }, scroll: model.scroll, scrub: model.scrub,
                                                    seek: { model.onSeekFraction($0) }, seekable: model.seekable, seekOff: model.seekOff,
                                                    seekWait: model.seekWait))
        .environment(\.recordPlaying, model.playing)
        .environment(\.songLoop, model.loop)
        .environment(\.songChords, model.chords.isEmpty ? nil : SongChords(marks: model.chords, shift: model.shift, capo: model.capo))
        .environment(\.lyricsTiming, model.timingPill)
        .environment(\.openURL, OpenURLAction { url in
            model.onLink(url)
            return .systemAction
        })
        .animation(.smooth(duration: 0.35), value: model.songArriving == nil)
        // A drag anywhere on the glass moves the panel (HUDPanel.sendEvent).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.glassFrame = $0 }
        .onHover { model.hovering = $0 }
        .animation(.snappy, value: model.phase)
        .animation(.snappy, value: model.picking)
        .animation(.snappy(duration: 0.25), value: model.shift)
        .animation(.snappy(duration: 0.25), value: model.relative)
        .animation(.snappy(duration: 0.2), value: model.keepKey)
        .animation(.smooth(duration: 0.4), value: model.key)
        .animation(.smooth(duration: 0.4), value: deckTrack?.song)
        .animation(.snappy(duration: 0.3), value: model.moved)
        .animation(.snappy(duration: 0.3), value: model.pending)
        .animation(.smooth(duration: 0.35), value: model.card)
        .animation(.snappy(duration: 0.3), value: model.relativeKeys)
        .animation(.snappy(duration: 0.3), value: model.lyricsShown)
        .animation(.snappy(duration: 0.3), value: model.stemsAvailable)
        .animation(.snappy(duration: 0.3), value: model.stemsOpen)
        // Karaoke is opened by a key or a click, so it shows almost at once instead of growing into place.
        .animation(.easeOut(duration: 0.12), value: model.lyricsFocus)
        .animation(.easeOut(duration: 0.15), value: model.keysActive)
        // The card is taller than the wide glass, so it grows up from where the bottom of the wide glass sits,
        // instead of reaching down toward the Dock. The stems open downward, which keeps the top of the card and its
        // corner buttons in place and the card inside the panel.
        .padding(.bottom, model.card && !focus ? HUDPanel.size.height / 2 - 150 - (cardStemsOpen ? Self.cardStemsGrowth : 0) : 0)
        // The wide glass keeps its top edge where a glass of its usual height has it, and grows down, so that the stems,
        // their button and the hints that come and go under the key row leave the title, the keys and the record in
        // place. Centred, every change of height moved the whole glass by half of it.
        .padding(.top, !model.card && !focus ? HUDPanel.size.height / 2 - Self.wideUsualHeight / 2 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: focus ? .center : model.card ? .bottom : .top)
    }

    /// The key beside the record, with the hint bar along the bottom, which has Lock Key and Stop Pitch Change at
    /// its right end.
    private func wide(_ palette: Palette) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Takes any width that the hint bar adds, so the record keeps the same gap on both sides: the side
                // padding of the glass on its right, and the same from the divider on its left.
                Group {
                    if let picking = model.notesPicking {
                        // T shows the stems to transcribe in place of the key column.
                        NotesStemPicker(picking: picking, palette: palette, select: model.onNotesSelect, start: model.onNotesStart, startFull: model.onNotesStartFull,
                                pickPart: model.onNotesPart)
                            .frame(maxHeight: .infinity)
                    } else if model.lyricsShown, showsStrip {
                        // The stems stay under the lyrics, which get shorter by as much, so the vocals can be muted
                        // while the lyrics show.
                        VStack(spacing: 10) {
                            LyricsPanel(state: model.lyrics, line: model.lyricLine, palette: palette, width: 470, height: lyricsHeight,
                                        downloading: model.lyricsDownloading, writing: model.lyricsWriting && !model.lyricsSkipped, waiting: model.lyricsWaiting, retry: model.onLyricsRetry,
                                        add: model.onLyricsEdit, edit: model.onLyricsEdit, showsFooter: false)
                            stems(palette)
                        }
                        .transition(.opacity)
                    } else {
                        main(palette)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                // The timing and the service of the lyrics, at the top right of this side, in the row of the close
                // button.
                .overlay(alignment: .topTrailing) {
                    if model.lyricsShown, showsStrip, case let .found(lyrics) = model.lyrics {
                        LyricsBadges(lyrics: lyrics, downloading: model.lyricsDownloading, writing: model.lyricsWriting && !model.lyricsSkipped, palette: palette)
                            .offset(y: -13)
                            .transition(.opacity)
                    }
                }
                if let track = deckTrack {
                    Rectangle()
                        .fill(palette.ink.opacity(0.1))
                        .frame(width: 1)
                        .padding(.leading, 30)
                        .transition(.opacity)
                    // Q turns this side over to the queue, which takes the margins around the record too.
                    FlipCard(flipped: model.backShown) {
                        TurntableDeck(track: track, artwork: model.artwork, playing: model.playing, spinning: model.shown && model.playing,
                                      flash: model.playFlash, palette: palette)
                            .onHover { model.overRecord = $0 && !model.backShown }
                    } back: {
                        back(palette)
                            .padding(.horizontal, -20)
                            .padding(.top, -8)
                    }
                    .padding(.leading, 30)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, showsStrip ? 16 : 22)

            if showsStrip, let key = model.key {
                HStack(spacing: 16) {
                    // The stem picker of T has its own keys under it, and the keys of the key row don't work while it shows.
                    WaveformKeysSwap(wave: model.wave, alignment: .leading, seek: model.seekable, loop: model.loop != nil, palette: palette) {
                        KeyHints(lyrics: model.lyricsShown, vocals: model.stemsAvailable, seek: model.seekable, restart: model.restartable, chords: !model.chords.isEmpty, otherMode: key.minor != model.relative ? "major" : "minor", palette: palette)
                    }
                    .opacity(model.notesPicking == nil ? model.hintsOpacity : 0)
                    Spacer(minLength: 0)
                    // The ? button sits as close to Lock Key as Stop Pitch Change does.
                    HStack(spacing: 6) {
                        PitchControls(model: model, palette: palette, small: true)
                        RoundButton(symbol: "questionmark", help: "Shortcuts (?)", isOn: model.shortcuts, size: HUDButton.questionSize, palette: palette) { model.shortcuts.toggle() }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.leading, 20)
                .padding(.trailing, 10)
                .padding(.vertical, 7)
                .background(palette.ink.opacity(0.04))
                .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.1)).frame(height: 1) }
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
                .transition(.opacity)
            }
        }
    }

    /// The back of the record: the recents while nothing plays, the queue otherwise.
    @ViewBuilder private func back(_ palette: Palette) -> some View {
        if model.recentsFlipped {
            VStack(spacing: 12) {
                RecentsView(songs: model.recents, selection: model.recentsSelection, palette: palette, compact: !model.card, play: model.onRecentPlay, add: model.onRecentAdd,
                            remove: model.onRecentRemove, close: { model.recentsShown = false }, frame: { model.queueFrame = $0 },
                            headerInset: model.card ? 22 : 0)
                // The whole card turns over, so the buttons of Nothing playing come along under the recents.
                if model.card { IdleActions(model: model, palette: palette) }
            }
        } else {
            queue(palette)
        }
    }

    /// The queue, on the back of the record in the wide layout and on the back of the card.
    private func queue(_ palette: Palette) -> some View {
        QueueView(songs: model.queue, current: model.queueCurrent, selection: $model.queueSelection, palette: palette, compact: !model.card,
                  play: model.onQueuePlay, remove: model.onQueueRemove, move: model.onQueueMove, playNext: model.onQueuePlayNext,
                  close: model.onQueueToggle, frame: { model.queueFrame = $0 }, headerInset: model.card ? 22 : 0)
    }

    /// The title fills as the listen goes on, so there is no progress bar under it.
    private func main(_ palette: Palette) -> some View {
        VStack(spacing: 7) {
            VStack(spacing: 12) {
            TitleLine(model: model, palette: palette, optionHint: true)
            if model.phase == .idle {
                IdleActions(model: model, palette: palette)
                    .transition(.opacity)
            }
            if model.pending ?? model.heard != nil {
                ShiftPills(model: model, palette: palette)
                    .padding(.top, -6)
            }
            if showsStrip, let key = model.key {
                KeyPicker(original: key, shift: model.shift, relative: model.relative, showsRelatives: model.relativeKeys, flipped: model.flipped != model.relative,
                          accidentals: model.accidentals, palette: palette, select: model.onShift)
                    // The row still has the last song's keys while a new song waits for its key.
                    .opacity(model.pending == nil ? 1 : 0.4)
                    .allowsHitTesting(model.pending == nil)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
            if showsWaveform(.ribbon) {
                waveform(palette, width: Self.keyRowWidth - 14, height: 40)
                    .transition(.opacity)
            }
            // A recording from the microphone: its parts along the waveform, and how readily each kind is heard.
            if let recording = model.recording, showsStrip {
                VStack(spacing: 8) {
                    RecordingStrip(analysis: recording, palette: palette, edit: model.onRecordingEdit)
                        .frame(width: Self.keyRowWidth - 14, height: 16)
                    SensitivityRow(sensitivity: recording.sensitivity, palette: palette, titled: false) { sensitivity in
                        var changed = recording
                        changed.sensitivity = sensitivity
                        model.onRecordingEdit(changed)
                    }
                }
                .padding(.top, -4)
                .transition(.opacity)
            }
            }
            // The key sits at the top of the space above the stems rather than in its middle, so that the stems, which
            // take more of that space than their button, leave the title and the keys where they are.
            .frame(maxHeight: .infinity, alignment: .top)
            // The stems stay at the bottom of this column, beside the record, so they don't make the glass taller.
            stems(palette)
        }
        // The strip grows up from the hints bar across the whole column, behind the stems and their button.
        .background(alignment: .bottom) {
            if showsWaveform(.strip) {
                GeometryReader { column in
                    waveform(palette, width: column.size.width + 40, height: 30)
                        .frame(width: column.size.width + 40, height: 30)
                        .offset(x: -20, y: column.size.height - 30 + 16)
                }
                .transition(.opacity)
            }
        }
    }

    /// The waveform shows in `style` while a song with a length plays and the key row shows.
    private func showsWaveform(_ style: WaveformStyle) -> Bool {
        showsStrip && model.key != nil && model.waveformShown && model.waveformStyle == style && deckTrack?.duration != nil && model.phase != .idle
    }

    private func waveform(_ palette: Palette, width: CGFloat, height: CGFloat) -> some View {
        WaveformHost(wave: model.wave, track: deckTrack, style: model.waveformStyle, width: width, height: height, ticking: model.shown && model.playing,
                     bpm: model.shownTempo?.bpm, muted: model.stemsMuted, loop: model.loop, setLoop: model.onLoopSet, typing: model.onLoopTyping, palette: palette)
    }

    /// Karaoke: the lyrics large in a glass as tall as the screen allows, with the key at the top and the record
    /// rising from the bottom edge. The key turns into the key row while the pointer is over it, and the cover in the
    /// middle of the record shows the instruments and vocals. With no song playing there is no record, and the hints
    /// sit under the lyrics, dimmed until the pointer is over them.
    private func lyricsFocus(_ palette: Palette) -> some View {
        let track = deckTrack
        return VStack(spacing: 0) {
            // The key's place in the top row, which the overlay fills.
            Color.clear.frame(height: Self.focusRowHeight).padding(.top, Self.focusRowTop)
            GeometryReader { space in
                LyricsPanel(state: model.lyrics, line: model.lyricLine, palette: palette, width: Self.focusLyricsWidth, height: space.size.height, large: true,
                            downloading: model.lyricsDownloading, writing: model.lyricsWriting && !model.lyricsSkipped, waiting: model.lyricsWaiting,
                            rewind: model.karaokeCountdown, retry: model.onLyricsRetry, add: model.onLyricsEdit, edit: model.onLyricsEdit)
                    .overlay { if track == nil { PlayFlashView(flash: model.playFlash, size: 80) } }
            }
            .frame(width: Self.focusLyricsWidth)
            .padding(.top, 8)
            if let track {
                KaraokeRecord(track: track, artwork: model.artwork, spinning: model.shown && model.playing, flash: model.playFlash, side: recordSide,
                              width: Self.focusWidth, palette: palette, hoverLabel: { karaokeHover($0, \.karaokeStems, $stemsCollapse) }) {
                    karaokeFooter
                }
                .overlay(alignment: .bottom) { karaokeStems(palette) }
                .padding(.top, 6)
            } else {
                VStack(spacing: 8) {
                    if let track = deckTrack {
                        Text([track.title, track.artist].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: Self.focusLyricsWidth)
                    }
                    // FocusDim makes these faint without the pointer, so they get no second dim.
                    KeyHints(lyrics: true, focus: true, vocals: model.stemsAvailable, seek: model.seekable, restart: model.restartable, karaokeKeys: model.karaokeKeys, chords: !model.chords.isEmpty, otherMode: otherMode,
                             palette: palette)
                }
                .modifier(FocusDim(on: true))
                // Without the record, the song and the hints show the instruments and vocals.
                .onHover { karaokeHover($0, \.karaokeStems, $stemsCollapse) }
                .overlay(alignment: .bottom) { karaokeStems(palette).padding(.bottom, 40) }
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(width: Self.focusWidth, height: focusHeight)
        .overlay(alignment: .top) { karaokeKey(palette).padding(.top, Self.focusRowTop) }
        .overlay { if track != nil { karaokeTransport(palette) } }
    }

    /// Karaoke's playback buttons, in a pill of their own between the lyrics and the record, which doesn't hold them,
    /// since its cover shows the instruments and vocals.
    private func karaokeTransport(_ palette: Palette) -> some View {
        KaraokeTransport(size: 30, ink: palette.ink)
            .padding(.horizontal, 4)
            .background(Capsule().fill(palette.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(palette.ink.opacity(0.1), lineWidth: 0.5))
            .modifier(FocusDim(on: true))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, KaraokeRecord<EmptyView>.height(side: recordSide) + 2)
    }

    /// The mode that Option picks keys in: the one that the key row hides.
    private var otherMode: String { model.key.map { $0.minor != model.relative ? "major" : "minor" } ?? "" }

    /// The hints along the bottom edge of the record, no wider than the record: the keys of the lyrics, or the keys
    /// that change the key while the key row shows.
    private var karaokeFooter: some View {
        KeyHints(style: .footer, lyrics: true, focus: true, vocals: model.stemsAvailable, seek: model.seekable, restart: model.restartable, karaokeKeys: model.karaokeKeys, chords: !model.chords.isEmpty, otherMode: otherMode,
                 palette: Palette.of(.dark))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 5)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                    .fill(Color(white: 0.06).opacity(0.75))
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 8) }
            }
            .environment(\.colorScheme, .dark)
            .opacity(model.hintsOpacity)
    }

    /// The key in the top row, which turns into the key row while the pointer is over it.
    /// The key at the top of karaoke, which opens the key row while the pointer is over it. With the instruments
    /// model, the Vocals pill sits under the key, and the key row takes the pill's place while it is open. Only the
    /// key opens the row, never the pill.
    private func karaokeKey(_ palette: Palette) -> some View {
        let pill = model.stemsAvailable && showsStrip
        return VStack(spacing: 6) {
            ZStack(alignment: .top) {
                if model.karaokeKeys, !pill, let key = model.key {
                    karaokeKeyRow(key, palette)
                } else {
                    TitleLine(model: model, palette: palette, symbolSize: 13, keySize: 15, relativeSize: 11, listeningSize: 15)
                        .frame(height: Self.focusRowHeight)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                        .opacity(0.75)
                        .transition(.opacity)
                }
            }
            .onHover { karaokeHover($0, \.karaokeKeys, $keysCollapse) }
            if pill {
                if model.karaokeKeys, let key = model.key {
                    karaokeKeyRow(key, palette)
                        .onHover { karaokeHover($0, \.karaokeKeys, $keysCollapse) }
                } else {
                    KaraokeVocalsPill(muted: model.stemsMuted.contains(.vocals), hudHovered: model.hovering, palette: palette, action: model.onVocals)
                        .transition(.opacity)
                }
            }
        }
    }

    private func karaokeKeyRow(_ key: DetectedKey, _ palette: Palette) -> some View {
        KeyPicker(original: key, shift: model.shift, relative: model.relative, showsRelatives: model.relativeKeys, flipped: model.flipped != model.relative,
                  accidentals: model.accidentals, palette: palette, select: model.onShift)
            // A new song still waits for its key.
            .opacity(model.pending == nil ? 1 : 0.4)
            .allowsHitTesting(model.pending == nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(KaraokePopup())
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    /// The instruments and vocals over the record's cover while the pointer is over it, or the button that separates
    /// them. The number keys mute and solo them without the pointer there too.
    @ViewBuilder private func karaokeStems(_ palette: Palette) -> some View {
        if model.karaokeStems, showsStrip, model.stemsAvailable {
            Group {
                if model.stemsOpen {
                    StemsRow(model: model, palette: palette, compact: true)
                        .frame(width: Self.keyRowWidth)
                } else {
                    SeparateButton(palette: palette, action: model.onSeparate)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(KaraokePopup())
            .padding(.bottom, 30)
            .onHover { karaokeHover($0, \.karaokeStems, $stemsCollapse) }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        }
    }

    /// Shows a part of karaoke while the pointer is over its spot, and hides it a moment after the pointer leaves, so
    /// that the pointer can move from the spot onto what it shows.
    private func karaokeHover(_ inside: Bool, _ flag: ReferenceWritableKeyPath<HUDModel, Bool>, _ collapse: Binding<Task<Void, Never>?>) {
        collapse.wrappedValue?.cancel()
        if inside {
            guard !model[keyPath: flag] else { return }
            withAnimation(.snappy(duration: 0.2)) { model[keyPath: flag] = true }
        } else {
            collapse.wrappedValue = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.2)) { model[keyPath: flag] = false }
            }
        }
    }

    /// The record fills the glass's width, short of the corners that hold the times, and leaves the lyrics at least
    /// 300 points on a short screen.
    private var recordSide: CGFloat { min(540, max(360, (focusHeight - 340) * 2)) }

    private static let focusRowTop: CGFloat = 10
    private static let focusRowHeight: CGFloat = 26
    private static var focusWidth: CGFloat { focusLyricsWidth + 56 }

    /// The large lyrics fill the screen's height, with a margin, up to a height that still reads as one glass.
    private var focusHeight: CGFloat { min(Self.focusMaxHeight, max(560, model.screenHeight - 2 * HUDPanel.screenMargin)) }
    static let focusMaxHeight: CGFloat = 1000
    private static let focusLyricsWidth: CGFloat = 600

    /// The Separate instruments and vocals button, or the stems in its place, under the keys or the lyrics.
    @ViewBuilder private func stems(_ palette: Palette) -> some View {
        if showsStrip, model.stemsAvailable {
            if model.stemsOpen {
                StemsRow(model: model, palette: palette, compact: true)
                    .frame(width: Self.keyRowWidth)
                    .transition(.opacity)
            } else {
                SeparateButton(palette: palette, action: model.onSeparate)
                    // Quiet until the pointer is over it, so the keys read first.
                    .modifier(FocusDim(on: true))
                    .transition(.opacity)
            }
        }
    }

    /// The lyrics in the wide layout keep the glass at the same height with the stems or the button under them.
    private var lyricsHeight: CGFloat {
        guard model.stemsAvailable else { return 250 }
        // The stems are smaller while the pointer is away from the HUD, and the lyrics take the room that they leave.
        return model.stemsOpen ? 250 - (model.keysActive ? Self.stemsRowHeight : Self.compactStemsRowHeight) : 250 - Self.separateButtonHeight
    }

    private static let stemsRowHeight: CGFloat = 106
    private static let compactStemsRowHeight: CGFloat = 72
    private static let separateButtonHeight: CGFloat = 34

    /// The width of the key row, which the stems under it match.
    private static let keyRowWidth: CGFloat = 466
}

/// The glass of the key row and the instruments that karaoke shows over the lyrics and the record.
private struct KaraokePopup: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        shape.fill(scheme == .dark ? Color(white: 0.13).opacity(0.96) : Color(red: 0.99, green: 0.97, blue: 0.95).opacity(0.97))
            .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.08 : 0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}

/// Everything around the large lyrics fades back until the pointer is over it, and so do the busy buttons of the
/// layouts.
struct FocusDim: ViewModifier {
    let on: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .opacity(on && !hovering ? 0.3 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.25), value: on)
    }
}

/// How the HUD glass gets its warmth. `.tint()` colours the glass itself, so a pale tint vanishes and a saturated one
/// reads as a coloured button. Instead, a translucent base layer and a soft glow are painted inside regular glass.
struct Tint: Hashable {
    var baseLight = 0.38
    var baseDark = 0.45
    var glow = 0.6
    var tone = 0.3

    static let current = Tint()
}

struct HUDBackground: ViewModifier {
    let tint: Tint
    let scheme: ColorScheme
    @Environment(\.renderingPreview) private var renderingPreview

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
    // Warm skin tones in light mode, near black warmed with ember in dark mode.
    private static let flesh = rgb(0.97, 0.89, 0.84)
    private static let peach = rgb(0.95, 0.72, 0.62)
    private static let ember = rgb(0.36, 0.09, 0.15)

    private var dark: Bool { scheme == .dark }

    private func color(_ color: Color, _ opacity: Double, glow: Bool = true) -> Color {
        color.mix(with: dark ? .black : .white, by: tint.tone).opacity(min(1, opacity * (glow ? tint.glow : 1)))
    }

    private func radial(_ color: Color, _ center: UnitPoint, _ radius: CGFloat) -> RadialGradient {
        RadialGradient(colors: [color, .clear], center: center, startRadius: 0, endRadius: radius)
    }

    private var base: Color {
        dark ? Color.black.opacity(tint.baseDark) : color(Self.flesh, tint.baseLight, glow: false)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26)
        let painted = content.background { layers(shape).opacity(0.5).brightness(dark ? -0.4 : 0.4) }
        if renderingPreview {
            // ImageRenderer draws neither glass nor what sits inside it, so previews put the layers on a flat stand-in.
            painted.background(shape.fill(Color(white: dark ? 0.2 : 0.97)))
        } else {
            painted.glassEffect(.regular, in: shape)
        }
    }

    private func layers(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(base)
            shape.fill(radial(dark ? color(Self.ember, 0.55) : color(Self.peach, 0.55), .bottomLeading, 300))
        }
    }
}

/// The first click on a button in the HUD acts on it, instead of only making the panel key.
/// A SwiftUI control in the HUD that a drag adjusts, which the panel leaves the drag to instead of moving with it.
struct KeepsDrag: ViewModifier {
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { HUDPanel.dragKeepers[token] = $0 }
            .onDisappear { HUDPanel.dragKeepers[token] = nil }
    }
}

extension View {
    func keepsDrag() -> some View { modifier(KeepsDrag()) }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

final class HUDPanel: NSPanel {
    /// Tall enough for the large lyrics at their tallest, and for the single card with the stems, which grows up
    /// from where the bottom of the wide glass sits.
    static let size = CGSize(width: 900, height: HUDView.focusMaxHeight + 100)
    /// The glass stays at least this far inside the visible part of its screen.
    static let screenMargin: CGFloat = 12

    /// Only while a key is being picked, so Esc and the arrow keys reach the HUD. The panel is non-activating,
    /// so the app in front stays in front.
    private var takesKeyboard = false
    override var canBecomeKey: Bool { takesKeyboard || holdsFront }
    /// While the pointer over the HUD keeps Muskey the active app with another window of Muskey open, the panel is its
    /// key and main window, since an app that becomes active brings its key and main windows in front: Settings or the
    /// notes window came up over the app that was in front.
    var holdsFront = false
    override var canBecomeMain: Bool { holdsFront }

    /// A key typed while the panel holds the front only for the pointer was meant for the app that was in front, and
    /// makes no sound.
    override func noResponder(for eventSelector: Selector) {
        if holdsFront, !takesKeyboard, eventSelector == #selector(NSResponder.keyDown(with:)) { return }
        super.noResponder(for: eventSelector)
    }
    private let model: HUDModel

    init(model: HUDModel) {
        self.model = model
        // Room for the key picker and the record; the transparent margin around the glass lets clicks through.
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = FirstClickHostingView(rootView: HUDView(model: model))
    }

    /// `clickable` for a result with a Change Key button, `keyboard` while a key is being picked.
    /// The panel stops being key when it is ordered out after the fade.
    func setInteraction(clickable: Bool, keyboard: Bool) {
        let clickable = clickable && !headless, keyboard = keyboard && !headless
        wantsClicks = clickable
        watchPointer(clickable)
        updatePassThrough()
        takesKeyboard = keyboard
        if keyboard { makeKey() }
    }

    /// The panel takes the mouse only while the pointer is over the glass. The window server lets left clicks through
    /// the clear margin around the glass, but not right clicks, which then did nothing anywhere under the panel, and
    /// the pointer over the margin counted as over the HUD, which took its keys.
    private var wantsClicks = false
    private var pointerMonitors: [Any] = []

    func updatePassThrough() {
        // While the button is held after a press on the glass, the panel keeps the mouse, since a fast drag can take
        // the pointer past the edge of the glass before the panel catches up with it.
        let ignore = pressStart == nil && !(wantsClicks && overGlass(NSEvent.mouseLocation))
        if ignoresMouseEvents != ignore { ignoresMouseEvents = ignore }
    }

    /// A control that a drag along it moves, like the bar with the song's time, sets this while its drag runs, so
    /// that the drag doesn't move the panel instead.
    static var controlTracksDrag = false
    /// Where the SwiftUI controls that a drag adjusts sit in the panel, like the sliders and the strip of a recording,
    /// in the coordinates of the glass from its top left. A press there keeps its drag.
    static var dragKeepers: [UUID: CGRect] = [:]

    private func onDragKeeper(_ event: NSEvent) -> Bool {
        guard !Self.dragKeepers.isEmpty, let view = contentView else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return Self.dragKeepers.values.contains { $0.insetBy(dx: -3, dy: -3).contains(point) }
    }
    /// Where the pointer and the panel were when the mouse button went down on the glass.
    private var pressStart: (mouse: NSPoint, origin: NSPoint)?
    private var draggingPanel = false
    /// For the log: what the press landed on, when it went down, and whether a drag event came after it.
    private var pressHit = ""
    private var pressedAt = Date.distantPast
    private var pressDragged = false
    var log: (String, OSLogType) -> Void = { _, _ in }
    /// Runs on each move of the pointer while the panel takes clicks.
    var pointerMoved: () -> Void = {}

    /// The press is on the time bar, a little taller than the bar, which seeks with its drag.
    private func onTimeBar(_ event: NSEvent) -> Bool {
        guard let view = contentView else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return model.scroll.frames.values.contains { $0.region.seeks && $0.frame.insetBy(dx: -2, dy: -4).contains(point) }
    }

    private func onQueue(_ event: NSEvent) -> Bool {
        guard model.backShown, let queue = model.queueFrame, let view = contentView else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        return queue.contains(CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y))
    }

    /// A drag that starts anywhere on the glass moves the panel once the pointer has moved a few points, also from
    /// a button, the key or the record. SwiftUI's window drag gesture never moved this non-activating panel.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            Self.controlTracksDrag = false
            draggingPanel = false
            // Text fields, scroll bars and the time bar keep their drags.
            let hit = contentView?.hitTest(event.locationInWindow)
            let onBar = onTimeBar(event)
            // The list of the queue keeps its drags too, which move songs.
            pressStart = hit is NSControl || hit is NSText || onBar || onQueue(event) || onDragKeeper(event) ? nil : (NSEvent.mouseLocation, frame.origin)
            pressHit = onBar ? "the time bar" : hit.map { String(describing: type(of: $0)).components(separatedBy: "<").first ?? "" } ?? "nothing"
            pressedAt = Date()
            pressDragged = false
        case .leftMouseDragged:
            if !pressDragged {
                pressDragged = true
                log("HUD drag: pressed on \(pressHit), " + (pressStart == nil ? "which keeps the drag" : "the panel follows the drag"), .debug)
            }
            guard let start = pressStart, !Self.controlTracksDrag else { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
            if !draggingPanel {
                guard hypot(dx, dy) >= 4 else { break }
                draggingPanel = true
                // The drag sets the new place, so a move that kept the glass on the screen is forgotten.
                pushed = .zero
                heading = nil
            }
            setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
            return
        case .leftMouseUp:
            pressStart = nil
            // A press held this long is usually a drag, so a press without a single drag event means that the
            // system never sent the drag to the panel.
            if !pressDragged, Date().timeIntervalSince(pressedAt) > 0.4 {
                log(String(format: "HUD drag: pressed on %@ for %.1f s, with no drag events", pressHit, Date().timeIntervalSince(pressedAt)), .debug)
            }
            guard draggingPanel else { break }
            draggingPanel = false
            // The button or the record under the pointer would take this release as a click. SwiftUI gets it far
            // outside the panel instead, which ends the press without one.
            let outside = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10000, y: -10000), modifierFlags: event.modifierFlags,
                                             timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
                                             eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: 0)
            if let outside { super.sendEvent(outside) }
            updatePassThrough()
            return
        default: break
        }
        super.sendEvent(event)
    }

    /// The pointer is over the glass now, whatever SwiftUI's hover last said.
    var pointerOverGlass: Bool { isVisible && overGlass(NSEvent.mouseLocation) }
    /// The pointer is on the glass itself, without the margin that takes clicks, as SwiftUI's hover counts it.
    var pointerOnGlass: Bool { isVisible && !model.glassFrame.isEmpty && overGlass(NSEvent.mouseLocation, margin: 0) }

    private func overGlass(_ point: NSPoint, margin: CGFloat = 4) -> Bool {
        let glass = model.glassFrame
        guard !glass.isEmpty else { return true }
        // The glass frame is in the window's coordinates, from its top left.
        let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        return glass.insetBy(dx: -margin, dy: -margin).contains(local)
    }

    /// The pointer moves over other apps while the panel lets it through, and over the panel while it doesn't.
    private func watchPointer(_ on: Bool) {
        guard on != !pointerMonitors.isEmpty else { return }
        if on {
            acceptsMouseMovedEvents = true
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            pointerMonitors = [
                NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                    self?.updatePassThrough()
                    self?.pointerMoved()
                },
                NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                    self?.updatePassThrough()
                    self?.pointerMoved()
                    return event
                },
            ].compactMap { $0 }
        } else {
            pointerMonitors.forEach(NSEvent.removeMonitor)
            pointerMonitors = []
        }
    }

    /// The HUD runs without its window while a request from the phone runs, with Settings > Remote > Hide HUD for
    /// phone actions on: the panel isn't ordered in, and takes neither clicks nor the keyboard.
    var headless = false

    func present() {
        guard !headless else { return }
        // Already up: leave it where it is, even if the pointer has moved to another screen or the glass was dragged.
        guard !isVisible || alphaValue < 1 else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        pushed = .zero
        heading = nil
        if let visible = screen?.visibleFrame {
            // Where it was dragged to last, on the screen with the pointer, and kept on that screen below.
            let home = Self.home(on: visible, size: frame.size)
            let dragged = Self.dragged
            setFrameOrigin(NSPoint(x: home.x + dragged.dx, y: home.y + dragged.dy))
            if model.screenHeight != visible.height { model.screenHeight = visible.height }
        }
        keepOnScreen(animated: false)
        if !isVisible { alphaValue = 0 }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }

    /// Where the panel is headed while it moves there.
    private var heading: NSRect?
    /// How far the panel was moved to keep a growing glass on the screen, or to centre karaoke on it. It moves back
    /// once the glass fits where it was, as when karaoke closes.
    private var pushed = CGVector.zero
    /// Karaoke was dragged, and stays where it was dropped instead of being centred again.
    private var karaokeDragged = false

    /// The glass on the screen with the panel at `frame`, from where SwiftUI last laid it out in the panel.
    private func glassOnScreen(in frame: NSRect) -> CGRect? {
        let glass = model.glassFrame
        guard glass.width > 0, glass.height > 0 else { return nil }
        return CGRect(x: frame.minX + glass.minX, y: frame.maxY - glass.maxY, width: glass.width, height: glass.height)
    }

    /// The screen that holds most of the glass.
    private func screen(holding glass: CGRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(glass)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let best = NSScreen.screens.max { overlap($0) < overlap($1) }
        return best.flatMap { overlap($0) > 0 ? $0 : nil } ?? screen ?? NSScreen.main
    }

    /// Moves the panel so the whole glass is on the screen that holds most of it, when the glass grows, as the large
    /// lyrics do, and back to where it was once the glass shrinks. The large lyrics are sized for that screen, and
    /// karaoke opens in the middle of it, unless it was dragged since it opened. `start` is the place to keep on the
    /// screen in place of where the panel would be without its push.
    func keepOnScreen(animated: Bool, from start: NSRect? = nil) {
        if !model.lyricsFocus { karaokeDragged = false }
        let base = heading ?? frame
        let home = start ?? base.offsetBy(dx: -pushed.dx, dy: -pushed.dy)
        guard let glass = glassOnScreen(in: home), let screen = screen(holding: glass) else { return }
        let visible = screen.visibleFrame
        if model.screenHeight != visible.height { model.screenHeight = visible.height }
        // Only once the glass has karaoke's size: it is at least 560 points tall, and the other layouts never are.
        let centred = model.lyricsFocus && !karaokeDragged && glass.height >= 540
            ? CGVector(dx: visible.midX - glass.midX, dy: visible.midY - glass.midY) : .zero
        let inside = Self.offset(keeping: glass.offsetBy(dx: centred.dx, dy: centred.dy), inside: visible, margin: Self.screenMargin)
        let move = CGVector(dx: centred.dx + inside.dx, dy: centred.dy + inside.dy)
        pushed = move
        let target = home.offsetBy(dx: move.dx, dy: move.dy)
        guard target != base else { return }
        guard animated else {
            heading = nil
            return setFrame(target, display: true)
        }
        heading = target
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            if self?.heading == target { self?.heading = nil }
        })
    }

    /// A glass dropped partly off the screen moves fully onto it, and stays there as its new place.
    func settleAfterDrag() {
        if model.lyricsFocus { karaokeDragged = true }
        pushed = .zero
        heading = nil
        keepOnScreen(animated: true)
        pushed = .zero
        // Karaoke opens in the middle of the screen each time, so only a drag of the other layouts is kept.
        let target = heading ?? frame
        guard !model.lyricsFocus, let glass = glassOnScreen(in: target), let visible = screen(holding: glass)?.visibleFrame else { return }
        let home = Self.home(on: visible, size: frame.size)
        Self.dragged = CGVector(dx: target.minX - home.x, dy: target.minY - home.y)
    }

    /// ⌘⌥C: the HUD moves back to where it opens when it was never dragged, at the bottom centre of the screen that
    /// holds most of the glass, and forgets the place it was dragged to. Karaoke and the large lyrics are pushed from
    /// there as usual, so karaoke ends in the middle of the screen and the HUD comes back home when it closes.
    func returnHome() {
        Self.dragged = .zero
        karaokeDragged = false
        guard let glass = glassOnScreen(in: heading ?? frame), let visible = screen(holding: glass)?.visibleFrame else { return }
        let home = NSRect(origin: Self.home(on: visible, size: frame.size), size: frame.size)
        pushed = .zero
        log("HUD back to its home", .info)
        keepOnScreen(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, from: home)
    }

    /// The glass centred in the panel, at the same height as when the panel was 240 points tall: the place of a HUD
    /// that was never dragged.
    private static func home(on visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.14 + 120 - size.height / 2)
    }

    /// How far the HUD was dragged from its home, which it opens at the next time, on any screen.
    private static var dragged: CGVector {
        get {
            let values = UserDefaults.standard.array(forKey: "hudDragged") as? [Double] ?? []
            return values.count == 2 ? CGVector(dx: values[0], dy: values[1]) : .zero
        }
        set { UserDefaults.standard.set([Double(newValue.dx), Double(newValue.dy)], forKey: "hudDragged") }
    }

    /// How far `glass` has to move to sit inside `visible`, `margin` points from its edges, in screen points with y
    /// going up. A glass taller or wider than that keeps its top or its left edge inside.
    static func offset(keeping glass: CGRect, inside visible: CGRect, margin: CGFloat) -> CGVector {
        let area = visible.insetBy(dx: margin, dy: margin)
        func shift(_ low: CGFloat, _ high: CGFloat, within min: CGFloat, _ max: CGFloat, keepHigh: Bool) -> CGFloat {
            if high - low > max - min { return keepHigh ? max - high : min - low }
            if low < min { return min - low }
            if high > max { return max - high }
            return 0
        }
        return CGVector(dx: shift(glass.minX, glass.maxX, within: area.minX, area.maxX, keepHigh: false),
                        dy: shift(glass.minY, glass.maxY, within: area.minY, area.maxY, keepHigh: true))
    }

    func fadeOut(then completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; animator().alphaValue = 0 }, completionHandler: completion)
    }
}

/// Stays running with no Dock icon. The hotkey starts a listen, cancels a listen in progress, or closes the result.
/// A result can start a pitch change, which keeps running after the HUD closes.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let delegate = AppDelegate()

    static func main() {
        if TestFlags.has("--selftest") { exit(PitchSelfTest.run()) }
        if let path = TestFlags.value("--stems-cache") { exit(CachedStemsTest.runFile(path, speed: TestFlags.value("--speed").flatMap(Double.init) ?? 1)) }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// The key picker is `model.picking`, on top of any of these: it can open on the first estimate of a listen.
    private enum State { case idle, listening, showing }

    private let model = HUDModel()
    private lazy var panel: HUDPanel = {
        let panel = HUDPanel(model: model)
        panel.log = { [weak self] in self?.log($0, $1) }
        panel.pointerMoved = { [weak self] in
            self?.checkClipboard()
            self?.followPointer()
            self?.model.wave.pointerMoved()
            self?.hoverFocus(moved: true)
        }
        return panel
    }()
    /// When the clipboard was last checked for ⌘V over the HUD.
    private var clipboardCheckedAt = Date.distantPast

    /// Something copied while the pointer rests on the HUD turns ⌘V on or off there, from the pointer's next move.
    private func checkClipboard() {
        guard !hoverKeys.isEmpty, Date().timeIntervalSince(clipboardCheckedAt) > 0.25 else { return }
        clipboardCheckedAt = Date()
        if NSPasteboard.general.changeCount != hoverKeysPasteboard { updateHoverKeys() }
    }
    private var hotKey: HotKey?
    private var state = State.idle {
        // The activity pill shows a song that opens only while the HUD is closed.
        didSet { if state != oldValue { syncActivityPill() } }
    }
    // Bumped whenever a listen starts or ends, so late callbacks from a cancelled one are dropped.
    private var session = 0
    private var tap: SystemAudioTap?
    private var analyzer: KeyAnalyzer?
    private var ticker: Timer?
    private var startedAt = Date()
    /// The song played at some point of the listen, so a pause holds the listen instead of ending it.
    private var listenHeardPlaying = false
    /// When the song of the listen paused, which stopped the recording until it plays again, and that song.
    private var listenPausedAt: Date?
    private var listenPausedSong: [String?]?
    /// The sample rate that the listen's analyzer takes.
    private var listenTapRate: Double = 0
    private var peak: Float = 0
    /// The peak comes with each estimate, so before the first one a quiet listen can't be told from a late start.
    private var estimated = false

    private let pitch = PitchChanger(recordTo: stringOption("--shift-wav"))
    /// A song from another player slowed down, and the song as it is heard while it is.
    private lazy var slow = SlowStream(pitch: pitch)
    /// The player whose song is slowed down: another player taking over stops the slowing.
    private var slowedPlayer: String?
    /// The speed that a slowed song had before it was recorded for a save, which it gets back after it.
    private var speedBeforeRecording: Double?
    /// The player whose song Muskey had to stop slowing, while the red tempo pill shows it.
    private var slowFailedPlayer: String?
    private let statusItem = StatusItem()
    /// The key the running pitch change starts from, kept for the menu bar item after the HUD shows another listen.
    private var shiftBase: DetectedKey?
    /// The key of the song that plays, in the song's own key, for the menu bar: from a listen, from the keys
    /// remembered by song, from Always listening, or from Noiseblend. `song` is the song that Now Playing named, nil
    /// when it named none, `final` is false for an estimate that the end of the listen can still change, and `online`
    /// is true for a key that Noiseblend gave and no listen confirmed yet.
    private var songKey: (song: [String?]?, key: DetectedKey, final: Bool, online: Bool)? {
        didSet {
            if songKey?.key != oldValue?.key { log("menu bar: \(songKey.map(\.key.name) ?? "turntable")", .debug) }
            updateWatching(shown: model.shown)
            refreshStatus()
            // A key found after the notes window opened gives the notes their key signature.
            if let notes = notesWindow.model, let key = songKey?.key, notes.key != key, playsInFilePlayer, filePlayer.current?.path == notes.path {
                notes.key = key
            }
        }
    }

    /// The key that the song is heard in now, with the pitch change, as the menu bar shows it.
    private var currentKey: DetectedKey? {
        songKey.map { model.shown($0.key.transposed(by: model.shift)) }
    }

    // Always listening: a listen without the HUD for each song that plays with no key known.
    private var autoTap: SystemAudioTap?
    private var autoAnalyzer: KeyAnalyzer?
    private var autoSession = 0
    private var autoSong: [String?]?
    /// Listens that each song got without finding a key, so that a song that stays silent isn't listened to over
    /// and over.
    private var autoTries: [[String?]: Int] = [:]
    /// Clears the menu bar's key when Now Playing names no song for 2 seconds.
    private var noSong: DispatchWorkItem?

    private let nowPlaying = NowPlaying()
    /// Plays the files and links that Muskey opens, through Muskey Player.
    private let filePlayer = FilePlayer()
    /// Separates the whole song that Muskey Player plays into the cache, the first time that its stems are used.
    private let stemsCache = StemsCacheBuilder()
    private var cacheSweeper: Timer?
    private static let cacheSweepQueue = DispatchQueue(label: "Muskey cache cleanup", qos: .utility)
    /// The song whose stems were looked up in the cache last. It is looked up again for another song, or once its
    /// separation is done.
    private var stemsCacheLooked: String?
    /// Songs whose whole separation failed, which aren't separated whole again until Muskey quits.
    private var stemsCacheFailed: Set<String> = []
    private let activityPill = ActivityPill()
    private let mini = MiniState()
    private lazy var miniPanel: MiniPlayerPanel = {
        let panel = MiniPlayerPanel(model: model, mini: mini)
        panel.onSkip = { [weak self] in self?.skip($0) }
        panel.naturalSwipes = { [weak self] in self?.prefs.naturalSwipes ?? false }
        panel.onHover = { [weak self] _ in self?.updateMiniKeys() }
        return panel
    }()
    private lazy var locationPanel: OpenLocationPanel = {
        let panel = OpenLocationPanel()
        panel.onOpen = { [weak self] url in
            guard let self else { return }
            addingLocation ? add([url], next: false) : open([url])
        }
        if Self.logKeys { panel.onLog = { [weak self] in self?.log($0, .debug) } }
        // The HUD takes the keyboard back while a key is picked, and the app that was in front otherwise.
        panel.onClose = { [weak self] in
            guard let self else { return }
            dialogOpen = false
            if model.picking, self.panel.isVisible { return self.panel.makeKey() }
            if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
               let lastOtherApp, lastOtherApp != .current { frontAfterClose(lastOtherApp) }
        }
        return panel
    }()
    /// Files opened before the app finished launching, as with Open With.
    private var openedEarly: [URL]?
    private var launched = false
    /// The key that every song gets moved to when it starts playing: set while Lock Key is on, from the key that
    /// was heard when a key was picked or Lock Key was turned on.
    private var keptKey: DetectedKey? {
        didSet {
            // The button shows the lock itself, so it is never red while no key is locked, as after a relaunch.
            model.keepKey = keptKey != nil
            updateWatching(shown: model.shown)
            refreshStatus()
        }
    }
    private var shownChange: AnyCancellable?
    private var glassChange: AnyCancellable?
    private var karaokeChange: AnyCancellable?
    /// When karaoke last opened or closed.
    private var focusChangedAt = Date.distantPast
    private var glyphSheet: NSWindow?
    private var backdropChange: AnyCancellable?
    /// Blurs and dims the screen around the karaoke glass, and a click on it closes karaoke.
    private lazy var karaokeBackdrop: KaraokeBackdrops = {
        let backdrop = KaraokeBackdrops()
        backdrop.onClick = { [weak self] in
            guard let self, model.lyricsFocus else { return }
            log("click outside karaoke")
            toggleKaraoke()
        }
        return backdrop
    }()
    private var dragSettle: DispatchWorkItem?

    /// A drag can leave part of the glass off the screen. Once the mouse button is up, the panel moves it back.
    private func panelMoved(tries: Int = 0) {
        dragSettle?.cancel()
        let settle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Checked every 0.15 seconds while the button is down, for up to 90 seconds.
            if NSEvent.pressedMouseButtons & 1 != 0, tries < 600 { return panelMoved(tries: tries + 1) }
            panel.settleAfterDrag()
            log("the HUD was dragged to a new place")
        }
        dragSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: settle)
    }

    /// The helper runs while the HUD is up, for the record, and for the song changes while a key is kept, while the
    /// menu bar shows a song's key, and with Always listening. It stays up when the HUD closes with a key kept, since
    /// starting it again would count the song as a new one.
    private func updateWatching(shown: Bool) {
        // While the stems or the lyrics delay play, a pause has to be heard at once, so the helper keeps telling.
        // A song that Muskey Player plays faster or slower keeps its pitch correction only while it is the one that plays.
        nowPlaying.watching = keptKey != nil || shown || songKey != nil || prefs.alwaysListen || model.stemsEngaged || lyricsDelayed
            || filePlayer.speed != 1 || songRecording != nil || slow.active || (prefs.pauseStop && changesRun)
            // The mini player and the phone's page show the song with the HUD closed.
            || prefs.miniPlayer || phoneWatches || phoneListening
    }

    /// A pitch change, a tempo change or the stems run, which the pause timeout stops.
    private var changesRun: Bool {
        pitch.running || model.shift != 0 || keptKey != nil || model.pending != nil || model.stemsEngaged || model.stemsAdjusted
            || currentSpeed != 1 || slow.active
    }

    /// Settings > General > Pause timeout: once the song has been paused that long with the HUD hidden, the pitch change,
    /// the tempo change and the stems stop, as Stop Pitch Change and the original tempo would have them. Lock Key is
    /// released too, and nothing comes back when the song plays again.
    private var pauseStopWork: DispatchWorkItem?

    private var pauseStopWaits: Bool {
        prefs.pauseStop && !model.shown && !(nowPlaying.player?.playing ?? false) && changesRun && songRecording == nil
            && saveJob == nil && karaokeRestart == nil && !phoneListening
            // The notes window is a place where a song is paused for long, to study a bar at the tempo it was set to.
            && !notesWindow.isShown
    }

    private func syncPauseStop() {
        updateWatching(shown: model.shown)
        guard pauseStopWaits else {
            pauseStopWork?.cancel()
            pauseStopWork = nil
            return
        }
        guard pauseStopWork == nil else { return }
        let seconds = prefs.pauseStopSeconds
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pauseStopWork = nil
            guard pauseStopWaits else { return }
            stopAfterPause(seconds)
        }
        pauseStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func stopAfterPause(_ seconds: Int) {
        let stopped = [
            model.shift != 0 || keptKey != nil ? String(format: "the pitch change (%+d)", model.shift) : nil,
            currentSpeed != 1 ? String(format: "the tempo change (%.0f %%)", currentSpeed * 100) : nil,
            model.stemsEngaged || model.stemsAdjusted ? "the stems" : nil,
        ].compactMap { $0 }
        log("paused for \(seconds) s with the HUD hidden, stopping \(stopped.isEmpty ? "the pitch change" : stopped.joined(separator: ", "))", .notice)
        // A slowed song's player is up to 30 seconds ahead of what was heard, so it moves back to the moment heard
        // before the slowing stops, and plays on from there. A player that is already there isn't moved.
        if slow.active, let heard = nowPlaying.track, let player = nowPlaying.player, heard.song == player.song,
           let at = heard.position(at: Date()), (player.position(at: Date()).map { $0 - at > 0.5 } ?? true) {
            slow.stop("the song was paused with the HUD hidden")
            log(String(format: "the player moves back to %.1f s, where the song was heard", at))
            movePlayer(player, to: at)
        } else {
            slow.stop("the song was paused with the HUD hidden")
        }
        if filePlayer.speed != 1 { filePlayer.setSpeed(1) }
        if !model.stemVolumes.isEmpty {
            model.stemVolumes = [:]
            pitch.stemVolumes = [:]
        }
        syncSpeed()
        stopPitch()
        // The separation of the whole song into the cache stops too, and starts again the next time the stems are used.
        stemsCache.cancel()
        refreshStatus()
    }

    /// The stems play seconds behind the song, so they hold where they are while the player pauses it. A track
    /// with no title, or no track, counts as playing, so a player that doesn't report never holds the stems.
    private func syncPaused() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false else { return pitch.paused = false }
        if let guess = playGuess {
            // A report from before the player took the command would undo the change that Space made.
            guard guess.playing == track.playing else { return }
            playGuess = nil
            playGuessCheck?.cancel()
        }
        // A slowed song holds at a pause, but some players (Safari) report a pause and a play within a fraction of a
        // second around a move that Muskey sent. A pause right after a move holds the output only once it lasts.
        if !track.playing, !pitch.paused, slow.movedRecently {
            if pauseDeferredUntil == nil {
                pauseDeferredUntil = Date().addingTimeInterval(0.6)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.syncPaused() }
            }
            if let until = pauseDeferredUntil, Date() < until { return }
        }
        pauseDeferredUntil = nil
        if pitch.paused == track.playing, Self.logKeys || pitch.stemsEngaged { log(track.playing ? "song plays" : "song paused", .debug) }
        if !track.playing {
            // A move during the pause: the stems from the cache wait for the song at its new place, from the moment it
            // plays again.
            if cachedStems, let (song, position) = pausedAt, song == track.song, let position, let now = track.position(at: Date()), abs(now - position) > 2 {
                log(String(format: "the song moved to %.1f s during the pause", now))
                pitch.cachedSeek(to: now)
                pausedAt = (song, now)
            }
            pausedAt = pausedAt ?? (track.song, track.position(at: Date()))
        } else if let (song, position) = pausedAt {
            pausedAt = nil
            // Another song, or a seek, during the pause: the held stems belong to the moment before it.
            let moved = zip([position], [track.position(at: Date())]).contains { old, new in abs((old ?? 0) - (new ?? 0)) > 2 }
            if song != track.song || moved {
                log("the song changed during the pause, the stems start over")
                pitch.restartStems()
            }
        }
        pitch.paused = !track.playing
    }

    /// The song and its position when the player paused it.
    private var pausedAt: ([String?], Double?)?
    /// A pause reported right after a move, which holds the output only from this moment on.
    private var pauseDeferredUntil: Date?

    /// Space over the HUD plays or pauses the song, as the play key does. The record, the tonearm and the stems
    /// change right away, before the player reports the change, and a glyph on the record confirms it.
    private func playPause() {
        if model.phase == .idle {
            log("nothing plays: play")
            nowPlaying.play(true)
            return start()
        }
        nowPlaying.togglePlayPause()
        log("play or pause")
        guard let track = nowPlaying.track, track.title?.isEmpty == false else { return }
        // A second press before the report counts from the first one.
        let playing = !(playGuess?.playing ?? track.playing)
        playGuess = (playing, Date())
        pitch.paused = !playing
        showPlaying(playing, flash: true)
        syncNotesPlaying()
        // A player that ignored the command sends no change, so the guess is checked against what it reports.
        playGuessCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            playGuess = nil
            syncPaused()
            syncNotesPlaying()
            if model.shown, let track = nowPlaying.track, track.title?.isEmpty == false { showPlaying(track.playing, flash: false) }
        }
        playGuessCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: check)
    }

    /// What Space asked the player for, until the player reports it or 1.5 seconds pass.
    private var playGuess: (playing: Bool, at: Date)?
    private var playGuessCheck: DispatchWorkItem?
    /// When the HUD last appeared: a play or pause reported in its first moments happened while it was hidden.
    private var shownAt = Date.distantPast

    /// The record and its tonearm show the song as playing or paused, and with `flash` the glyph confirms the change.
    private func showPlaying(_ playing: Bool, flash: Bool) {
        guard model.playing != playing else { return }
        model.playing = playing
        guard flash, model.shown else { return }
        model.playFlash = PlayFlash(playing: playing, id: (model.playFlash?.id ?? 0) + 1)
        if Self.logKeys { log(playing ? "glyph play" : "glyph pause", .debug) }
    }

    /// Return while the lyrics show: karaoke, or back to the lyrics.
    private func toggleLyricsFocus() {
        guard model.lyricsShown else { return }
        karaokeAskedAt = CACurrentMediaTime()
        model.lyricsFocus.toggle()
        log(model.lyricsFocus ? "karaoke" : "lyrics at their usual size")
    }

    /// Karaoke opened from the keys, by its button or ⌘K, which closes back to the keys.
    private var karaokeFromKeys = false
    /// When the last key or click asked for karaoke, for the log of how long it took to show.
    private var karaokeAskedAt: CFTimeInterval?

    /// The karaoke button and ⌘K: karaoke from the keys or from the lyrics, and back to where it opened from.
    private func toggleKaraoke() {
        karaokeAskedAt = CACurrentMediaTime()
        if model.lyricsFocus {
            let back = karaokeFromKeys
            model.lyricsFocus = false
            log("karaoke closed")
            if back, model.lyricsShown { toggleLyrics() }
            return
        }
        let fromKeys = !model.lyricsShown
        if fromKeys {
            toggleLyrics()
            guard model.lyricsShown else { return }
        }
        model.lyricsFocus = true
        karaokeFromKeys = fromKeys
        log(fromKeys ? "karaoke from the keys" : "karaoke")
    }

    /// Karaoke mutes the vocals it finds playing, when Settings has it, and plays them again once it closes, by
    /// Return, L or the HUD closing. Vocals that were muted before, or that V changed during karaoke, stay as they are.
    private func karaokeChanged(_ on: Bool) {
        if !on {
            karaokeFromKeys = false
            model.karaokeKeys = false
            model.karaokeStems = false
            endKaraokeRestart()
        }
        // Karaoke takes the keys that change the key, which the lyrics at their usual size don't.
        updateHoverKeys()
        if on {
            if prefs.karaokeMutesVocals, model.stemsAvailable, !model.stemsMuted.contains(.vocals) {
                karaokeMutedVocals = true
                log("karaoke: vocals muted")
                setStems(model.stemsMuted.union([.vocals]), fade: true)
            }
            if prefs.karaokeRestarts { restartForKaraoke() }
            if let asked = karaokeAskedAt {
                karaokeAskedAt = nil
                log(String(format: "karaoke: set up %.0f ms after it was asked for", (CACurrentMediaTime() - asked) * 1000), .debug)
                DispatchQueue.main.async { [self] in
                    log(String(format: "karaoke: main thread free %.0f ms after it was asked for", (CACurrentMediaTime() - asked) * 1000), .debug)
                }
            }
        } else if karaokeMutedVocals {
            karaokeMutedVocals = false
            guard model.stemsMuted.contains(.vocals) else { return }
            log("karaoke: vocals play again")
            setStems(model.stemsMuted.subtracting([.vocals]), fade: true)
        }
    }

    private var karaokeMutedVocals = false

    /// Karaoke starting the song over: waiting for the model to be ready, waiting for the player to report the song at
    /// its start since the moment the move was asked for, or started over.
    /// The song moves to its start for karaoke, or to the place that a seek key asked for while the stems play:
    /// waiting for the model, waiting for the player's report of the move, and moved, with the place in seconds.
    private enum KaraokeRestart: Equatable { case waitingForModel, seeking(Date, Double), started(Double) }

    /// The move goes to the start of the song, as karaoke's, and not to the place of a seek.
    private var restartsFromStart: Bool {
        switch karaokeRestart {
        case let .seeking(_, target), let .started(target): target == 0
        case .waitingForModel: true
        case nil: false
        }
    }
    private var karaokeRestart: KaraokeRestart?
    /// Karaoke's start over steps back to the start of the song with a fade, whatever Settings > Instruments and vocals
    /// > Rewind effect has for the other steps back: a backspin all the way to the start felt like too much. Set until
    /// that one step back is heard.
    private var fadeToStart = false {
        didSet { pitch.fadeSteps = prefs.rewindEffect == .fade || fadeToStart }
    }
    private var karaokeRestartTimeout: DispatchWorkItem?

    /// Karaoke starts the song over (Settings > Lyrics > Karaoke > Start song from beginning). While the stems play, the output dips
    /// while the player moves the song to its start, and the song plays from there with its vocals while the stems of
    /// the start are separated, under the countdown. Then it rewinds to the start without them. Without the stems, the
    /// song only moves to its start.
    private func restartForKaraoke() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false, track.playing else {
            return log("karaoke: no song plays, nothing to start over")
        }
        // The lyrics delay plays the song 30 seconds behind on the same timeline, with a countdown of its own.
        guard !lyricsDelayed else { return log("karaoke: the song doesn't start over while Whisper writes its lyrics") }
        guard model.stemsEngaged else {
            log("karaoke: the song starts over")
            return moveSong(track, to: 0)
        }
        // Stems that already play for this song are ready, as when karaoke opens again: it opens on them at once,
        // where the song is, with nothing to separate again.
        if pitch.stemsPlaying { return log("karaoke: the stems already play, the song goes on from where it is") }
        // The stems from the cache play at once wherever the song is, so the song moves to its start as for a seek.
        if cachedStems {
            log("karaoke: the song starts over, with the stems from the cache")
            pitch.cachedSeek(to: 0)
            return moveSong(track, to: 0)
        }
        // Core ML prepares the model for an unknown time, and the stems separated meanwhile would be wasted, so the song
        // plays on and starts over once the model is ready.
        guard StemModel.prepared else {
            log("karaoke: the song starts over once the model is ready")
            karaokeRestart = .waitingForModel
            return
        }
        beginKaraokeRestart()
    }

    private func beginKaraokeRestart(to target: Double = 0) {
        guard let track = nowPlaying.track else { return }
        log(target == 0 ? "karaoke: the song starts over" : String(format: "seek: the stems start over at %.1f s", target))
        if target == 0, !fadeToStart { fadeToStart = true }
        let asked = Date()
        karaokeRestart = .seeking(asked, target)
        pitch.awaitingSeek = true
        // A player that ignores the move: the song plays on, and rewinds to where karaoke opened.
        let giveUp = { [weak self] in
            guard let self, case let .seeking(at, _) = karaokeRestart, at == asked else { return }
            log(restartsFromStart ? "karaoke: the player didn't move the song to its start" : "seek: the player didn't move the song", .error)
            karaokeRestart = nil
            pitch.awaitingSeek = false
            model.seekWait = nil
        }
        let filePlayer = track.bundleID == FilePlayer.bundleID
        if filePlayer {
            // Karaoke waits for the report of the move. Now Playing reports a move that it sent at once, while a seek
            // sent to Muskey Player straight would be read only a few seconds later.
            nowPlaying.seek(to: target)
        } else {
            moveSong(track, to: target) { moved in if !moved { giveUp() } }
        }
        // The Automation question can stay open for long, so the sound comes back after a while without an answer.
        let timeout = DispatchWorkItem(block: giveUp)
        karaokeRestartTimeout?.cancel()
        karaokeRestartTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (filePlayer ? 2 : 30), execute: timeout)
    }

    /// The player reports the song at its start after karaoke moved it there: the stems start over from that moment.
    private func checkKaraokeRestart() {
        guard case let .seeking(asked, target) = karaokeRestart, let track = nowPlaying.track, track.playing,
              let position = track.position(at: Date()), position >= target - 0.5, position < target + 3,
              // A report from before the move would place the start at the wrong moment.
              (track.timestamp ?? .infinity) >= asked.timeIntervalSince1970 - 0.05 else { return }
        karaokeRestartTimeout?.cancel()
        karaokeRestart = .started(target)
        log(target == 0 ? String(format: "karaoke: the song started over %.2f s ago", position)
            : String(format: "seek: the song moved to %.1f s, %.2f s ago", target, position - target))
        // The player's timestamp can be a little early, and the start is better 50 ms late than in the moment
        // before the move.
        pitch.restartStems(back: max(0, (position - target) / max(track.rate ?? 1, 0.1) - 0.05))
        recordRewound()
    }

    private func endKaraokeRestart() {
        model.seekWait = nil
        if fadeToStart { fadeToStart = false }
        karaokeRestartTimeout?.cancel()
        karaokeRestartTimeout = nil
        karaokeRestart = nil
        pitch.awaitingSeek = false
    }

    /// The seconds that the stems take to start once the model is ready: the first window, the margin after it, and
    /// about the time that a window takes to separate.
    private static var stemsWait: Double { StemModel.chunkSeconds + 0.75 + (StemModel.isInstalled(.winds) ? 1.2 : 0.6) }

    /// Karaoke counts down while the stems are separated, and says how far the song rewinds after it. Nothing shows
    /// while the player is asked to move the song to its start, which takes a moment.
    private func karaokeCountdown(_ progress: StemsProgress?) -> KaraokeCountdown? {
        guard model.lyricsFocus, let progress else { return nil }
        if case .seeking = karaokeRestart { return nil }
        // The countdown starts at the seconds that the song rewinds by, rounded the same way.
        let total = Int(Self.stemsWait.rounded())
        guard case .separating = progress, let waited = pitch.stemsWaited else {
            return KaraokeCountdown(seconds: nil, total: total, restart: restartsFromStart, rewind: nil)
        }
        let left = max(1, Int((Self.stemsWait - waited).rounded()))
        // The song rewinds as far as the stems took to start: the estimate, unless they run late.
        let rewind = Int(max(Self.stemsWait, waited + 0.5).rounded())
        return KaraokeCountdown(seconds: left, total: total, restart: restartsFromStart, rewind: rewind)
    }

    /// The V key, in every layout: the vocals muted, or playing again.
    private func toggleVocals() {
        guard model.stemsAvailable else { return }
        karaokeMutedVocals = false
        let muted = model.stemsMuted.contains(.vocals) ? model.stemsMuted.subtracting([.vocals]) : model.stemsMuted.union([.vocals])
        setStems(muted, fade: true)
    }

    /// Keeps the menu bar's key on the song that plays. A song that Now Playing names for the first time starts on
    /// its remembered key, or on the turntable until a listen finds its key.
    private func syncSongKey() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false else {
            // A player that quit leaves no song, and the turntable comes back. A player that starts another song
            // reports no song for a moment, so the key waits 2 seconds for a song to show up.
            if autoSong != nil { cancelAutoListen() }
            guard songKey?.song != nil, noSong == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                noSong = nil
                if nowPlaying.track?.title?.isEmpty != false, songKey?.song != nil { songKey = nil }
            }
            noSong = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
            return
        }
        noSong?.cancel()
        noSong = nil
        if let autoSong, autoSong != track.song || !track.playing { cancelAutoListen() }
        if songKey?.song != track.song {
            songKey = knownKey(for: track.song).map { (track.song, $0.key, true, $0.online) }
        }
        autoListenIfNeeded()
    }

    /// The key known for a song without a listen: the one that a full listen found, or else the one that Noiseblend
    /// gave before.
    private func knownKey(for song: [String?]) -> (key: DetectedKey, online: Bool)? {
        if prefs.rememberKeys, let key = keyCache.key(for: song) { return (key, false) }
        if let id = KeyCache.id(song), let heard = heardKeys[id] { return (heard.key, false) }
        if prefs.onlineKeys, let key = keyLookup.key(for: song) { return (key, true) }
        return nil
    }

    /// The tempo known for a song without a listen: the one that a full listen found, or else Noiseblend's.
    private func knownTempo(for song: [String?]) -> SongTempo? {
        if prefs.rememberKeys, let bpm = keyCache.bpm(for: song) { return SongTempo(song: song, bpm: bpm) }
        if let id = KeyCache.id(song), let bpm = heardKeys[id]?.bpm { return SongTempo(song: song, bpm: bpm) }
        if prefs.onlineKeys, let bpm = keyLookup.bpm(for: song) { return SongTempo(song: song, bpm: bpm, online: true) }
        return nil
    }

    /// The pill under the key shows the tempo of the song that plays, once it is known.
    private func showTempo() {
        let song = model.track?.song
        guard model.tempo?.song != song || model.tempo == nil else { return }
        let known = song.flatMap(knownTempo)
        if model.tempo != known { model.tempo = known }
    }

    /// A listen heard `tempo` in `song`. Noiseblend's tempo picks the level at which the beats are counted, and the
    /// tempo is kept with the song's key.
    private func heardTempo(_ tempo: (bpm: Double, confidence: Float)?, in song: [String?]?) -> Double? {
        guard let tempo else { return nil }
        let online = prefs.onlineKeys ? song.flatMap(keyLookup.bpm) : nil
        let shown = TempoDetector.reconcile(heard: tempo.bpm, online: online)
        log(String(format: "tempo: heard %.1f BPM, confidence %.2f, Noiseblend %@, shown %.1f", tempo.bpm, tempo.confidence,
                   online.map { String(format: "%.1f", $0) } ?? "none", shown))
        if model.track?.song == song { model.tempo = SongTempo(song: song, bpm: shown) }
        return shown
    }

    /// Asks Noiseblend for the key of a song that a listen starts on. The answer shows in the menu bar unless a listen
    /// found the song's key first, and a listen in the HUD starts on it if no estimate came before it. The listen goes
    /// on either way, and its key counts over Noiseblend's.
    private func lookUpKey(_ track: NowPlaying.Track) {
        guard prefs.onlineKeys, Self.lyricsTest == nil else { return }
        let song = track.song
        keyLookup.find(track) { [weak self] key in
            guard let self, nowPlaying.track?.song == song else { return }
            showTempo()
            guard key != nil else { return }
            if songKey?.song != song, let known = knownKey(for: song) { songKey = (song, known.key, true, known.online) }
            startOnKnownKey()
        }
    }

    /// Always listening: a song that plays with no key heard yet gets a listen of the usual length, without the HUD.
    /// Its key shows in the menu bar and is remembered like the key of any listen. Each song gets two tries, for one
    /// that was paused or quiet through the first. A key from Noiseblend shows during the listen, which confirms it.
    private func autoListenIfNeeded() {
        guard prefs.alwaysListen, state == .idle, keptKey == nil, autoAnalyzer == nil, Self.lyricsTest == nil,
              AudioCapturePermission.status == .granted, let track = nowPlaying.track, track.playing,
              track.title?.isEmpty == false, songKey.map({ $0.song != track.song || $0.online }) ?? true,
              autoTries[track.song, default: 0] < 2
        else { return }
        autoTries[track.song, default: 0] += 1
        autoSession += 1
        let current = autoSession
        autoSong = track.song
        let tap = SystemAudioTap()
        do {
            try tap.prepare()
            let analyzer = KeyAnalyzer(sampleRate: tap.sampleRate, speed: playedSpeed)
            autoTap = tap
            autoAnalyzer = analyzer
            // Only the final estimate counts here, so the ones on the way are dropped.
            try tap.start { samples in analyzer.append(samples) { _, _ in } }
        } catch {
            cancelAutoListen()
            return log("always listening: \(error)", .error)
        }
        log("always listening to \(track.title ?? "")")
        if songKey?.song != track.song { lookUpKey(track) }
        // The listen runs its whole length. One that heard nothing ends without a key, and the song gets its second
        // try if it still plays.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, autoSession == current else { return }
            finishAutoListen()
        }
    }

    private func finishAutoListen() {
        guard let analyzer = autoAnalyzer, let song = autoSong else { return }
        autoTap?.stop()
        autoTap = nil
        let current = autoSession
        analyzer.finish { [weak self] result, peak, bpm in
            guard let self, autoSession == current else { return }
            autoAnalyzer = nil
            autoSong = nil
            guard peak >= 0.0005, let key = DetectedKey(result) else {
                log("always listening: no key heard")
                return autoListenIfNeeded()
            }
            guard nowPlaying.track?.song == song else { return syncSongKey() }
            log(String(format: "always listening: %@  strength %.3f", key.name, result.strength))
            autoTries[song] = nil
            let tempo = heardTempo(bpm, in: song)
            if prefs.rememberKeys { log(keyCache.store(key, strength: result.strength, bpm: tempo, for: song)) }
            if let id = KeyCache.id(song) { heardKeys[id] = (key, tempo) }
            keyLookup.heard(key, for: song)
            // A pitch change that runs on into this song starts from its key.
            if pitch.running, keptKey == nil { shiftBase = key }
            songKey = (song, key, true, false)
        }
    }

    /// Stops a listen of Always listening, for a listen in the HUD, a song change or a pause. It doesn't count as one
    /// of the song's tries.
    private func cancelAutoListen() {
        autoSession += 1
        autoTap?.stop()
        autoTap = nil
        autoAnalyzer = nil
        if let autoSong, let tries = autoTries[autoSong] { autoTries[autoSong] = max(0, tries - 1) }
        autoSong = nil
    }

    /// A listen in the HUD found a key for the song that it heard, or started on the song's remembered key or on
    /// Noiseblend's. A song that changed during the listen keeps the key that it has.
    private func noteKey(_ key: DetectedKey, final: Bool, online: Bool = false) {
        let song = listenSong ?? nowPlaying.track?.song
        if let playing = nowPlaying.track, playing.title?.isEmpty == false, let song, song != playing.song { return }
        if !final, let songKey, songKey.final, songKey.song == song { return }
        songKey = (song, key, final, online)
    }

    /// The record shows the song that plays. While the HUD is hidden it keeps the song that it showed last, so the
    /// HUD that opens for a song change starts on the old record and swaps to the new one.
    private func syncTrack(gapOver: Bool = false) {
        if let fake = Self.lyricsTest?.track {
            if model.track != fake { model.track = fake }
            showPlaying(fake.playing, flash: false)
            return loadLyrics()
        }
        guard nowPlaying.watching else {
            trackGap?.cancel()
            trackGap = nil
            model.track = nil
            model.artwork = nil
            showPlaying(false, flash: false)
            return
        }
        guard model.shown else {
            // The mini player follows the song while the HUD is closed: its record, its title and its turning.
            guard prefs.miniPlayer else { return }
            if model.track != nowPlaying.track { model.track = nowPlaying.track }
            if model.artwork !== nowPlaying.artwork { model.artwork = nowPlaying.artwork }
            if let track = nowPlaying.track, playGuess == nil || playGuess?.playing == track.playing { showPlaying(track.playing, flash: false) }
            return
        }
        // A player that starts another song directly (Spotify's play track, a click on a song in a list) reports no
        // song for a moment. The record holds through that gap, so the HUD swaps records instead of shrinking and
        // growing back.
        if !gapOver, nowPlaying.track?.title?.isEmpty != false, model.track?.title?.isEmpty == false {
            guard trackGap == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                self?.trackGap = nil
                self?.syncTrack(gapOver: true)
            }
            trackGap = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
            return
        }
        trackGap?.cancel()
        trackGap = nil
        // A play or pause of the same song, from the play key or the player, gets the glyph that Space shows. One
        // that Space asked for already shows, and a report against it is from before the player took it.
        let sameSong = model.track?.song == nowPlaying.track?.song
        if model.track != nowPlaying.track { model.track = nowPlaying.track }
        let otherPlayer = nowPlaying.track?.title?.isEmpty == false && nowPlaying.player?.bundleID != FilePlayer.bundleID
        if model.otherPlayer != otherPlayer {
            model.otherPlayer = otherPlayer
            if otherPlayer, model.queueShown { toggleQueue() }
            updateHoverKeys()
        }
        showTempo()
        if model.artwork !== nowPlaying.artwork { model.artwork = nowPlaying.artwork }
        if let track = nowPlaying.track, playGuess == nil || playGuess?.playing == track.playing {
            showPlaying(track.playing, flash: sameSong && Date().timeIntervalSince(shownAt) > 0.6)
            syncOpeningRecord()
        }
        loadLyrics()
    }

    private var trackGap: DispatchWorkItem?
    /// The kept key, during a listen that a song change started; nil during a listen started by the hotkey.
    private var follow: DetectedKey?
    /// The first estimate of that listen has moved the song, and the key and shift hold until the listen ends.
    private var followApplied = false
    /// The key to follow was picked by a person during a listen, not kept by Lock Key: the final estimate keeps that
    /// key, and the HUD shows no red pill for it.
    private var followByPerson = false
    /// A new song plays in its original key for at least this long before Lock Key moves it.
    private static let originalKeyFor: TimeInterval = 3
    private var songChangedAt = Date.distantPast
    private let keyCache = KeyCache()
    /// The song that Now Playing named when the listen started. Its key is remembered only if it still plays at the
    /// end of the listen.
    private var listenSong: [String?]?
    /// The listen started on the key that an earlier full listen found for the song, or on Noiseblend's. Estimates
    /// don't change it, and only the final estimate can.
    private var remembered: DetectedKey?
    /// The song that this listen asked Noiseblend about, so that it asks once.
    private var lookedUp: [String?]?
    /// The keys and tempos that listens found since Muskey started, by song, also with Remember song keys off. A song
    /// that a listen found the key of shows that key at once when the HUD opens on it again.
    private var heardKeys: [String: (key: DetectedKey, bpm: Double?)] = [:]
    /// A click on the key listens to the song again, as if no key were known for it. The key that it finds replaces
    /// the remembered one.
    private var redetecting = false
    /// The HUD was opened by a person (the hotkey, the menu, a click, an opened song), or showed already when the song
    /// changed, so it stays up after the result until it is closed, unless Auto-hide is on. A HUD that a song change
    /// opened with Lock Key on closes after the period of Auto-hide either way.
    private var stayOpen = false
    private let keyLookup = KeyLookup()
    private var keyMonitor: Any?
    private var magnifyMonitor: Any?
    /// Gets keyboard focus back when the key picker closes, if a click on the HUD made Muskey the active app.
    private var lastOtherApp = NSWorkspace.shared.frontmostApplication
    private var signalSources: [DispatchSourceSignal] = []

    private let prefs = Preferences.shared
    private var prefChanges: Set<AnyCancellable> = []
    /// Made when Settings opens and let go when it closes. The pane shown is kept in `SettingsRoute`.
    private var openSettings: SettingsWindowController?
    private var settingsWindow: SettingsWindowController {
        if let openSettings { return openSettings }
        let view = SettingsView(hud: model, keyCache: keyCache, setLayout: { [weak self] card in self?.setLayout(card: card) })
        let controller = SettingsWindowController(view: view)
        controller.onClosed = { [weak self, weak controller] in
            // Settings may have opened again before this ran, and then the same window stays.
            guard let self, let controller, openSettings === controller, controller.window?.isVisible != true else { return }
            openSettings = nil
            log("settings: closed and released", .debug)
        }
        openSettings = controller
        return controller
    }

    // The estimate kept getting more accurate the longer a listen ran, and stopping early once it held steady lost
    // accuracy, so a listen has a fixed length.
    private var seconds: Double { Self.stringOption("--seconds").flatMap(Double.init) ?? Double(prefs.listenSeconds) }
    private let silenceAfter = KeyAnalyzer.firstEstimateAfter + 0.5
    /// How long a result stays up before the HUD closes, or nil when it stays up until it is closed. With Auto-hide
    /// off, only a HUD that a song change opened with Lock Key on closes by itself. `--show SECONDS` sets the period
    /// for tests.
    private var resultHideDelay: TimeInterval? {
        guard prefs.autoHide || !stayOpen else { return nil }
        return Self.stringOption("--show").flatMap(Double.init) ?? Double(prefs.autoHideSeconds)
    }

    private static func stringOption(_ name: String) -> String? { TestFlags.value(name) }

    private static func option(_ name: String, _ fallback: Double) -> Double {
        stringOption(name).flatMap(Double.init) ?? fallback
    }

    func applicationDidFinishLaunching(_: Notification) {
        if let dir = Self.stringOption("--render") { return renderPreviews(to: dir) }
        if TestFlags.has("--log-playhead") { WaveformView.trace = { [weak self] in self?.log(String(format: "playhead %.3f", $0), .debug) } }
        if TestFlags.has("--log-notes-frames") {
            notesFrameLog = { [weak self] count, gap in self?.log(String(format: "notes frames: %d in a second, longest wait %.0f ms", count, gap * 1000), .debug) }
        }
        if let path = Self.stringOption("--render-menubar") {
            StatusItem.renderSheet(to: path)
            return NSApp.terminate(nil)
        }
        if let spec = Self.stringOption("--lyrics-lookup") { return lookUpLyrics(spec) }
        if let spec = Self.stringOption("--key-lookup") { return lookUpKeyForTesting(spec) }
        if let path = Self.stringOption("--tempo") { return tempoForTesting(path) }
        if let path = Self.stringOption("--key-file") { return keyFileForTesting(path) }
        if let dir = Self.stringOption("--dettato-check") {
            DettatoCheck.run(dir)
            return
        }
        if let path = Self.stringOption("--notes-render") {
            renderNotesWindow(fixture: path, to: Self.stringOption("--render") ?? Self.stringOption("--notes-out") ?? "/tmp")
            return NSApp.terminate(nil)
        }
        if let file = Self.stringOption("--stem-activity") {
            NotesPipeline.printActivity(file)
            return NSApp.terminate(nil)
        }
        if let path = Self.stringOption("--notes-headless") {
            NotesPipeline.headless(path)
            return
        }
        if let path = Self.stringOption("--chords") {
            // `--chords FILE` prints the beats and the chords that the lyrics would show over the file.
            Task {
                let url = URL(fileURLWithPath: path)
                let duration = await ChordDetector.duration(url)
                let started = Date()
                guard let grid = await ChordDetector.analyse(url, duration: duration) else {
                    print("chords: nothing found in \(path)")
                    exit(1)
                }
                print(String(format: "%d beats at %.1f BPM, %d chords, %.1f s for %.0f s of song", grid.beats.count, grid.bpm, grid.chords.count,
                             Date().timeIntervalSince(started), duration))
                print(grid.chords.prefix(40).map { String(format: "%.1f %@", $0.time, $0.name(moved: 0)) }.joined(separator: "  "))
                if let key = Self.stringOption("--key").flatMap(DetectedKey.init(name:)) {
                    let fitted = grid.fitted(to: key)
                    print("in \(key.name), \(fitted.count) chords:")
                    print(fitted.prefix(40).map { String(format: "%.1f %@", $0.time, $0.name(moved: 0)) }.joined(separator: "  "))
                }
                exit(0)
            }
            return
        }
        if let path = Self.stringOption("--loop-snap") {
            // `--loop-snap FILE --at S --to S` prints where presses at those moments of the file would land.
            Task {
                let at = Self.option("--at", 30), to = Self.option("--to", at + 8)
                let url = URL(fileURLWithPath: path)
                for (name, time) in [("start", at), ("end", to)] {
                    let from = max(0, time - 8)
                    let samples = await LoopSnap.excerpt(url, from: from, to: time + 1.5)
                    let started = Date()
                    let grid = LoopSnap.grid(samples, start: from)
                    let snapped = name == "start" ? LoopSnap.snap(time, grid: grid) : LoopSnap.snapEnd(time, start: LoopSnap.snap(at, grid: grid), grid: grid, bpm: nil)
                    print(String(format: "%@: pressed %.3f s, snapped %.3f s (%+.0f ms), %d beats, %d attacks, %.1f BPM, %.0f ms", name, time, snapped,
                                 (snapped - time) * 1000, grid.beats.count, grid.onsets.count, grid.bpm ?? 0, Date().timeIntervalSince(started) * 1000))
                }
                exit(0)
            }
            return
        }
        if let path = Self.waveformTest {
            Task {
                let start = Date()
                guard let waveform = await WaveformReader.read(URL(fileURLWithPath: path)) else {
                    print("waveform: can't read \(path)")
                    exit(1)
                }
                let bars = waveform.bars(40)
                print(String(format: "waveform: %.1f s, %d levels, %.0f%% heard, read in %.2f s", waveform.duration, waveform.levels.count, waveform.heard * 100, Date().timeIntervalSince(start)))
                print(bars.map { $0 < 0 ? " " : String(" ▁▂▃▄▅▆▇█".map { $0 }[min(8, Int($0 * 8.99))]) }.joined())
                exit(0)
            }
            return
        }
        if let path = Self.stringOption("--transcribe") { return TranscribeTest.run(path) }
        if TestFlags.has("--dettato-download") { return ModelDownload.dettato.downloadForTesting() }
        if let path = Self.stringOption("--dettato-install") { return ModelDownload.dettato.installForTesting(path) }
        if let path = Self.stringOption("--splice-dump") {
            exit(SlowStream.searchDump(path, old: Self.option("--splice-old", 3), move: Self.option("--splice-move", 0)))
        }
        if let path = Self.stringOption("--whisper-file") { return WhisperTest.run(file: path, model: Self.stringOption("--whisper-model") ?? "") }
        if let path = Self.stringOption("--lyrics-transcribe") {
            return LyricsTranscribeTest.run(file: path, server: Self.stringOption("--whisper-server"), vocals: !TestFlags.has("--no-vocals"))
        }
        if let path = Self.stringOption("--aligner-install") { return ModelDownload.aligner.installForTesting(path) }
        if let path = Self.stringOption("--lyrics-live"), let reference = Self.stringOption("--lyrics-ref") {
            return LyricsLiveTest.run(file: path, reference: reference, plays: Self.stringOption("--plays") ?? "0-end")
        }
        if let path = Self.stringOption("--lyrics-align"), let reference = Self.stringOption("--lyrics-ref") {
            return LyricsAlignTest.run(file: path, reference: reference)
        }
        if let path = Self.stringOption("--lyrics-replay"), let server = Self.stringOption("--whisper-server") {
            return LyricsReplayTest.run(file: path, server: server, plays: Self.stringOption("--plays") ?? "0-60,0-120")
        }
        if TestFlags.has("--stems-download") { return ModelDownload.stems.downloadForTesting() }
        if TestFlags.has("--winds-download") { return ModelDownload.winds.downloadForTesting() }
        if TestFlags.has("--whisper-download") { return ModelDownload.whisper.downloadForTesting() }
        if let path = Self.stringOption("--stems-install") { return ModelDownload.stems.installForTesting(path) }
        if let path = Self.stringOption("--winds-install") { return ModelDownload.winds.installForTesting(path) }
        if let path = Self.stringOption("--stems-file") { return StemFileTest.run(path, to: Self.stringOption("--stems-out") ?? "/tmp/muskey-stems") }
        if let path = Self.stringOption("--render-song") {
            return SaveTest.run(path, to: Self.stringOption("--render-out") ?? "/tmp/muskey-render.m4a", semitones: Int(Self.option("--render-semitones", 0)),
                                speed: Self.option("--render-speed", 1),
                                mute: (Self.stringOption("--render-mute") ?? "").split(separator: ",").map { $0.lowercased() },
                                range: Self.stringOption("--render-range").flatMap { text -> ClosedRange<Double>? in
                                    let ends = text.split(separator: "-").compactMap { Double($0) }
                                    return ends.count == 2 && ends[0] < ends[1] ? ends[0] ... ends[1] : nil
                                },
                                tags: SongTags(title: Self.stringOption("--render-title"), artist: Self.stringOption("--render-artist"),
                                               cover: Self.stringOption("--render-cover").flatMap { SongTags.jpeg(NSImage(contentsOfFile: $0)) }))
        }

        // Error reports start before anything else of a normal launch, so a crash while Muskey sets up is reported too.
        ErrorReports.start()
        NSApp.mainMenu = mainMenu()
        hangWatch.start()
        if let seconds = Self.stringOption("--test-hang").flatMap(Double.init) {
            // Blocks the main thread on purpose, 3 s after the launch, so the log shows how a hang is written.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.log(String(format: "test hang: blocking the main thread for %.1f s", seconds), .notice)
                Thread.sleep(forTimeInterval: seconds)
            }
        }
        Updates.shared.start()
        prefs.$cacheCleanup.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.sweepCaches() } }.store(in: &prefChanges)
        cacheSweeper = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.sweepCaches() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.sweepCaches() }
        prefs.$hotkey.combineLatest(prefs.$recordingHotkey).sink { [weak self] shortcut, recording in
            self?.registerHotKey(recording ? nil : shortcut)
        }.store(in: &prefChanges)
        prefs.$micHotkey.combineLatest(prefs.$recordingMicHotkey).sink { [weak self] shortcut, recording in
            self?.registerMicHotKey(recording ? nil : shortcut)
            self?.model.micHotkey = shortcut.symbols
        }.store(in: &prefChanges)
        prefs.$launchAtLogin.sink { [weak self] in self?.updateLoginItem($0) }.store(in: &prefChanges)
        prefs.$relativeKeys.sink { [weak self] in self?.model.relativeKeys = $0 }.store(in: &prefChanges)
        prefs.$waveform.dropFirst().sink { [weak self] shown in
            self?.model.waveformShown = shown
            DispatchQueue.main.async { self?.syncWaveform() }
        }.store(in: &prefChanges)
        prefs.$waveformStyle.dropFirst().sink { [weak self] in self?.model.waveformStyle = $0 }.store(in: &prefChanges)
        prefs.$miniPlayer.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                updateWatching(shown: model.shown)
                syncMini()
            }
        }.store(in: &prefChanges)
        prefs.$miniLayout.dropFirst().sink { [weak self] layout in
            self?.mini.layout = layout
            DispatchQueue.main.async { self?.miniPanel.chooseSide() }
        }.store(in: &prefChanges)
        prefs.$miniBackground.dropFirst().sink { [weak self] background in
            self?.mini.background = background
            DispatchQueue.main.async { self?.miniPanel.chooseSide() }
        }.store(in: &prefChanges)
        prefs.$miniDirection.dropFirst().sink { [weak self] direction in
            self?.mini.songOnRecord = direction == .onRecord
            DispatchQueue.main.async { self?.miniPanel.chooseSide() }
        }.store(in: &prefChanges)
        // Published before the change, so the panel takes its new size on the next turn, once the setting reads it.
        prefs.$miniThreeFingerTap.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.miniPanel.syncGestures() } }.store(in: &prefChanges)
        prefs.$miniRecordScale.dropFirst().sink { [weak self] scale in
            self?.mini.recordScale = scale
            DispatchQueue.main.async { self?.miniPanel.resize() }
        }.store(in: &prefChanges)
        model.$track.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.syncMini() } }.store(in: &prefChanges)
        model.$lyricsShown.dropFirst().removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.syncChords() } }.store(in: &prefChanges)
        mini.onHide = { [weak self] in self?.hideMiniPlayer() }
        mini.onShowHUD = { [weak self] in self?.pickKey() }
        mini.onSettings = { [weak self] in
            SettingsRoute.shared.pane = .mini
            self?.settingsWindow.show()
        }
        // The waveform of another player's song is drawn only while the HUD shows it.
        model.$shown.dropFirst().removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.syncWaveform() } }.store(in: &prefChanges)
        prefs.$rewindEffect.sink { [weak self] effect in
            guard let self else { return }
            pitch.fadeSteps = effect == .fade || fadeToStart
        }.store(in: &prefChanges)
        // A changed timeout counts from the change.
        prefs.$pauseStop.combineLatest(prefs.$pauseStopSeconds).sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.pauseStopWork?.cancel()
                self?.pauseStopWork = nil
                self?.syncPauseStop()
            }
        }.store(in: &prefChanges)
        prefs.$menuBarIcon.combineLatest(prefs.$hotkey).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }.store(in: &prefChanges)
        // Published before the change, so the new value is read on the next turn of the run loop.
        prefs.$alwaysListen.dropFirst().removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !on { cancelAutoListen() }
                updateWatching(shown: model.shown)
                guard on, AudioCapturePermission.status == .undetermined else { return syncSongKey() }
                AudioCapturePermission.request { [weak self] granted in
                    if granted { self?.syncSongKey() }
                }
            }
        }.store(in: &prefChanges)
        // A key forgotten in Settings stops showing in the menu bar for the song that plays, and Always listening
        // listens to that song again. Noiseblend's key for the song is forgotten too, so the song starts over.
        keyCache.onForget = { [weak self] id in
            guard let self else { return }
            if let id { keyLookup.forget(id) } else { keyLookup.clear() }
            if let song = model.tempo?.song, id == nil || id == KeyCache.id(song) { model.tempo = nil }
            guard let song = songKey?.song, id == nil || id == KeyCache.id(song) else { return }
            songKey = nil
            autoTries[song] = nil
            autoListenIfNeeded()
        }

        model.onShift = { [weak self] shift, relative in
            if Self.logKeys { self?.log("click \(shift)\(relative ? " other mode" : "")", .debug) }
            self?.change(to: shift, relative: relative)
        }
        model.onClose = { [weak self] in self?.dismiss() }
        model.onRedetect = { [weak self] in self?.redetect() }
        model.onStop = { [weak self] in self?.stopPitch() }
        model.onKeep = { [weak self] in self?.toggleKeep() }
        model.onLayout = { [weak self] in self?.toggleLayout() }
        model.onLyrics = { [weak self] in self?.toggleLyrics() }
        model.onSpeed = { [weak self] in self?.changeSpeed(by: $0) }
        model.onKaraoke = { [weak self] in
            if Self.logKeys { self?.log("click karaoke", .debug) }
            self?.toggleKaraoke()
        }
        model.onLyricsRetry = { [weak self] in self?.retryLyrics() }
        model.onLyricsTiming = { [weak self] in self?.pressLyricsTiming() }
        model.onLyricsTimingDismiss = { [weak self] in
            guard let self, model.lyricsTiming == .failed else { return }
            model.lyricsTiming = .unchecked
        }
        model.onLyricsNudge = { [weak self] seconds in
            guard let self else { return }
            // The arrows start from an offset that a check found and that waits to be applied.
            var base = model.lyricsShift
            if base == 0, case let .found(offset)? = model.lyricsTiming { base = offset }
            setLyricsShift(base + seconds)
        }
        model.onLyricsForget = { [weak self] in self?.forgetLyricsTiming() }
        NotificationCenter.default.addObserver(forName: LyricsStore.timingsRemoved, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lyricsSync.forgetKept()
                self?.lyricsTimingsRemoved()
            }
        }
        // Songs from other apps are checked and fitted as Settings allows, and never without both models.
        lyricsSync.canFit = { [weak self] in
            guard let self else { return false }
            return AlignerModel.installed && StemModel.installed && prefs.lyricsLiveTiming && prefs.timingConditions.hold
        }
        model.onLyricsEdit = { [weak self] in self?.editLyrics() }
        model.onStem = { [weak self] stem, solo in solo ? self?.toggleStem(stem, solo: true) : self?.pressStem(stem) }
        model.onVocals = { [weak self] in self?.toggleVocals() }
        model.onStemsReset = { [weak self] in self?.playAllStems() }
        model.onStemsRetry = { [weak self] in self?.retryStems() }
        model.onSeparate = { [weak self] in self?.separate() }
        lyricsSync.onChange = { [weak self] in self?.lyricsTimingChanged() }
        lyricsSync.whisper = { [weak self] in self?.whisperBackend() }
        lyricsSync.onOffset = { [weak self] song, key, offset in
            // The check of a song from another app has its answer while the lyrics show: the Fix timing pill offers
            // the offset, and only a click on it moves the lines.
            guard let self, lyricsSong == song, lyricsApp != nil, let original = lyricsOriginal, LyricsFit.key(original) == key else { return }
            model.lyricsTiming = offset.map { $0 == 0 ? .onTime : .found($0) } ?? .unknown
            model.lyricsTimingKept = true
        }
        // Once Whisper writes a part of a song that it hasn't transcribed before, the song stays 30 seconds behind
        // until the lyrics are hidden or the HUD closes: a new song stops the writing while its lyrics are looked
        // up, and dropping the delay then would cut off the last 30 seconds of the song before it.
        lyricsSync.onNeedsLead = { [weak self] in self?.setLyricsDelay(true) }
        lyricsSync.onWritingFailed = { [weak self] in
            guard let self, model.lyricsWriting else { return }
            model.lyricsWriting = false
            if case let .found(lyrics) = model.lyrics, lyrics.lines.isEmpty { model.lyrics = .failed }
        }
        lyricsSync.onWritten = { [weak self] lyrics in
            guard let self, model.lyricsWriting else { return }
            // How far the written lines reach, against the position that is heard, for checking that the delay is
            // enough. Never the words.
            let position = model.track?.position(at: Date()) ?? 0
            log(String(format: "lyrics: %d lines written, the last at %.0fs, heard at %.0fs", lyrics.lines.count, lyrics.lines.last?.time ?? 0,
                       position - pitch.stemsDelay), .debug)
            model.lyrics = .found(lyrics)
            updateLyricLine()
        }
        model.onHoverChange = { [weak self] in
            // A hover that ended under a pointer that is still on the glass came from a change of the layout.
            if self?.model.hovering == false { self?.keepHover() }
            self?.updateHoverKeys()
            self?.updateKeysActive()
            self?.warmUpStems()
            self?.hoverFocus(moved: false)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                self?.updateKeysActive()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.keepPickerKeyboard()
        }
        statusItem.onFindKey = { [weak self] in
            if self?.state == .idle { self?.start() }
        }
        statusItem.onChangeKey = { [weak self] in self?.pickKey() }
        statusItem.onKeep = { [weak self] in self?.toggleKeep() }
        statusItem.onStop = { [weak self] in self?.stopPitch() }
        statusItem.onPlayAllStems = { [weak self] in self?.playAllStems() }
        statusItem.onSettings = { [weak self] in self?.settingsWindow.show() }
        statusItem.onOpenFile = { [weak self] in self?.openFile() }
        statusItem.onOpenLocation = { [weak self] in self?.openLocation() }
        statusItem.onMic = { [weak self] in self?.toggleMic() }
        statusItem.onShowMic = { [weak self] in self?.showMic() }
        statusItem.onCancelMic = { [weak self] in self?.cancelMic() }
        model.onMic = { [weak self] in self?.toggleMic() }
        model.onMicStop = { [weak self] in self?.stopMic() }
        model.onMicCancel = { [weak self] in self?.cancelMic() }
        model.onMicEdit = { [weak self] in self?.editMic($0) }
        model.onRecordingEdit = { [weak self] in self?.editRecording($0) }
        filePlayer.onActivity = { [weak self] in self?.openActivity = $0 }
        filePlayer.onPlaying = { [weak self] in self?.filePlays() }
        filePlayer.pauseOthers = { [weak self] done in
            guard let self else { return done() }
            nowPlaying.pauseOthers(except: FilePlayer.bundleID, then: done)
        }
        activityPill.onRetry = { [weak self] in
            guard let self else { return }
            if openActivity == nil, case .saveFailed = saveActivity { retrySave() } else { filePlayer.retry() }
        }
        activityPill.onInstall = { [weak self] in self?.filePlayer.installDownloader() }
        activityPill.onDismiss = { [weak self] in
            guard let self else { return }
            if openActivity != nil { filePlayer.dismiss() } else { saveActivity = nil }
        }
        model.onOpenRetry = { [weak self] in self?.filePlayer.retry() }
        model.onOpenInstall = { [weak self] in self?.filePlayer.installDownloader() }
        model.onOpenCancel = { [weak self] in self?.cancelOpening() }
        model.onOpenBackground = { [weak self] in self?.continueOpeningInBackground() }
        activityPill.onReveal = { [weak self] in
            if case .recovered = self?.saveActivity, let url = self?.recoveredURL {
                self?.saveActivity = nil
                return self?.open([url]) ?? ()
            }
            guard let url = self?.savedURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self?.saveActivity = nil
        }
        model.onSave = { [weak self] in self?.saveSong() }
        model.onSaveCancel = { [weak self] in self?.cancelSave() }
        model.onSaveStop = { [weak self] in self?.stopSave() }
        statusItem.onSave = { [weak self] in self?.saveSong() }
        model.onOpen = { [weak self] urls in self?.open(urls) }
        model.onAdd = { [weak self] urls, next in self?.add(urls, next: next) }
        model.onQueuePlay = { [weak self] id in self?.playFromQueue(id) }
        model.onQueueRemove = { [weak self] ids in self?.removeFromQueue(ids) }
        model.onQueueMove = { [weak self] ids, offset in self?.filePlayer.move(ids, to: offset) }
        model.onQueuePlayNext = { [weak self] id in self?.filePlayer.playNext(id) }
        model.onQueueToggle = { [weak self] in self?.toggleQueue() }
        model.onMore = { [weak self] in self?.showMoreMenu() }
        filePlayer.onQueue = { [weak self] in self?.syncQueue() }
        filePlayer.onStarted = { url, song in RecentSongs.add(url, song: song) }
        model.onRecentPlay = { [weak self] song in
            self?.log("recents: playing \(song.folder == song.url ? "a folder" : song.url.isFileURL ? "a file" : "a link")")
            self?.open([song.url])
        }
        model.onRecentAdd = { [weak self] song in self?.add([song.url], next: false) }
        model.onRecentRemove = { [weak self] song in self?.removeRecent(song) }
        // A listen or a song that opens takes the HUD from the recents, which wait for the next time nothing plays.
        model.$phase.removeDuplicates().sink { [weak self] phase in
            if phase != .idle, self?.model.recentsShown == true { self?.model.recentsShown = false }
        }.store(in: &prefChanges)
        // Published before the change, so the keys over the HUD are read again on the next turn.
        model.$recentsShown.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverKeys() }
        }.store(in: &prefChanges)
        // Right after the hotkey, the HUD is the key window without the pointer over it, and the hover keys aren't
        // registered: ↑, ↓ and Return reach the recents from the panel's own key events.
        recentsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, Self.logKeys, model.recentsFlipped {
                log("recents: key \(event.keyCode) in \(event.window === panel ? "the HUD" : event.window == nil ? "no window" : "another window")", .debug)
            }
            guard let self, event.window == nil || event.window === panel, model.recentsFlipped, model.opening == nil,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  [kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
            else { return event }
            return handleKey(Int(event.keyCode), shift: false, option: false) ? nil : event
        }
        model.onOpenFile = { [weak self] in self?.openFile() }
        model.onSeekFraction = { [weak self] in self?.seek(toFraction: $0) }
        model.onStemsClose = { [weak self] in self?.closeStems() }
        model.onOpenLocation = { [weak self] in self?.openLocation() }
        slow.onReturn = { [weak self] progress in self?.model.tempoReturn = progress }
        slow.onEnd = { [weak self] in self?.stopPitchIfUnwanted() }
        model.onPlayPause = { [weak self] in self?.playPause() }
        model.onSkip = { [weak self] in self?.skip($0) }
        model.onLink = { [weak self] url in self?.log("opening \(url.host() ?? url.absoluteString) in the browser") }
        filePlayer.onChange = { [weak self] in
            self?.syncRecording()
            self?.syncChords()
            self?.refreshStatus()
            self?.syncSpeed()
            self?.syncWaveform()
        }
        filePlayer.onMove = { [weak self] in self?.playerMoved(to: $0) }
        filePlayer.onClock = { [weak self] elapsed, at, rate in
            self?.nowPlaying.clock(elapsed: elapsed, at: at, rate: rate, bundleID: FilePlayer.bundleID)
        }
        // Muskey Player drops its loop when it opens a file, while the same song in another file stays the same song.
        filePlayer.onReplace = { [weak self] in self?.clearLoop() }
        stemsCache.live = { [separating = pitch.separatingLive] in separating.value }
        stemsCache.onDone = { [weak self] path, ok in
            guard let self else { return }
            if !ok { stemsCacheFailed.insert(path) }
            stemsCacheLooked = nil
            syncStemsCache()
            syncWaveformStems()
            if ok { fitShownLyrics() }
        }
        statusItem.onStopPlaying = { [weak self] in self?.filePlayer.close() }
        statusItem.onAddFiles = { [weak self] in self?.addFiles() }
        statusItem.onAddLocation = { [weak self] in self?.addLocation() }
        statusItem.onMiniPlayer = { [weak self] in self?.toggleMiniPlayer() }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === panel else { return event }
            // A save in progress leaves the stems and the songs as they are, and so do the shortcuts, which hide them.
            if model.saving != nil || model.opening != nil || model.shortcuts { return nil }
            // The list of the queue scrolls, and takes the sideways swipes that remove a song or play it next.
            if overQueue(event) { return event }
            // ⌘ with a scroll over the waveform zooms it, fingers up zooming in.
            if event.modifierFlags.contains(.command), overWaveform(event) {
                let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
                zoomWaveform(exp(Double(sign * event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)))
                return nil
            }
            // A scroll that begins over the time bar or the waveform while the song can't move does nothing, instead of
            // reaching the swipe that skips the song.
            if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                scrollOverStillBar = !model.seekable && overSeekPlace(event)
            }
            if scrollOverStillBar { return nil }
            return adjust(event) || swipe(event) ? nil : event
        }
        // A pinch reaches this monitor only while Muskey is the active app, since macOS sends trackpad gestures to the
        // active app alone. Muskey becomes the active app while the pointer is over the waveform (`hoverFocus`).
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self else { return event }
            return pinch(event) ? nil : event
        }
        nowPlaying.heard = { [weak self] report in self?.slow.heard(report) ?? report }
        nowPlaying.onPlayerReport = { [weak self] in self?.slow.playerReported($0) }
        slow.player = { [weak self] in self?.nowPlaying.player }
        slow.move = { [weak self] track, seconds in self?.movePlayer(track, to: seconds) }
        slow.movesKnown = { [weak self] id in self?.seekPaths[id] != nil || Self.forcedSeekPath != nil }
        slow.refresh = { [weak self] in self?.nowPlaying.refresh() }
        slow.onReadSpeed = { [weak self] in self?.syncSpeed() }
        slow.onFailed = { [weak self] wanted in
            guard let self else { return }
            slowFailedPlayer = slowedPlayer
            model.slowFailed = wanted
        }
        model.onSlowRetry = { [weak self] in self?.retrySlowing() }
        model.onLoopSet = { [weak self] in self?.setLoopEnd($0, $1) }
        model.onNotesSelect = { [weak self] in self?.selectNotesStem($0) }
        model.onNotesStart = { [weak self] in self?.startNotes() }
        model.onNotesStartFull = { [weak self] in self?.startNotes(full: true) }
        model.onNotesPart = { [weak self] whole in self?.pickNotesPart(whole: whole) }
        model.onLoopTyping = { [weak self] in self?.loopTyping($0) }
        nowPlaying.onSongChange = { [weak self] in
            // Another song during karaoke's countdown plays as it comes.
            if self?.karaokeRestart != nil { self?.endKaraokeRestart() }
            self?.songArrives()
            self?.songChanged($0)
        }
        nowPlaying.onTrack = { [weak self] in
            self?.syncChords()
            self?.syncWaveform()
            self?.checkLoopSong()
            self?.listenWhenPlaying()
            self?.resumeListen()
            self?.syncPauseStop()
            self?.syncSpeed()
            self?.syncSeekable()
            self?.syncSavable()
            self?.checkRecording()
            self?.syncPaused()
            self?.checkKaraokeRestart()
            self?.syncTrack()
            self?.startOnKnownKey()
            self?.syncSongKey()
            self?.syncNotesPlaying()
        }
        // The keys over the record differ from the ones over the rest of the HUD.
        overRecordChange = model.$overRecord.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverKeys() }
        }
        // And over the tab of an end of the region loop, the arrows nudge that end.
        loopEndChange = model.wave.$loopEnd.map { $0 != nil }.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverKeys() }
        }
        // Over the waveform, they move the song, and the numbers go to its bars once it numbers them.
        waveHoverChange = model.wave.$hovered.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverKeys() }
        }
        barsChange = model.wave.$zoom.map { $0 > 1.05 }.removeDuplicates()
            .combineLatest(model.$loop.map { $0?.end != nil }.removeDuplicates(), model.$tempo.map { $0 != nil }.removeDuplicates())
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateHoverKeys() } }
        // A new song's listen starts with no key, and the keys that change the key come back with its first estimate.
        keyChange = model.$key.map { $0 != nil }.removeDuplicates().sink { [weak self] keyed in
            DispatchQueue.main.async {
                if keyed { self?.model.heldGlass = nil }
                self?.updateHoverKeys()
            }
        }
        // The glass that a song change held at its size lets go once the listen ends or the HUD hides.
        heldGlassChange = model.$phase.combineLatest(model.$shown).sink { [weak self] phase, shown in
            guard phase != .listening || !shown else { return }
            DispatchQueue.main.async { self?.model.heldGlass = nil }
        }
        // A save and the shortcuts leave the HUD only the keys that end them.
        lockChange = model.$saving.map { $0 != nil }.removeDuplicates().combineLatest(model.$shortcuts.removeDuplicates()).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverKeys() }
        }
        // Published before the change, so the new value comes from the publisher.
        shownChange = model.$shown.removeDuplicates().sink { [weak self] shown in
            if shown { self?.shownAt = Date() }
            // The HUD opens on the record again, not on the queue that it closed on.
            if !shown {
                DispatchQueue.main.async {
                    self?.model.queueShown = false
                    self?.model.recentsShown = false
                    self?.closeNotesPicker()
                }
            }
            // The sink runs before `shown` changes.
            DispatchQueue.main.async { self?.syncPauseStop() }
            self?.updateWatching(shown: shown)
            self?.watchOption(shown)
            if !shown { DispatchQueue.main.async { self?.hoverFocus(moved: false) } }
            self?.updateLyricsClock(shown: shown)
            self?.updateStemMeters(shown: shown)
            self?.prepareStemModel(shown: shown)
            // With every stem playing, the song as it plays comes back once the HUD is gone.
            if !shown, self?.model.stemsAdjusted == false { self?.engageStems(false) }
            // Once the HUD has faded in, a song that changed while it was hidden swaps in on the record.
            if shown { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.syncTrack() } }
        }
        backdropChange = model.$lyricsFocus.combineLatest(model.$lyricsShown, model.$shown, prefs.$karaokeBackdrop)
            .map { $0 && $1 && $2 && $3 }.removeDuplicates().dropFirst().sink { [weak self] on in
                // Published before the change, so the panel is where the change leaves it on the next turn.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    karaokeBackdrop.show(on, below: panel)
                }
            }
        // The key row and the instruments that the pointer shows in karaoke, for testing the hover from a script.
        if Self.logKeys {
            model.$karaokeKeys.removeDuplicates().dropFirst().sink { [weak self] in self?.log($0 ? "karaoke: key row shown" : "karaoke: key row hidden", .debug) }
                .store(in: &prefChanges)
            model.$karaokeStems.removeDuplicates().dropFirst().sink { [weak self] in self?.log($0 ? "karaoke: instruments shown" : "karaoke: instruments hidden", .debug) }
                .store(in: &prefChanges)
        }
        karaokeChange = model.$lyricsFocus.removeDuplicates().dropFirst().sink { [weak self] on in
            self?.focusChangedAt = Date()
            // Published before the change. The stems and the pitch change start once karaoke's first frame is drawn,
            // since they hold the main thread for a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.karaokeChanged(on) }
        }
        glassChange = model.$glassFrame.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.panel.updatePassThrough() }
            // Published before the change, so the panel reads the new frame on the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, panel.isVisible else { return }
                // Karaoke opens or closes in place at once, so the glass doesn't slide after it.
                panel.keepOnScreen(animated: panel.alphaValue >= 1 && Date().timeIntervalSince(focusChangedAt) > 0.6)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            karaokeBackdrop.follow(panel)
            // Only a drag: the moves that keep the glass on the screen aren't a new place for it.
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
            panelMoved()
        }
        pitch.onFailure = { [weak self] error in self?.pitchFailed("\(error)") }
        // A phone that listens is sent away at the old rate and connects again at the new one.
        pitch.onRate = { WebStream.shared.rate = $0 }
        pitch.stillNeeded = { [weak self] in self?.pitchWanted ?? false }
        pitch.onStemsFailure = { [weak self] error in self?.stemsFailed("\(error)") }
        stopPitchOnSignals()
        network.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkChanged(online: path.status == .satisfied) }
        }
        network.start(queue: .global(qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            self?.lastOtherApp = app
        }

        if TestFlags.has("--listen") { toggle() }
        // Test flags: start a pitch change, or open the key picker, from a sample key.
        if let shift = Self.stringOption("--shift").flatMap(Int.init) {
            shiftBase = .sample
            model.key = .sample
            setShift(shift)
        }
        // `--status-key Em` starts with the menu bar showing that key, as if a listen had found it for the song.
        if let name = Self.stringOption("--status-key") {
            guard let key = DetectedKey(name: name) else { return log("--status-key needs a key like Cm, F# or Eb", .error) }
            songKey = (nowPlaying.track?.song, key, true, false)
        }
        if let name = Self.stringOption("--keep") {
            guard let key = DetectedKey(name: name) else { return log("--keep needs a key like Cm, F# or Eb", .error) }
            keptKey = key
            log("keeping \(key.name) for the next songs")
        }
        if TestFlags.has("--pick") || Self.lyricsTest != nil {
            shiftBase = shiftBase ?? .sample
            pickKey()
        }
        // `--stems-only guitar,piano` plays only those stems, as the chips would.
        if let names = Self.stringOption("--stems-only") {
            let playing = Set(names.split(separator: ",").compactMap { name in Stem.allCases.first { $0.name.lowercased() == name.lowercased() } })
            model.stemsAvailable = StemModel.installed
            shiftBase = shiftBase ?? .sample
            model.key = model.key ?? .sample
            // As if the HUD showed the stems a few seconds before a chip was pressed: `--stems-after 0` starts cold.
            let after = Self.stringOption("--stems-after").flatMap(Double.init) ?? 3
            if after > 0 { StemModel.warmUp() }
            // `all` presses Separate instruments and vocals, which plays every stem.
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in
                if names == "all" { separate() } else { setStems(Set(Stem.allCases).subtracting(playing)) }
            }
        }
        if let test = Self.lyricsTest {
            lyricsFinder.keep(test.state, for: test.track)
            syncTrack()
            toggleLyrics()
        } else if Self.lyricsPlain, model.picking {
            toggleLyrics()
        }
        recoverRecordings()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        if TestFlags.has("--settings") || firstLaunch {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            settingsWindow.show()
        }
        // The first launch shows the HUD too, as the hotkey does, so that someone who opened Muskey sees more than an
        // icon in the menu bar: the key of what plays, or Nothing playing with the ways to open a song.
        if firstLaunch || TestFlags.has("--first-launch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, state == .idle else { return }
                toggle()
            }
        }
        launched = true
        MainActor.assumeIsolated { startCLI() }
        // `--open PATH_OR_LINK` plays a file or a link, as a drop on the HUD does.
        if let text = Self.stringOption("--open"), let url = FilePlayer.url(from: text) { open([url]) }
        // `--notes-open STEM` opens the notes window on that stem of the song that `--open` plays, once it plays.
        // `--notes-fixture FILE` puts the notes of a fixture in the cache for that song first, for a Mac without them.
        if let name = Self.stringOption("--notes-open"), let stem = Stem.allCases.first(where: { $0.name.lowercased() == name.lowercased() }) {
            Task { @MainActor [weak self] in
                for _ in 0 ..< 40 {
                    try? await Task.sleep(for: .seconds(0.5))
                    guard let self else { return }
                    if playsInFilePlayer, let path = filePlayer.current?.path, let track = nowPlaying.track {
                        if let file = Self.stringOption("--notes-fixture"), let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                           let fixture = try? JSONDecoder().decode(NotesFixture.self, from: data) {
                            NotesStore.save(fixture, path: path, stem: stem)
                        }
                        return openNotes(path: path, track: track, stem: stem)
                    }
                }
                self?.log("notes: no song played for --notes-open", .notice)
            }
        }
        // `--notes-file FIXTURE` opens the notes window on the notes that `--notes-headless` wrote, without a song.
        if let path = Self.stringOption("--notes-file"), let notes = NotesModel.fixture(path) {
            wireNotes(notes)
            notesWindow.show(notes)
            syncNotesPlaying()
        }
        // `--install-yt-dlp` presses Install yt-dlp on the pill.
        if TestFlags.has("--install-yt-dlp") { filePlayer.installDownloader() }
        // `--menu "Stop Playing" [--menu-after SECONDS]` picks an item of the menu bar menu, which no automation can
        // open on macOS 27.
        // `--glyph-sheet` opens a window of live records with the play and pause glyph on their covers.
        if TestFlags.has("--glyph-sheet") {
            let paths = Self.stringOption("--glyph-covers")?.split(separator: ",").map(String.init) ?? []
            let window = NSWindow(contentViewController: NSHostingController(rootView: GlyphSheet(covers: GlyphSheet.covers(paths: paths))))
            window.title = "Glyph sheet"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            glyphSheet = window
        }
        // `--open-menu-after S` opens the menu bar menu after S seconds, so a posted key reaches the open menu.
        if let after = Self.stringOption("--open-menu-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in
                log("menu: opened", .debug)
                statusItem.openMenu()
            }
        }
        if let title = Self.stringOption("--menu") {
            let after = Self.stringOption("--menu-after").flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in
                log(statusItem.perform(title) ? "menu: \(title)" : "menu: no item \(title)", .debug)
            }
        }
        if let urls = openedEarly {
            openedEarly = nil
            open(urls)
        }
    }

    /// Open With in Finder, or a file dropped on Muskey's icon.
    func application(_: NSApplication, open urls: [URL]) {
        guard launched else { return openedEarly = (openedEarly ?? []) + urls }
        open(urls)
    }

    /// Plays files or links: dropped on the HUD, pasted, or picked with Open File… and Open URL…, or sent by the tool
    /// or the phone (`fromMac` false).
    private func open(_ urls: [URL], fromMac: Bool = true) {
        if fromMac { revealHeadless() }
        withFolders(urls) { [self] urls, folders in
            log("opening \(urls.count == 1 ? (urls[0].isFileURL ? "a file" : "a link") : "\(urls.count) items")\(folders.isEmpty ? "" : " from \(Set(folders.values).count == 1 ? "a folder" : "\(Set(folders.values).count) folders")")")
            // A song that a person opens shows, also over one that keeps opening in the background.
            openingInBackground = false
            raisesHUD = true
            filePlayer.open(urls, folders: folders)
            raisesHUD = false
        }
    }

    // MARK: Command line

    /// The `muskey` tool reaches the app through `CLIService`, which plays its songs here.
    @MainActor private func startCLI() {
        // A Muskey that crashed or was killed while a phone listened left the output muted.
        if OutputMute.leftMuted {
            OutputMute.set(false)
            log("remote: the sound output that the last run left muted is unmuted")
        }
        let cli = CLIService.shared
        cli.play = { [weak self] request, job in self?.cliPlay(request, job: job) }
        cli.knownKey = { [weak self] song in self?.knownKey(for: song)?.key }
        cli.serve = { WebLinks.shared.serve($0) }
        WebLinks.shared.startIfNeeded()
        WebRemote.shared.recents = { [weak self] in await self?.remoteRecents() ?? [] }
        WebRemote.shared.state = { [weak self] in self?.remoteState() }
        WebRemote.shared.nowCover = { [weak self] in self?.model.artwork }
        WebRemote.shared.mute = { [weak self] in self?.setOutputMuted($0) }
        WebRemote.shared.transport = { [weak self] in self?.remoteTransport($0) }
        WebRemote.shared.songShown = { [weak self] in self?.remoteSongShown() }
        WebRemote.shared.loop = { [weak self] in self?.remoteLoop($0) }
        WebRemote.shared.volume = { [weak self] stem, volume in self?.setStemVolume(stem, (volume * 100).rounded() / 100) }
        WebRemote.shared.waveform = { [weak self] in self?.model.wave.waveform }
        WebRemote.shared.waveLanes = { [weak self] in self?.remoteLanes($0) ?? [] }
        WebStream.shared.onListening = { [weak self] on in self?.phoneListens(on) }
        pitch.stream = WebStream.shared.ring
        WebRemote.shared.update()
        cli.start()
    }

    /// The changes for the song that plays now which still wait for the HUD and the key.
    private var liveWait: (request: CLIRequest, job: CLIJob)?

    /// Plays the inputs of the tool in the HUD, or listens to the song that plays now, and applies the changes once
    /// the song plays and its key is known: the key, the speed, the region loop, the stems and the notes window.
    @MainActor private func cliPlay(_ request: CLIRequest, job: CLIJob) {
        // From the phone with Settings > Remote > Hide HUD for phone actions on: the HUD runs without its window until the job ends,
        // unless it was already up on the Mac.
        if request.headless == true, state == .idle || panel.headless {
            if !panel.headless { log("the HUD runs hidden for the phone") }
            panel.headless = true
            headlessJobs += 1
            job.onEnd = { [weak self] in self?.endHeadlessJob() }
        }
        if request.inputs.count == 1, let uri = Spotify.uri(from: request.inputs[0]) { return cliSpotify(uri, request: request, job: job) }
        if request.inputs.contains(where: Spotify.isLink) { return job.fail("that Spotify link names no song, album or playlist") }
        let urls = request.inputs.compactMap(FilePlayer.url(from:))
        guard urls.count == request.inputs.count else { return job.fail("Muskey can't open \(request.inputs.first ?? "the input")") }
        if (request.stems != nil || request.mute != nil || request.notes != nil), !StemModel.installed {
            return job.fail("the separation model is not installed. Install it in Settings > Instruments and vocals")
        }
        let ready = { [weak self] () -> Bool in
            guard let self else { return false }
            return model.pending == nil && model.key != nil && state == .showing
        }
        if urls.isEmpty {
            guard request.notes == nil else {
                return job.fail("--notes needs a song file or a link. For the song that plays now, press T over the HUD")
            }
            if state == .idle { toggle() }
            // A pitch change that only corrects a tempo has no key to open the HUD on, so the HUD listens for one.
            if state == .idle { start() }
            job.step = "Listening"
            // Changes sent while an earlier one still waits for the HUD or the key are applied as one, the newest
            // value of each winning. Waiting side by side, they would apply in the order that their waits end.
            var request = request
            if let waiting = liveWait, !waiting.job.done {
                request = waiting.request.followed(by: request)
                waiting.job.finish()
            }
            liveWait = (request, job)
            // The tempo, the instruments and a loop need no key, so a song whose key isn't found still takes them
            // once the listen ends.
            let listened = { [weak self] () -> Bool in
                guard let self else { return false }
                return model.pending == nil && state != .idle && (model.key != nil || model.phase != .listening)
            }
            let changes = request
            return cliWait(job, seconds: 90, until: request.key == nil ? listened : ready) { [weak self] in
                guard let self else { return }
                if liveWait?.job === job { liveWait = nil }
                cliApply(changes, job: job)
            }
        }
        let before = filePlayer.current?.path
        let songBefore = nowPlaying.track?.song
        let opened = Date()
        // A failure that the HUD showed before this song opened isn't this song's failure.
        let staleActivity = openActivity
        var fresh = false
        open(urls, fromMac: false)
        if let link = urls.first(where: { !$0.isFileURL }), !LinkDownload.directExtensions.contains(link.pathExtension.lowercased()), Downloader.find() == nil {
            return job.fail("links of this site need yt-dlp. Click Install yt-dlp in Muskey's HUD on the Mac")
        }
        job.step = urls[0].isFileURL ? "Opening" : "Downloading"
        // Muskey Player names the new song once it plays it. The same file opened again plays as the song that was there.
        cliWait(job, seconds: urls[0].isFileURL ? 60 : 900, until: { [weak self] in
            guard let self else { return false }
            // A link that downloads keeps the song that played before it in Muskey Player until the download ends.
            if openActivity != staleActivity { fresh = true }
            switch openActivity {
            case let .opening(step, _, _, progress):
                fresh = true
                job.step = switch step {
                case .reading: "Reading the link"
                case .downloading: "Downloading"
                case .converting: "Converting"
                case .updating: "Updating yt-dlp"
                }
                job.progress = progress
                return false
            case .installing:
                fresh = true
                job.step = "Installing yt-dlp"
                return false
            case .failed where fresh:
                job.fail("the link couldn't be downloaded")
                return false
            case .installFailed where fresh:
                job.fail("yt-dlp couldn't be installed")
                return false
            case .unplayable where fresh:
                job.fail("Muskey can't play that file")
                return false
            default: break
            }
            guard playsInFilePlayer, let path = filePlayer.current?.path else { return false }
            if job.step != "Reading the key", path != before || Date().timeIntervalSince(opened) > 3 { job.step = "Reading the key" }
            // Now Playing names the new song a moment after Muskey Player starts it, and reports it as a song change a
            // second later, which makes the HUD listen to it. Until then the HUD can show the key of the song that
            // played before. A file named like the song before it is taken as that song after 3 seconds.
            let song = nowPlaying.track?.song
            let named = path == before || (song != songBefore ? nowPlaying.reported == song : Date().timeIntervalSince(opened) > 3)
            return (path != before || Date().timeIntervalSince(opened) > 3) && named && ready()
        }) { [weak self] in self?.cliApply(request, job: job) }
    }

    /// Plays a Spotify link in Spotify, then listens to it once Spotify plays the new song, as the hotkey does, and
    /// applies the changes. Sent from away from the Mac, the song plays with the Mac's sound output muted.
    @MainActor private func cliSpotify(_ uri: String, request: CLIRequest, job: CLIJob) {
        guard request.notes == nil else {
            return job.fail("--notes needs a song file or a link. For a song from Spotify, press T over the HUD")
        }
        if (request.stems != nil || request.mute != nil), !StemModel.installed {
            return job.fail("the separation model is not installed. Install it in Settings > Instruments and vocals")
        }
        let unmuted = request.remote && !muteForRemote()
        let before = nowPlaying.track
        let sent = Date()
        job.step = "Opening Spotify"
        log("cli: playing \(uri.split(separator: ":").dropLast().joined(separator: ":")) in Spotify")
        Spotify.play(uri) { [weak self] outcome in
            guard let self else { return }
            // Nothing plays after a failure, so the sound that the remote muted comes back.
            switch outcome {
            case .refused:
                restoreRemoteMute()
                return job.fail("Muskey isn't allowed to control Spotify. Allow it in System Settings > Privacy & Security > Automation")
            case .needsConsent:
                restoreRemoteMute()
                return job.fail("Muskey needs permission to control Spotify. Click Allow in the dialog on the Mac, then send the link again")
            case let .failed(reason):
                restoreRemoteMute()
                return job.fail(reason)
            case .playing: break
            }
            job.step = "Listening"
            cliWait(job, seconds: 60, until: { [weak self] in
                guard let self, let track = nowPlaying.track, track.bundleID == Spotify.bundleID, track.playing else { return false }
                // The song that Spotify played before is still reported for a moment after the new one starts.
                let changed = before?.bundleID != Spotify.bundleID || track.song != before?.song || Date().timeIntervalSince(sent) > 4
                guard changed else { return false }
                if state == .idle { toggle() }
                return model.pending == nil && model.key != nil && state == .showing && model.track?.song == track.song
            }) { [weak self] in self?.cliApply(request, job: job, notes: unmuted ? ["the Mac's sound couldn't be muted"] : []) }
        }
    }

    /// Whether the sound output was muted before Muskey muted it for the remote, while Muskey's mute lasts. The switch
    /// on the remote and the hotkey end it, and the HUD closing doesn't, since nobody may be at the Mac to hear it.
    private var remoteMuteBefore: Bool?

    /// Mutes the sound output, and tells whether it is muted now.
    @discardableResult private func muteForRemote() -> Bool {
        guard remoteMuteBefore == nil else { return true }
        guard let before = OutputMute.muted else {
            log("remote: the sound output has no mute or volume, the pitch change sends it silence")
            return false
        }
        guard before || OutputMute.set(true) else {
            log("remote: the sound output can't be muted, the pitch change sends it silence", .error)
            return false
        }
        remoteMuteBefore = before
        // Kept for a Muskey that crashes or is killed while the output is muted: the next launch unmutes it.
        if !before { OutputMute.leftMuted = true }
        log("remote: sound output muted")
        return true
    }

    private func restoreRemoteMute() {
        guard let before = remoteMuteBefore else { return }
        remoteMuteBefore = nil
        if !before, OutputMute.stillMuted || OutputMute.muted == true {
            OutputMute.set(false)
            log("remote: sound output unmuted")
        }
    }

    /// The Mac's sound output from the remote's switch.
    private func setOutputMuted(_ muted: Bool) {
        if muted {
            muteForRemote()
        } else {
            remoteMuteBefore = nil
            OutputMute.set(false)
        }
    }

    /// What the web remote shows of the HUD: the song that plays, its key and the change, and the Mac's sound output.
    @MainActor private func remoteState() -> WebRemote.State {
        phonePolled()
        // The HUD's record keeps the song that it showed last while it is hidden, so the phone reads the player then.
        let track = model.shown ? model.track ?? nowPlaying.track : nowPlaying.track
        let app = track?.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName }
        // A play, a pause or a seek that the player hasn't reported yet, as the HUD shows it.
        let playing = remotePlaying(track) ?? false
        let seeked = seekTarget.flatMap { target in
            track.flatMap { target.song == $0.song && Date().timeIntervalSince(target.at) < 2 ? target.seconds + (playing ? Date().timeIntervalSince(target.at) : 0) : nil }
        }
        return WebRemote.State(
            title: track?.title, artist: track?.artist, app: playsInFilePlayer ? "Muskey Player" : app, playing: playing,
            listening: state != .idle && model.phase == .listening, key: remoteKey(track)?.code, shift: model.shift, relative: model.relative,
            bpm: model.tempo?.bpm, speed: currentSpeed, cover: model.artwork != nil, muted: OutputMute.muted,
            relativeKeys: prefs.relativeKeys, file: playsInFilePlayer ? filePlayer.current?.path : nil,
            // While the stems play seconds behind the player, the phone shows the moment that is heard, as the lyrics do.
            position: seeked ?? track?.position(at: Date()).map { max(0, $0 - pitch.stemsDelay) }, duration: track?.duration,
            seekable: model.seekable, mac: Self.macName,
            mutedStems: model.stemsMuted.map { $0.name.lowercased() }.sorted(),
            stemVolumes: Dictionary(uniqueKeysWithValues: model.stemVolumes.map { ($0.key.name.lowercased(), $0.value) }),
            recordingDenied: AudioCapturePermission.status == .denied ? true : nil,
            loop: model.loop.map { WebRemote.State.Loop(start: $0.start, end: $0.end) },
            // Changes when more of the song is heard, and when the phone's waveforms per instrument change or fill in.
            wave: model.wave.waveform.map { wave in
                remoteLanes(wave).reduce(wave.levels.count &* 7919 &+ wave.levels.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) { hash, stem in
                    hash &* 31 &+ (stem.rawValue &+ 1) &* 1_000_003 &+ (wave.stems?[stem.rawValue]?.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } ?? 0)
                }
            },
            source: remoteSource(track).kind, sourceApp: remoteSource(track).app,
            rewinds: remoteRewinds, rewindAgo: remoteRewinds > 0 ? Date().timeIntervalSince(remoteRewoundAt) : nil,
            rewindSoon: playing && (model.stemsProgress != nil || model.lyricsWaiting != nil || karaokeRestart == .waitingForModel || {
                if case .seeking = karaokeRestart { return true }
                return false
            }())
        )
    }

    /// The backspins that the Mac's output played, for the phone's record, which spins back whether the HUD shows or not.
    private var remoteRewinds = 0
    private var remoteRewoundAt = Date.distantPast

    /// The output stepped back in the song: the records on the HUD and on the phone turn back.
    private func recordRewound() {
        if model.shown { model.rewinds += 1 }
        remoteRewinds += 1
        remoteRewoundAt = Date()
    }

    /// The key of the song that plays: the HUD's while it is up, and the menu bar's while it is closed, since the HUD
    /// keeps the key of the last song that it showed.
    @MainActor private func remoteKey(_ track: NowPlaying.Track?) -> DetectedKey? {
        if state != .idle { return model.key }
        guard let songKey, songKey.song == nil || songKey.song == track?.song else { return nil }
        return songKey.key
    }

    /// The source of the song for the badge on the phone's cover, kept for the file that Muskey Player plays, since
    /// finding a download's link reads the index of links.
    private var remoteSourceCache: (path: String, kind: String)?

    @MainActor private func remoteSource(_ track: NowPlaying.Track?) -> (kind: String?, app: String?) {
        guard playsInFilePlayer, let path = filePlayer.current?.path else {
            return track?.bundleID.map { ("app", $0) } ?? (nil, nil)
        }
        if let cached = remoteSourceCache, cached.path == path { return (cached.kind, nil) }
        let cache = LinkCache()
        var kind = "file"
        if path.hasPrefix(cache.folder.path), let host = cache.link(ofFile: path)?.host?.lowercased() {
            kind = host.hasSuffix("spotify.com") ? "spotify" : host.hasSuffix("youtube.com") || host == "youtu.be" ? "youtube" : "link"
        }
        remoteSourceCache = (path, kind)
        return (kind, nil)
    }

    /// Whether the song plays, counting a play or pause asked for in the last 1.5 seconds that the player hasn't reported.
    @MainActor private func remotePlaying(_ track: NowPlaying.Track?) -> Bool? {
        if let guess = playGuess, Date().timeIntervalSince(guess.at) < 1.5 { return guess.playing }
        return track?.playing
    }

    /// A phone picked **Phone** in the web remote: the Mac's output is muted, and the pitch change runs, since the
    /// phone hears what it plays. The last phone leaving puts the sound back as it was.
    private var phoneListening = false
    private var phoneWatch: Timer?

    @MainActor private func phoneListens(_ on: Bool) {
        guard on != phoneListening else { return }
        phoneListening = on
        phoneWatch?.invalidate()
        phoneWatch = nil
        // Without the permission to record the Mac's sound, the phone would get silence from a muted Mac. The page
        // reads the refusal in the state and goes back to the Mac.
        let denied = AudioCapturePermission.status == .denied
        pitch.speakersSilent = on && !denied
        if on, denied {
            log("remote: a phone listens, but system audio recording is not allowed", .error)
        } else if on {
            muteForRemote()
            if !pitch.running { startPitch() }
            // Anything that stopped the pitch change, like a device change or a failed start, is undone while the phone
            // listens, or it would hear silence while the muted Mac plays.
            phoneWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.phoneListening, !self.pitch.running, AudioCapturePermission.status == .granted else { return }
                    self.startPitch()
                }
            }
        } else {
            log("remote: no phone listens, the Mac's sound is back as it was")
            restoreRemoteMute()
            stopPitchIfUnwanted()
        }
    }

    private var remoteWarmedAt = Date.distantPast

    /// The region loop from the phone: a tap on its loop button works as R does, a drag across the waveform sets the
    /// loop where the finger went, and a handle moves one end.
    /// Answers why nothing was done, for the phone to show.
    @MainActor private func remoteLoop(_ action: WebLoop) -> String? {
        switch action.action {
        case "press":
            guard model.seekable || model.loop != nil else { return Self.cantMove }
            pressLoop(snapping: true, behind: min(action.behind ?? 0, 10))
        case "set":
            guard let start = action.start, let end = action.end, end > start + 0.25 else { return nil }
            guard model.seekable else { return Self.cantMove }
            let duration = nowPlaying.track?.duration ?? end
            loopSnap?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { model.loop = LoopRegion(start: max(0, start), end: min(end, duration)) }
            loopSong = nowPlaying.track?.song
            log(String(format: "region loop from the phone: %.2f s to %.2f s", start, end))
            applyLoop()
        case "move":
            guard let loop = model.loop, let seconds = action.seconds else { return nil }
            let end: LoopEnd = action.which == "end" ? .end : .start
            setLoopEnd(end, loop.clamped(end, seconds, duration: nowPlaying.track?.duration ?? .infinity))
        default:
            clearLoop()
        }
        return nil
    }

    private static let cantMove = "The player can't move this song now"

    /// A phone shows the song, so the stems model is loaded as it is for a pointer over the HUD, and a tap on an
    /// instrument starts the stems in a second instead of waiting for the model. It is freed 15 minutes after the
    /// phone stops asking, as after the HUD closes.
    /// The instruments that get a waveform each on the phone while some are muted: up to three of those that play,
    /// the ones with the most sound in the song.
    @MainActor private func remoteLanes(_ wave: SongWaveform) -> [Stem] {
        guard !model.stemsMuted.isEmpty, wave.stems != nil else { return [] }
        let sounds = Stem.shown.filter { !model.stemsMuted.contains($0) }.compactMap { stem in
            wave.sound(of: stem).flatMap { $0 > 0 ? (stem, $0) : nil }
        }
        return sounds.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    /// The phone showed the song that plays a moment ago: its state is asked for every 1.5 seconds while it does.
    private var remoteSongSeenAt = Date.distantPast
    private var phoneShowsSong: Bool { Date().timeIntervalSince(remoteSongSeenAt) < 5 }

    /// A phone has the page open: it asks for the state every second and a half. The helper that names the song
    /// runs for it, or the page would show nothing playing with the HUD closed.
    private var phonePolledAt = Date.distantPast
    private var phonePollEnd: DispatchWorkItem?
    private var phoneWatches: Bool { Date().timeIntervalSince(phonePolledAt) < 6 }

    @MainActor private func phonePolled() {
        phonePolledAt = Date()
        if !nowPlaying.watching { updateWatching(shown: model.shown) }
        phonePollEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            updateWatching(shown: model.shown)
        }
        phonePollEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5, execute: work)
    }

    @MainActor private func remoteSongShown() {
        remoteSongSeenAt = Date()
        // A song from another app gets its waveforms per instrument from what its stems play, which the stem meters
        // read, also while the HUD is hidden.
        if !model.shown, stemMeterClock == nil, model.stemsEngaged { updateStemMeters(shown: false) }
        guard Date().timeIntervalSince(remoteWarmedAt) > 60 else { return }
        remoteWarmedAt = Date()
        guard StemModel.installed, pitch.stemsFeed == nil else { return }
        StemModel.warmUp()
        if !model.shown { prepareStemModel(shown: false) }
    }

    /// The Mac's name as Settings > General > Sharing shows it, read once without a lookup on the network.
    private static let macName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"

    /// Answers why nothing was done, for the phone to show.
    @MainActor private func remoteTransport(_ request: WebTransport) -> String? {
        switch request.action {
        // The page asks for the state that its button shows the opposite of, so a tap on a page that is behind the
        // Mac does nothing instead of the reverse.
        case "play", "pause":
            let playing = remotePlaying(nowPlaying.track) ?? false
            if request.action == "play" ? !playing || model.phase == .idle : playing { playPause() }
        case "back", "forward":
            guard model.seekable, songRecording == nil else { return Self.cantMove }
            seek(by: request.action == "back" ? -5 : 5)
        case "seek":
            guard let seconds = request.seconds, let duration = nowPlaying.track?.duration, duration > 0, model.seekable, songRecording == nil else {
                return Self.cantMove
            }
            seek(to: seconds, flash: "\(Int((seconds / duration * 100).rounded()))%")
        default: break
        }
        return nil
    }

    /// Jobs from the phone that run with the HUD hidden.
    private var headlessJobs = 0

    /// The last job from the phone that ran with the HUD hidden ended: the hidden HUD closes, and the next request
    /// starts a new one. The changes keep running, as after a HUD is closed on the Mac.
    @MainActor private func endHeadlessJob() {
        headlessJobs = max(0, headlessJobs - 1)
        guard headlessJobs == 0, panel.headless else { return }
        if state != .idle { dismiss() }
        panel.headless = false
    }

    /// Someone at the Mac asked for the HUD while it ran hidden for the phone, so it shows from now on.
    private func revealHeadless() {
        guard panel.headless else { return }
        panel.headless = false
        log("the HUD that ran hidden for the phone shows")
        guard state != .idle else { return }
        panel.present()
        panel.setInteraction(clickable: true, keyboard: model.picking)
    }

    @MainActor private func cliWait(_ job: CLIJob, seconds: Double, until: @escaping () -> Bool, then: @escaping () -> Void) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(seconds)
            while !until() {
                guard !job.cancelled, !job.done else { return }
                guard Date() < deadline else { return job.fail(job.step == "Listening" ? "no key was found for the song that plays" : "the song didn't play in Muskey") }
                try? await Task.sleep(for: .seconds(0.25))
            }
            then()
        }
    }

    @MainActor private func cliApply(_ request: CLIRequest, job: CLIJob, notes: [String] = []) {
        var said: [String] = []
        if let text = request.key, let key = model.key {
            guard let shift = key.cliShift(to: text) else { return job.fail("unknown key \"\(text)\"") }
            change(to: shift.semitones, relative: shift.relative)
            said.append("in \(model.heard?.name ?? text)" + (shift.semitones == 0 ? "" : " (\(Shift.text(model.shift)))"))
        } else if model.shift != 0, let heard = model.heard {
            // A song keeps the changes that were made to it before, so the answer names those as well.
            said.append("in \(heard.name) (\(Shift.text(model.shift)))")
        }
        if let speed = request.speed {
            playSpeed(min(max(speed, 0.5), fastestSpeed))
        }
        if request.speed != nil || abs(currentSpeed - 1) > 0.001 {
            said.append(String(format: "at %.0f%% speed", currentSpeed * 100))
        }
        var region: ClosedRange<Double>?
        if request.from != nil || request.to != nil, let duration = nowPlaying.track?.duration, duration > 0 {
            let start = max(0, request.from ?? 0), end = min(duration, request.to ?? duration)
            if end > start + 0.25 {
                setNotesLoop(start, end)
                region = start ... end
                let clock = { (seconds: Double) in String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
                said.append("looping \(clock(start)) to \(clock(end))")
            }
        }
        if let playing = request.stems ?? request.mute.map({ muted in muskeyStemNames.filter { !muted.contains($0) } }) {
            let muted = Set(Stem.allCases.filter { !playing.contains($0.name.lowercased()) })
            setStems(muted)
            said.append(request.stems != nil ? "only \(request.stems!.joined(separator: ", "))" : "without \(request.mute!.joined(separator: ", "))")
        }
        if let name = request.notes {
            guard playsInFilePlayer, let path = filePlayer.current?.path, let track = nowPlaying.track else {
                return job.fail("the song didn't play in Muskey, so its notes can't be transcribed")
            }
            let stems = notesStems
            let stem = name == "auto"
                ? richestNotesStem(stems, in: region) ?? lastNotesStem.flatMap { stems.contains($0) ? $0 : nil } ?? (stems.contains(.bass) ? .bass : stems[0])
                : stems.first { $0.name.lowercased() == name }
            guard let stem else { return job.fail("the \(name) can't be transcribed") }
            openNotes(path: path, track: track, stem: stem, region: region)
            said.append("transcribing the \(stem.name.lowercased())")
        }
        let title = model.track?.title ?? "the song"
        job.finish(([urlsPlaying(request) ? "Playing \(title)" : "Listening to \(title)"] + said + notes).joined(separator: ", "))
    }

    private func urlsPlaying(_ request: CLIRequest) -> Bool { !request.inputs.isEmpty }

    /// The songs of Recents for the web remote, with their details read once and kept with the rows of the record's
    /// back, and the key and tempo that Muskey knows for each.
    @MainActor private func remoteRecents() async -> [QueueItem] {
        var rows: [QueueItem] = []
        for entry in RecentSongs.load() where !FilePlayer.isFolder(entry.url) {
            let id = entry.url.absoluteString
            var row = recentRows[id] ?? QueueItem(url: entry.url, cached: entry.song)
            if !row.read, let file = row.file, !Volumes.remote(file.path), FileManager.default.fileExists(atPath: file.path) {
                row.apply(await QueueItem.details(file, name: entry.url.isFileURL ? nil : SongName.link(entry.url)))
                recentRows[id] = row
            } else if recentRows[id] == nil {
                // A row whose file is gone is kept too, or it would be built again at every question of the phone.
                recentRows[id] = row
            }
            let song: [String?] = [row.title, row.artist, row.album]
            if row.key == nil { row.key = knownKey(for: song)?.key }
            if row.bpm == nil { row.bpm = knownTempo(for: song)?.bpm }
            rows.append(row)
        }
        return rows
    }

    /// Counts what was opened, so a folder that was still being read when something else was opened doesn't replace it.
    private var opensAsked = 0

    /// A folder opens as its songs and the songs of its subfolders, read off the main thread, with the folder that each
    /// song came from. Files and links pass through at once.
    private func withFolders(_ urls: [URL], then open: @escaping ([URL], [URL: URL]) -> Void) {
        opensAsked += 1
        guard urls.contains(where: FilePlayer.isFolder) else { return open(urls, [:]) }
        let asked = opensAsked
        Task { @MainActor [weak self] in
            let expanded = await Task.detached(priority: .userInitiated) {
                urls.map { url in FilePlayer.isFolder(url) ? (url, FilePlayer.songs(in: url)) : (url, [url]) }
            }.value
            // A big folder, or one on a network volume, can take seconds to read. A song opened meanwhile stays.
            guard let self, asked == opensAsked else { return }
            var songs: [URL] = []
            var folders: [URL: URL] = [:]
            for (opened, found) in expanded {
                if found.isEmpty { filePlayer.noSongs(in: opened) }
                for song in found where song != opened { folders[song] = opened }
                songs += found
            }
            if !songs.isEmpty { open(songs, folders) }
        }
    }

    // MARK: A song that opens

    /// A person opens a song right now, so a step that it starts with shows the HUD. A song of the queue that starts
    /// to download when the one before it ends leaves a closed HUD closed, and shows in the activity pill.
    private var raisesHUD = false
    /// The HUD was closed when the song started to open, so Cancel closes it again.
    private var raisedForOpening = false
    /// Continue in Background over a song with changes: the HUD shows that song again, and the song that opens shows
    /// in the activity pill until it plays.
    private var openingInBackground = false
    /// The step that the log named last, which a song that keeps opening in the background still has.
    private var loggedOpening: OpeningState?

    /// The HUD shows the song that opens, and the activity pill shows it while the HUD is closed.
    private func syncOpening() {
        let actual = OpeningState(openActivity)
        // One line per step, not per part done.
        if actual?.step != loggedOpening?.step || actual?.failed != loggedOpening?.failed {
            log(actual.map { "opening: \($0.step ?? "failed")" } ?? "opening: done")
        }
        loggedOpening = actual
        if actual == nil { openingInBackground = false }
        let opening = openingInBackground ? nil : actual
        let started = model.opening == nil && opening != nil
        // The HUD shows the record of a song, which stays where it is: the glass keeps its size until the song has
        // opened. Karaoke, the shortcuts and the stem picker of T have no record at that place.
        if started, state != .idle, model.phase == .listening || model.phase == .done, model.track?.title?.isEmpty == false {
            model.openingOverSong = true
            let plain = !model.lyricsFocus && !model.shortcuts && model.notesPicking == nil && model.saving == nil
            model.openingGlass = plain && model.glassFrame.width > 0 ? model.glassFrame.size : nil
        }
        if model.opening != opening { model.opening = opening }
        syncOpeningRecord()
        if opening != nil {
            if state == .idle, raisesHUD {
                session += 1
                state = .showing
                model.key = nil
                model.phase = .idle
                model.shown = true
                raisedForOpening = true
                // A HUD that closed while the song kept opening has no record to keep in place any more.
                model.openingGlass = nil
                panel.present()
                // The buttons take clicks also on a HUD that closed while the song kept opening and opens again.
                panel.setInteraction(clickable: true, keyboard: false)
                log("the HUD shows the song that opens")
            }
            // A listen and its result can leave the glass without clicks, and Cancel and Retry need them. The key
            // picker already takes them, with the keyboard, which it keeps.
            if started, state != .idle, !model.picking { panel.setInteraction(clickable: true, keyboard: false) }
        }
        syncActivityPill()
        updateHoverKeys()
    }

    /// A song that plays while another one opens keeps its record in the HUD, from the moment that it plays until
    /// the other song has opened. A HUD that the link opened learns the song a moment later.
    private func syncOpeningRecord() {
        guard model.opening != nil else {
            if model.openingOverSong { model.openingOverSong = false }
            if model.openingGlass != nil { model.openingGlass = nil }
            return
        }
        if !model.openingOverSong, model.playing, model.track?.title?.isEmpty == false { model.openingOverSong = true }
    }

    /// Continue in Background, and Backspace: the song keeps opening in the activity pill, and the HUD opens again when
    /// it plays. Over a song that plays with changes (a pitch or tempo change, stems, a loop, karaoke or the key
    /// picker), the HUD goes back to that song. Otherwise it closes.
    private func continueOpeningInBackground() {
        guard model.opening != nil else { return }
        let changed = changesRun || model.loop != nil || model.lyricsFocus || model.picking
        guard model.openingOverSong, changed, !raisedForOpening else {
            log("opening continues in the background")
            return dismiss()
        }
        log("opening continues in the background, back to the song that plays")
        openingInBackground = true
        syncOpening()
    }

    /// The pill at the top right shows a song that opens only while the HUD doesn't, and a save once that is done.
    private func syncActivityPill() {
        let onHUD = state != .idle && model.saving == nil && !openingInBackground
        activityPill.show(onHUD ? saveActivity : openActivity ?? saveActivity)
    }

    /// Cancel, and the ✕ of a failure: the HUD shows what it showed before, or closes if the song opened it.
    private func cancelOpening() {
        filePlayer.dismiss()
        guard raisedForOpening else {
            // A result that was about to hide waited for the song, and hides now.
            if state == .showing, model.phase == .done, !model.picking, let delay = resultHideDelay { dismiss(after: delay) }
            return
        }
        raisedForOpening = false
        if model.phase == .idle { dismiss() }
    }

    // MARK: Chords

    /// The beats and the chords of each file that Muskey Player played while the lyrics showed, until Muskey quits.
    private var grids: [String: SongGrid] = [:]
    private var gridTask: (path: String, task: Task<Void, Never>)?

    /// The file that plays in Muskey Player gets its chords once the lyrics show, in about 2 seconds for a song of 5
    /// minutes, off the main thread.
    private func syncChords() {
        let path = playsInFilePlayer ? filePlayer.current?.path : nil
        if let task = gridTask, task.path != path {
            task.task.cancel()
            gridTask = nil
        }
        guard let path else { return fitChords() }
        if grids[path] != nil || !model.lyricsShown || gridTask != nil { return fitChords() }
        let duration = model.track?.duration
        gridTask = (path, Task { @MainActor [weak self] in
            let url = URL(fileURLWithPath: path)
            let seconds: Double = if let duration { duration } else { await ChordDetector.duration(url) }
            let grid = await Task.detached(priority: .utility) { await ChordDetector.analyse(url, duration: seconds) }.value
            guard let self, !Task.isCancelled else { return }
            gridTask = nil
            if let grid {
                grids[path] = grid
                log("chords: \(grid.chords.count) chords over \(grid.beats.count) beats")
            } else {
                log("chords: none found")
            }
            fitChords()
        })
    }

    /// The chords of the song that plays, with the mode that its key gives each root.
    private func fitChords() {
        let path = playsInFilePlayer ? filePlayer.current?.path : nil
        let fitted = path.flatMap { grids[$0] }?.fitted(to: songKey?.key) ?? []
        if model.chords != fitted { model.chords = fitted }
    }

    private func setCapo(_ fret: Int) {
        let fret = min(11, max(0, fret))
        guard fret != model.capo else { return }
        model.capo = fret
        log(fret == 0 ? "no capo" : "capo on fret \(fret)")
    }

    // MARK: Notes

    private let notesWindow = NotesWindowController()
    private var notesTask: Task<Void, Never>?
    private var notesWork: Task<[TranscribedNote], Error>?
    /// The song whose stems the notes wait for. Another song doesn't stop the separation of its whole song.
    private var notesStemsPath: String?
    private var notesSinks: Set<AnyCancellable> = []
    private var notesDownloads: Set<AnyCancellable> = []
    /// The stem picked last, which the picker starts on.
    private var lastNotesStem: Stem?

    /// The stems that the picker offers: every stem but the drums, which Dettato's transcriber doesn't hear.
    private var notesStems: [Stem] { Stem.shown.filter { $0 != .drums } }

    /// The bytes of the models that transcribing needs and that aren't installed: the stems model and Dettato.
    private var notesMissing: Int? {
        MainActor.assumeIsolated {
            let bytes = (ModelDownload.dettato.installed ? 0 : ModelDownload.dettato.size) + (StemModel.isInstalled(.stems) ? 0 : ModelDownload.stems.size)
            return bytes > 0 ? bytes : nil
        }
    }

    /// T shows the stems to transcribe in place of the key column, and hides them again.
    private func toggleNotesPicker() {
        if model.notesPicking != nil { return closeNotesPicker() }
        let stems = notesStems
        model.queueShown = false
        // A song from another app is transcribed from what Muskey heard of it, which its waveform's recorder keeps.
        let live = !playsInFilePlayer
        let recorder = live ? liveRecorder : nil
        let region = notesRegion(recorder: recorder, live: live)
        let selected = shownNotesStem(stems) ?? richestNotesStem(stems, in: region) ?? lastNotesStem.flatMap { stems.contains($0) ? $0 : nil }
            ?? (stems.contains(.bass) ? .bass : stems[0])
        model.notesPicking = NotesPicking(stems: stems, selected: selected, available: live ? recorder?.captures == true : true,
                                          duration: model.track?.duration, heard: live ? recorder?.capturedSeconds ?? 0 : nil, missing: notesMissing,
                                          region: region)
        log("notes: picker shown" + (live ? String(format: " for a song from another app, %.0f s heard", recorder?.capturedSeconds ?? 0) : "")
            + (region.map { String(format: ", with the region loop from %.1f s to %.1f s", $0.lowerBound, $0.upperBound) } ?? ""))
        updateHoverKeys()
        keepHover()
    }

    /// SwiftUI's hover ends when the layout changes under a pointer that stays still, and doesn't start again while the
    /// pointer moves on the glass, only once it leaves and comes back. That left the keys over the HUD off for a pointer
    /// resting on the HUD when the waveform arrived. Each move of the pointer sets the hover from where it is.
    private func followPointer() {
        let on = panel.pointerOnGlass
        guard model.hovering != on else { return }
        if Self.logKeys { log("hover \(on ? "started" : "ended") with a move of the pointer", .debug) }
        model.hovering = on
    }

    // MARK: Focus over the waveform

    /// The app that was in front when the pointer came over the waveform and made Muskey the active app. macOS sends
    /// trackpad gestures like a pinch only to the active app, so the waveform zooms with a pinch only while Muskey is
    /// active. Only that app gets the front back, when the pointer leaves the waveform: a Muskey that was made active
    /// any other way stays active.
    private var focusReturn: NSRunningApplication?
    private var focusWork: DispatchWorkItem?
    /// The pointer came over a waveform that zooms with a pinch with a move, and nothing covers it, as `hoverFocus`
    /// saw last.
    private var pointerOverWaveform = false
    /// The key picker takes the keyboard back from the app that got the front back, until then.
    private var pickerKeyboardUntil: Date?
    /// The last window logged above the glass, so a pointer that moves over it logs it once.
    private var coverLogged = 0
    private var tookFrontAt = Date.distantPast

    /// Makes Muskey the active app a moment after the pointer comes over the waveform, where a pinch zooms, and gives
    /// the front back to the app that had it a moment after the pointer leaves. The rest of the HUD takes clicks and
    /// keys without Muskey being active. A pointer that crosses the waveform on its way elsewhere, or a hover that ends
    /// for an instant while the layout changes, leaves the front where it is.
    private func hoverFocus(moved: Bool) {
        let over: Bool
        if !model.shown || !panel.pointerOnGlass || !waveformPinchable || !overWaveform(screen: NSEvent.mouseLocation, above: 16) {
            over = false
        } else if pointerOverWaveform {
            over = true
        } else {
            // A menu or another window above the glass gets the pointer, and a glass that appears or grows under a
            // pointer that rests there leaves the app in front alone until the pointer moves, since that app is
            // likely the one being typed in.
            // The window server can still let the pointer through the panel for an instant after it starts taking the
            // mouse, and then names a window below it, which doesn't count.
            let hit = moved ? NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) : panel.windowNumber
            // Windows of the window server itself and the ones at the level of the screen saver and above, like the
            // cursor and screen overlays, cover nothing (one at level 2147483646 sat over the whole HUD on gray).
            let top = Int(CGWindowLevelForKey(.screenSaverWindow))
            let cover = hit == panel.windowNumber ? nil : Self.otherAppWindow(hit).flatMap {
                $0.layer >= panel.level.rawValue && $0.layer < top && $0.owner != "Window Server" ? $0 : nil
            }
            over = moved && cover == nil
            if let cover, Self.logKeys, hit != coverLogged {
                coverLogged = hit
                log("focus: a window of \(cover.owner) at level \(cover.layer) is above the glass under the pointer", .debug)
            }
        }
        guard over != pointerOverWaveform else {
            // Something took the front while the pointer stayed over the waveform, like a song that opened from a link: the
            // next move of the pointer takes it again, at most once a second.
            if over, moved, focusWork == nil, Date().timeIntervalSince(tookFrontAt) > 1,
               let front = NSWorkspace.shared.frontmostApplication, front != .current {
                let work = DispatchWorkItem { [weak self] in self?.takeFront() }
                focusWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            }
            return
        }
        pointerOverWaveform = over
        focusWork?.cancel()
        focusWork = nil
        if over {
            guard focusReturn == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.takeFront() }
            focusWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        } else if focusReturn != nil {
            let work = DispatchWorkItem { [weak self] in self?.giveFrontBack() }
            focusWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (model.shown ? 0.15 : 0), execute: work)
        }
    }

    private func takeFront() {
        focusWork = nil
        // A drag that comes over the HUD, like a file on its way to be dropped, keeps going in the app it started in.
        // Muskey counts as active while the key picker holds the keyboard with another app in front, so the app in
        // front decides.
        guard pointerOverWaveform, !dialogOpen, NSApp.modalWindow == nil, NSEvent.pressedMouseButtons == 0,
              let front = NSWorkspace.shared.frontmostApplication, front != .current
        else { return }
        focusReturn = front
        tookFrontAt = Date()
        if NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.styleMask.contains(.titled) }) {
            panel.holdsFront = true
            panel.makeKey()
            panel.makeMain()
        }
        NSApp.takeFocus()
        log("focus: Muskey is the active app while the pointer is over the waveform, in place of \(Self.appName(front))", .debug)
        logFront()
        // macOS can leave the other app in front, as right after it got the front back: Muskey asks once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, pointerOverWaveform, focusReturn != nil, let now = NSWorkspace.shared.frontmostApplication, now != .current else { return }
            log("focus: \(Self.appName(now)) stayed in front, Muskey asks for the front again", .debug)
            focusReturn = now
            NSApp.takeFocus()
            logFront()
        }
    }

    /// A window of Muskey that closes while the pointer is over the waveform leaves Muskey in front, as a pointer that
    /// came over it would, and the app that was in front before gets the front back once the pointer leaves it.
    private func frontAfterClose(_ app: NSRunningApplication) {
        guard pointerOverWaveform, model.shown else { app.activate(); return }
        focusReturn = app
        tookFrontAt = Date()
    }

    private func giveFrontBack() {
        focusWork = nil
        guard let app = focusReturn else { return }
        // A loop time being typed keeps the keyboard, and the front goes back once the field closes.
        if loopTyping { return }
        focusReturn = nil
        panel.holdsFront = false
        guard NSWorkspace.shared.frontmostApplication == .current else {
            return log("focus: another app became active while the pointer was over the waveform", .debug)
        }
        // A window of Muskey that took the keyboard while the pointer was over the waveform keeps the front: Settings, the
        // notes window, Open URL, a dialog.
        if let key = NSApp.keyWindow, key !== panel { return log("focus: \(key.title.isEmpty ? "another window" : key.title) keeps Muskey in front", .debug) }
        guard NSApp.modalWindow == nil, !dialogOpen, !app.isTerminated else { return }
        pickerKeyboardUntil = model.picking ? Date().addingTimeInterval(1) : nil
        NSApp.yieldActivation(to: app)
        app.activate()
        log("focus: \(Self.appName(app)) is the active app again, the pointer left the waveform", .debug)
        logFront()
    }

    /// With `--log-keys`, the app in front and the window with the keyboard, a moment after the front changed hands.
    private func logFront() {
        guard Self.logKeys else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let front = NSWorkspace.shared.frontmostApplication.map(Self.appName) ?? "no app"
            let keyboard = panel.isKeyWindow ? "the HUD" : NSApp.keyWindow.map { $0.title.isEmpty ? "\(type(of: $0))" : $0.title } ?? "no window of Muskey"
            log("focus: \(front) is in front, \(keyboard) has the keyboard", .debug)
        }
    }

    /// The key picker holds the keyboard while another app is in front, as it did before the pointer came over the
    /// HUD, so Escape and the arrow keys still reach it after the front goes back.
    private func keepPickerKeyboard() {
        guard let until = pickerKeyboardUntil else { return }
        pickerKeyboardUntil = nil
        guard Date() < until, model.picking, panel.isVisible else { return }
        // After the other app's window took the keyboard, which happens once Muskey stopped being active.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, model.picking, panel.isVisible, !panel.isKeyWindow else { return }
            panel.makeKey()
        }
    }

    private static func appName(_ app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "another app"
    }

    /// The owner and the level of a window of another app.
    private static func otherAppWindow(_ number: Int) -> (owner: String, layer: Int)? {
        guard number > 0, NSApp.window(withWindowNumber: number) == nil,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first
        else { return nil }
        return (info[kCGWindowOwnerName as String] as? String ?? "another app", info[kCGWindowLayer as String] as? Int ?? 0)
    }

    /// A layout that changes under a pointer that stays still can end SwiftUI's hover, which turns the keys over the
    /// HUD off until the pointer moves. They stay on while the pointer is still over the glass.
    private func keepHover() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !model.hovering, panel.pointerOnGlass else { return }
            log("hover kept after the layout changed under the pointer", .debug)
            model.hovering = true
        }
    }

    private func closeNotesPicker() {
        guard model.notesPicking != nil else { return }
        model.notesPicking = nil
        notesFullAfterDownload = false
        notesDownloads = []
        updateHoverKeys()
        keepHover()
    }

    /// The stem that the HUD shows on its own, which T picks first: the only stem with a waveform of its own, or else
    /// the only stem that plays.
    private func shownNotesStem(_ stems: [Stem]) -> Stem? {
        let lanes = model.wave.lanes && model.wave.waveform?.stems != nil ? stems.filter { model.wave.laneStems.contains($0) } : []
        if lanes.count == 1 { return lanes[0] }
        let playing = model.stemsEngaged ? Stem.shown.filter { !model.stemsMuted.contains($0) } : []
        return playing.count == 1 && stems.contains(playing[0]) ? playing[0] : nil
    }

    /// The stem that sounds the most in the part that T picks first, the region loop or the whole song, as the levels
    /// of the stems on the waveform show. Nil until the stems of the song are known.
    private func richestNotesStem(_ stems: [Stem], in region: ClosedRange<Double>?) -> Stem? {
        guard let waveform = model.wave.waveform else { return nil }
        let sounds = stems.compactMap { stem in
            waveform.sound(of: stem, from: region?.lowerBound ?? 0, to: region?.upperBound).map { (stem, $0) }
        }
        guard let richest = sounds.max(by: { $0.1 < $1.1 }), richest.1 > 0 else { return nil }
        log("notes: \(richest.0.name) sounds the most" + (region == nil ? "" : " in the region loop") + ": "
            + sounds.sorted { $0.1 > $1.1 }.map { "\($0.0.name) \($0.1)" }.joined(separator: ", "))
        return richest.0
    }

    /// The region loop that T offers to transcribe in place of the whole song, and picks first: both of its ends are
    /// set, and a song from another app was heard all through it.
    private func notesRegion(recorder: WaveformRecorder?, live: Bool) -> ClosedRange<Double>? {
        guard let loop = model.loop, let end = loop.end, end > loop.start + 0.25 else { return nil }
        let region = max(0, loop.start) ... end
        if live, recorder?.holds(region) != true {
            log(String(format: "notes: the region loop from %.1f s to %.1f s wasn't heard whole, only the whole song is offered", loop.start, end))
            return nil
        }
        return region
    }

    /// Tab or a click in T's picker: the whole song or the region loop.
    private func pickNotesPart(whole: Bool) {
        guard model.notesPicking?.region != nil, model.notesPicking?.wholeSong != whole else { return }
        model.notesPicking?.wholeSong = whole
        log("notes: the \(whole ? "whole song" : "region loop") is picked")
    }

    private func selectNotesStem(_ stem: Stem) {
        guard model.notesPicking?.stems.contains(stem) == true else { return }
        model.notesPicking?.selected = stem
    }

    /// Return or the honey button: downloads the models that are missing, then transcribes the stem. A song from
    /// another app is transcribed from what Muskey heard of it, and with `full` it plays to its end first.
    private func startNotes(full: Bool = false) {
        guard let picking = model.notesPicking, picking.available, picking.downloading == nil else { return }
        lastNotesStem = picking.selected
        let region = picking.transcribesRegion ? picking.region : nil
        // A region loop was heard whole, so it never waits for the rest of the song.
        if full, region == nil { notesFullAfterDownload = true }
        if notesMissing != nil { return downloadNotesModels() }
        let full = (full || notesFullAfterDownload) && region == nil
        notesFullAfterDownload = false
        guard let track = model.track else { return }
        if playsInFilePlayer {
            guard let path = filePlayer.current?.path else { return }
            closeNotesPicker()
            openNotes(path: path, track: track, stem: picking.selected, region: region)
        } else if let region {
            guard let recorder = liveRecorder, recorder.captures, recorder.holds(region) else { return }
            closeNotesPicker()
            openLiveNotes(recorder, track: track, stem: picking.selected, waiting: false, region: region)
        } else {
            guard let recorder = liveRecorder, recorder.captures else { return }
            let whole = recorder.firstGap == nil
            guard full && !whole || recorder.capturedSeconds >= 5 else { return }
            closeNotesPicker()
            openLiveNotes(recorder, track: track, stem: picking.selected, waiting: full && !whole)
        }
        // The HUD floats above every window, and the notes window takes the screen under it.
        dismiss()
    }

    /// ⌥↩ or Capture Full Song started the download of the models, and the song plays to its end once they are in.
    private var notesFullAfterDownload = false

    /// The recorder of the song from another app that plays, which keeps what Muskey heard of it.
    private var liveRecorder: WaveformRecorder? {
        guard !playsInFilePlayer, let recorder = waveformRecorder, let track = nowPlaying.track, recorder.song == track.song else { return nil }
        return recorder
    }

    /// A song from another app that plays to its end before its notes are transcribed: the window's notes, and the
    /// recorder that hears it, kept even after the song changes.
    private var liveCapture: (notes: NotesModel, recorder: WaveformRecorder, song: [String?])?
    private var liveCaptureTimer: Timer?

    /// The capture of a song from another app is written here for the beats, the stems and the notes, and deleted once
    /// the notes are done or the window closes, so no copy of the song stays on disk.
    private static func captureURL(_ key: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Muskey/Captures/\(key).wav")
    }

    /// Opens the notes window on a song from another app: transcribed now from what was heard, or once it played to
    /// its end (`waiting`), from the first part that wasn't heard.
    private func openLiveNotes(_ recorder: WaveformRecorder, track: NowPlaying.Track, stem: Stem, waiting: Bool, region: ClosedRange<Double>? = nil) {
        notesTask?.cancel()
        notesWork?.cancel()
        let path = Self.captureURL(recorder.key).path
        let title = track.title?.isEmpty == false ? track.title! : "Song"
        let notes = NotesModel(path: path, title: title, artist: track.artist, stem: stem, duration: track.duration ?? recorder.duration)
        notes.key = songKey?.key
        notes.region = region
        wireNotes(notes, song: track.song)
        notesWindow.show(notes)
        syncNotesPlaying()
        log(String(format: "notes: %@ of %@, from %.0f s heard of a song from another app%@%@", stem.name.lowercased(), title, recorder.capturedSeconds,
                   waiting ? ", after the rest of it plays" : "", Self.regionText(region)))
        guard waiting else { return transcribeCapture(recorder, notes: notes) }
        // The song goes back to the first part that wasn't heard, and plays to its end from there.
        let gap = recorder.firstGap ?? 0
        let now = track.position(at: Date()) ?? 0
        let from = gap < now - 1 && model.seekable ? gap : now
        notes.captureSeconds = max(1, notes.duration - from)
        notes.begin([.capture, .beats, .stems, .notes])
        notes.phase = .working(.capture, recorder.capturedShare)
        liveCapture = (notes, recorder, track.song)
        if from < now - 1 {
            seek(to: from, flash: "")
            log(String(format: "notes: the song moves back to %.1f s, the first part that wasn't heard", from))
        }
        if !track.playing { playPause() }
        liveCaptureTimer?.invalidate()
        liveCaptureTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkLiveCapture() }
        syncWaveform()
    }

    /// The song from another app plays on: the bar follows what was heard, and the notes are transcribed once the song
    /// was heard whole, reached its end or gave way to another song.
    private func checkLiveCapture() {
        guard let capture = liveCapture, notesWindow.model === capture.notes else { return stopLiveCapture() }
        let recorder = capture.recorder
        let share = recorder.capturedShare
        if capture.notes.phase.step == .capture { capture.notes.phase = .working(.capture, share) }
        let track = nowPlaying.track
        let otherSong = track?.song != capture.song
        let atEnd = !otherSong && (track?.position(at: Date())).map { $0 >= capture.notes.duration - 0.75 } == true
        guard recorder.firstGap == nil || otherSong || atEnd else { return }
        log(String(format: "notes: the song was heard %@, %.0f%% of it", recorder.firstGap == nil ? "whole" : otherSong ? "until another song played" : "to its end", share * 100))
        stopLiveCapture()
        transcribeCapture(recorder, notes: capture.notes)
    }

    private func stopLiveCapture() {
        liveCaptureTimer?.invalidate()
        liveCaptureTimer = nil
        guard liveCapture != nil else { return }
        liveCapture = nil
        syncWaveform()
    }

    /// Writes what was heard to the file of the notes, and transcribes it like a file of Muskey Player.
    private func transcribeCapture(_ recorder: WaveformRecorder, notes: NotesModel) {
        do {
            try recorder.writeCapture(to: URL(fileURLWithPath: notes.path))
        } catch {
            notes.phase = .failed
            log("notes: the capture couldn't be written: \(error.localizedDescription)", .error)
            return
        }
        runNotes(notes)
    }

    /// Deletes the capture of a song from another app and the stems separated from it.
    private func deleteCapture(_ path: String) {
        guard path.hasPrefix(Self.captureURL("").deletingLastPathComponent().path) else { return }
        if let stems = StemsCache.url(for: path) { try? FileManager.default.removeItem(at: stems) }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func downloadNotesModels() {
        MainActor.assumeIsolated { downloadNotesModelsOnMain() }
    }

    @MainActor private func downloadNotesModelsOnMain() {
        let downloads = [ModelDownload.stems, ModelDownload.dettato].filter { !$0.installed }
        model.notesPicking?.failed = false
        notesDownloads = []
        for download in downloads {
            download.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncNotesDownloads(downloads) }.store(in: &notesDownloads)
            if download.state != .installing, !isDownloading(download) { download.start() }
        }
        log("notes: downloading \(downloads.map(\.name).joined(separator: " and "))")
        syncNotesDownloads(downloads)
    }

    @MainActor private func isDownloading(_ download: ModelDownload) -> Bool {
        if case .downloading = download.state { return true }
        return false
    }

    /// The picker's button shows the share of the bytes downloaded over both models, and transcribes once both are
    /// installed.
    @MainActor private func syncNotesDownloads(_ downloads: [ModelDownload]) {
        guard model.notesPicking != nil else {
            notesDownloads = []
            return
        }
        if downloads.contains(where: { $0.state == .failed }) {
            model.notesPicking?.downloading = nil
            model.notesPicking?.failed = true
            notesDownloads = []
            return
        }
        if downloads.allSatisfy({ $0.installed && $0.state == .idle }) {
            notesDownloads = []
            model.notesPicking?.downloading = nil
            model.notesPicking?.missing = nil
            log("notes: models installed", .notice)
            return startNotes()
        }
        let total = Double(downloads.map(\.size).reduce(0, +))
        let done = downloads.map { download -> Double in
            switch download.state {
            case let .downloading(fraction): Double(download.size) * fraction
            case .installing: Double(download.size)
            case .idle: download.installed ? Double(download.size) : 0
            case .failed: 0
            }
        }.reduce(0, +)
        model.notesPicking?.downloading = total > 0 ? min(1, done / total) : 0
    }

    /// Opens the notes window on a stem of the song in Muskey Player, with the notes from the cache or transcribed now.
    private func openNotes(path: String, track: NowPlaying.Track, stem: Stem, region: ClosedRange<Double>? = nil) {
        notesTask?.cancel()
        notesWork?.cancel()
        let title = track.title?.isEmpty == false ? track.title! : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let notes = NotesModel(path: path, title: title, artist: track.artist, stem: stem, duration: track.duration ?? 0)
        notes.key = songKey?.key
        notes.region = region
        if let grid = grids[path] { notes.setGrid(beats: grid.beats, bpm: grid.bpm) }
        wireNotes(notes)
        notesWindow.show(notes)
        // The window's play state can only be set once the window holds the notes.
        syncNotesPlaying()
        log("notes: \(stem.name.lowercased()) of \(title)" + Self.regionText(region))
        fillNotes(notes)
    }

    /// ", in the region loop from 12.0 s to 20.5 s" for the log, or nothing for the whole song.
    private static func regionText(_ region: ClosedRange<Double>?) -> String {
        region.map { String(format: ", in the region loop from %.1f s to %.1f s", $0.lowerBound, $0.upperBound) } ?? ""
    }

    /// Shows the notes from the cache, or transcribes them. The cache holds whole songs, and a region loop shows the
    /// part of them that it covers.
    private func fillNotes(_ notes: NotesModel) {
        guard let cached = NotesStore.load(path: notes.path, stem: notes.stem) else { return runNotes(notes) }
        if grids[notes.path] == nil { notes.setGrid(beats: cached.beats, bpm: cached.bpm) }
        let shown = notes.region.map { NotesPipeline.notes(cached.notes, in: $0) } ?? cached.notes
        if shown.count < notes.fewest { offerOtherStems(notes) }
        notes.finish(shown)
        log("notes: \(shown.count) notes from the cache" + Self.regionText(notes.region))
    }

    /// Opens the window's song on another stem, from the card of a stem that hardly plays.
    private func switchNotesStem(_ notes: NotesModel, to stem: Stem) {
        notesTask?.cancel()
        notesWork?.cancel()
        let next = NotesModel(path: notes.path, title: notes.title, artist: notes.artist, stem: stem, duration: notes.duration)
        next.key = notes.key
        next.region = notes.region
        if let grid = grids[notes.path] { next.setGrid(beats: grid.beats, bpm: grid.bpm) }
        wireNotes(next, song: notes.song)
        notesWindow.show(next)
        syncNotesPlaying()
        lastNotesStem = stem
        log("notes: the \(stem.name.lowercased()) instead of the \(notes.stem.name.lowercased())")
        fillNotes(next)
    }

    /// The other stems that play in the song, the most present first, for a stem that hardly plays. Until the stems of
    /// the song are measured, and when none of the others plays either, every other stem is offered.
    private func offerOtherStems(_ notes: NotesModel, activity: StemActivity? = nil) {
        let others = notesStems.filter { $0 != notes.stem }
        if let activity = activity?.shares {
            let playing = others.filter { (activity[$0] ?? 0) >= NotesPipeline.quiet }.sorted { (activity[$0] ?? 0) > (activity[$1] ?? 0) }
            notes.otherStems = playing.isEmpty ? others : playing
            return
        }
        notes.otherStems = others
        guard let cache = StemsCache.open(for: notes.path) else { return }
        Task { @MainActor [weak self, weak notes] in
            let activity = await Task.detached(priority: .userInitiated) { NotesPipeline.activity(cache) }.value
            guard let self, let notes else { return }
            offerOtherStems(notes, activity: activity)
        }
    }

    /// The window's actions go to the song, and the pitch change, the loop and the play state come back from it. A
    /// song from another app (`song`) is the window's while that app plays it.
    private func wireNotes(_ notes: NotesModel, song: [String?]? = nil) {
        notes.song = song
        notes.now = { [weak self, weak notes] in
            guard let self, let notes else { return nil }
            if let song {
                guard nowPlaying.track?.song == song else { return nil }
            } else {
                guard playsInFilePlayer, filePlayer.current?.path == notes.path else { return nil }
            }
            return nowPlaying.track?.position(at: Date())
        }
        notes.onSeek = { [weak self] seconds in self?.seek(to: seconds, flash: "") }
        notes.onLoop = { [weak self] start, end in self?.setNotesLoop(start, end) }
        notes.onPlayPause = { [weak self] in self?.playPause() }
        // The window shows the new key itself, so the HUD stays closed and the window keeps the keyboard.
        notes.onTranspose = { [weak self] step in
            guard let self, model.pending == nil else { return }
            setShift(model.shift + step)
        }
        notes.onRetry = { [weak self, weak notes] in
            guard let notes else { return }
            self?.runNotes(notes)
        }
        notes.onTranscribeAnyway = { [weak self, weak notes] in
            guard let notes, notes.phase == .quiet else { return }
            notes.forced = true
            self?.log("notes: transcribe anyway")
            self?.runNotes(notes)
        }
        notes.onPickStem = { [weak self, weak notes] stem in
            guard let notes else { return }
            self?.switchNotesStem(notes, to: stem)
        }
        notes.onClose = { [weak self] in self?.notesWindow.close() }
        notes.onSave = { [weak self, weak notes] format in
            guard let self, let notes else { return }
            notesWindow.save(format, score: notes.fullScore, title: notes.title)
        }
        notes.onCopyTab = { [weak self, weak notes] in
            guard let notes else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(notes.fullScore.textTab, forType: .string)
            self?.log("notes: text tab copied")
        }
        notes.onTurnPage = { [weak self] in self?.notesWindow.turnPage() }
        notesWindow.onLoopKey = { [weak self] snapping in self?.pressLoop(snapping: snapping) }
        notesWindow.onSongLoopKey = { [weak self] in self?.toggleSongLoop() }
        notesWindow.onClosed = { [weak self] in self?.notesClosed() }
        notesSinks = []
        model.$shift.sink { [weak notes] in notes?.shift = $0 }.store(in: &notesSinks)
        model.$capo.sink { [weak notes] in notes?.capo = $0 }.store(in: &notesSinks)
        // The HUD shows a change of speed only for a song whose speed Muskey can change, and so does the notes window.
        model.$speed.combineLatest(model.$speedAdjustable).sink { [weak notes] speed, adjustable in
            notes?.speed = adjustable ? speed : 1
            notes?.speedAdjustable = adjustable
        }
        .store(in: &notesSinks)
        model.$fastestSpeed.sink { [weak notes] in notes?.fastestSpeed = $0 }.store(in: &notesSinks)
        model.$relative.sink { [weak notes] in notes?.relative = $0 }.store(in: &notesSinks)
        model.$relativeKeys.sink { [weak notes] in notes?.relativeKeys = $0 }.store(in: &notesSinks)
        notes.onCapo = { [weak self] step in
            guard let self else { return }
            setCapo(model.capo + step)
        }
        // The key and the tempo of the status bar change the song as the HUD's key row and tempo pill do, with the HUD
        // closed, so the window keeps the keyboard.
        notes.onPickKey = { [weak self] shift, relative in
            guard let self, model.pending == nil else { return }
            if Self.logKeys { log("notes: key picked, \(Shift.text(shift))\(relative ? " in the other mode" : "")", .debug) }
            setShift(shift, relative: relative)
        }
        notes.onSpeedStep = { [weak self] step in self?.changeSpeed(by: step) }
        notes.onSpeed = { [weak self] speed in
            guard let self else { return }
            playSpeed(min(max(speed, 0.5), fastestSpeed))
        }
        model.$loop.sink { [weak notes] in notes?.loop = $0 }.store(in: &notesSinks)
    }

    /// The notes window takes the play state from the player's reports, because the HUD's state only changes while the
    /// HUD shows. A play or pause that Space asked for shows at once, and reports against it are ignored until the
    /// player takes it or 1.5 seconds pass, as in the HUD.
    private func syncNotesPlaying() {
        guard let notes = notesWindow.model else { return }
        let playing = notes.now() != nil && (playGuess?.playing ?? (nowPlaying.track?.playing == true))
        if notes.playing != playing { notes.playing = playing }
        // The line only draws on the frames of a playing song, so a seek while paused draws it again where it moved.
        if !playing, let time = notes.now(), abs(time - notes.pausedAt) > 0.005 { notes.pausedAt = time }
    }

    /// A drag across the notes: the region loop from one beat to another.
    private func setNotesLoop(_ start: Double, _ end: Double) {
        guard end > start + 0.25 else { return }
        loopSnap?.cancel()
        model.loop = LoopRegion(start: max(0, start), end: end, startPress: nil)
        loopSong = nowPlaying.track?.song
        log(String(format: "region loop from the notes: %.2f s to %.2f s", start, end))
        applyLoop()
    }

    private func notesClosed() {
        notesTask?.cancel()
        notesWork?.cancel()
        notesTask = nil
        notesWork = nil
        notesSinks = []
        notesStemsPath = nil
        stemsCache.progress = { _ in }
        // A separation that only the notes needed stops with them. The stems of the HUD keep theirs.
        if let building = stemsCache.path, !(model.stemsEngaged && playsInFilePlayer && building == filePlayer.current?.path) {
            stemsCache.cancel()
            log("notes: the separation stopped")
        }
        stopLiveCapture()
        clearCaptures()
        log("notes: closed")
    }

    /// Deletes the captures of songs from other apps, except the one that the notes window transcribes now.
    private func clearCaptures() {
        let folder = Self.captureURL("").deletingLastPathComponent()
        let kept = notesWindow.model?.path
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.path != kept {
            deleteCapture(url.path)
        }
    }

    /// Finds the beats if they aren't known yet, separates the stems if the cache doesn't have them, and transcribes
    /// the stem off the main thread. The window shows the notes once they are all found, and one bar for the steps
    /// before that.
    private func runNotes(_ notes: NotesModel) {
        notesTask?.cancel()
        notesWork?.cancel()
        let path = notes.path, stem = notes.stem
        stemsCacheFailed.remove(path)
        let steps = (grids[path] == nil ? [NotesStep.beats] : []) + (StemsCache.open(for: path) == nil ? [.stems] : []) + [.notes]
        // After a capture, the capture stays in the steps row, ticked.
        if notes.steps.first == .capture { notes.carryOn(steps) } else { notes.begin(steps) }
        if Self.logKeys {
            // The bar and the time left once a second, for testing that the bar only goes forward.
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak notes] timer in
                guard let self, let notes, case let .working(step, _) = notes.phase else { return timer.invalidate() }
                let now = Date()
                log(String(format: "notes progress: %@ %.1f%%, %@", step.name, notes.progress(at: now) * 100,
                           notes.secondsLeft(at: now).map { String(format: "%.0f s left", $0) } ?? "no estimate"), .debug)
            }
        }
        notesTask = Task { @MainActor [weak self, weak notes] in
            guard let self, let notes else { return }
            let url = URL(fileURLWithPath: path)
            let song = notes.duration > 0 ? notes.duration : await ChordDetector.duration(url)
            if grids[path] == nil {
                let started = Date()
                let grid = await Task.detached(priority: .utility) { await ChordDetector.analyse(url, duration: song) }.value
                guard !Task.isCancelled else { return }
                if let grid {
                    grids[path] = grid
                    fitChords()
                    NotesTiming.learn(.beats, seconds: Date().timeIntervalSince(started), song: song)
                }
            }
            if let grid = grids[path] { notes.setGrid(beats: grid.beats, bpm: grid.bpm) }
            guard let cache = await notesStems(path, notes: notes, song: song) else {
                if !Task.isCancelled {
                    notes.phase = .failed
                    log("notes: the stems couldn't be separated", .error)
                }
                return
            }
            // A stem that hardly plays waits for Transcribe Anyway or another stem, which the card offers. A region loop
            // counts only its own music.
            let region = notes.region
            let activity = await Task.detached(priority: .userInitiated) { NotesPipeline.activity(cache, range: region) }.value
            guard !Task.isCancelled else { return }
            let share = activity.shares[stem] ?? 0
            log(String(format: "notes: the %@ plays in %.0f%% of the %.0f s of music", stem.name.lowercased(), share * 100, activity.seconds) + Self.regionText(region))
            offerOtherStems(notes, activity: activity)
            if share < NotesPipeline.quiet, !notes.forced {
                notes.phase = .quiet
                return
            }
            notes.phase = .working(.notes, 0)
            let started = Date()
            let stopHere = StopFlag()
            notes.onStopHere = { [weak self] in
                stopHere.set()
                self?.log("notes: stop here")
            }
            // A region loop is transcribed with a little of the song around it, and its notes are moved to the song's time.
            let heard = region.map { max(0, $0.lowerBound - NotesPipeline.regionContext) ... min(song > 0 ? song : .infinity, $0.upperBound + NotesPipeline.regionContext) }
            let offset = heard?.lowerBound ?? 0
            let moved = { (found: [TranscribedNote]) -> [TranscribedNote] in
                guard let region else { return found }
                let shifted = found.map { TranscribedNote(start: $0.start + offset, end: $0.end + offset, pitch: $0.pitch, program: $0.program, drum: $0.drum) }
                return NotesPipeline.notes(shifted, in: region)
            }
            let work = Task.detached(priority: .userInitiated) { () throws -> [TranscribedNote] in
                let audio = Dettato.resample(NotesPipeline.stemSamples(cache, stem: stem, range: heard), from: StemsCache.rate)
                return try Dettato.transcribe(audio, program: stem.program, progress: { fraction in
                    // The notes are decoded from the maps after the last window, so the windows fill most of the step.
                    Task { @MainActor in
                        if notes.phase.step == .notes { notes.phase = .working(.notes, fraction * 0.96) }
                    }
                }, stop: { stopHere.isSet })
            }
            notesWork = work
            do {
                let found = moved(try await work.value)
                guard !Task.isCancelled else { return }
                notes.finish(found)
                if notes.phase == .empty { log("notes: \(found.count) notes are too few to show") }
                // The cache holds whole songs, so the notes of a region loop aren't kept.
                if region == nil { NotesStore.save(notes.fixture, path: path, stem: stem) }
                // Without notes, the capture stays for another stem until the window closes.
                if notes.phase == .ready { deleteCapture(path) }
                NotesTiming.learn(.notes, seconds: Date().timeIntervalSince(started), song: heard.map { $0.upperBound - $0.lowerBound } ?? song)
                log(String(format: "notes: %d notes of the %@ in %.1f s", found.count, stem.name.lowercased(), Date().timeIntervalSince(started)) + Self.regionText(region))
            } catch let stopped as Dettato.Stopped {
                // The notes so far show, and the bars after them stay faint. They aren't kept in the cache, which holds
                // whole transcriptions, and the capture of a song from another app stays for the rest until the window
                // closes.
                guard !Task.isCancelled else { return }
                notes.transcribedUntil = stopped.until + offset
                notes.finish(moved(stopped.notes))
                log(String(format: "notes: stopped at %.1f s with %d notes of the %@", stopped.until + offset, notes.notes.count, stem.name.lowercased()))
            } catch is CancellationError {
                log("notes: transcription stopped")
            } catch {
                notes.phase = .failed
                log("notes: transcription failed: \(error.localizedDescription)", .error)
            }
        }
    }

    /// The stems of the whole song from the cache, separating them first with the separation that the stems of Muskey
    /// Player use. A separation that ran from its start times the step for the next estimate. On the main thread, since
    /// it sets the window's progress: an async method of the app delegate runs off it otherwise, and a progress set from
    /// another thread locked the window and the main thread against each other.
    @MainActor private func notesStems(_ path: String, notes: NotesModel, song: Double) async -> StemsCache? {
        if let cache = StemsCache.open(for: path) { return cache }
        // A separation that already runs for the stems of the HUD starts the step where it is.
        notes.phase = .working(.stems, stemsCache.path == path ? stemsCache.fraction : 0)
        notesStemsPath = path
        let started = Date()
        var from: Double?
        stemsCache.progress = { [weak notes] fraction in
            if from == nil { from = fraction }
            if notes?.phase.step == .stems { notes?.phase = .working(.stems, fraction) }
        }
        defer {
            notesStemsPath = nil
            stemsCache.progress = { _ in }
        }
        // A song of an hour separates in well under half an hour.
        for _ in 0 ..< 1800 {
            if stemsCache.path != path, !stemsCacheFailed.contains(path) { stemsCache.start(path) }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return nil }
            if let cache = StemsCache.open(for: path) {
                if (from ?? 1) < 0.05 { NotesTiming.learn(.stems, seconds: Date().timeIntervalSince(started), song: song) }
                return cache
            }
            if stemsCacheFailed.contains(path) { return nil }
        }
        log("notes: the stems weren't separated after 30 minutes", .error)
        return nil
    }

    // MARK: Mini player

    /// The mini player floats while Settings has it on and a player names a song.
    private func syncMini() {
        let wanted = prefs.miniPlayer && model.track?.title?.isEmpty == false
        if mini.key != currentKey { mini.key = currentKey }
        if wanted { miniPanel.show() } else if miniPanel.isVisible { miniPanel.hide() }
        refreshStatus()
    }

    /// M over the HUD or the mini player, and Mini Player in the ⋯ menu.
    @objc private func toggleMiniPlayer() {
        prefs.miniPlayer.toggle()
        log(prefs.miniPlayer ? "mini player on" : "mini player off")
        if prefs.miniPlayer, model.track?.title?.isEmpty != false { log("the mini player shows once a song plays") }
    }

    private var miniKeys: [HotKey] = []

    /// Escape or Delete over the mini player, and Hide Mini Player in its menu.
    private func hideMiniPlayer() {
        guard prefs.miniPlayer else { return }
        prefs.miniPlayer = false
        log("mini player off")
    }

    /// The keys that work over the mini player: Space, N and P, the arrows that seek, and M, Escape and Delete, which hide
    /// it.
    private func updateMiniKeys() {
        miniKeys = []
        guard miniPanel.hovering else { return }
        var keys: [(Int, () -> Void)] = [
            (kVK_Space, { [weak self] in self?.playPause() }),
            (kVK_ANSI_N, { [weak self] in self?.skip(1) }),
            (kVK_ANSI_P, { [weak self] in self?.skip(-1) }),
            (kVK_ANSI_M, { [weak self] in self?.toggleMiniPlayer() }),
            (kVK_Escape, { [weak self] in self?.hideMiniPlayer() }),
            (kVK_Delete, { [weak self] in self?.hideMiniPlayer() }),
        ]
        if model.seekable {
            keys += [(kVK_LeftArrow, { [weak self] in self?.seek(by: -5) }), (kVK_RightArrow, { [weak self] in self?.seek(by: 5) })]
        }
        miniKeys = keys.compactMap { code, action in try? HotKey(keyCode: code, modifiers: 0, action: action) }
    }

    // MARK: Queue

    /// Adds files or links to the queue: dropped on Add to Queue, pasted with ⇧⌘V, or picked with Add Files to Queue…
    /// and Add URL to Queue…. With `next`, they play right after the song that plays.
    private func add(_ urls: [URL], next: Bool) {
        guard !model.otherPlayer else { return open(urls) }
        withFolders(urls) { [self] urls, folders in
            raisesHUD = true
            filePlayer.add(urls, next: next, folders: folders)
            raisesHUD = false
        }
    }

    /// The queue changed in Muskey Player, so the HUD shows it, and the songs that have no key yet get one.
    private func syncQueue() {
        let queue = filePlayer.queue
        if model.queue != queue { model.queue = queue }
        if model.queueCurrent != filePlayer.currentID { model.queueCurrent = filePlayer.currentID }
        let ids = Set(queue.map(\.id))
        if !model.queueSelection.isSubset(of: ids) { model.queueSelection.formIntersection(ids) }
        analyseQueue()
    }

    /// The song of the queue whose key and tempo are looked for, one song at a time so a long queue never takes more
    /// than one core.
    private var queueAnalysis: UUID?

    /// Finds the key and the tempo of the next song in the queue that has neither: the key that Muskey remembers for the
    /// song, or else a listen of 30 seconds of its file, which takes a fraction of a second.
    private func analyseQueue() {
        guard queueAnalysis == nil,
              let item = filePlayer.queue.first(where: { !$0.analysed && $0.read && $0.file != nil }), let file = item.file
        else { return }
        let song: [String?] = [item.title, item.artist, item.album]
        if prefs.rememberKeys, let key = keyCache.key(for: song) {
            // On the next turn of the run loop, so a long queue of remembered songs doesn't nest a call for each one.
            queueAnalysis = item.id
            let bpm = keyCache.bpm(for: song)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                queueAnalysis = nil
                filePlayer.setAnalysis(item.id, key: key, bpm: bpm)
            }
            return
        }
        queueAnalysis = item.id
        let duration = item.duration
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { await QueueItem.analyse(file, duration: duration) }.value
            guard let self else { return }
            queueAnalysis = nil
            if Self.logKeys { log("queue: \(item.title) in \(result.key?.name ?? "no key")\(result.bpm.map { String(format: " at %.0f BPM", $0) } ?? "")", .debug) }
            filePlayer.setAnalysis(item.id, key: result.key, bpm: result.bpm)
        }
    }

    /// The song that plays takes the key and the tempo of the HUD's listen, which heard more of it than the short
    /// listen of the queue.
    private func syncQueueRow() {
        // Now Playing names the new song a moment after Muskey Player starts it, so the key has to belong to this song.
        guard let id = filePlayer.currentID, let item = filePlayer.queue.first(where: { $0.id == id }), item.read,
              let found = songKey, found.song == nil || found.song == model.track?.song, model.track?.title == item.title
        else { return }
        let key = found.key
        let bpm = model.tempo.flatMap { $0.song == nil || $0.song == model.track?.song ? $0.bpm : nil }
        guard item.key != key || (bpm != nil && item.bpm != bpm) else { return }
        filePlayer.setAnalysis(id, key: key, bpm: bpm)
    }

    /// A double click or Return in the queue plays the song.
    private func playFromQueue(_ id: UUID) {
        log("playing a song of the queue")
        filePlayer.play(id)
    }

    private func removeFromQueue(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        log("removing \(ids.count) song\(ids.count == 1 ? "" : "s") from the queue")
        filePlayer.remove(ids)
        model.queueSelection.subtract(ids)
    }

    /// Q: the record turns over to the queue, and back.
    private func toggleQueue() {
        guard model.queueShown || !model.otherPlayer else { return }
        if !model.picking, model.shown { pickKey() }
        model.queueShown.toggle()
        log(model.queueShown ? "queue shown" : "queue hidden")
        updateHoverKeys()
    }

    /// The arrows in the queue: the next or the previous song is selected, and Shift adds it to the selection.
    private func stepQueueSelection(_ direction: Int, extending: Bool) {
        let ids = model.queue.map(\.id)
        guard !ids.isEmpty else { return }
        let selected = ids.indices.filter { model.queueSelection.contains(ids[$0]) }
        guard let from = direction > 0 ? selected.last : selected.first else {
            // Nothing selected yet: the song that plays, or the first song.
            model.queueSelection = [model.queueCurrent.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]]
            return
        }
        let target = ids[max(0, min(ids.count - 1, from + direction))]
        if extending { model.queueSelection.insert(target) } else { model.queueSelection = [target] }
    }

    /// Keys while the queue shows. Space, N and P still play, pause and skip, and the other keys, which change what
    /// the queue hides, do nothing. Returns false for the keys that go on to the usual handling.
    private func handleQueueKey(_ code: Int, shift: Bool) -> Bool {
        switch code {
        case kVK_ANSI_Q, kVK_Escape: toggleQueue()
        case kVK_UpArrow, kVK_DownArrow: stepQueueSelection(code == kVK_DownArrow ? 1 : -1, extending: shift)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let id = model.queue.first(where: { model.queueSelection.contains($0.id) })?.id { playFromQueue(id) }
        case kVK_Delete, kVK_ForwardDelete: removeFromQueue(model.queueSelection)
        case kVK_Space, kVK_ANSI_N, kVK_ANSI_P: return false
        default: break
        }
        return true
    }

    /// Add URL to Queue… opens the same bar as Open URL…, and the link it takes is added instead of played.
    private var addingLocation = false

    @objc private func addFiles() {
        guard !model.otherPlayer else { return openFile() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        // A folder of an album, an artist or a playlist opens as all of its songs.
        panel.canChooseDirectories = true
        panel.prompt = "Add to Queue"
        showInFront(panel) { [weak self] chosen in
            if chosen { self?.add(panel.urls, next: false) }
        }
    }

    @objc private func addLocation() {
        guard !model.otherPlayer else { return openLocation() }
        addingLocation = true
        dialogOpen = true
        locationPanel.show()
    }

    /// ⇧⌘V: adds the files or the link on the clipboard to the queue. Returns false when the clipboard holds neither.
    @discardableResult @objc private func addCopied() -> Bool {
        let urls = Self.pastedURLs()
        guard !urls.isEmpty else { return false }
        add(urls, next: false)
        return true
    }

    @objc private func toggleQueueFromMenu() { toggleQueue() }
    @objc private func toggleWaveformFromMenu() { toggleWaveform() }
    @objc private func toggleLayoutFromMenu() { toggleLayout() }
    @objc private func notesFromMenu() { toggleNotesPicker() }
    @objc private func karaokeFromMenu() { toggleKaraoke() }
    @objc private func lanesFromMenu() { toggleWaveformLanes() }
    @objc private func loopFromMenu() { pressLoop(snapping: true) }
    @objc private func songLoopFromMenu() { toggleSongLoop() }
    @objc private func zoomInFromMenu() { zoomWaveform(1.5) }
    @objc private func zoomOutFromMenu() { zoomWaveform(1 / 1.5) }
    @objc private func wholeSongFromMenu() { zoomWaveform(0) }
    @objc private func resetFromMenu() { resetAll() }
    @objc private func pasteFromMenu() { pasteSongs() }
    @objc private func homeFromMenu() { panel.returnHome() }

    /// The ⋯ button in the corner of the HUD: every action that has a key and no button in the HUD, so each one can be
    /// found, with its key beside it.
    private func showMoreMenu() {
        if !model.picking, model.shown { pickKey() }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [], on: Bool = false, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        let keyed = model.key != nil
        let hasSong = nowPlaying.track?.title?.isEmpty == false
        // The queue belongs to Muskey Player, so a song from another app has none.
        if !model.otherPlayer {
            item("Queue", #selector(toggleQueueFromMenu), key: "q", on: model.queueShown)
            item("Add Files to Queue…", #selector(addFiles), key: "o", modifiers: [.command, .shift])
            item("Add URL to Queue…", #selector(addLocation), key: "l", modifiers: [.command, .shift])
            item("Add Copied Songs", #selector(addCopied), key: "v", modifiers: [.command, .shift], enabled: !Self.pastedURLs().isEmpty)
            menu.addItem(.separator())
        }
        if hasSong {
            if !model.lyricsFocus { item("Transcribe Notes…", #selector(notesFromMenu), key: "t", on: model.notesPicking != nil) }
            if keyed { item("Karaoke", #selector(karaokeFromMenu), key: "k", modifiers: .command, on: model.lyricsFocus) }
            menu.addItem(.separator())
        }
        item("Waveform", #selector(toggleWaveformFromMenu), key: "w", on: model.waveformShown)
        if keyed, model.waveformShown, model.waveformStyle == .ribbon {
            item("One Waveform per Instrument", #selector(lanesFromMenu), key: "w", modifiers: .option, on: model.wave.lanes, enabled: lanesAvailable || model.stemsAvailable)
        }
        if model.seekable || model.loop != nil {
            let title = model.loop == nil ? "Start Region Loop" : model.loop?.end == nil ? "End Region Loop" : "Clear Region Loop"
            item(title, #selector(loopFromMenu), key: "r", enabled: model.loop != nil || model.playing)
            item("Loop Song", #selector(songLoopFromMenu), key: "r", modifiers: .shift, on: model.loop?.coversSong(nowPlaying.track?.duration) == true)
        }
        if keyed, model.waveformShown, model.waveformStyle == .ribbon, model.wave.waveform != nil {
            item("Zoom In", #selector(zoomInFromMenu), key: "+", modifiers: .command)
            item("Zoom Out", #selector(zoomOutFromMenu), key: "-", modifiers: .command)
            item("Whole Song", #selector(wholeSongFromMenu), key: "0", modifiers: .command, enabled: model.wave.zoom > 1)
        }
        menu.addItem(.separator())
        item("Mini Player", #selector(toggleMiniPlayer), key: "m", on: prefs.miniPlayer)
        item("Card Layout", #selector(toggleLayoutFromMenu), key: "s", on: model.card)
        item("Center Window", #selector(homeFromMenu), key: "c", modifiers: [.command, .option])
        menu.addItem(.separator())
        item("Open File…", #selector(openFile), key: "o", modifiers: .command)
        item("Open URL…", #selector(openLocation), key: "l", modifiers: .command)
        item("Play Copied Songs", #selector(pasteFromMenu), key: "v", modifiers: .command, enabled: !Self.pastedURLs().isEmpty)
        if keyed {
            let changed = model.shift != 0 || currentSpeed != 1 || !model.stemsMuted.isEmpty || !model.stemVolumes.isEmpty
            item("Original Song", #selector(resetFromMenu), key: String(UnicodeScalar(UInt8(8))), modifiers: .command, enabled: changed)
        }
        if filePlayer.hasSong { item("Stop Playing", #selector(stopPlaying)) }
        menu.addItem(.separator())
        item("Settings…", #selector(showSettings), key: ",", modifiers: .command)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The previous or next song, from the buttons beside the record or a swipe over the HUD. The player gets the
    /// command that the media keys send, and the record shows the glyph at once.
    private func skip(_ direction: Int) {
        log(direction > 0 ? "next song" : "previous song")
        nowPlaying.skip(direction)
        guard model.shown, let track = nowPlaying.track, track.title?.isEmpty == false else { return }
        model.playFlash = PlayFlash(playing: model.playing, id: (model.playFlash?.id ?? 0) + 1, skip: direction)
    }

    private var scrollMonitor: Any?
    /// The fingers' travel across the HUD in the swipe that goes on, in points, and whether it skipped already.
    private var swipeTravel = CGSize.zero
    private var swiped = false

    /// A two-finger swipe across the HUD skips to another song, once per swipe. The fingers moving right play the next
    /// song, and moving left play the previous one, the other way round with Natural swiping in Settings. Mostly
    /// vertical scrolls, like the lyrics', and a mouse wheel are left alone.
    private func swipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.phase == .began {
            swipeTravel = .zero
            swiped = false
        }
        // The momentum after the fingers lift belongs to the swipe that skipped.
        if event.phase.isEmpty { return swiped && !event.momentumPhase.isEmpty }
        // With natural scrolling the deltas go the way the fingers go.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipeTravel.width += event.scrollingDeltaX * sign
        swipeTravel.height += abs(event.scrollingDeltaY)
        if !swiped, abs(swipeTravel.width) > 60, abs(swipeTravel.width) > 2 * swipeTravel.height {
            swiped = true
            if Self.logKeys { log(String(format: "swipe %.0f points", swipeTravel.width), .debug) }
            let right = swipeTravel.width > 0
            skip(right != prefs.naturalSwipes ? 1 : -1)
        }
        return swiped
    }

    /// The scroll over the tempo or a stem that goes on: what it adjusts, the value when it began, and the fingers'
    /// travel since then, in points, up as positive.
    private var adjusting: (region: ScrollRegion, start: Double, travel: CGFloat)?
    /// A trackpad scroll that began over the tempo or a stem, until its first points say whether it goes up and down,
    /// which adjusts, or sideways, which is a swipe.
    private var adjustCandidate: (region: ScrollRegion, start: Double, travel: CGSize)?
    /// Ends a scroll of a mouse wheel, which has no phases, a moment after its last notch.
    private var adjustEnd: DispatchWorkItem?
    /// The last adjusting scroll ended: its momentum still belongs to it.
    private var adjustedAt = Date.distantPast

    /// A scroll that begins over the tempo of a song in Muskey Player changes its speed, by 1 % for every 6 points,
    /// and one that begins over a stem changes its volume, by 1 % for every 3 points. It adjusts the same thing
    /// until the fingers lift, even after the pointer has left it. Fingers moving up raise the value, with natural
    /// scrolling or without.
    private func adjust(_ event: NSEvent) -> Bool {
        let precise = event.hasPreciseScrollingDeltas
        // The momentum after the fingers lift isn't the hand's, so it adjusts nothing, and scrolls nothing else.
        if !event.momentumPhase.isEmpty { return adjusting != nil || Date().timeIntervalSince(adjustedAt) < 0.5 }
        if event.phase == .ended || event.phase == .cancelled {
            adjustCandidate = nil
            guard adjusting != nil else { return false }
            endAdjusting()
            return true
        }
        if event.phase == .began, precise {
            if let region = scrollRegion(at: event), let value = adjustedValue(region) {
                adjusting = nil
                adjustCandidate = (region, value, .zero)
                if Self.logKeys { log("scroll begins over \(region)", .debug) }
            } else if Self.logKeys, let view = panel.contentView {
                let local = view.convert(event.locationInWindow, from: nil)
                let places = model.scroll.frames.values.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height) }
                log(String(format: "scroll begins over nothing to adjust at %.0f,%.0f (flipped %@, height %.0f): ", local.x, local.y, view.isFlipped ? "yes" : "no", view.bounds.height)
                    + places.joined(separator: " | "), .debug)
            }
        }
        if var candidate = adjustCandidate {
            // Over the time bar, a scroll sideways moves the song too, so it is never a swipe there.
            candidate.travel.width += candidate.region.seeks ? 0 : abs(event.scrollingDeltaX)
            candidate.travel.height += scrollTravel(event, for: candidate.region)
            guard candidate.travel.width + abs(candidate.travel.height) > 6 else {
                adjustCandidate = candidate
                return false
            }
            adjustCandidate = nil
            // Sideways: the swipe has seen every event so far and goes on.
            if Self.logKeys { log(abs(candidate.travel.height) > candidate.travel.width ? "the scroll adjusts" : "the scroll is a swipe", .debug) }
            guard abs(candidate.travel.height) > candidate.travel.width else { return false }
            adjusting = (candidate.region, candidate.start, candidate.travel.height)
            model.scroll.region = candidate.region
            Self.hideToolTip()
            return applyAdjusting()
        }
        // A trackpad scroll picks what it adjusts when it begins, above, and a wheel at each notch, keeping the last
        // one while the pointer is over nothing to adjust.
        if event.phase == .began {
            adjusting = nil
        } else if !precise, event.phase.isEmpty, let region = scrollRegion(at: event), let value = adjustedValue(region), adjusting?.region != region {
            adjusting = (region, value, 0)
            model.scroll.region = region
            Self.hideToolTip()
        }
        guard var current = adjusting else { return false }
        current.travel += scrollTravel(event, for: current.region) * (precise ? 1 : 8)
        adjusting = current
        let handled = applyAdjusting()
        if !precise {
            adjustEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in self?.endAdjusting() }
            adjustEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: end)
        }
        return handled
    }

    /// How far `event` moves the fingers, in points: up for the tempo and a stem, and up or right for the time bar,
    /// with natural scrolling or without.
    private func scrollTravel(_ event: NSEvent, for region: ScrollRegion) -> CGFloat {
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let up = sign * event.scrollingDeltaY
        return region.seeks ? up - sign * event.scrollingDeltaX : up
    }

    /// Sets the tempo, the volume or the place in the song from the travel so far, and the lift that goes with it.
    private func applyAdjusting() -> Bool {
        guard let current = adjusting else { return false }
        model.scroll.lift = tanh(current.travel / 60)
        switch current.region {
        case .tempo:
            let speed = min(max(((current.start + Double(current.travel) / 600) * 100).rounded() / 100, 0.5), fastestSpeed)
            if speed != currentSpeed { playSpeed(speed) }
        case let .stem(stem):
            let volume = min(max(((current.start + Double(current.travel) / 300) * 100).rounded() / 100, 0), 1.5)
            if volume != model.stemVolumes[stem] ?? 1 { setStemVolume(stem, volume) }
        case .timeBar, .waveform:
            // 400 points of travel cross the whole song, or the part that the close-up shows on a zoomed waveform, so
            // the song moves more finely the more it is zoomed. The bar shows the place, and the song moves there once
            // the fingers lift, so a player gets one seek per scroll.
            let across = current.region == .waveform ? closeUpShare : 1
            let fraction = min(max(current.start + Double(current.travel) / 400 * across, 0), 1)
            if model.scrub != fraction { model.scrub = fraction }
        }
        return true
    }

    /// AppKit keeps a tooltip on screen through a scroll that the monitor takes, even after the view drops its text,
    /// so the one over a stem is put away when the scroll starts to change the volume.
    private static func hideToolTip() {
        guard let manager = NSClassFromString("NSToolTipManager") as? NSObject.Type,
              manager.responds(to: NSSelectorFromString("sharedToolTipManager")),
              let shared = manager.perform(NSSelectorFromString("sharedToolTipManager"))?.takeUnretainedValue() as? NSObject
        else { return }
        for name in ["abortToolTip", "orderOutToolTip"] where shared.responds(to: NSSelectorFromString(name)) {
            shared.perform(NSSelectorFromString(name))
            return
        }
    }

    private func endAdjusting() {
        adjustEnd?.cancel()
        adjustEnd = nil
        if case let .stem(stem) = adjusting?.region {
            log(String(format: "%@ at %.0f%%", stem.name.lowercased(), (model.stemVolumes[stem] ?? 1) * 100))
        }
        if adjusting?.region.seeks == true, let fraction = model.scrub {
            seek(toFraction: fraction)
            // The bar holds the place until the player reports the move.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.model.scrub == fraction { self?.model.scrub = nil }
            }
        }
        adjusting = nil
        adjustedAt = Date()
        model.scroll.region = nil
        model.scroll.lift = 0
    }

    /// The scroll that goes on began over the time bar or the waveform while the song couldn't move.
    private var scrollOverStillBar = false

    /// The pointer is over the time bar or the waveform, whether the song can move or not.
    private func overSeekPlace(_ event: NSEvent) -> Bool {
        guard let view = panel.contentView else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return model.scroll.frames.values.contains { $0.region.seeks && $0.frame.contains(point) }
    }

    /// The tempo or the stem under the pointer, among the ones that can be adjusted now.
    private func scrollRegion(at event: NSEvent) -> ScrollRegion? {
        guard let view = panel.contentView else { return nil }
        let local = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return model.scroll.frames.values.first { $0.frame.contains(point) && adjustedValue($0.region) != nil }?.region
    }

    /// The value that a scroll over `region` starts from, or nil while it can't be adjusted.
    private func adjustedValue(_ region: ScrollRegion) -> Double? {
        switch region {
        case .tempo: model.speedAdjustable ? currentSpeed : nil
        case let .stem(stem): model.stemsAvailable ? model.stemVolumes[stem] ?? 1 : nil
        case .timeBar, .waveform: model.seekable ? playedFraction : nil
        }
    }

    /// How far the song has played, from 0 to 1, counting a seek that the player hasn't reported yet.
    private var playedFraction: Double? {
        guard let track = nowPlaying.track, let duration = track.duration, duration > 0 else { return nil }
        let pending = seekTarget.flatMap { $0.song == track.song && Date().timeIntervalSince($0.at) < 2 ? $0.seconds : nil }
        guard let position = pending ?? track.position(at: Date()) else { return nil }
        return min(max(position / duration, 0), 1)
    }

    /// The song that Muskey opened plays: the HUD opens on it as the hotkey opens it, unless it already shows. During a
    /// pitch change or with a key locked, that is the key picker, since the song change moves the song already.
    /// The song that Now Playing still names when Muskey Player starts another file. A listen doesn't take that song's
    /// key until Now Playing names the new one, for at most 3 seconds.
    private var staleSong: (song: [String?], until: Date)?

    private func filePlays() {
        if let song = nowPlaying.track?.song { staleSong = (song, Date().addingTimeInterval(3)) }
        syncStemsCache()
        raisedForOpening = false
        // The HUD that showed the song while it opened, or that offered to open one, goes on to the listen.
        guard state == .idle || (state == .showing && model.phase == .idle && model.shown) else { return }
        (pitch.running && changesNeedPitch) || keptKey != nil ? pickKey() : start()
    }

    @objc private func stopPlaying() { filePlayer.close() }

    @objc private func saveFromMenu() { saveSong() }

    /// Stop Playing in the File menu works only while Muskey Player has a song, and Save Song only while the song
    /// can be saved with its changes.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(stopPlaying): filePlayer.hasSong
        case #selector(saveFromMenu): model.savable
        default: true
        }
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        // A folder of an album, an artist or a playlist opens as all of its songs.
        panel.canChooseDirectories = true
        showInFront(panel) { [weak self] chosen in
            if chosen { self?.open(panel.urls) }
        }
    }

    /// A link to a song or a video, or the path of a file, in a glass bar like the HUD's.
    @objc private func openLocation() {
        addingLocation = false
        dialogOpen = true
        locationPanel.show()
    }

    /// The open or save panel on screen, which a second Save Song or Open File brings to the front instead of opening
    /// another.
    private var shownPanel: NSSavePanel?

    /// Shows an open or save panel in front of the app that is active, with the keyboard on the panel. macOS brings
    /// only a regular app to the front, so Muskey shows in the Dock while the panel is open, as it does for Settings.
    /// The app that was in front gets the keyboard back afterwards, as when the HUD closes.
    ///
    /// The panel isn't modal: while `runModal` runs a save panel, the main queue runs almost nothing, so Muskey
    /// Player's moves never reached the stems from the cache. A region loop that went back to its start then
    /// lost the song, and the stems were separated as it played again.
    private func showInFront(_ panel: NSSavePanel, then done: @escaping (Bool) -> Void) {
        if let shownPanel { return shownPanel.makeKeyAndOrderFront(nil) }
        let accessory = NSApp.activationPolicy() == .accessory
        if accessory { NSApp.setActivationPolicy(.regular) }
        NSApp.takeFocus()
        // The HUD, karaoke's blur and the activity pill sit at the status bar's level, above the panel: the HUD hid
        // half of the save panel and took the clicks meant for its Format picker. They go below the panel while it is
        // open, and the panel goes above the floating level that they take meanwhile.
        let raised = NSApp.windows.filter { $0.isVisible && $0.level == .statusBar }
        raised.forEach { $0.level = .floating }
        panel.level = .modalPanel
        dialogOpen = true
        shownPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            shownPanel = nil
            dialogOpen = false
            raised.forEach { $0.level = .statusBar }
            if accessory, !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
                if let lastOtherApp, lastOtherApp != .current { frontAfterClose(lastOtherApp) }
            }
            done(response == .OK)
        }
    }

    /// ⌘V over the HUD: plays the files or the link on the clipboard. Returns false when the clipboard holds neither.
    @discardableResult private func pasteSongs() -> Bool {
        let urls = Self.pastedURLs()
        guard !urls.isEmpty else { return false }
        open(urls)
        return true
    }

    /// Files or a link on the clipboard, for ⌘V over the HUD.
    private static func pastedURLs() -> [URL] {
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return files }
        if let text = board.string(forType: .string), let url = FilePlayer.url(from: text) { return [url] }
        return []
    }

    private func registerHotKey(_ shortcut: Shortcut?) {
        hotKey = nil
        prefs.hotkeyFailed = false
        guard let shortcut else { return }
        do {
            hotKey = try HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                // Someone is at the Mac: the sound that the remote muted plays again. While a phone listens, the song
                // plays on the phone, and the Mac sends its output silence whatever the mute says.
                if self?.phoneListening == false { self?.restoreRemoteMute() }
                self?.toggle()
            }
        } catch {
            prefs.hotkeyFailed = true
            log("\(error); is \(shortcut.symbols) taken by another app?", .error)
        }
    }

    /// The hotkey only works while the app runs. An app that moved, like from ~/Applications to /Applications,
    /// registers again, so the login item opens this copy.
    private func updateLoginItem(_ enabled: Bool) {
        let path = Bundle.main.bundlePath
        // The login item is read and changed through a system daemon, which can be slow to answer, so it happens off
        // the main thread, one change at a time.
        Self.loginItemQueue.async { [weak self] in
            let service = SMAppService.mainApp
            guard enabled else {
                if service.status == .enabled { try? service.unregister() }
                return
            }
            guard service.status != .enabled || UserDefaults.standard.string(forKey: "loginItemPath") != path else { return }
            if service.status == .enabled { try? service.unregister() }
            do {
                try service.register()
                UserDefaults.standard.set(path, forKey: "loginItemPath")
            } catch {
                DispatchQueue.main.async { self?.log("adding the login item failed: \(error)", .error) }
            }
        }
    }

    private static let loginItemQueue = DispatchQueue(label: "muskey.login-item", qos: .utility)

    /// Settings and the key commands of its window and of the lyrics window, which work while one of them is the
    /// active window. The text editing commands are what make Command-V paste lyrics.
    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Muskey", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open File…", action: #selector(openFile), keyEquivalent: "o").target = self
        file.addItem(withTitle: "Open URL…", action: #selector(openLocation), keyEquivalent: "l").target = self
        file.addItem(withTitle: "Add Files to Queue…", action: #selector(addFiles), keyEquivalent: "O").target = self
        file.addItem(withTitle: "Add URL to Queue…", action: #selector(addLocation), keyEquivalent: "L").target = self
        file.addItem(withTitle: "Save Song…", action: #selector(saveFromMenu), keyEquivalent: "s").target = self
        file.addItem(withTitle: "Stop Playing", action: #selector(stopPlaying), keyEquivalent: "").target = self
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose), keyEquivalent: "w")
        for submenu in [app, file, edit, window] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
    }

    @objc private func showSettings() { settingsWindow.show() }

    /// Quitting while the lyrics show keeps the words heard and the lines written so far, as closing the HUD does.
    func applicationWillTerminate(_: Notification) {
        // A recording keeps its samples on disk and becomes a song file at the next launch.
        micRecorder?.flush()
        restoreRemoteMute()
        filePlayer.stop()
        cancelAutoListen()
        pitch.stop(waiting: true)
        lyricsSync.end()
        nowPlaying.watching = false
    }

    /// `killall` and Ctrl-C end the app without `applicationWillTerminate`, so they stop the pitch change here.
    /// A crash or SIGKILL can't be caught, but then Core Audio removes the tap and the aggregate device with the
    /// process, and a `.mutedWhenTapped` tap stops muting once nothing reads it.
    private func stopPitchOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreRemoteMute()
                self?.pitch.stop(waiting: true)
                self?.lyricsSync.end()
                self?.filePlayer.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Opening the app again while it runs, from Finder, the Dock or Spotlight, shows the HUD as the hotkey does. While
    /// the HUD, the mini player or a window of Muskey shows, it changes nothing: app switchers like rcmd send the same
    /// event when they only bring Muskey to the front, as when the notes window is focused. Settings opens with ⌘, from
    /// the HUD, and from the menu bar icon.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        let windows = NSApp.windows.filter { window in
            window.isVisible && window.screen != nil && (window.styleMask.contains(.titled) || window === miniPanel)
        }
        if model.shown || !windows.isEmpty {
            let names = windows.map { $0 === miniPanel ? "mini player" : $0.title.isEmpty ? "untitled window" : $0.title }
            log("reopen: \(model.shown ? "the HUD" : names.joined(separator: ", ")) already shows")
            return false
        }
        // A listen always shows the HUD, so the state is idle unless the HUD is still fading out.
        guard state == .idle else {
            log("reopen: the HUD is closing")
            return false
        }
        log("reopen: showing the HUD")
        toggle()
        return false
    }

    /// While a pitch change runs or a key is kept, the hotkey opens the key picker instead of starting another listen.
    private func toggle() {
        // While the microphone records, the hotkey brings its HUD back.
        if micRecorder != nil { return showMic() }
        if state != .idle, panel.headless { return revealHeadless() }
        switch state {
        case .idle: (pitch.running && changesNeedPitch) || keptKey != nil ? pickKey() : start()
        case .listening, .showing: dismiss()
        }
    }

    private func start() {
        session += 1
        stayOpen = true
        state = .listening
        follow = nil
        followByPerson = false
        model.moved = nil
        model.pending = nil
        switch AudioCapturePermission.status {
        case .granted: listen()
        case .denied: fail(.denied, "system audio recording is not allowed")
        case .undetermined:
            let current = session
            AudioCapturePermission.request { [self] granted in
                guard session == current, state == .listening else { return }
                granted ? listen() : fail(.denied, "system audio recording was not allowed")
            }
        }
    }

    /// An open picker keeps its key and its keys during a listen that a song change started.
    private func listen() {
        cancelAutoListen()
        model.phase = .listening
        model.progress = 0
        model.pitchFailed = false
        peak = 0
        estimated = false
        listenSong = nil
        remembered = nil
        lookedUp = nil
        let shownWithKey = model.shown && model.key != nil && !model.lyricsFocus && model.glassFrame.width > 0
        model.shown = true
        if !model.picking {
            if shownWithKey { model.heldGlass = model.glassFrame.size }
            model.key = nil
            // The glass takes the mouse during the listen too, so it can be dragged away.
            panel.setInteraction(clickable: true, keyboard: false)
        }
        panel.present()
        startedAt = Date()
        listenHeardPlaying = false
        listenFromFile = false
        if let path = listenFile { return readKey(of: path) }

        let tap = SystemAudioTap()
        self.tap = tap
        do {
            try tap.prepare()
            let analyzer = KeyAnalyzer(sampleRate: tap.sampleRate, speed: playedSpeed, recordTo: Self.stringOption("--wav"))
            self.analyzer = analyzer
            listenTapRate = tap.sampleRate
            try feed(tap, to: analyzer)
        } catch {
            return fail(.failed, "\(error)")
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        startOnKnownKey()
    }

    /// The listen reads the song's file instead of recording the song as it plays.
    private var listenFromFile = false

    /// The file of the song that Muskey Player plays, which a listen reads instead of recording it.
    private var listenFile: String? {
        guard playsInFilePlayer, let path = filePlayer.current?.path, FileManager.default.isReadableFile(atPath: path) else { return nil }
        return path
    }

    /// A song that Muskey Player plays has its file, so its key comes from the whole file at once, whatever its length,
    /// instead of from a listen that records it as it plays. A key known from before still shows at once.
    private func readKey(of path: String) {
        listenFromFile = true
        listenSong = listenSong ?? nowPlaying.track?.song
        startOnKnownKey()
        guard state == .listening else { return }
        let current = session
        log("reading the key from the file")
        DispatchQueue.global(qos: .userInitiated).async {
            let read = KeyAnalyzer.read(path)
            DispatchQueue.main.async { [self] in
                guard session == current, state == .listening, listenFromFile else { return }
                guard let read else { return fail(.failed, "the song's file can't be read for its key") }
                state = .showing
                model.progress = 1
                log(String(format: "read %.1f s of the file in %.2f s", read.seconds, Date().timeIntervalSince(startedAt)))
                finishListen(read.result, peak: read.peak, bpm: read.tempo, elapsed: read.seconds)
            }
        }
    }

    /// Sends what the tap records to the listen's analyzer, whose estimates show while this listen runs.
    private func feed(_ tap: SystemAudioTap, to analyzer: KeyAnalyzer) throws {
        let current = session
        try tap.start { [weak self] samples in
            analyzer.append(samples) { result, peak in
                guard let self, self.session == current else { return }
                self.update(result, peak: peak)
            }
        }
    }

    /// The song paused during its listen, after it played: the recording and the ticker stop, and the analyzer keeps
    /// what it heard. The HUD keeps the song instead of offering to play, and the listen goes on when the song plays
    /// again. A listen that starts on a paused player still ends on Nothing playing.
    private func pauseListen() {
        guard state == .listening, listenPausedAt == nil else { return }
        // A song shorter than a listen stops at its end before the listen does: the key comes from all of it.
        if estimated, let track = nowPlaying.track, let duration = track.duration, let now = track.position(at: Date()), now >= duration - 1 {
            log("the song ended before the listen, which ends with it")
            return finish()
        }
        ticker?.invalidate()
        ticker = nil
        tap?.stop()
        tap = nil
        listenPausedAt = Date()
        listenPausedSong = nowPlaying.track?.song
        log("the song paused, and the listen waits for it without recording")
    }

    /// The song of a paused listen plays again: a new recording goes to the same analyzer, and the listen's time goes
    /// on from where it stopped.
    private func resumeListen() {
        // Another song gets a listen of its own from the song change.
        guard let pausedAt = listenPausedAt, state == .listening, let analyzer, let track = nowPlaying.track, track.playing,
              track.song == listenPausedSong else { return }
        listenPausedAt = nil
        startedAt += Date().timeIntervalSince(pausedAt)
        let tap = SystemAudioTap()
        do {
            try tap.prepare()
            // Another output device with another rate: the analyzer can't take its sound, so the listen starts over.
            guard tap.sampleRate == listenTapRate else {
                log("the song plays again at another sample rate, listening from the start")
                return listen()
            }
            try feed(tap, to: analyzer)
        } catch {
            return fail(.failed, "\(error)")
        }
        self.tap = tap
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        log("the song plays again, and so does the listen")
    }

    /// A song whose key a full listen found before shows that key at once, with no listen, unless Lock Key has to move
    /// it, which waits for the listen. A song with only Noiseblend's key starts on that key: the HUD shows it with its
    /// row right away, the listen still runs, and only its final estimate can change the key. Runs again on each Now
    /// Playing update until the first estimate, since the helper that reads the song starts with the HUD, and once
    /// more when Noiseblend answers. A click on the key listens again without either.
    private func startOnKnownKey() {
        guard state == .listening, !estimated, remembered == nil, let track = nowPlaying.track, track.playing else { return }
        if let stale = staleSong, stale.song == track.song, Date() < stale.until { return }
        // A paused player that Now Playing still names may not be what the Mac plays.
        listenSong = listenSong ?? track.song
        guard track.song == listenSong, !redetecting else { return }
        guard let known = knownKey(for: track.song) else {
            if lookedUp != track.song {
                lookedUp = track.song
                lookUpKey(track)
            }
            return
        }
        let key = known.key
        // A key remembered without its tempo, as before Muskey kept tempos, gets one more listen, which finds it.
        if !known.online, follow == nil, knownTempo(for: track.song) != nil { return finishOnKnownKey(key) }
        remembered = key
        log("starting on \(known.online ? "Noiseblend's" : "the remembered") \(key.name)")
        model.key = key
        noteKey(key, final: true, online: known.online)
        if let follow {
            shiftBase = key
            let current = session
            let wait = max(0, Self.originalKeyFor - Date().timeIntervalSince(songChangedAt))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
                guard session == current, state == .listening, !followApplied, let key = model.key, follow == self.follow else { return }
                retarget(key, to: follow, final: false)
            }
        } else if model.picking {
            shiftBase = key
            if keptKey != nil { keptKey = model.heard }
            refreshStatus()
        }
        if !model.picking { panel.setInteraction(clickable: true, keyboard: false) }
        updateHoverKeys()
    }

    /// The key of a song that a listen found before, shown as a listen's result, with no listen.
    private func finishOnKnownKey(_ key: DetectedKey) {
        stopCapture()
        analyzer = nil
        state = .showing
        remembered = key
        model.key = key
        model.phase = .done
        noteKey(key, final: true)
        if model.picking || model.shift != 0 {
            shiftBase = key
            if model.picking, keptKey != nil { keptKey = model.heard }
            refreshStatus()
        }
        log("\(key.name), known from an earlier listen")
        showTempo()
        if !model.picking { panel.setInteraction(clickable: true, keyboard: false) }
        updateHoverKeys()
        if !model.picking, let delay = resultHideDelay { dismiss(after: delay) }
    }

    /// A click on the key: the song is listened to again as if no key were known for it, and the key that the listen
    /// finds replaces the remembered one.
    private func redetect() {
        guard model.saving == nil, model.phase == .done || model.phase == .listening else { return }
        log("re-detecting the key")
        stopCapture()
        analyzer = nil
        redetecting = true
        start()
    }

    private func update(_ result: EKResult, peak: Float) {
        guard state == .listening else { return }
        self.peak = peak
        estimated = true
        // A new song that the first estimate moved keeps that key and shift until the listen ends: on a real song,
        // the estimates can swing between two keys for a while, and each swing would change the pitch.
        if follow != nil, followApplied { return }
        if remembered != nil { return }
        // An open picker keeps its last key if an estimate comes back empty.
        model.key = DetectedKey(result) ?? (model.picking ? model.key : nil)
        guard let key = model.key else { return }
        noteKey(key, final: false)
        if let follow {
            shiftBase = key
            if Date().timeIntervalSince(songChangedAt) >= Self.originalKeyFor { retarget(key, to: follow, final: false) }
        } else if model.picking {
            // The rows relabel in place: each key's column is its shift, so the selected one doesn't move.
            shiftBase = key
            if keptKey != nil { keptKey = model.heard }
            refreshStatus()
        }
        // The first estimate brings the key strip, which needs clicks.
        if !model.picking { panel.setInteraction(clickable: true, keyboard: false) }
        updateHoverKeys()
    }

    private func tick() {
        if let track = nowPlaying.track, track.title?.isEmpty == false {
            if track.playing { listenHeardPlaying = true } else if listenHeardPlaying { return pauseListen() }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        model.progress = min(1, elapsed / seconds)
        // Nothing has made a sound in 3 seconds of a listen that the hotkey started, and no player says that it plays:
        // the HUD offers to play. A song that starts quietly gets its whole listen.
        if follow == nil, !model.picking, elapsed >= Self.idleAfter, peak < 0.0005, nowPlaying.track?.playing != true {
            return nothingPlays(after: elapsed)
        }
        // A song that starts quietly gets the whole listen when it has to be moved to the kept key.
        if ((follow == nil || followByPerson) && elapsed >= silenceAfter && estimated && peak < 0.0005) || elapsed >= seconds { finish() }
    }

    private func stopCapture() {
        ticker?.invalidate()
        ticker = nil
        tap?.stop()
        tap = nil
        listenPausedAt = nil
    }

    private func finish() {
        guard state == .listening, let analyzer else { return }
        stopCapture()
        self.analyzer = nil
        state = .showing
        let current = session
        let elapsed = Date().timeIntervalSince(startedAt)

        analyzer.finish { [self] result, peak, bpm in
            guard session == current else { return }
            finishListen(result, peak: peak, bpm: bpm, elapsed: elapsed)
        }
    }

    /// The final key of a listen, or of a song's file, with the tempo found in the same audio.
    private func finishListen(_ result: EKResult, peak: Float, bpm: (bpm: Double, confidence: Float)?, elapsed: Double) {
        let target = follow
        let byPerson = followByPerson
        follow = nil
        followByPerson = false
        guard peak >= 0.0005, let key = DetectedKey(result) else {
            if target != nil { return followFailed(String(format: "no key found in the new song after %.1fs", elapsed)) }
            return fail(.silent, String(format: "silence after %.1fs", elapsed))
        }
        model.key = key
        model.phase = .done
        noteKey(key, final: true)
        // A listen during a pitch change hears the original song, so this is the key the change starts from.
        if let target {
            shiftBase = key
            retarget(key, to: target, final: true, byPerson: byPerson)
        } else if model.picking || model.shift != 0 {
            shiftBase = key
            if model.picking, keptKey != nil { keptKey = model.heard }
            refreshStatus()
        }
        log(String(format: "%@ (relative %@)  strength %.3f  %.1fs", key.name, key.relative.name, result.strength, elapsed), .notice)
        if let remembered, remembered != key { log("the full listen found \(key.name), not the \(remembered.name) that it started on") }
        let tempo = heardTempo(bpm, in: listenSong ?? nowPlaying.track?.song)
        if let song = listenSong, let track = nowPlaying.track, track.playing || listenFromFile, track.song == song {
            if prefs.rememberKeys { log(keyCache.store(key, strength: result.strength, bpm: tempo, for: song, replace: redetecting)) }
            if let id = KeyCache.id(song) { heardKeys[id] = (key, tempo) }
            keyLookup.heard(key, for: song)
        }
        redetecting = false
        updateHoverKeys()
        guard !model.picking else { return }
        panel.setInteraction(clickable: true, keyboard: false)
        if let delay = resultHideDelay { dismiss(after: delay) }
    }

    private func fail(_ phase: HUDModel.Phase, _ reason: String) {
        stopCapture()
        analyzer = nil
        redetecting = false
        state = .showing
        // The picker opened on an estimate, so it keeps that key rather than turning into an error.
        if model.picking {
            model.phase = .done
            return log(reason, .notice)
        }
        model.key = nil
        model.phase = phase
        model.shown = true
        panel.setInteraction(clickable: false, keyboard: false)
        panel.present()
        updateHoverKeys()
        log(reason, .notice)
        dismiss(after: 2)
    }

    private static let idleAfter = 3.0

    /// Nothing plays: the HUD stays up with an empty record that plays whatever macOS played last, and the buttons
    /// that open a file or a link. A song that starts meanwhile is listened to at once.
    private func nothingPlays(after elapsed: Double) {
        stopCapture()
        analyzer = nil
        state = .showing
        model.key = nil
        model.phase = .idle
        model.shown = true
        panel.setInteraction(clickable: true, keyboard: true)
        panel.present()
        updateHoverKeys()
        log(String(format: "nothing plays after %.1f s", elapsed))
        showRecents()
    }

    /// The recents as rows, kept from one time nothing plays to the next, so their covers are read once.
    private var recentRows: [String: QueueItem] = [:]

    /// Nothing plays: the empty record shows for a moment and turns over to the songs that Muskey Player played last.
    private func showRecents() {
        let entries = RecentSongs.load()
        guard !entries.isEmpty else { return }
        model.recents = entries.map { entry in
            let id = entry.url.absoluteString
            if var row = recentRows[id] {
                // A listen since the last time may have found the song's key.
                if row.read, row.folder != row.url, prefs.rememberKeys {
                    let song: [String?] = [row.title, row.artist, row.album]
                    row.key = keyCache.key(for: song) ?? row.key
                    row.bpm = keyCache.bpm(for: song) ?? row.bpm
                    recentRows[id] = row
                }
                return row
            }
            var row = QueueItem(url: entry.url, cached: entry.song)
            if FilePlayer.isFolder(entry.url) {
                row.folder = entry.url
                row.title = entry.url.lastPathComponent
            }
            recentRows[id] = row
            return row
        }
        readRecentDetails()
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recentsAfter) { [weak self] in
            guard let self, session == current, model.phase == .idle, model.shown, model.opening == nil, !model.queueShown else { return }
            // Return plays the song that played last, until ↑ and ↓ highlight another.
            model.recentsSelection = model.recents.first?.id
            model.recentsShown = true
            log("recents shown: \(model.recents.count) song\(model.recents.count == 1 ? "" : "s")")
            if Self.logKeys {
                log("recents: the HUD \(panel.isKeyWindow ? "has" : "doesn't have") the keyboard, \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing") is in front", .debug)
            }
        }
    }

    /// Long enough for the empty record to be seen before it turns over.
    private static let recentsAfter = 0.7

    /// The title, artist and cover of each recent song that wasn't read yet, and the key that Muskey remembers for it.
    private func readRecentDetails() {
        for item in model.recents where !item.read && item.folder == item.url {
            readFolderDetails(item)
        }
        for item in model.recents where !item.read && item.folder != item.url {
            guard let file = item.file, FileManager.default.fileExists(atPath: file.path) else { continue }
            Task { @MainActor [weak self] in
                let details = await QueueItem.details(file, name: item.url.isFileURL ? nil : SongName.link(item.url))
                guard let self else { return }
                var row = recentRows[item.url.absoluteString] ?? item
                row.apply(details)
                let song: [String?] = [row.title, row.artist, row.album]
                if prefs.rememberKeys {
                    row.key = keyCache.key(for: song)
                    row.bpm = keyCache.bpm(for: song)
                }
                row.analysed = true
                recentRows[item.url.absoluteString] = row
                if let at = model.recents.firstIndex(where: { $0.id == row.id }) { model.recents[at] = row }
            }
        }
    }

    /// A folder in Recents shows the cover of its first song, or a cover image in the folder, and its song count with
    /// the first song's artist under its name.
    private func readFolderDetails(_ item: QueueItem) {
        let folder = item.url
        Task { @MainActor [weak self] in
            let songs = await Task.detached(priority: .utility) { FilePlayer.songs(in: folder) }.value
            let details = if let first = songs.first { await QueueItem.details(first) } else { QueueItem.Details?.none }
            // A playlist mixes artists: the artist shows only when the last song has the same one as the first.
            let lastArtist = if songs.count > 1, let last = songs.last { await QueueItem.details(last)?.artist } else { details?.artist }
            let cover = await Task.detached(priority: .utility) { () -> NSImage? in
                for name in ["cover", "folder", "front", "Cover", "Folder", "Front"] {
                    for ext in ["jpg", "jpeg", "png"] {
                        if let image = NSImage(contentsOf: folder.appending(path: "\(name).\(ext)")) { return image }
                    }
                }
                return nil
            }.value
            guard let self, var row = recentRows[folder.absoluteString] else { return }
            row.read = true
            row.analysed = true
            row.artwork = cover ?? details?.artwork
            let count = songs.count >= FilePlayer.folderLimit ? "\(FilePlayer.folderLimit)+ songs" : "\(songs.count) song\(songs.count == 1 ? "" : "s")"
            let artist = details?.artist.flatMap { $0 == lastArtist ? $0 : nil }
            row.detail = [artist, count].compactMap { $0 }.joined(separator: " · ")
            recentRows[folder.absoluteString] = row
            if let at = model.recents.firstIndex(where: { $0.id == row.id }) { model.recents[at] = row }
        }
    }

    private func removeRecent(_ song: QueueItem) {
        RecentSongs.remove(song.url)
        recentRows[song.url.absoluteString] = nil
        let at = model.recents.firstIndex { $0.id == song.id }
        model.recents.removeAll { $0.id == song.id }
        if model.recentsSelection == song.id {
            model.recentsSelection = at.flatMap { model.recents.isEmpty ? nil : model.recents[min($0, model.recents.count - 1)].id }
        }
        if model.recents.isEmpty { model.recentsShown = false }
    }

    private var recentsKeyMonitor: Any?

    /// ↑ and ↓ highlight the song before or after, and Return plays the highlighted song. Returns false for the other
    /// keys, which go on to the usual handling.
    private func handleRecentsKey(_ code: Int) -> Bool {
        let songs = model.recents
        guard !songs.isEmpty else { return false }
        switch code {
        case kVK_UpArrow, kVK_DownArrow:
            let at = model.recentsSelection.flatMap { id in songs.firstIndex { $0.id == id } }
            let next = at.map { max(0, min(songs.count - 1, $0 + (code == kVK_DownArrow ? 1 : -1))) } ?? 0
            model.recentsSelection = songs[next].id
        case kVK_Return, kVK_ANSI_KeypadEnter:
            let song = songs.first { $0.id == model.recentsSelection } ?? songs[0]
            log("recents: Return plays song \(songs.firstIndex { $0.id == song.id }.map { $0 + 1 } ?? 1) of \(songs.count)")
            model.onRecentPlay(song)
        default:
            return false
        }
        return true
    }

    /// A song plays while the HUD offers to play one: the listen starts over on it.
    private func listenWhenPlaying() {
        // The song of another app still plays while a link downloads, and the listen waits for the song that opens.
        guard model.phase == .idle, model.shown, model.opening == nil, nowPlaying.track?.playing == true else { return }
        log("a song plays, listening")
        start()
    }

    private func dismiss(after delay: TimeInterval) {
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            // A song that opens keeps the HUD until it plays.
            guard session == current, !model.picking, model.opening == nil else { return }
            // The pointer is on the result, likely on its way to Change Key.
            if model.hovering { return dismiss(after: 1.5) }
            dismiss()
        }
    }

    /// Turns the HUD into the key picker: from a listen's first estimate (the listen keeps going), from a result,
    /// or from the hotkey and the menu bar item while a pitch change runs.
    private func pickKey() {
        guard !model.picking else { return }
        let fromHUD = (state == .listening || (state == .showing && model.phase == .done)) ? model.key : nil
        if fromHUD == nil {
            guard let base = shiftBase else { return }
            stopCapture()
            analyzer = nil
            session += 1
            state = .showing
            model.key = base
            model.phase = .done
        }
        shiftBase = model.key
        model.picking = true
        model.shown = true
        warmUpStems()
        panel.present()
        panel.setInteraction(clickable: true, keyboard: true)

        keyMonitor = keyMonitor ?? NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // A key that can be held already acted when it went down. Its first repeat starts the hold, its other
            // repeats do nothing, and its release ends the watch for the hold.
            if event.type == .keyUp {
                self?.releaseKey(Int(event.keyCode))
                return event
            }
            if event.isARepeat, let self, self.heldKey?.code == Int(event.keyCode) {
                self.holdKey()
                return nil
            }
            let flags = event.modifierFlags
            // ⌘⌥C moves the HUD back home, in every state, also while a song is saved or the shortcuts show.
            if let self, event.window === self.panel, flags.intersection(.deviceIndependentFlagsMask) == [.command, .option],
               Int(event.keyCode) == kVK_ANSI_C {
                self.panel.returnHome()
                return nil
            }
            // While a song is saved, the HUD takes none of its keys but Escape, which closes it. ⌘Q and the other
            // menu keys still work.
            if let self, self.model.saving != nil, event.window === self.panel {
                if Int(event.keyCode) == kVK_Escape { return self.handleKey(kVK_Escape, shift: false, option: false) ? nil : event }
                return flags.contains(.command) && !Self.hudCommandKeys.contains(Int(event.keyCode)) ? event : nil
            }
            // The shortcuts hide what the HUD's keys with Command change, so those keys wait until they close.
            if let self, self.model.shortcuts, event.window === self.panel, flags.contains(.command) {
                return Self.hudCommandKeys.contains(Int(event.keyCode)) ? nil : event
            }
            // ⌘V plays the file or the link on the clipboard, while the HUD takes the keyboard, and ⇧⌘V adds it to the queue.
            if let self, event.window === self.panel, flags.contains(.command), Int(event.keyCode) == kVK_ANSI_V {
                return (flags.contains(.shift) ? self.addCopied() : self.pasteSongs()) ? nil : event
            }
            // ⌘A selects every song of the queue.
            if let self, self.model.queueShown, event.window === self.panel, flags.contains(.command), Int(event.keyCode) == kVK_ANSI_A {
                self.model.queueSelection = Set(self.model.queue.map(\.id))
                return nil
            }
            // ⌘⌫ takes the song back to how it was: its key, its tempo and every stem.
            if let self, self.model.picking || self.model.phase == .idle, event.window === self.panel, flags.contains(.command),
               Int(event.keyCode) == kVK_Delete {
                self.resetAll()
                return nil
            }
            // ⌘O and ⌘L open a file or a link, and with Shift they add it to the queue.
            if let self, event.window === self.panel, flags.contains(.command),
               [kVK_ANSI_O, kVK_ANSI_L].contains(Int(event.keyCode)) {
                switch (Int(event.keyCode) == kVK_ANSI_O, flags.contains(.shift)) {
                case (true, false): self.openFile()
                case (false, false): self.openLocation()
                case (true, true): self.addFiles()
                case (false, true): self.addLocation()
                }
                return nil
            }
            // ⌘+ and ⌘− zoom the waveform, and ⌘0 shows the whole song again.
            if let self, event.window === self.panel, flags.contains(.command), !flags.contains(.option),
               [kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadMinus, kVK_ANSI_0, kVK_ANSI_Keypad0].contains(Int(event.keyCode)) {
                let code = Int(event.keyCode)
                self.zoomWaveform([kVK_ANSI_0, kVK_ANSI_Keypad0].contains(code) ? 0 : [kVK_ANSI_Equal, kVK_ANSI_KeypadPlus].contains(code) ? 1.5 : 1 / 1.5)
                return nil
            }
            // ⌘K opens karaoke, or closes it.
            if let self, self.model.picking, event.window === self.panel, flags.contains(.command), !flags.contains(.option),
               Int(event.keyCode) == kVK_ANSI_K {
                self.toggleKaraoke()
                return nil
            }
            // ⌘S saves the song with its changes.
            if let self, self.model.picking, event.window === self.panel, flags.contains(.command), !flags.contains(.option),
               Int(event.keyCode) == kVK_ANSI_S, self.model.savable {
                self.saveSong()
                return nil
            }
            // Typing in the lyrics editor, or a time of the region loop, stays in the field.
            if self?.loopTyping == true { return event }
            guard let self, self.model.picking, !flags.contains(.command), !flags.contains(.control),
                  event.window == nil || event.window === self.panel else { return event }
            return self.pressKey(Int(event.keyCode), shift: flags.contains(.shift), option: flags.contains(.option)) ? nil : event
        }
        updateHoverKeys()
    }

    /// A number key of an instrument, a letter of a key, W or R, which do one thing when pressed and another when held.
    /// The press acts as the key goes down, so that a tap never waits, and the hold takes its place, the way the accent
    /// menu of macOS replaces a letter that was already typed.
    private struct HeldKey {
        let code: Int
        let hold: () -> Void
        let timer: Timer
        var held = false
    }

    private var heldKey: HeldKey?
    /// The key being handled was just pressed, by a person, so the keys that can be held watch for the hold.
    private var holdable = false

    /// A key that a person pressed, as the HUD's key events and the keys over the HUD get it.
    @discardableResult private func pressKey(_ code: Int, shift: Bool, option: Bool) -> Bool {
        // Another key that came first ends the hold of the one before, as does a release that was lost.
        if let waiting = heldKey { releaseKey(waiting.code) }
        holdable = true
        defer { holdable = false }
        return handleKey(code, shift: shift, option: option)
    }

    /// "Delay until repeat" in Keyboard settings, kept between 0.2 and 0.8 seconds.
    private static var holdDelay: Double { min(0.8, max(0.2, NSEvent.keyRepeatDelay)) }

    /// Runs `press` at once, and `hold` after the hold delay while the key is still down. `hold` starts from the state
    /// that `press` left, so it puts back what it needs of the state before the press.
    private func pressOrHold(_ code: Int, press: () -> Void, hold: @escaping () -> Void) {
        press()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            self?.holdKey()
        }
        heldKey = HeldKey(code: code, hold: hold, timer: timer)
    }

    private func holdKey() {
        guard var key = heldKey, !key.held else { return }
        key.timer.invalidate()
        key.held = true
        heldKey = key
        if Self.logKeys { log("key \(key.code) held", .debug) }
        key.hold()
    }

    private func releaseKey(_ code: Int) {
        guard let key = heldKey, key.code == code else { return }
        key.timer.invalidate()
        heldKey = nil
    }

    /// The keys with Command that the HUD uses, which a save in progress turns off.
    private static let hudCommandKeys: Set<Int> = [kVK_ANSI_V, kVK_Delete, kVK_ANSI_O, kVK_ANSI_L, kVK_ANSI_K, kVK_ANSI_S]

    /// Letter keys: A picks the A in the song's mode, Option the A in the other mode, and Shift the key with a sharp or
    /// flat on A.
    private static let letters: [Int: Character] = [
        kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_A: "A", kVK_ANSI_B: "B",
    ]

    /// Keys of the key picker, from the picker's own key events or from the hotkeys that hovering over the HUD
    /// registers. Returns false for a key it doesn't use.
    @discardableResult private func handleKey(_ code: Int, shift: Bool, option: Bool) -> Bool {
        if Self.logKeys { log("key \(code)\(shift ? " shift" : "")\(option ? " option" : "")", .debug) }
        // A save in progress leaves the HUD only Escape, which closes it while the save goes on.
        if model.saving != nil {
            if code == kVK_Escape { dismiss() }
            return true
        }
        // A song that opens leaves it Escape, which cancels it as Cancel does, and Backspace, which closes the HUD
        // while the song keeps opening, as Continue in Background does. On a failure, Escape dismisses it.
        if model.opening != nil {
            if code == kVK_Escape { cancelOpening() }
            if code == kVK_Delete { continueOpeningInBackground() }
            return true
        }
        // ? shows every key and gesture in place of the HUD, and closes them again, on whichever key types ? in the
        // keyboard layout. While they show, Escape closes them too, and the other keys do nothing, since what they
        // change is hidden under them.
        if let question = LayoutKey.questionMark, code == question.code, shift == question.shift, option == question.option {
            model.shortcuts.toggle()
            return true
        }
        if model.shortcuts {
            if code == kVK_Escape { model.shortcuts = false }
            return true
        }
        // The stem picker of T takes the numbers, Return and Escape, and leaves Space to play or pause.
        if model.notesPicking != nil {
            switch code {
            case kVK_Escape, kVK_ANSI_T: closeNotesPicker()
            case kVK_Return, kVK_ANSI_KeypadEnter: startNotes(full: option)
            case kVK_Tab: pickNotesPart(whole: model.notesPicking?.wholeSong == false)
            case kVK_Space: playPause()
            default:
                if let digit = Self.digitKeys.firstIndex(of: code), digit > 0, let stems = model.notesPicking?.stems, digit <= stems.count {
                    selectNotesStem(stems[digit - 1])
                }
            }
            return true
        }
        if model.queueShown, !model.lyricsFocus, handleQueueKey(code, shift: shift) { return true }
        if model.recentsFlipped, !shift, !option, handleRecentsKey(code) { return true }
        // Over the tab of an end of the region loop, ← and → nudge that end, and by a beat with ⌥.
        if let end = model.wave.loopEnd, model.loop != nil, !shift, code == kVK_LeftArrow || code == kVK_RightArrow {
            nudgeLoopEnd(end, by: code == kVK_RightArrow ? 1 : -1, beat: option)
            return true
        }
        // Over the waveform and its lanes, ← and → move the song 5 seconds in every layout. A song that can't move
        // leaves them doing nothing, so that they never change the key or the chords out of sight.
        if model.wave.hovered, !shift, !option, code == kVK_LeftArrow || code == kVK_RightArrow {
            if model.seekable { seek(by: code == kVK_RightArrow ? 5 : -5) } else { log("seek: the player ignores seeks or the lyrics delay runs") }
            return true
        }
        // And 0 goes to the start of the region loop, or of the song, and 1 to 9 to the bars that it numbers. With no
        // numbered bars, 1 to 9 keep their usual meaning, which mutes the stems.
        if model.wave.hovered, !shift, !option, let digit = Self.digitKeys.firstIndex(of: code), digit == 0 || waveformNumbersBars {
            waveformDigit(digit)
            return true
        }
        // With chords over the lyrics, ← and → move the song a semitone, and ⌥← and ⌥→ move the capo, which changes
        // only the chords shown.
        // Over the record, they still seek.
        if model.lyricsShown, !model.karaokeKeys, !model.overRecord, !model.chords.isEmpty, !shift, code == kVK_LeftArrow || code == kVK_RightArrow {
            let step = code == kVK_RightArrow ? 1 : -1
            if option { setCapo(model.capo + step) } else { change(to: model.shift + step) }
            return true
        }
        // Q turns the record over to the queue, in both layouts.
        if code == kVK_ANSI_Q, !shift, !option, !model.lyricsFocus, !model.otherPlayer {
            toggleQueue()
            return true
        }
        // T shows the stems to transcribe into notes.
        if code == kVK_ANSI_T, !shift, !option, !model.lyricsFocus {
            toggleNotesPicker()
            return true
        }
        // M shows the mini player, or hides it.
        if code == kVK_ANSI_M, !shift, !option {
            toggleMiniPlayer()
            return true
        }
        if !shift, handleSongKey(code, option: option) { return true }
        // With the key row hidden, the keys that change the pitch would change it out of sight.
        if handleStemKey(code, option: option) { return true }
        if model.speedAdjustable, let step = Self.speedKeys[code] {
            changeSpeed(by: step)
            return true
        }
        if code == kVK_Space {
            playPause()
            return true
        }
        // W shows or hides the waveform in every layout, and holding it, or ⌥W, splits it into the lanes of the stems.
        if code == kVK_ANSI_W, !shift {
            if option {
                toggleWaveformLanes()
            } else if holdable {
                let shown = prefs.waveform
                pressOrHold(code, press: toggleWaveform, hold: { [weak self] in self?.holdWaveform(shown: shown) })
            } else {
                toggleWaveform()
            }
            return true
        }
        // R starts the region loop, ends it and clears it, in every layout. ⌥R doesn't snap the end, and holding R, or
        // ⇧R, loops the whole song.
        if code == kVK_ANSI_R {
            if shift {
                toggleSongLoop()
            } else if holdable, !option {
                // The press clears a loop that is set, so a hold that finds the whole song looped leaves it cleared.
                let songLooped = model.loop.map { loop in nowPlaying.track?.duration.map { loop.coversSong($0) } ?? false } ?? false
                pressOrHold(code, press: { pressLoop(snapping: true) }, hold: { [weak self] in
                    if !songLooped { self?.toggleSongLoop() }
                })
            } else {
                pressLoop(snapping: !option)
            }
            return true
        }
        if model.lyricsShown {
            switch code {
            case kVK_Escape: dismiss()
            case kVK_Return, kVK_ANSI_KeypadEnter: toggleLyricsFocus()
            case kVK_ANSI_L: toggleLyrics()
            // Karaoke has no layout button, and the layout under it would change out of sight.
            case kVK_ANSI_S where !model.lyricsFocus: toggleLayout()
            case kVK_ANSI_K: toggleKeep()
            // Karaoke changes the key with the keys of the key row, which shows while the pointer is over the key
            // at the top. Delete in the original key has nothing to undo, and leaves karaoke as it is.
            case kVK_Delete where model.lyricsFocus && model.shift == 0 && !model.relative && model.pending == nil: break
            default:
                guard model.lyricsFocus else { return false }
                return handlePitchKey(code, shift: shift, option: option)
            }
            return true
        }
        switch code {
        case kVK_ANSI_L: toggleLyrics()
        case kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter: dismiss()
        // In the original key, with no move waiting for a new song's key, there is nothing to undo: close the HUD.
        case kVK_Delete where model.shift == 0 && !model.relative && model.pending == nil: dismiss()
        case kVK_Delete: change(to: 0, relative: false)
        case kVK_ANSI_K: toggleKeep()
        case kVK_ANSI_S: toggleLayout()
        default: return handlePitchKey(code, shift: shift, option: option)
        }
        return true
    }

    /// Keys 0 to 9, for the seeks over the record and in karaoke.
    private static let digitKeys = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// N and P play the next and the previous song in every layout. With the lyrics, ← and → seek 5 seconds back or
    /// ahead, except while karaoke shows its key row, which takes them for the key. In karaoke, 0 starts the song over
    /// and 1 to 9 move it to a tenth of its length, except while the stems show, which take the numbers. The seeks
    /// exist while the player takes them and the lyrics delay doesn't run (`model.seekable`). With the stems separated
    /// live, a seek starts them over at the new place.
    private func handleSongKey(_ code: Int, option: Bool) -> Bool {
        // Over the record and its time bar, ← → move the song 5 seconds, 0 starts it over and 1 to 9 move it to a
        // tenth of its length, in every layout. The numbers mute no stem there, even while a seek can't be instant.
        if model.overRecord, !option {
            switch code {
            case kVK_LeftArrow where model.seekable: seek(by: -5); return true
            case kVK_RightArrow where model.seekable: seek(by: 5); return true
            case kVK_ANSI_0 where model.restartable: startOver(); return true
            default:
                if let digit = Self.digitKeys.firstIndex(of: code), digit > 0 {
                    if model.seekable { seek(toFraction: Double(digit) / 10) } else { log("seek: the player ignores seeks or the lyrics delay runs") }
                    return true
                }
            }
        }
        switch code {
        case kVK_ANSI_N where !option: skip(1)
        case kVK_ANSI_P where !option: skip(-1)
        case kVK_LeftArrow where model.seekable && model.lyricsShown && !model.karaokeKeys: seek(by: -5)
        case kVK_RightArrow where model.seekable && model.lyricsShown && !model.karaokeKeys: seek(by: 5)
        // In karaoke, 0 starts the song over in every player, as karaoke's own start does, unless the stems show.
        case kVK_ANSI_0 where model.restartable && model.lyricsFocus && !option && !(model.stemsAvailable && model.karaokeStems): startOver()
        // Karaoke's arrows change the key only while its key row shows, so they never change it out of sight.
        case kVK_LeftArrow where model.lyricsFocus && !model.karaokeKeys, kVK_RightArrow where model.lyricsFocus && !model.karaokeKeys: break
        default:
            guard model.seekable, model.lyricsFocus, !option, !(model.stemsAvailable && model.karaokeStems), let digit = Self.digitKeys.firstIndex(of: code)
            else { return false }
            seek(toFraction: Double(digit) / 10)
        }
        return true
    }

    /// The keys 0 to 9 over the waveform. 0 goes to the start of the region loop, or to the song's start without one,
    /// and 1 to 9 to the bars that the waveform numbers.
    private func waveformDigit(_ digit: Int) {
        guard model.seekable else { return log("seek: the player ignores seeks or the lyrics delay runs") }
        if digit == 0 {
            if let loop = model.loop { return seek(to: loop.start, flash: "repeat") }
            return model.restartable ? startOver() : seek(to: 0, flash: "0%")
        }
        let bars = waveformBars()
        guard digit <= min(9, bars.count) else { return log("seek: the waveform numbers \(bars.count) bars") }
        log("seek: bar \(digit) of the waveform")
        seek(to: bars[digit - 1], flash: "\(digit).circle")
    }

    /// The waveform numbers bars, which 1 to 9 go to: a region loop is set or the waveform shows a close-up, and the
    /// song's tempo is known.
    private var waveformNumbersBars: Bool {
        model.shownTempo != nil && (model.loop?.end != nil || model.wave.zoom > 1.05 && (model.card || model.waveformStyle == .ribbon))
    }

    /// The share of the song that the close-up of the waveform shows, as `WaveformView` spans it, or 1 for the whole
    /// song.
    private var closeUpShare: Double {
        guard model.wave.zoom > 1.05, model.card || model.waveformStyle == .ribbon,
              let duration = nowPlaying.track?.duration, duration > 0 else { return 1 }
        return min(1, max(4, duration / model.wave.zoom) / duration)
    }

    /// The bars that the waveform numbers, as `WaveformView` finds them for the close-up around the playhead.
    private func waveformBars() -> [Double] {
        guard let track = nowPlaying.track, let duration = track.duration, duration > 0 else { return [] }
        let zoomed = model.wave.zoom > 1.05 && (model.card || model.waveformStyle == .ribbon)
        let span = max(4, duration / model.wave.zoom)
        let now = track.position(at: Date()) ?? 0
        return WaveformBars.starts(loop: model.loop, bpm: model.shownTempo?.bpm, closeUp: zoomed ? now - span / 2 ... now + span / 2 : nil)
    }

    /// The position that the last seek asked for, until the player reports it, so that quick presses add up.
    private var seekTarget: (song: [String?], seconds: Double, at: Date)?
    /// Checks that the player moved the song, a few seconds after a seek.
    private var seekCheck: DispatchWorkItem?
    /// The path that moved the song in each player, which its next seeks take at once.
    private var seekPaths: [String: SeekPath] = [:]
    /// `--seek-path elapsed|command|script` sends every seek through that path alone, for testing each one.
    private static let forcedSeekPath = TestFlags.value("--seek-path").flatMap(SeekPath.init(rawValue:))
    /// `--seek-ignore elapsed,command` sends nothing through those paths, as a player that ignores them would have it,
    /// for testing the fallbacks.
    private static let ignoredSeekPaths = Set((TestFlags.value("--seek-ignore") ?? "").split(separator: ",").compactMap { SeekPath(rawValue: String($0)) })
    /// Players that left the song where it was after a seek. The seek keys leave them alone until Muskey quits.
    private var unseekable: Set<String> = []

    /// The key 0 in karaoke: the song starts over, at once while the stems are off, and with karaoke's own start
    /// while they play: the sound dips, the song plays from its start under the countdown, and it rewinds to the start
    /// without the muted stems.
    private func startOver() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false else { return }
        if let id = track.bundleID, unseekable.contains(id) { return log("start over: \(id) ignored the last seek") }
        if case .seeking = karaokeRestart { return log("start over: the last move isn't done yet") }
        guard !lyricsDelayed else { return log("start over: the song plays behind itself while Whisper writes its lyrics") }
        guard model.stemsEngaged, !cachedStems else { return seek(to: 0, flash: "0%") }
        if model.shown { model.playFlash = PlayFlash(playing: model.playing, id: (model.playFlash?.id ?? 0) + 1, seek: "0%") }
        guard StemModel.prepared else {
            log("karaoke: the song starts over once the model is ready")
            karaokeRestart = .waitingForModel
            return
        }
        beginKaraokeRestart()
    }

    // MARK: Saving

    /// Where a song is saved from: the file that Muskey Player plays, or another player, which plays the song from
    /// its start to its end while Muskey records it.
    private enum SaveSource: Equatable {
        case file(path: String)
        case player(bundleID: String, song: [String?], seconds: Double)
    }

    private struct SaveJob: Equatable {
        let name: String
        let source: SaveSource
        let changes: SongChanges
        let url: URL
        let format: SaveFormat
        var tags = SongTags()
    }

    /// The song being saved, and the last save that failed, for Retry.
    private var saveJob: SaveJob?
    private var failedSave: SaveJob?
    /// The file of the last save, for Show in Finder.
    private var savedURL: URL?
    /// The pill at the top right: a song that opens takes it, and the save shows again once that is done.
    private var openActivity: OpenActivity? {
        didSet { syncOpening() }
    }
    private var saveActivity: OpenActivity? {
        didSet {
            syncActivityPill()
            let saving: SavingState? = switch saveActivity {
            case let .saving(name, progress): SavingState(name: name, progress: progress, left: nil)
            case let .recording(name, left, progress): SavingState(name: name, progress: progress, left: left)
            default: nil
            }
            if model.saving != saving {
                model.saving = saving
                syncActivityPill()
            }
        }
    }
    /// Set by Cancel, and read by the thread that renders the save, which stops at its next step.
    private var saveCancelled = OSAllocatedUnfairLock(initialState: false)

    /// The changes that a save keeps, nil when the song plays as it is.
    private func saveChanges() -> SongChanges? {
        var changes = SongChanges(semitones: model.shift, speed: currentSpeed)
        if model.stemsEngaged, model.stemsAdjusted {
            changes.stemGains = Stem.allCases.map { model.stemsMuted.contains($0) ? 0 : Float(model.stemVolumes[$0] ?? 1) }
        }
        // A region loop with both ends saves only the region.
        if let loop = model.loop, let end = loop.end, end > loop.start, !loop.coversSong(nowPlaying.track?.duration) { changes.range = loop.start ... end }
        // A recording from the microphone can be saved as it is, since it lives in Muskey's folder until then.
        return changes.isEmpty && model.recording == nil ? nil : changes
    }

    private func saveSource() -> SaveSource? {
        guard let track = nowPlaying.track else { return nil }
        if track.bundleID == FilePlayer.bundleID { return filePlayer.current.map { .file(path: $0.path) } }
        // Another player has to move the song to its start, and the song has to fit in memory.
        guard model.restartable, let id = track.bundleID, let seconds = track.duration, seconds > 1, seconds <= SongRecorder.maxSeconds
        else { return nil }
        return .player(bundleID: id, song: track.song, seconds: seconds)
    }

    private func syncSavable() {
        let savable = saveChanges() != nil && saveSource() != nil
        guard savable != model.savable else { return }
        model.savable = savable
        updateHoverKeys()
    }

    /// Save Song in the menus, the button on the HUD and ⌘S: asks where to save the song, then renders it with the
    /// changes it plays with now.
    private func saveSong() {
        guard saveJob == nil else { return log("save: a song is being saved already") }
        // The changes are taken at the press, so a change made while the panel is open doesn't go in the file.
        guard let changes = saveChanges(), let source = saveSource() else { return log("save: nothing changed, or the song can't be saved") }
        let title = switch source {
        case let .file(path): filePlayer.current?.title ?? nowPlaying.track?.title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .player: nowPlaying.track?.title ?? "Song"
        }
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var caveat: String?
        if case let .player(id, _, _) = source {
            caveat = SongRecorder.hearsPlayerOnly(bundleID: id, pid: nowPlaying.track?.pid) ? SaveCaveat.recorded : SaveCaveat.recordedWithOthers
        }
        // The tags and the cover are taken at the press too, from the song that plays.
        let track = nowPlaying.track
        let tags = SongTags(title: track?.title ?? filePlayer.current?.title, artist: track?.artist, album: track?.album,
                            cover: SongTags.jpeg(nowPlaying.artwork))
        askWhereToSave(fileName(name, changes), caveat: caveat) { [weak self] url, format in
            guard let self else { return }
            guard let url, let format else { return log("save: cancelled") }
            guard saveJob == nil else { return log("save: a song is being saved already") }
            startSave(SaveJob(name: name, source: source, changes: changes, url: url, format: format, tags: tags))
        }
    }

    /// `1:02` for a moment of a song, in the name of a saved region.
    private static func minutes(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d.%02d", whole / 60, whole % 60)
    }

    /// The title, and what changed in parentheses: `Bine (C minor, 0.9x, 1.02–1.34, no vocals)`.
    private func fileName(_ name: String, _ changes: SongChanges) -> String {
        var parts: [String] = []
        if changes.semitones != 0, let base = shiftBase { parts.append(model.shown(base.transposed(by: changes.semitones)).name) }
        if abs(changes.speed - 1) > 0.001 { parts.append(MiniPlayerView.speed(changes.speed) + "x") }
        if let range = changes.range { parts.append("\(Self.minutes(range.lowerBound))–\(Self.minutes(range.upperBound))") }
        if let gains = changes.stemGains {
            let muted = Stem.shown.filter { gains[$0.rawValue] == 0 }, playing = Stem.shown.filter { gains[$0.rawValue] > 0 }
            if muted.isEmpty {
                parts.append("stem volumes")
            } else if playing.count == 1 {
                parts.append("\(playing[0].name.lowercased()) only")
            } else if muted.count <= 2 {
                parts.append("no " + muted.map { $0.name.lowercased() }.joined(separator: " and "))
            } else {
                parts.append("\(playing.count) stems")
            }
        }
        return parts.isEmpty ? name : "\(name) (\(parts.joined(separator: ", ")))"
    }

    private func askWhereToSave(_ name: String, caveat: String?, then done: @escaping (URL?, SaveFormat?) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Save Song"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        var format = prefs.saveFormat
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(name).\(format.rawValue)"
        let pick = { (picked: SaveFormat) in
            format = picked
            panel.allowedContentTypes = [picked.type]
            panel.nameFieldStringValue = ((panel.nameFieldStringValue as NSString).deletingPathExtension as NSString).appendingPathExtension(picked.rawValue) ?? name
        }
        let accessory = NSHostingView(rootView: SaveAccessory(format: format, caveat: caveat, picked: pick))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        // `--save-pick wav` picks a format a second after the panel opens, as the Format picker does: macOS draws the
        // panel in a service process, which takes neither posted clicks nor accessibility.
        if let test = Self.stringOption("--save-pick").flatMap(SaveFormat.init(rawValue:)) {
            let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
                pick(test)
                self?.log("save: picked \(test.name) for the test, the name reads \(panel.nameFieldStringValue)", .debug)
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        showInFront(panel) { [weak self] saved in
            guard saved, let url = panel.url else { return done(nil, nil) }
            self?.prefs.saveFormat = format
            done(url, format)
        }
    }

    private func retrySave() {
        guard let job = failedSave, saveJob == nil else { return }
        startSave(job)
    }

    /// Renders the song on a thread of its own, into a temporary file that replaces the chosen one once it is whole.
    /// A song from another player is recorded first, as it plays from its start to its end.
    private func startSave(_ job: SaveJob, recorded: StereoAudio? = nil) {
        saveJob = job
        failedSave = nil
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        saveCancelled = cancelled
        if case .player = job.source, recorded == nil { return startRecording(job) }
        saveActivity = .saving(name: job.name, progress: 0)
        let changes = job.changes
        log(String(format: "save: %@ as %@, %+d semitones, %.0f%% tempo%@%@%@", job.name, job.format.name, changes.semitones, changes.speed * 100,
                   changes.stemGains == nil ? "" : ", stems \(changes.stemGains!.map { String(format: "%.2f", $0) }.joined(separator: " "))",
                   changes.range.map { String(format: ", from %.2f s to %.2f s", $0.lowerBound, $0.upperBound) } ?? "",
                   job.tags.cover == nil ? ", no cover" : ", with the cover"))
        // With the stems separated for the output too, the separation of the whole song leaves them half of the time.
        let live = model.stemsEngaged
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var shown = -1
            let report = { (part: Double) -> Bool in
                let percent = Int(part * 100)
                if percent != shown {
                    shown = percent
                    DispatchQueue.main.async {
                        guard let self, self.saveJob == job else { return }
                        self.saveActivity = .saving(name: job.name, progress: part)
                    }
                }
                return !cancelled.withLock { $0 }
            }
            let temporary = FileManager.default.temporaryDirectory.appending(path: "Muskey save \(UUID().uuidString).\(job.format.rawValue)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let audio: StereoAudio
                var path: String?
                var changes = changes
                if let recorded {
                    audio = recorded
                    // A recording holds the region alone already.
                    changes.range = nil
                } else if case let .file(file) = job.source {
                    audio = try SongRender.read(URL(fileURLWithPath: file))
                    path = file
                } else {
                    throw SaveError(message: "The song has no file")
                }
                let rendered = try SongRender.render(audio, changes: changes, path: path, live: { live }) { report($0 * 0.95) }
                try SongRender.write(rendered, as: job.format, to: temporary, tags: job.tags) { report(0.95 + $0 * 0.05) }
                // Cancel in the last moment of the write leaves no file either.
                if cancelled.withLock({ $0 }) { throw CancellationError() }
                if FileManager.default.fileExists(atPath: job.url.path) { try FileManager.default.removeItem(at: job.url) }
                try FileManager.default.moveItem(at: temporary, to: job.url)
                DispatchQueue.main.async { self?.saveFinished(job, error: nil, seconds: Date().timeIntervalSince(started), length: rendered.seconds) }
            } catch {
                DispatchQueue.main.async { self?.saveFinished(job, error: error, seconds: Date().timeIntervalSince(started), length: 0) }
            }
        }
    }

    /// A song from another player, recorded for Save Song: the player pauses, moves the song to its start and plays
    /// it, and the recording ends at the song's length. A pause, a seek or another song ends it with a failure, which
    /// Retry starts over.
    private final class SongRecording {
        /// Learning the move that the player takes, while the song plays, then the pause, the move sent while paused
        /// (which a paused player reports no position for), and the song playing from its start.
        enum Phase { case learning, pausing, moving, playing }
        let job: SaveJob
        let recorder: SongRecorder
        var phase = Phase.pausing
        var since = Date()
        var timer: Timer?

        init(job: SaveJob, recorder: SongRecorder) {
            self.job = job
            self.recorder = recorder
        }

        /// Where the recording starts in the song, and how long it runs: the region loop, or the whole song.
        var start: Double { job.changes.range?.lowerBound ?? 0 }
        var length: Double {
            guard case let .player(_, _, seconds) = job.source else { return 0 }
            return job.changes.range.map { $0.upperBound - $0.lowerBound } ?? seconds
        }
    }

    private var songRecording: SongRecording?

    private func startRecording(_ job: SaveJob) {
        // The player moves under a slowed song, which would stop the recording, so the song plays as it is while it is
        // recorded, and the save slows it down. The slowing comes back after the save.
        guard case let .player(id, _, _) = job.source, let track = nowPlaying.track, track.bundleID == id else {
            return saveFinished(job, error: SaveError(message: "The song isn't playing anymore"), seconds: 0, length: 0)
        }
        if slow.active {
            speedBeforeRecording = slow.speed
            slow.stop("the song is recorded for a save")
        }
        let recorder = SongRecorder(bundleID: id, pid: track.pid)
        let recording = SongRecording(job: job, recorder: recorder)
        songRecording = recording
        updateWatching(shown: model.shown)
        saveActivity = .recording(name: job.name, left: Self.clock(recording.length))
        log("save: recording \(job.name) from \(recorder.playerOnly ? id + " alone" : "every app but Muskey")")
        recording.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkRecording() }
        guard Self.forcedSeekPath == nil, seekPaths[id] == nil else {
            if track.playing { nowPlaying.play(false) }
            return checkRecording()
        }
        // A paused player gives no position to check a move against, so the move that this player takes is learned
        // while the song plays, from its start.
        recording.phase = .learning
        if !track.playing { nowPlaying.play(true) }
        movePlayer(track, to: recording.start) { [weak self] moved in
            guard let self, songRecording === recording else { return }
            guard moved else { return endRecording(error: SaveError(message: "The player didn't move the song to its start")) }
            recording.phase = .pausing
            recording.since = Date()
            nowPlaying.play(false)
        }
    }

    /// Sends a move through the path that moved the song in this player before, without checking it.
    private func sendMove(_ track: NowPlaying.Track, to target: Double) {
        guard let id = track.bundleID, id != FilePlayer.bundleID else {
            return track.bundleID == FilePlayer.bundleID ? filePlayer.seek(target) : nowPlaying.seek(to: target)
        }
        switch Self.forcedSeekPath ?? seekPaths[id] ?? .elapsed {
        case .elapsed: nowPlaying.seek(to: target)
        case .command: if let pid = track.pid { nowPlaying.seek(to: target, pid: pid) } else { nowPlaying.seek(to: target) }
        case .script: PlayerScript.seek(id, to: target) { _ in }
        }
    }

    /// Steps the recording on, from the reports of the player and a timer.
    private func checkRecording() {
        guard let recording = songRecording, case let .player(_, song, _) = recording.job.source else { return }
        let track = nowPlaying.track
        let waited = Date().timeIntervalSince(recording.since)
        switch recording.phase {
        case .learning:
            break
        case .pausing:
            // The player stopped, or didn't answer within 3 seconds: the recording starts, then the song moves.
            guard track?.playing == false || waited > 3, let track else { return }
            do {
                try recording.recorder.start()
            } catch {
                return endRecording(error: SaveError(message: "The song can't be recorded: \(error)"))
            }
            recording.phase = .moving
            recording.since = Date()
            sendMove(track, to: recording.start)
        case .moving:
            // The player had a moment to take the move. A song that stayed where it was ends the recording below, once
            // it plays.
            guard waited > 0.6 else { return }
            recording.phase = .playing
            recording.since = Date()
            nowPlaying.play(true)
        case .playing:
            let rate = recording.recorder.rate, frames = recording.recorder.frames, target = Int(recording.length * rate)
            if frames >= target { return endRecording(error: nil) }
            // Another song: a recording that is all but done keeps what it has.
            if let track, track.song != song {
                return frames >= target - Int(2 * rate) ? endRecording(error: nil)
                    : endRecording(error: SaveError(message: "Another song started"))
            }
            if waited > 10, !recording.recorder.heard { return endRecording(error: SaveError(message: "Nothing was heard from the player")) }
            // A pause stops the recording, and the save keeps the part recorded until then.
            if waited > 2, track?.playing == false {
                log("save: the song was paused, saving the part recorded so far")
                return endRecording(error: nil, partial: true)
            }
            // A seek moves the player away from the recording, which counts the song from its first sound.
            if recording.recorder.heard, let position = track?.position(at: Date()), abs(position - recording.start - Double(frames) / rate) > 4 {
                return endRecording(error: SaveError(message: String(format: "The song moved to %.0f s", position)))
            }
            saveActivity = .recording(name: recording.job.name, left: Self.clock(Double(target - frames) / rate), progress: Double(frames) / Double(max(1, target)))
        }
    }

    /// Ends the recording of a song from another player. `partial` saves the part recorded so far, without the silence
    /// after it, and `cancelled` saves nothing.
    private func endRecording(error: Error?, partial: Bool = false, cancelled: Bool = false) {
        guard let recording = songRecording, case .player = recording.job.source else { return }
        recording.timer?.invalidate()
        songRecording = nil
        updateWatching(shown: model.shown)
        if let speed = speedBeforeRecording {
            speedBeforeRecording = nil
            DispatchQueue.main.async { [weak self] in
                self?.syncSpeed()
                self?.playSpeed(speed)
            }
        }
        var audio = recording.recorder.stop(frames: Int(recording.length * recording.recorder.rate))
        if cancelled { return }
        if let error { return saveFinished(recording.job, error: error, seconds: 0, length: 0) }
        if partial {
            audio = audio.trimmingSilentEnd()
            guard audio.seconds >= 1 else { return saveFinished(recording.job, error: SaveError(message: "Nothing was recorded yet"), seconds: 0, length: 0) }
        }
        log(String(format: "save: recorded %.1f s of %@ at %.0f Hz", audio.seconds, recording.job.name, audio.rate))
        startSave(recording.job, recorded: audio)
    }

    /// Cancel on the HUD while a song is saved: a recording stops, a render stops at its next step, and no file is
    /// written.
    private func cancelSave() {
        guard let job = saveJob else { return }
        log("save: \(job.name) cancelled")
        saveCancelled.withLock { $0 = true }
        if songRecording != nil { endRecording(error: nil, cancelled: true) }
        saveJob = nil
        saveActivity = nil
    }

    /// Stop and Save on the HUD while a song from another player is recorded: the save keeps the part recorded so far.
    /// Before the song plays from its start, nothing is recorded, and it cancels.
    private func stopSave() {
        guard let recording = songRecording else { return }
        guard recording.phase == .playing else { return cancelSave() }
        log("save: stopped, saving the part recorded so far")
        endRecording(error: nil, partial: true)
    }

    /// `2:15` for the time left.
    private static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d left", whole / 60, whole % 60)
    }

    private func saveFinished(_ job: SaveJob, error: Error?, seconds: Double, length: Double) {
        guard saveJob == job else { return }
        saveJob = nil
        if let error {
            log("save: \(job.name) failed: \(error.localizedDescription)", .error)
            failedSave = job
            saveActivity = .saveFailed(name: job.name)
            return
        }
        log(String(format: "save: wrote %@ (%.1f s of song) in %.1f s", job.url.lastPathComponent, length, seconds))
        savedURL = job.url
        saveActivity = .saved(name: job.name)
        // The pill of a finished save goes away by itself after a while.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            // A later save that finished meanwhile keeps its pill for its own 8 seconds.
            if case .saved = self?.saveActivity, self?.savedURL == job.url { self?.saveActivity = nil }
        }
    }

    /// Seeks are instant only while nothing plays behind the song: with the stems separated live, a seek would wait
    /// for them again under a countdown, and the lyrics delay would start over. A song in Muskey Player with its stems
    /// in the cache seeks at once with the stems on, since the stems of the new place are there already.
    private func syncSeekable() {
        let track = nowPlaying.track
        let ignored = track?.bundleID.map(unseekable.contains) ?? false
        let restartable = track?.title?.isEmpty == false && !ignored && !lyricsDelayed
        // Stems separated as the song plays don't stop a seek: it goes through the start over, which separates the new
        // place before the stems step back to it.
        let seekable = restartable
        let seekOff = lyricsDelayed ? "Seeking is off while the lyrics are transcribed" : ignored ? "Seeking is off for this player" : "Seeking is off"
        if model.seekOff != seekOff { model.seekOff = seekOff }
        guard seekable != model.seekable || restartable != model.restartable else { return }
        model.restartable = restartable
        model.seekable = seekable
        if Self.logKeys { log("seek keys \(seekable ? "on" : "off")", .debug) }
        updateHoverKeys()
    }

    /// Deletes the cached stems and the songs downloaded from links that weren't played for the period in Settings >
    /// General > Cache. The song in Muskey Player and its stems stay, however long it has been playing.
    private func sweepCaches() {
        let age = prefs.cacheCleanup.rawValue
        guard age > 0 else { return }
        let playing = filePlayer.current?.path
        Self.cacheSweepQueue.async { [weak self] in
            var kept: Set<String> = []
            if let playing {
                kept.insert(playing)
                if let stems = StemsCache.url(for: playing) { kept.formUnion([stems.path, stems.appendingPathExtension("partial").path]) }
            }
            let stems = StemsCache.sweep(olderThan: age, keeping: kept)
            let songs = LinkCache().sweep(olderThan: age, keeping: kept)
            guard stems + songs > 0 else { return }
            DispatchQueue.main.async { self?.log("cache cleanup: deleted \(stems) stems files and \(songs) downloaded songs") }
        }
    }

    private func seek(by seconds: Double) {
        guard let track = nowPlaying.track else { return }
        let pending = seekTarget.flatMap { $0.song == track.song && Date().timeIntervalSince($0.at) < 2 ? $0.seconds : nil }
        guard let base = pending ?? track.position(at: Date()) else { return log("seek: the player gives no position for the song") }
        seek(to: base + seconds, flash: seconds < 0 ? "gobackward.5" : "goforward.5")
    }

    private func seek(toFraction fraction: Double) {
        guard let duration = nowPlaying.track?.duration, duration > 0 else { return log("seek: the player gives no length for the song") }
        seek(to: duration * fraction, flash: "\(Int((fraction * 100).rounded()))%")
    }

    /// Moves the song that plays to `seconds` and flashes the record with `flash`, a percent or an SF Symbol.
    private func seek(to seconds: Double, flash: String) {
        guard let track = nowPlaying.track, track.title?.isEmpty == false else { return }
        guard model.seekable else { return log("seek: not now, the player ignores seeks or the lyrics delay would start over") }
        // A save moves the player to the song's start and records it from there.
        guard songRecording == nil else { return log("seek: not while the song is recorded for a save") }
        let target = max(0, min(seconds, (track.duration ?? .infinity) - 1))
        seekTarget = (track.song, target, Date())
        log(String(format: "seek to %.1f s", target))
        if model.shown { model.playFlash = PlayFlash(playing: model.playing, id: (model.playFlash?.id ?? 0) + 1, seek: flash) }
        // The output goes quiet until the stems of the new place play, a moment after the player moves the song.
        if model.stemsEngaged, cachedStems { pitch.cachedSeek(to: target) }
        // Stems separated as the song plays start over at the new place: the output dips, the player moves the song,
        // and the stems step back to it once its first part is separated. Before the model is ready, nothing was
        // separated yet, and the song moves as it is.
        if model.stemsEngaged, !cachedStems, StemModel.prepared {
            showSeekWait(from: track.position(at: Date()) ?? target, to: target)
            return beginKaraokeRestart(to: target)
        }
        moveSong(track, to: target)
    }

    /// The time bar and the waveform travel to the place of a seek and pulse until the stems of that place play, or
    /// until the wait clearly ran over.
    private func showSeekWait(from: Double, to: Double) {
        let wait = SeekWait(from: from, to: to, started: Date(), expected: Self.stemsWait + 0.75)
        model.seekWait = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + wait.expected + 10) { [weak self] in
            if self?.model.seekWait == wait { self?.model.seekWait = nil }
        }
    }

    /// Moves the song that is heard: through the slowed stream while it is slowed down, which jumps to the move.
    private func moveSong(_ track: NowPlaying.Track, to target: Double, done: ((Bool) -> Void)? = nil) {
        guard slow.active, track.bundleID != FilePlayer.bundleID else { return movePlayer(track, to: target, done: done) }
        slow.moved(track, to: target)
        done?(true)
    }

    /// Moves the song in the player of `track` to `target` seconds. Players differ in the seek they take, so the first
    /// seek in a player sets the elapsed time that Now Playing shows, and when the song didn't move 2.5 seconds later,
    /// it sends the seek command to the player's process, then sets the time through the player's AppleScript, which
    /// asks for the Automation permission the first time. The path that moved the song is kept for the player's next
    /// seeks, and a player that took none goes in `unseekable`. `done` gets whether the song moved.
    private func movePlayer(_ track: NowPlaying.Track, to target: Double, path: SeekPath? = nil, done: ((Bool) -> Void)? = nil) {
        guard let id = track.bundleID, id != FilePlayer.bundleID else {
            if track.bundleID == FilePlayer.bundleID { filePlayer.seek(target) } else { nowPlaying.seek(to: target) }
            done?(true)
            return
        }
        let path = path ?? Self.forcedSeekPath ?? seekPaths[id] ?? .elapsed
        let asked = Date()
        let before = track.position(at: asked)
        seekCheck?.cancel()
        seekCheck = nil
        // Checks where the song is a while after the move was sent, and tries the next path when it stayed.
        func check(_ sent: Date, tries: Int = 0) {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard let now = nowPlaying.player, now.song == track.song else {
                    log(nowPlaying.player == nil ? "seek: nothing plays, the move is over"
                        : "seek: another song plays (\(nowPlaying.player?.label ?? "")), the move is over")
                    return done?(false) ?? ()
                }
                guard let position = now.position(at: Date()) else {
                    // Music leaves the time out of its report right after a move, until the next report.
                    if tries < 3 { return check(sent, tries: tries + 1) }
                    log("seek: the player gives no position (elapsed \(now.elapsed.map { String($0) } ?? "none"), rate \(now.rate.map { String($0) } ?? "none")), the move is over")
                    return done?(false) ?? ()
                }
                let rate = now.playing ? now.rate ?? 1 : 0
                if abs(position - (target + Date().timeIntervalSince(sent) * rate)) <= 2 {
                    log("seek: \(id) moved the song through the \(path.name)")
                    seekPaths[id] = path
                    return done?(true) ?? ()
                }
                // A player that ignored the seek is still near where the song would have been without it.
                guard let before, abs(position - (before + Date().timeIntervalSince(asked) * rate)) < 1.5 else {
                    log(String(format: "seek: the song is at %.1f s, neither where it was nor where it was sent", position), .notice)
                    return done?(false) ?? ()
                }
                if Self.forcedSeekPath == nil, let next = path.next(for: id) {
                    log("seek: \(id) left the song where it was after the \(path.name), trying the \(next.name)")
                    return movePlayer(now, to: target, path: next, done: done)
                }
                unseekable.insert(id)
                log("seek: \(id) left the song where it was", .notice)
                syncSeekable()
                done?(false)
            }
            seekCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 2.5 : 1.5), execute: work)
        }
        if Self.ignoredSeekPaths.contains(path), path != .script {
            log("seek: nothing sent through the \(path.name), for the test", .debug)
            return check(asked)
        }
        switch path {
        case .elapsed:
            nowPlaying.seek(to: target)
            check(asked)
        case .command:
            guard let pid = track.pid else {
                log("seek: Now Playing gives no process for \(id)", .notice)
                return path.next(for: id).map { movePlayer(track, to: target, path: $0, done: done) } ?? (done?(false) ?? ())
            }
            nowPlaying.seek(to: target, pid: pid)
            check(asked)
        case .script:
            log("seek: asking \(id) through AppleScript")
            PlayerScript.seek(id, to: target) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .sent:
                    check(Date())
                case .refused:
                    log("seek: Automation for \(id) isn't allowed", .error)
                    unseekable.insert(id)
                    syncSeekable()
                    done?(false)
                case let .failed(reason):
                    log("seek: \(reason)", .error)
                    unseekable.insert(id)
                    syncSeekable()
                    done?(false)
                }
            }
        }
    }

    /// The keys that change the key: Delete, the arrows and the letters, with Shift for a sharp or a flat and Option
    /// for the other mode. The key row and karaoke take them.
    private func handlePitchKey(_ code: Int, shift: Bool, option: Bool) -> Bool {
        // The card's ring only shows outside karaoke, which has the key row.
        let ring = model.card && !model.lyricsFocus
        switch code {
        case kVK_Delete: change(to: 0, relative: false)
        // The row steps a semitone, and the single card steps around its ring of keys, clockwise for →.
        case kVK_LeftArrow: change(to: ring ? FifthsRing.step(from: model.shift, by: -1) : model.shift - 1)
        case kVK_RightArrow: change(to: ring ? FifthsRing.step(from: model.shift, by: 1) : model.shift + 1)
        // An octave either way, as long as it stays within an octave of the original.
        case kVK_DownArrow where model.shift - 12 >= Shift.range.lowerBound: change(to: model.shift - 12)
        case kVK_UpArrow where model.shift + 12 <= Shift.range.upperBound: change(to: model.shift + 12)
        case kVK_DownArrow, kVK_UpArrow: break
        default:
            guard let letter = Self.letters[code], model.key != nil else { return false }
            // Holding a letter picks the key in the other mode, as Option does, in place of the key that the press picked.
            // A press keeps the mode that the keys are named in, so the hold finds the same mode as the press did.
            if holdable, !option {
                pressOrHold(code, press: { pickLetter(letter, shift: shift, option: false) },
                            hold: { [weak self] in self?.pickLetter(letter, shift: shift, option: true) })
            } else {
                pickLetter(letter, shift: shift, option: option)
            }
        }
        return true
    }

    /// A letter picks a key in the mode that the row shows, which is the other mode after a key was picked in it, and
    /// Option picks one in the mode that it hides. A letter with no sharp or flat key in that mode does nothing with
    /// Shift.
    private func pickLetter(_ letter: Character, shift: Bool, option: Bool) {
        guard let key = model.key else { return }
        let other = option != model.relative
        let minor = other ? !key.minor : key.minor
        guard let pitchClass = DetectedKey.pitchClass(letter: letter, accidental: shift, minor: minor) else { return }
        change(to: key.shift(to: DetectedKey(pitchClass: pitchClass, minor: minor)), relative: other)
    }

    /// A key pressed over a result or a listen opens the picker first, so the HUD stays up with the change.
    /// `relative` names the keys in the other mode, and nil keeps the mode that they are named in.
    private func change(to semitones: Int, relative: Bool? = nil) {
        guard model.pending == nil else { return }
        if !model.picking { pickKey() }
        setShift(semitones, relative: relative)
    }

    /// Lock Key in the HUD, the K key and the menu: the key that is heard now is the one every next song gets.
    private func toggleKeep() {
        if !model.picking, state != .idle { pickKey() }
        if keptKey == nil {
            let base = state == .idle ? shiftBase : model.key ?? shiftBase
            guard let base else { return log("no key to lock yet") }
            keptKey = model.shown(base.transposed(by: model.shift))
            log("keeping \(keptKey!.name) for the next songs")
        } else {
            keptKey = nil
            follow = nil
            model.pending = nil
            log("not keeping a key for the next songs")
            if !pitchWanted, !model.picking, pitch.running { pitch.stopSmoothly { [self] in logShift() } }
        }
    }

    /// The corner button and the S key: the single card or the wide layout, remembered for the next launch.
    private func toggleLayout() { setLayout(card: !model.card) }

    /// Keys 1 to 7 for the stems in the order that the HUD shows them (7 with the winds model).
    private static let stemKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7]

    /// Keys 1 to 7 mute a stem or play it again, held or with Option they play only that stem, pressed twice they set
    /// it back to playing at 100%, and 0 plays every stem. V fades the vocals out or back in, in every layout.
    private func handleStemKey(_ code: Int, option: Bool) -> Bool {
        guard model.stemsAvailable else { return false }
        if code == kVK_ANSI_0 {
            playAllStems()
        } else if code == kVK_ANSI_V, !option {
            toggleVocals()
        } else if let index = Self.stemKeys.firstIndex(of: code), index < Stem.shown.count {
            let stem = Stem.shown[index]
            if option {
                toggleStem(stem, solo: true)
            } else if holdable {
                // A press fades a stem out over as long as V fades the vocals, so a hold that plays the stem alone
                // catches it halfway down instead of after a gap.
                let muted = model.stemsMuted
                pressOrHold(code, press: { pressStem(stem, fade: true) }, hold: { [weak self] in
                    self?.lastStemPress = nil
                    self?.soloStem(stem, from: muted)
                })
            } else {
                pressStem(stem)
            }
        } else {
            return false
        }
        return true
    }

    /// The last press of a stem's number key, or click on its circle, for a second one that sets the stem back.
    private var lastStemPress: (stem: Stem, at: Date)?

    /// A press of a stem's number key or a click on its circle mutes it or plays it again. A second one within the
    /// double-click interval of macOS plays it at 100%, as a double tap does on the phone.
    private func pressStem(_ stem: Stem, fade: Bool = false) {
        if let last = lastStemPress, last.stem == stem, Date().timeIntervalSince(last.at) < NSEvent.doubleClickInterval {
            lastStemPress = nil
            return resetStem(stem)
        }
        lastStemPress = (stem, Date())
        var muted = model.stemsMuted
        if muted.contains(stem) { muted.remove(stem) } else { muted.insert(stem) }
        setStems(muted, fade: fade && muted.contains(stem))
    }

    /// The stem plays alone, or every stem plays again when it already played alone before the press of its key.
    private func soloStem(_ stem: Stem, from muted: Set<Stem>) {
        let others = Set(Stem.allCases).subtracting([stem])
        setStems(muted == others ? [] : others)
    }

    /// A stem plays again at 100%, and the others stay as they are.
    private func resetStem(_ stem: Stem) {
        log("\(stem.name) plays at 100%")
        if model.stemVolumes[stem] != nil { setStemVolume(stem, 1) }
        setStems(model.stemsMuted.subtracting([stem]))
    }

    /// Option on a stem that already plays alone brings every stem back.
    private func toggleStem(_ stem: Stem, solo: Bool) {
        var muted = model.stemsMuted
        if solo {
            let others = Set(Stem.allCases).subtracting([stem])
            muted = muted == others ? [] : others
        } else if muted.contains(stem) {
            muted.remove(stem)
        } else {
            muted.insert(stem)
        }
        setStems(muted)
    }

    /// Play all, 0 and the menu: every stem plays again, at the volume of the others.
    private func playAllStems() {
        if !model.stemVolumes.isEmpty {
            model.stemVolumes = [:]
            pitch.stemVolumes = [:]
            log("every stem at its own volume")
        }
        if model.stemsMuted.isEmpty {
            engageStems(model.shown && model.stemsEngaged)
            refreshStatus()
        } else {
            setStems([])
        }
    }

    /// A scroll over a stem sets its volume. Like a mute, it plays the stems in place of the song, and picks the key
    /// so that the HUD stays up with the change.
    private func setStemVolume(_ stem: Stem, _ volume: Double) {
        guard model.stemsAvailable else { return }
        if !model.picking, model.shown { pickKey() }
        model.stemsFailed = false
        let adjusted = model.stemsAdjusted
        model.stemVolumes[stem] = volume == 1 ? nil : volume
        pitch.stemVolumes = model.stemVolumes
        engageStems(model.stemsAdjusted || (model.shown && model.stemsEngaged))
        // A scroll changes the volume a percent at a time, and the menu bar only shows whether any instrument is
        // changed, so the menu and the chords are left alone until that changes.
        if adjusted != model.stemsAdjusted {
            refreshStatus()
        } else {
            syncSavable()
            syncPauseStop()
        }
        if pitchWanted, !pitch.running { startPitch() }
    }

    /// The stems that last played apart, for Retry after a failure.
    private var lastMutedStems: Set<Stem> = []

    /// Plays every stem but the muted ones. The pitch change runs while any stem is muted, so the HUD opens the picker
    /// and keeps up with the change, the way it does for a key. With every stem playing again, the stems keep playing
    /// while the HUD shows them, so muting another one is instant; the song as it plays comes back when the HUD closes.
    /// `fade` for the vocals of karaoke and of V, which fade out and back in; keys and clicks mute a stem at once.
    private func setStems(_ muted: Set<Stem>, fade: Bool = false) {
        guard model.stemsAvailable || muted.isEmpty, muted != model.stemsMuted else { return }
        if !muted.isEmpty, !model.picking, model.shown { pickKey() }
        model.stemsFailed = false
        model.stemsMuted = muted
        if !muted.isEmpty { lastMutedStems = muted }
        pitch.stemsFade = fade ? 0.45 : 0.02
        pitch.mutedStems = muted
        engageStems(model.stemsAdjusted || (model.shown && model.stemsEngaged))
        log(muted.isEmpty ? "playing every stem" : "playing only \(Stem.shown.filter { !muted.contains($0) }.map(\.name).joined(separator: ", "))")
        refreshStatus()
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// Starts or ends the separation, and the pitch change with it when nothing else needs it.
    private func engageStems(_ engaged: Bool) {
        guard engaged != model.stemsEngaged || engaged != pitch.stemsEngaged else { return }
        model.stemsEngaged = engaged
        pitch.stemsEngaged = engaged
        syncStemsCache()
        if !engaged {
            model.stemsProgress = nil
            model.karaokeCountdown = nil
            endKaraokeRestart()
        }
        updateWatching(shown: model.shown)
        updateStemMeters(shown: model.shown)
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// The stems from the cache, for the song that Muskey Player plays, once the whole song was separated: they play at
    /// the moment that plays, so a seek or karaoke's start over is instant. The whole song is separated in the
    /// background the first time that its stems are used, while the stems are separated as it plays.
    private var cachedStems: Bool { playsInFilePlayer && pitch.instantSeeks }

    /// Muskey Player moved its song, for Muskey's seek or Control Center's scrubber, or Previous that starts it over.
    /// Now Playing reports some of these seconds later, so the stems from the cache learn of the move from the player,
    /// and wait for the new place when nobody asked them.
    private func playerMoved(to seconds: Double) {
        if Self.logKeys { log(String(format: "Muskey Player moved to %.2f s", seconds), .debug) }
        nowPlaying.moved(to: seconds, bundleID: FilePlayer.bundleID)
        guard playsInFilePlayer, let feed = pitch.stemsFeed else { return }
        feed.moved(to: seconds)
        // A move during the pause is known from here, before Now Playing reports it.
        if let song = pausedAt?.0 { pausedAt = (song, seconds) }
        if model.stemsEngaged, cachedStems, !feed.asked(seconds) {
            log(String(format: "Muskey Player moved the song to %.1f s", seconds))
            pitch.cachedSeek(to: seconds)
        }
    }

    private func syncStemsCache() {
        let path = playsInFilePlayer ? filePlayer.current?.path : nil
        if path != stemsCacheLooked {
            stemsCacheLooked = path
            let cache = path.flatMap { StemsCache.open(for: $0) }
            if pitch.stemsFeed?.path != path || (pitch.stemsFeed == nil) != (cache == nil) {
                pitch.stemsFeed = path.flatMap { path in cache.map { StemsFeed(cache: $0, path: path, speed: filePlayer.speed) } }
                if pitch.stemsFeed != nil { log("stems: the whole song is in the cache") }
            }
        }
        if let feed = pitch.stemsFeed, let player = nowPlaying.player {
            feed.speed = filePlayer.speed
            feed.report(elapsed: player.elapsed, timestamp: player.timestamp, rate: player.rate)
        }
        // Another song stops the separation of the last one.
        if let building = stemsCache.path, building != path, building != notesStemsPath { stemsCache.cancel() }
        if let path, pitch.stemsFeed == nil, model.stemsEngaged, !stemsCacheFailed.contains(path) { stemsCache.start(path) }
        syncSeekable()
    }

    // MARK: Region loop

    /// Moves the song back to the start of the loop for players other than Muskey Player, which loops by itself.
    private var loopTimer: Timer?
    /// The song that the loop belongs to: another song clears it.
    private var loopSong: [String?]?
    private var loopSnap: Task<Void, Never>?
    /// A time of the loop is typed in, so the keys over the HUD go to the field.
    private var loopTyping = false
    /// The tempo that the beat grid found around the start of the loop, for rounding its length when the song's
    /// tempo isn't known.
    private var loopGridBPM: Double?

    /// R starts the region loop where the song is, ends it, then clears it. With the lyrics showing, the loop takes
    /// whole lines: from the start of the line sung now to the end of the line sung at the second press. ⌥R sets an
    /// end exactly where it is pressed.
    /// `behind` is how much later than the Mac the press was heard, on a phone that plays the Mac's sound.
    private func pressLoop(snapping: Bool, behind: Double = 0) {
        guard let track = nowPlaying.track, track.title?.isEmpty == false, let duration = track.duration, duration > 0,
              let played = track.position(at: Date()) else { return log("region loop: the player gives no position for the song") }
        let now = max(0, played - behind)
        guard model.seekable else { return log("region loop: the song can't move at once now") }
        let lines = loopLines
        if let loop = model.loop, loop.end != nil {
            return clearLoop()
        } else if let loop = model.loop {
            var end = max(now, loop.start + 0.25)
            if let lines, let line = model.lyricLine, lines.indices.contains(line) {
                end = line + 1 < lines.count ? lines[line + 1].time : duration
                end = max(end, loop.start + 0.25)
            }
            model.loop?.end = end
            model.loop?.endPress = now
            log(String(format: "region loop ends at %.2f s", end))
            if snapping, lines == nil, let score = loopNotes { snapToNotes(.end, at: end, in: score) }
            else if snapping, lines == nil { snap(.end, at: end) } else { applyLoop() }
        } else {
            // A loop started on a paused song would end a quarter of a second later, at the next R.
            guard playGuess?.playing ?? track.playing else { return log("region loop: the song is paused, so R starts no loop") }
            var start = now
            if let lines, let line = model.lyricLine, lines.indices.contains(line) { start = lines[line].time }
            model.loop = LoopRegion(start: start, end: nil, startPress: now)
            loopSong = track.song
            log(String(format: "region loop starts at %.2f s", start))
            if snapping, lines == nil, let score = loopNotes { snapToNotes(.start, at: start, in: score) }
            else if snapping, lines == nil { snap(.start, at: start) }
        }
        forgetLoopPresses()
    }

    /// ⇧R loops the whole song with a region loop from its start to its end, and clears that loop. It takes the place of
    /// a region loop that is set.
    private func toggleSongLoop() {
        guard let track = nowPlaying.track, track.title?.isEmpty == false, let duration = track.duration, duration > 0 else {
            return log("region loop: the player gives no length for the song")
        }
        guard model.seekable else { return log("region loop: the song can't move at once now") }
        if model.loop?.coversSong(duration) == true { return clearLoop() }
        loopSnap?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { model.loop = LoopRegion(start: 0, end: duration) }
        loopSong = track.song
        log(String(format: "region loop: the whole song, %.2f s", duration))
        applyLoop()
    }

    /// The notes of the song in the notes window, once they are done: R then snaps the ends of the loop to them instead of
    /// to the attacks in the audio.
    private var loopNotes: Score? {
        guard let notes = notesWindow.model, notes.done, notes.now() != nil else { return nil }
        return notes.fullScore
    }

    /// Moves an end of the loop to the notes: the start to the nearest note within half a beat, the end to the next note
    /// within a beat, or to the nearest sixteenth when no note is that close. Then the loop widens to cover any note that
    /// it would cut.
    private func snapToNotes(_ end: LoopEnd, at time: Double, in score: Score) {
        guard var loop = model.loop else { return }
        loopSnap?.cancel()
        let position = Score.position(of: time, in: score.beats)
        let onsets = score.onsets
        let sixteenth = (position * 4).rounded() / 4
        switch end {
        case .start:
            let onset = onsets.min { abs($0 - position) < abs($1 - position) }.flatMap { abs($0 - position) <= 0.5 ? $0 : nil } ?? sixteenth
            let start = score.encompassing(from: onset, to: onset).start
            loop.start = loop.end.map { min(score.time(at: start), $0 - 0.25) } ?? score.time(at: start)
        case .end:
            let from = Score.position(of: loop.start, in: score.beats)
            let onset = onsets.first { $0 >= position - 0.125 && $0 <= position + 1 && $0 > from } ?? max(sixteenth, from + 0.25)
            let widened = score.encompassing(from: from, to: onset)
            loop.start = score.time(at: widened.start)
            loop.end = max(score.time(at: widened.end), loop.start + 0.25)
        }
        log(String(format: "region loop: %@ snapped to the notes from %.2f s to %.2f s", end == .start ? "start" : "end",
                   time, end == .start ? loop.start : loop.end ?? 0))
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(duration: 0.32, bounce: 0.35)) { model.loop = loop }
        applyLoop()
    }

    /// The timed lines of the lyrics, while they show in place of the key row or as karaoke.
    private var loopLines: [Lyrics.Line]? {
        guard model.lyricsShown, case let .found(lyrics) = model.lyrics, lyrics.timing != .estimated, !lyrics.lines.isEmpty else { return nil }
        return lyrics.lines
    }

    /// Moves an end of the loop to the attack or the beat next to where it was pressed, once the audio around the press
    /// is known: a file is read around it, and a song from another player needs the 0.15 seconds after the press first.
    private func snap(_ end: LoopEnd, at time: Double) {
        let path = playsInFilePlayer ? filePlayer.current?.path : nil
        let recorder = waveformRecorder
        let bpm = model.shownTempo?.bpm
        let startBPM = loopGridBPM
        let song = loopSong
        loopSnap?.cancel()
        loopSnap = Task { @MainActor [weak self] in
            var excerpt: (samples: [Float], start: Double)?
            if let path {
                let from = max(0, time - 8)
                excerpt = (await LoopSnap.excerpt(URL(fileURLWithPath: path), from: from, to: time + 1.5), from)
            } else {
                try? await Task.sleep(for: .milliseconds(300))
                excerpt = recorder?.excerpt(from: time - 10, to: time + 0.3)
            }
            guard let excerpt, !excerpt.samples.isEmpty, !Task.isCancelled else {
                self?.log("region loop: no audio around the press, the end stays where it was pressed")
                self?.applyLoop()
                return
            }
            let grid = await Task.detached(priority: .userInitiated) { LoopSnap.grid(excerpt.samples, start: excerpt.start) }.value
            guard let self, !Task.isCancelled, loopSong == song, var loop = model.loop else { return }
            if end == .start { loopGridBPM = grid.bpm }
            let snapped = end == .start ? LoopSnap.snap(time, grid: grid) : LoopSnap.snapEnd(time, start: loop.start, grid: grid, bpm: bpm, startBPM: startBPM)
            switch end {
            case .start: loop.start = loop.end.map { min(snapped, $0 - 0.25) } ?? snapped
            case .end: loop.end = max(snapped, loop.start + 0.25)
            }
            log(String(format: "region loop: %@ snapped from %.2f s to %.2f s (%d beats, %d attacks, %.0f BPM)", end == .start ? "start" : "end",
                       time, end == .start ? loop.start : loop.end ?? 0, grid.beats.count, grid.onsets.count, grid.bpm ?? 0))
            // The end slides to its snapped place with a small overshoot, which shows the snap without slowing anything.
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(duration: 0.32, bounce: 0.35)) { self.model.loop = loop }
            applyLoop()
        }
    }

    /// The dashed lines at the presses fade a moment after each press.
    private func forgetLoopPresses() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, model.loop != nil else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                self.model.loop?.startPress = nil
                self.model.loop?.endPress = nil
            }
        }
    }

    /// An end moved by its arrows, a drag or a typed time.
    private func setLoopEnd(_ end: LoopEnd, _ seconds: Double) {
        guard var loop = model.loop else { return }
        switch end {
        case .start: loop.start = max(0, seconds)
        case .end: loop.end = seconds
        }
        model.loop = loop
        model.wave.endMovedUnder = NSEvent.mouseLocation
        log(String(format: "region loop %@ set to %.2f s", end == .start ? "start" : "end", seconds))
        applyLoop()
    }

    /// ← or → over the tab of an end, which moves it as a click on its arrow does.
    private func nudgeLoopEnd(_ end: LoopEnd, by direction: Double, beat: Bool) {
        guard let loop = model.loop, let time = loop.time(of: end) else { return }
        let step = beat ? model.shownTempo.map { 60 / $0.bpm } ?? 0.5 : LoopRegion.nudge
        setLoopEnd(end, loop.clamped(end, time + direction * step, duration: nowPlaying.track?.duration ?? .infinity))
    }

    /// Repeats the part from the start to the end of the loop: Muskey Player at the exact end, other players with a
    /// seek once the song reaches the end, which lands within a few hundredths of a second.
    private func applyLoop() {
        loopTimer?.invalidate()
        loopTimer = nil
        guard let loop = model.loop, let end = loop.end else {
            if filePlayer.hasSong { filePlayer.loop(nil) }
            return
        }
        if playsInFilePlayer {
            filePlayer.loop((loop.start, end))
            // A song that already played past the end goes back at once.
            if let now = nowPlaying.track?.position(at: Date()), now > end || now < loop.start - 0.5 { seek(to: loop.start, flash: "repeat") }
            return
        }
        // The common modes keep it firing while the pointer drags an end of the loop.
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.checkLoopEnd() }
        RunLoop.main.add(timer, forMode: .common)
        loopTimer = timer
    }

    private func checkLoopEnd() {
        // A region that is recorded for a save plays through to its end, where the recording stops, and goes back after.
        // A paused song, or one more than a second from the end of the loop, is looked at four times a second instead of
        // fifty.
        let later = { [weak self] in self?.loopTimer?.fireDate = Date().addingTimeInterval(0.25) }
        guard songRecording == nil, let loop = model.loop, let end = loop.end, let track = nowPlaying.track, track.playing, model.seekable,
              let now = track.position(at: Date()) else { return later() ?? () }
        // A seek that the player hasn't reported yet.
        if let target = seekTarget, Date().timeIntervalSince(target.at) < 1 { return }
        // A loop of the whole song goes back a little before the end, before the player moves on to the next song.
        let lead = loop.coversSong(track.duration) ? 0.4 : 0.03
        guard now >= end - lead, now < end + 3 else {
            if now < end - lead - 1 || now >= end + 3 { later() }
            return
        }
        seekTarget = (track.song, loop.start, Date())
        moveSong(track, to: loop.start)
    }

    private func clearLoop() {
        guard model.loop != nil else { return }
        loopSnap?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { model.loop = nil }
        model.wave.clearEnd()
        loopSong = nil
        applyLoop()
        log("region loop cleared")
    }

    /// Another song clears the loop of the last one.
    private func checkLoopSong() {
        guard model.loop != nil, let song = nowPlaying.track?.song, nowPlaying.track?.title?.isEmpty == false, song != loopSong else { return }
        if let loopSong, NowPlaying.Track.sameSong(song, loopSong) { return self.loopSong = song }
        log("region loop: the song changed from \(loopSong.map { $0.map { $0 ?? "–" }.joined(separator: " | ") } ?? "none") to \(song.map { $0 ?? "–" }.joined(separator: " | "))")
        clearLoop()
    }

    /// The keys over the HUD stay off while a loop time is typed, so digits and letters reach the field.
    private func loopTyping(_ typing: Bool) {
        loopTyping = typing
        if typing {
            panel.setInteraction(clickable: true, keyboard: true)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        } else if !pointerOverWaveform, focusReturn != nil {
            giveFrontBack()
        }
        updateHoverKeys()
    }

    // MARK: Waveform

    /// Draws the waveform of a song from another player from what Muskey hears, while the HUD shows.
    private var waveformRecorder: WaveformRecorder?
    /// The cache key of the waveform that the HUD has, so the same song isn't read twice.
    private var waveformKey: String?
    private var waveformRead: Task<Void, Never>?
    /// Copies what the recorder drew into the HUD four times a second.
    private var waveformTimer: Timer?
    /// `--waveform-file FILE` prints the waveform that Muskey reads from a file, for testing.
    static let waveformTest = TestFlags.value("--waveform-file")

    /// The waveform of the song that plays: a file's is read whole, and another player's comes from the cache and
    /// from what Muskey hears while the HUD shows, until the whole song was heard.
    private func syncWaveform() {
        // A song from another app is heard while the HUD shows even with the waveform hidden, since T transcribes it
        // from what was heard.
        guard model.waveformShown || !playsInFilePlayer, let track = nowPlaying.track, track.title?.isEmpty == false, let duration = track.duration, duration > 0 else {
            stopWaveformRecorder()
            if !model.waveformShown || nowPlaying.track?.title?.isEmpty != false {
                waveformKey = nil
                if model.wave.waveform != nil { model.wave.waveform = nil }
            }
            return
        }
        if playsInFilePlayer, let path = filePlayer.current?.path {
            stopWaveformRecorder()
            guard let key = WaveformStore.key(file: path), key != waveformKey else { return }
            waveformKey = key
            model.wave.waveform = nil
            model.wave.lanes = false
            waveformRead?.cancel()
            waveformRead = Task { @MainActor [weak self] in
                var waveform = WaveformStore.load(key)
                if waveform == nil {
                    waveform = await WaveformReader.read(URL(fileURLWithPath: path))
                    if let waveform { WaveformStore.save(waveform, as: key) }
                }
                guard !Task.isCancelled, let self, waveformKey == key else { return }
                model.wave.waveform = waveform
                log(waveform == nil ? "waveform: the file can't be read" : "waveform: read the whole file", waveform == nil ? .error : .info)
                syncWaveformStems()
            }
            return
        }
        let key = WaveformStore.key(song: track.song, duration: duration)
        if key != waveformKey {
            stopWaveformRecorder()
            waveformRead?.cancel()
            waveformKey = key
            let waveform = WaveformStore.load(key) ?? SongWaveform(duration: duration)
            model.wave.waveform = waveform
            model.wave.lanes = false
            waveformRecorder = WaveformRecorder(song: track.song, key: key, waveform: waveform)
        }
        guard let recorder = waveformRecorder else { return }
        if let player = nowPlaying.player { recorder.report(player) }
        // A hidden HUD shows no waveform. A song heard whole is still heard while the HUD shows, for the ends of the
        // region loop, which snap to the audio around them. A song that plays to its end for its notes is heard with
        // the HUD hidden too.
        let wanted = model.shown || liveCapture?.recorder === recorder
        if wanted, !recorder.running {
            do {
                try recorder.start(SystemAudioTap())
                log("waveform: drawing the song while it plays")
            } catch {
                log("waveform: the tap failed: \(error)", .error)
            }
            waveformTimer?.invalidate()
            waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.publishRecordedWaveform() }
        } else if !wanted, recorder.running {
            stopWaveformRecorder(keep: true)
        }
    }

    private func publishRecordedWaveform() {
        guard let recorder = waveformRecorder, recorder.key == waveformKey else { return }
        let (waveform, changed) = recorder.take()
        if changed, model.waveformShown { model.wave.waveform = waveform }
        // The picker of T shows how much of a song from another app was heard, which grows while it plays.
        if model.notesPicking?.heard != nil {
            let heard = recorder.capturedSeconds
            if abs((model.notesPicking?.heard ?? 0) - heard) >= 1 { model.notesPicking?.heard = heard }
        }
    }

    /// Stops drawing from what Muskey hears and keeps what was drawn on disk. `keep` leaves the recorder for the same
    /// song, which goes on drawing once the HUD shows again.
    private func stopWaveformRecorder(keep: Bool = false) {
        waveformTimer?.invalidate()
        waveformTimer = nil
        guard let recorder = waveformRecorder else { return }
        recorder.stop()
        let (waveform, _) = recorder.take()
        if waveform.heard > 0 { WaveformStore.save(waveform, as: recorder.key) }
        if !keep { waveformRecorder = nil }
    }

    /// The lanes of the stems, from the stems of the whole song once they are in the cache.
    private func syncWaveformStems() {
        guard playsInFilePlayer, let path = filePlayer.current?.path, let key = waveformKey, let waveform = model.wave.waveform, waveform.stems == nil,
              let cache = StemsCache.open(for: path) else { return }
        let base = waveform
        Task { @MainActor [weak self] in
            let stems = await Task.detached(priority: .utility) { WaveformReader.stems(cache) }.value
            guard let self, waveformKey == key else { return }
            var waveform = model.wave.waveform ?? base
            waveform.stems = stems
            // In one animation with the glass, which grows with the lanes that this brings.
            withAnimation(Self.glassResize) { self.model.wave.waveform = waveform }
            WaveformStore.save(waveform, as: key)
            log("waveform: lanes for the stems")
        }
    }

    /// W shows or hides the waveform, and remembers it.
    private func toggleWaveform() {
        withAnimation(Self.glassResize) { prefs.waveform.toggle() }
        log("waveform \(prefs.waveform ? "on" : "off")")
    }

    /// Holding W shows the waveform again after the press hid it, and turns the lanes of the stems on or off, or only on
    /// when the waveform was hidden before the press.
    private func holdWaveform(shown: Bool) {
        if !prefs.waveform { toggleWaveform() }
        if !shown, model.wave.lanes { return }
        toggleWaveformLanes()
    }

    /// A change that makes the glass taller or shorter, done in one animation with the glass. The views that animate it
    /// on their own leave the glass to jump to its new size while they move, which shook the HUD.
    static let glassResize = Animation.snappy(duration: 0.25)

    /// ⌥W: one lane per stem, or the whole song again. A song without stems is separated first: a song in Muskey
    /// Player quietly as a whole, with the lanes once it is done, and a song from another app as it plays, with
    /// lanes that fill in from what its stems play.
    private func toggleWaveformLanes() {
        guard model.waveformStyle == .ribbon else { return log("waveform: lanes only in the ribbon style") }
        if lanesAvailable || model.wave.lanes {
            withAnimation(Self.glassResize) { model.wave.lanes.toggle() }
            if !model.wave.lanes { stopLanesSeparation() }
            return log("waveform: lanes \(model.wave.lanes ? "on" : "off")")
        }
        guard model.stemsAvailable, model.track?.title?.isEmpty == false else {
            return log("waveform: no lanes without the common instruments model")
        }
        model.wave.lanes = true
        if playsInFilePlayer, let path = filePlayer.current?.path {
            if StemsCache.open(for: path) != nil { return syncWaveformStems() }
            if stemsCacheFailed.contains(path) {
                model.wave.lanes = false
                return log("waveform: no lanes, the separation of this song failed")
            }
            if stemsCache.path != path { stemsCache.start(path) }
            log("waveform: separating the whole song for the lanes")
            watchLanesSeparation(path)
        } else {
            log("waveform: separating the stems for the lanes")
            if !model.stemsEngaged { separate() }
        }
    }

    /// Shows how much of the song is separated while ⌥W waits for its stems, until the lanes show, the song changes or
    /// ⌥W turns them off.
    private var lanesTimer: Timer?
    private func watchLanesSeparation(_ path: String) {
        lanesTimer?.invalidate()
        model.wave.lanesSeparating = stemsCache.path == path ? stemsCache.fraction : 0
        lanesTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickLanesSeparation(path) }
        }
    }

    private func tickLanesSeparation(_ path: String) {
        guard model.wave.lanes, model.wave.waveform?.stems == nil, filePlayer.current?.path == path else { return stopLanesSeparation() }
        if stemsCacheFailed.contains(path) {
            model.wave.lanes = false
            log("waveform: no lanes, the separation of this song failed")
            return stopLanesSeparation()
        }
        let fraction = stemsCache.path == path ? stemsCache.fraction : 0
        if model.wave.lanesSeparating != fraction { model.wave.lanesSeparating = fraction }
    }

    private func stopLanesSeparation() {
        lanesTimer?.invalidate()
        lanesTimer = nil
        if model.wave.lanesSeparating != nil { model.wave.lanesSeparating = nil }
    }

    /// One waveform per instrument can show: from the stems of the whole song of Muskey Player, or from what the stems
    /// of a song from another app play, which fill in while it plays.
    private var lanesAvailable: Bool {
        model.wave.waveform?.stems != nil || (liveRecorder != nil && model.stemsEngaged && !cachedStems)
    }

    /// The waveform of the HUD can zoom: it shows as a ribbon, with the song's waveform read.
    private var waveformPinchable: Bool { model.waveformShown && model.waveformStyle == .ribbon && model.wave.waveform != nil }

    /// Zooms the waveform by `factor`, from the whole song to a close-up of a few seconds. A factor of 0 shows the
    /// whole song.
    private func zoomWaveform(_ factor: Double) {
        guard waveformPinchable else { return }
        let before = model.wave.zoom
        withAnimation(.snappy(duration: 0.2)) { model.wave.zoom(by: factor) }
        if Self.logKeys, before != model.wave.zoom { log(String(format: "waveform zoom %.1f", model.wave.zoom), .debug) }
    }

    /// The pointer of `event` is over the list of the queue, while it shows.
    private func overQueue(_ event: NSEvent) -> Bool {
        guard model.backShown, let frame = model.queueFrame, let view = panel.contentView else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        return frame.contains(CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y))
    }

    /// The pointer of `event` is over the waveform.
    private func overWaveform(_ event: NSEvent) -> Bool {
        overWaveform(inWindow: event.locationInWindow)
    }

    /// A point on the screen is over the waveform of the HUD, or `above` points above it, where the tabs of the region
    /// loop stand.
    private func overWaveform(screen point: NSPoint, above: CGFloat = 0) -> Bool {
        guard panel.isVisible, panel.frame.contains(point) else { return false }
        return overWaveform(inWindow: panel.convertPoint(fromScreen: point), above: above)
    }

    private func overWaveform(inWindow point: NSPoint, above: CGFloat = 0) -> Bool {
        guard let view = panel.contentView else { return false }
        let local = view.convert(point, from: nil)
        let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
        return model.scroll.frames.values.contains {
            $0.region == .waveform && CGRect(x: $0.frame.minX, y: $0.frame.minY - above, width: $0.frame.width, height: $0.frame.height + above).contains(point)
        }
    }

    /// A pinch with the pointer over the waveform zooms it. Returns true when the waveform zoomed.
    private func pinch(_ event: NSEvent) -> Bool {
        let over = model.shown && overWaveform(screen: NSEvent.mouseLocation)
        if event.phase == .began { log("pinch began " + (over ? "over the waveform" : "away from the waveform"), .debug) }
        guard over else { return false }
        zoomWaveform(1 + Double(event.magnification))
        return true
    }

    /// The Separate instruments and vocals button: separates the song with every stem playing, and shows the stems in
    /// place of the button. Like the keys, it pins the HUD open.
    private func separate() {
        guard model.stemsAvailable, !model.stemsEngaged else { return }
        if !model.picking, model.shown { pickKey() }
        model.stemsFailed = false
        lastMutedStems = model.stemsMuted
        engageStems(true)
        log("separating, with every stem playing")
        refreshStatus()
    }

    private func retryStems() {
        model.stemsFailed = false
        if lastMutedStems.isEmpty { separate() } else { setStems(lastMutedStems) }
    }

    /// The model couldn't load or run. Every stem plays again, and the pill on the stems row offers Retry.
    private func stemsFailed(_ reason: String) {
        log("stems failed: \(reason)", .error)
        model.stemsMuted = []
        model.stemVolumes = [:]
        pitch.stemVolumes = [:]
        model.stemsFailed = true
        engageStems(false)
        refreshStatus()
    }

    private var stemModelRelease: DispatchWorkItem?

    /// The model warms up once the pointer is on the HUD or the picker opens, so a chip pressed a moment later doesn't
    /// wait 3 seconds for Core ML. A HUD that only shows a key loads nothing.
    private func warmUpStems() {
        // A song whose stems are all in the cache plays them from there, so the model stays out of memory.
        guard model.stemsAvailable, pitch.stemsFeed == nil, model.hovering || model.picking else { return }
        StemModel.warmUp()
    }

    /// Fifteen minutes after the HUD closed with every stem playing, the model is freed. Each load makes Core ML
    /// compile the model for the GPU again and write hundreds of megabytes to disk, so a HUD that opens every few
    /// minutes keeps it.
    private func prepareStemModel(shown: Bool) {
        stemModelRelease?.cancel()
        stemModelRelease = nil
        if shown {
            model.stemsAvailable = StemModel.installed
        } else if !model.stemsAdjusted {
            let release = DispatchWorkItem { [weak self] in
                guard let self, !model.shown, !model.stemsAdjusted else { return }
                StemModel.unload()
            }
            stemModelRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 900, execute: release)
        }
    }

    private var stemMeterClock: Timer?

    private var arrivalClear: DispatchWorkItem?

    /// The stems and the lyrics delay play the song seconds behind it, so a new song is heard that much later than the
    /// player starts it. Its record waits in a loading state until then, while the last song plays out.
    private func songArrives() {
        arrivalClear?.cancel()
        let behind = pitch.stemsOn || lyricsDelayed ? pitch.stemsDelay : 0
        guard behind > 0.5 else {
            if model.songArriving != nil { model.songArriving = nil }
            return
        }
        let now = Date()
        model.songArriving = now ... now.addingTimeInterval(behind)
        log(String(format: "the new song is heard in %.1f s, its record waits until then", behind))
        let clear = DispatchWorkItem { [weak self] in self?.model.songArriving = nil }
        arrivalClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + behind, execute: clear)
    }

    /// The backspins that the output played so far, from the shifter that plays now.
    private var spinsSeen: UInt32 = 0

    /// The records turn back with each new backspin of the output, while the HUD shows them.
    private func checkSpins() {
        let spins = pitch.spins
        guard spins != spinsSeen else { return }
        // A new shifter counts from 0 again.
        if spins > spinsSeen {
            log("the output stepped back in the song" + (fadeToStart ? ", with a fade to the start" : ""))
            model.seekWait = nil
            recordRewound()
            if fadeToStart { fadeToStart = false }
        }
        spinsSeen = spins
    }

    /// Reads the level of each stem 20 times a second, and what the stems wait for, while the HUD or the phone's song
    /// view shows them.
    private func updateStemMeters(shown: Bool) {
        let wanted = (shown || phoneShowsSong) && model.stemsEngaged
        if !wanted {
            stemMeterClock?.invalidate()
            stemMeterClock = nil
            if model.stemsProgress != nil { model.stemsProgress = nil }
            if model.karaokeCountdown != nil { model.karaokeCountdown = nil }
            if model.stemMeters.levels.contains(where: { $0 != 0 }) { model.stemMeters.levels = Array(repeating: 0, count: Stem.allCases.count) }
            return
        }
        guard stemMeterClock == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            // The phone's song view closed while the HUD is hidden.
            if !model.shown, !phoneShowsSong { return updateStemMeters(shown: false) }
            // Stems from the cache take over in a moment, with nothing to wait for.
            var progress = cachedStems ? nil : pitch.stemsWaited.map { waited -> StemsProgress in
                StemModel.prepared ? .separating(min(0.97, waited / Self.stemsWait)) : .loading
            }
            // A paused song sends no sound to separate as it plays, but Muskey Player's whole song is separated in the
            // background all the same, and its stems play from the cache once it is done.
            if case .separating = progress, !model.playing, playsInFilePlayer, let building = stemsCache.path,
               building == filePlayer.current?.path {
                progress = .separating(min(0.99, max(0.01, stemsCache.fraction)))
            }
            // A cache that stopped lining up with the song takes the seek keys away again.
            syncSeekable()
            if model.stemsProgress != progress { model.stemsProgress = progress }
            if karaokeRestart == .waitingForModel, StemModel.prepared { beginKaraokeRestart() }
            let countdown = karaokeCountdown(progress)
            if model.karaokeCountdown != countdown { model.karaokeCountdown = countdown }
            let levels = Stem.allCases.map { self.pitch.stemLevel($0) }
            if model.stemMeters.levels != levels { model.stemMeters.levels = levels }
            // A song from another app gets one waveform per instrument from what its stems play, as its waveform is
            // drawn from what Muskey hears.
            let delay = pitch.stemsDelay
            if progress == nil, !cachedStems, delay > 0, let recorder = liveRecorder, recorder.running {
                recorder.addStems(levels, delay: delay)
            }
            checkSpins()
        }
        RunLoop.main.add(timer, forMode: .common)
        stemMeterClock = timer
    }

    private func setLayout(card: Bool) {
        model.shortcuts = false
        model.card = card
        UserDefaults.standard.set(card ? "card" : "wide", forKey: "layout")
        log("layout \(card ? "card" : "wide")")
    }

    /// Another song started while a key is kept: a listen finds its key and moves it to the kept one. Another song
    /// that starts while the key picker is open gets a listen too, so the HUD shows its key and not the last song's.
    /// Without a kept key, the pitch change runs on at the same shift, and the keys relabel once the new key is known.
    private func songChanged(_ track: NowPlaying.Track) {
        let target = keptKey
        // A HUD that shows gets the new song's key, so it never shows the last song's key over the new song.
        guard target != nil || (model.shown && model.saving == nil && model.phase != .idle) else { return }
        // The song that the HUD already listens to or shows, as when a player reports the song that it just started.
        if target == nil, state != .idle, listenSong == track.song { return }
        redetecting = false
        if !model.shown { stayOpen = false }
        log(target.map { "song changed, moving it to \($0.name)" } ?? "song changed, listening for its key", .notice)
        switch AudioCapturePermission.status {
        case .granted: break
        case .denied: return log("system audio recording is not allowed", .error)
        case .undetermined:
            // Each song change while the dialog is up asks again, so only the song that still plays gets a listen.
            return AudioCapturePermission.request { [self] granted in
                guard granted else { return log("system audio recording was not allowed", .error) }
                if keptKey != nil || model.shown, nowPlaying.track?.song == track.song, state != .listening { songChanged(track) }
            }
        }
        stopCapture()
        analyzer = nil
        session += 1
        state = .listening
        follow = target
        followByPerson = false
        followApplied = false
        model.moved = nil
        model.pending = target
        songChangedAt = Date()
        // The shift of the last song means nothing for this one, so it plays in its own key until the first estimate.
        // The pitch change keeps running at 0, so moving it doesn't start the tap over.
        if target != nil, model.shift != 0 {
            setShift(0, relative: false, byPerson: false)
            log("original key until the new song's key is found")
        }
        listen()
    }

    /// Moves the new song to the kept key on the first estimate, and once more on the final estimate of the listen if
    /// that one needs another shift. A final estimate that only swaps the key for its relative keeps the shift and
    /// renames the keys.
    private func retarget(_ key: DetectedKey, to target: DetectedKey, final: Bool, byPerson: Bool = false) {
        let shift = key.shift(to: target)
        let relative = target.minor != key.minor
        if shift == model.shift, followApplied {
            model.relative = relative
            return refreshStatus()
        }
        followApplied = true
        setShift(shift, relative: relative, byPerson: false)
        if byPerson { return log("kept \(model.heard?.name ?? target.name) after the key turned out to be \(key.name), \(Shift.text(shift))") }
        model.pending = nil
        model.moved = KeyMove(from: key, to: model.heard ?? target)
        log("moved \(key.name) to \(model.heard?.name ?? target.name), \(Shift.text(shift))")
    }

    /// A song change listen that heard nothing keeps the shift that the song plays at.
    private func followFailed(_ reason: String) {
        log(reason, .notice)
        model.pending = nil
        state = .showing
        if model.picking {
            model.phase = .done
        } else {
            dismiss()
        }
    }

    private var hoverKeys: [HoverKey: HotKey] = [:]
    /// ⌘, opens Settings while the pointer is over the HUD, in every state of the HUD, so it lives apart from the
    /// hover keys that come and go with the phase, the picker and the lyrics editor.
    private var settingsKey: HotKey?
    private var optionWatch: Timer?

    private let lyricsFinder = LyricsFinder()
    /// The made-up song of `--lyrics-test` keeps its lyrics apart from the real ones, so one test doesn't reuse the
    /// lyrics that Whisper wrote for another song in an earlier test.
    private let lyricsStore = lyricsTest == nil ? LyricsStore.main : LyricsStore(url: URL(fileURLWithPath: "/tmp/muskey-lyrics-test.json"))
    private lazy var lyricsSync = LyricsSync(store: lyricsStore)
    private var lyricsEditor: LyricsEditorWindowController?
    /// The song that the lyrics in the HUD belong to.
    private var lyricsSong: String?
    private var lyricsClock: Timer?

    /// The L key and the lyrics button: the lyrics in place of the key, or the key again. A HUD that opens starts
    /// on the key.
    private func toggleLyrics() {
        if !model.picking { pickKey() }
        guard model.picking else { return }
        model.shortcuts = false
        model.lyricsShown.toggle()
        if !model.lyricsShown { model.lyricsFocus = false }
        log(model.lyricsShown ? "lyrics shown" : "lyrics hidden")
        if model.lyricsShown {
            loadLyrics()
        } else {
            lyricsSong = nil
            lyricsSync.end()
        }
        updateLyricsClock(shown: model.shown)
        updateHoverKeys()
    }

    /// Lyrics added by hand for the song on the record, or the lyrics services', asked for once per song while the
    /// lyrics show.
    private func loadLyrics(again: Bool = false) {
        guard model.lyricsShown, model.shown else { return }
        guard let track = model.track, let song = LyricsFinder.id(track) else {
            lyricsSong = nil
            lyricsSync.end()
            if model.lyrics != .none { model.lyrics = .none }
            return
        }
        guard again || song != lyricsSong else { return }
        lyricsSong = song
        lyricsSync.end()
        model.lyricLine = nil
        if let text = lyricsStore.text(for: song) {
            let lyrics = Lyrics.parse(lrc: text) ?? Lyrics.estimate(plain: text, duration: track.duration ?? 200)
            return showLyrics(lyrics.map { .found($0) } ?? .notFound, song: song, track: track)
        }
        if let known = lyricsFinder.known(track) { return showLyrics(known, song: song, track: track) }
        model.lyrics = .loading
        lyricsFinder.find(track) { [weak self] state in
            guard let self, lyricsSong == song else { return }
            showLyrics(state, song: song, track: track)
            log("lyrics: \(Self.describe(state))")
        }
    }

    private let network = NWPathMonitor()
    private var online = true

    /// Lyrics that failed because the Mac was offline are looked up again once it is back online, without Retry.
    private func networkChanged(online: Bool) {
        defer { self.online = online }
        guard online, !self.online, model.lyricsShown, model.lyrics == .failed else { return }
        log("lyrics: back online, looking them up again")
        retryLyrics()
    }

    /// `--lyrics-plain` drops the times of synced lyrics, to test the timing by listening on any song, and logs how
    /// far the heard times are from the dropped ones. With `--pick`, the lyrics show from the start.
    private static let lyricsPlain = TestFlags.has("--lyrics-plain")
    private var droppedTimes: [Double]?

    private func showLyrics(_ state: LyricsState, song: String, track: NowPlaying.Track) {
        var state = state
        droppedTimes = nil
        if Self.lyricsPlain, case let .found(lyrics) = state, lyrics.timing == .synced,
           let plain = Lyrics.estimate(plain: lyrics.lines.map(\.text).joined(separator: "\n"), duration: track.duration ?? 200)
        {
            // The estimate drops breaks in a row, so each of its lines takes the time of the next line with its text.
            var next = 0
            droppedTimes = plain.lines.map { line in
                guard let index = lyrics.lines[next...].firstIndex(where: { $0.text == line.text }) else { return -1 }
                next = index + 1
                return lyrics.lines[index].time
            }
            droppedLogged = 0
            state = .found(plain)
        }
        lyricsFit?.cancel()
        lyricsFit = nil
        lyricsFitBusy = false
        lyricsMoved = false
        lyricsFixManual = false
        lyricsOriginal = nil
        model.lyricsTiming = nil
        model.lyricsShift = 0
        model.lyricsTimingKept = false
        let file = lyricsFile, player = lyricsPlayer(track)
        lyricsApp = player
        if case let .found(lyrics) = state, lyrics.timing == .synced, !lyrics.lines.isEmpty, let source = file ?? player {
            // Lyrics with times show moved by the shift that the Fix timing pill left for this file, or for this song
            // in the app that plays it, and the pill shows what a fit found: the offset to apply, or the times right.
            lyricsOriginal = lyrics
            let key = LyricsFit.key(lyrics)
            let shift = lyricsStore.shift(for: song, key: key, file: source)
            if shift != 0 {
                state = .found(lyrics.moved(by: shift))
                lyricsMoved = true
                model.lyricsShift = shift
                model.lyricsTimingKept = true
                log(String(format: "lyrics: their times moved by %+.2f s, kept from an earlier play", shift))
            }
            if let kept = lyricsStore.fit(for: song, key: key, file: source) {
                model.lyricsTimingKept = true
                // A fit kept before the limit for an offset went up reads as right below it.
                model.lyricsTiming = switch kept.offset {
                case let offset? where abs(offset) >= LyricsFit.smallestOffset: .found(offset)
                case .some: .onTime
                case nil: .unknown
                }
            } else if lyricsFitCanRun {
                model.lyricsTiming = .unchecked
                if prefs.timingConditions.hold { fitLyrics(lyrics, song: song, duration: track.duration) }
            } else {
                model.lyricsTiming = .idle
                // A song from another app is checked against its vocals while it plays, once, as Settings allows. The
                // pill stays idle until the check has an answer, since a click has nothing to start here.
                if file == nil, let player { lyricsSync.check(song: song, lyrics: lyrics, player: player, duration: track.duration) }
            }
        }
        if case let .found(lyrics) = state, lyrics.timing == .estimated {
            lyricsSync.begin(song: song, lyrics: lyrics, file: file, player: player, duration: track.duration)
            if !lyricsSync.fitted, prefs.timingConditions.hold { fitLyrics(lyrics, song: song, duration: track.duration) }
        }
        // A song that LRCLIB doesn't have: the lyrics that Whisper wrote in an earlier play, or Whisper writes them now.
        var writing = false
        if state == .notFound {
            let earlier = lyricsStore.written(for: song).flatMap { Lyrics.parse(lrc: $0) }?.lines ?? []
            let covered = lyricsStore.covered(for: song)
            if LyricsCoverage.complete(covered, duration: track.duration) {
                log("lyrics: \(earlier.count) lines written earlier, the whole song was transcribed")
            } else if lyricsSync.transcribe(song: song, written: earlier, covered: covered, duration: track.duration) {
                writing = true
                log(earlier.isEmpty && covered.isEmpty ? "lyrics: writing them by ear"
                    : "lyrics: \(earlier.count) lines written earlier over \(Int(covered.reduce(0) { $0 + $1.upperBound - $1.lowerBound })) seconds, writing the rest by ear")
            }
            if writing || !earlier.isEmpty { state = .found(Lyrics(lines: earlier, timing: .written)) }
        }
        if model.lyricsWriting != writing { model.lyricsWriting = writing }
        model.lyrics = state
        lyricsTimingChanged()
        updateLyricLine()
    }

    /// The fit of the lyrics onto the vocals that is being worked out.
    private var lyricsFit: Task<Void, Never>?
    /// The fit runs off the main thread and can't be stopped halfway, so another one doesn't start meanwhile.
    private var lyricsFitBusy = false
    /// Counts the fits started, so that a fit that ends clears only its own task.
    private var lyricsFitGeneration = 0
    /// The lyrics that show were moved by the offset that a fit found.
    private var lyricsMoved = false
    /// Lyrics with times at their own times, which the Fix timing pill moves and puts back.
    private var lyricsOriginal: Lyrics?
    /// The Fix timing pill was clicked: the fit shows its progress, and the offset it finds moves the lines at once.
    /// A check that started by itself only turns the pill red.
    private var lyricsFixManual = false
    /// The app that plays the song whose lyrics show, as the fits of its songs are kept. Nil for Muskey Player.
    private var lyricsApp: String?
    /// A fit can run for the song: both models are installed and the song plays in Muskey Player.
    private var lyricsFitCanRun: Bool { AlignerModel.installed && StemModel.installed && lyricsFile != nil }
    /// The file that Muskey Player plays, as the name of its stems in the cache. A fit of the lyrics belongs to that
    /// file: the same song in another file or from another player can start seconds earlier or later.
    private var lyricsFile: String? {
        guard playsInFilePlayer, let path = filePlayer.current?.path else { return nil }
        return StemsCache.url(for: path)?.lastPathComponent
    }

    /// The app that plays the song, when it isn't Muskey Player. What a fit finds for a song from another app is kept
    /// for that app: its audio comes as the song plays, and the same song in another app can start a moment earlier
    /// or later.
    private func lyricsPlayer(_ track: NowPlaying.Track) -> String? {
        guard !playsInFilePlayer, let bundle = track.bundleID, bundle != FilePlayer.bundleID else { return nil }
        return "app." + bundle
    }

    /// The stems of the whole song came into the cache while its lyrics show: lyrics with times that nothing checked
    /// yet are checked for an offset now.
    private func fitShownLyrics() {
        guard model.lyricsShown, !lyricsFitBusy, model.lyricsTiming == .unchecked, prefs.timingConditions.hold, let song = lyricsSong, let track = model.track,
              LyricsFinder.id(track) == song, let lyrics = lyricsOriginal else { return }
        fitLyrics(lyrics, song: song, duration: track.duration)
    }

    /// A click on the Fix timing pill: puts shifted lines back at their own times, checks the lyrics when nothing is
    /// known, and applies an offset that was found.
    private func pressLyricsTiming() {
        if model.lyricsShift != 0, model.lyricsTiming != .failed {
            if case .working? = model.lyricsTiming { return }
            return setLyricsShift(0)
        }
        switch model.lyricsTiming {
        case .unchecked?, .failed?:
            guard lyricsFitCanRun, let song = lyricsSong, let track = model.track, let lyrics = lyricsOriginal, let path = filePlayer.current?.path else { return }
            lyricsFixManual = true
            log("lyrics: Fix timing pressed")
            model.lyricsTiming = .working(StemsCache.open(for: path) == nil ? stemsCache.fraction : nil)
            // A check that started by itself goes on, and shows its progress from now on.
            if lyricsFit == nil { fitLyrics(lyrics, song: song, duration: track.duration) }
        case let .found(offset)?:
            setLyricsShift(offset)
        default:
            break
        }
    }

    /// Shows lyrics with times moved by `seconds`, 0 for their own times, and keeps that for the next play of the
    /// song in the same file or app.
    private func setLyricsShift(_ seconds: Double) {
        guard let song = lyricsSong, let original = lyricsOriginal, let source = lyricsFile ?? lyricsApp, case let .found(shown) = model.lyrics,
              shown.timing == .synced else { return }
        // Hundredths keep the arrows from adding up to 0.49999 and showing -0.0.
        let seconds = min(max((seconds * 100).rounded() / 100, -60), 60)
        model.lyrics = .found(seconds == 0 ? original : original.moved(by: seconds))
        lyricsMoved = seconds != 0
        model.lyricsShift = seconds
        lyricsStore.setShift(seconds, for: song, key: LyricsFit.key(original), file: source)
        model.lyricsTimingKept = seconds != 0 || lyricsStore.fit(for: song, key: LyricsFit.key(original), file: source) != nil
        updateLyricLine()
        log(seconds == 0 ? "lyrics: back at their own times" : String(format: "lyrics: their times moved by %+.2f s", seconds))
    }

    /// The ✕ of the Fix timing pill: forgets the fit and the shift kept for the song in this file or app, and shows
    /// the lines at their own times.
    private func forgetLyricsTiming() {
        guard let song = lyricsSong, let original = lyricsOriginal, let source = lyricsFile ?? lyricsApp else { return }
        lyricsStore.removeTiming(for: song, key: LyricsFit.key(original), file: source)
        log("lyrics: the saved timing was removed")
        lyricsTimingsRemoved()
    }

    /// Settings removed every fit and shift, or the ✕ removed those of the song: lyrics with times that show go back
    /// to their own times, and the pill to where a click checks them again.
    private func lyricsTimingsRemoved() {
        guard let original = lyricsOriginal, model.lyricsTiming != nil else { return }
        if case let .found(shown) = model.lyrics, shown.timing == .synced { model.lyrics = .found(original) }
        lyricsMoved = false
        model.lyricsShift = 0
        model.lyricsTimingKept = false
        if case .working? = model.lyricsTiming { return updateLyricLine() }
        model.lyricsTiming = lyricsFitCanRun ? .unchecked : .idle
        updateLyricLine()
    }

    /// With the lyrics timing model installed, fits the lyrics of a song that Muskey Player plays onto its vocals, which
    /// times the lines it finds before they are sung, and keeps what the fit found for the next play. Lyrics without
    /// times separate the stems of the whole song for it when the cache doesn't have them, and the heard words time
    /// every line until the fit is done, and the lines that it didn't find after that. Lyrics with times separate the
    /// song too, and the offset that the fit finds turns the Fix timing pill red, or moves the lines after a click.
    private func fitLyrics(_ lyrics: Lyrics, song: String, duration: Double?) {
        lyricsFit?.cancel()
        lyricsFit = nil
        guard AlignerModel.installed, StemModel.installed, playsInFilePlayer, let path = filePlayer.current?.path, let file = lyricsFile else { return }
        let key = LyricsFit.key(lyrics), synced = lyrics.timing == .synced
        // A fit that found too few lines is kept as well, so the file isn't fitted again on every play.
        guard lyricsStore.fit(for: song, key: key, file: file) == nil else { return }
        let texts = lyrics.lines.map(\.text)
        lyricsFitGeneration += 1
        let generation = lyricsFitGeneration
        lyricsFit = Task { @MainActor [weak self] in
            // A fit that ended leaves no task behind, so a click on the pill knows to start one.
            defer { if self?.lyricsFitGeneration == generation { self?.lyricsFit = nil } }
            // Only a check that was clicked shows that it failed. One that started by itself leaves the pill as it was.
            func failed(_ reason: String) {
                guard let self else { return }
                log("lyrics: \(reason)", .notice)
                guard synced, lyricsSong == song, lyricsOriginal == lyrics else { return }
                model.lyricsTiming = lyricsFixManual ? .failed : .unchecked
                lyricsFixManual = false
            }
            // A song of an hour separates in well under half an hour.
            for _ in 0 ..< 1800 where StemsCache.open(for: path) == nil {
                guard let self, !Task.isCancelled, lyricsSong == song else { return }
                if stemsCacheFailed.contains(path) { return failed("not fitted, the separation failed") }
                if stemsCache.path != path { stemsCache.start(path) }
                if synced, lyricsFixManual { model.lyricsTiming = .working(stemsCache.fraction) }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, lyricsSong == song else { return }
            guard let cache = StemsCache.open(for: path) else { return failed("not fitted, the separation took too long") }
            // While one song follows another, the file and the song on the record can be two songs for a moment. The
            // lyrics of one are never fitted onto the vocals of the other, and nothing is kept about it.
            let length = Double(cache.frames) / StemsCache.rate
            guard let duration, abs(length - duration) < 2 else {
                return failed(String(format: "not fitted, the file is %.0f s long and the song %.0f s", length, duration ?? 0))
            }
            if synced, lyricsFixManual { model.lyricsTiming = .working(nil) }
            let started = Date()
            lyricsFitBusy = true
            let fitted = await Task.detached(priority: .utility) { () -> Result<LyricsFit.Outcome?, Error> in
                Result { try LyricsFit.fit(texts, vocals: NotesPipeline.stemSamples(cache, stem: .vocals), rate: StemsCache.rate) }
            }.value
            lyricsFitBusy = false
            guard case let .success(outcome?) = fitted else {
                if case let .failure(error) = fitted { failed("the fit failed: \(error.localizedDescription)") }
                return
            }
            let took = String(format: "%.1f s", Date().timeIntervalSince(started))
            if synced {
                let check = LyricsFit.check(of: lyrics, outcome)
                let offset: Double? = switch check {
                case let .off(offset): offset
                case .right: 0
                case .unclear: nil
                }
                lyricsStore.setFit(LyricsStore.Fit(key: key, file: file, starts: nil, offset: offset), for: song)
                switch check {
                case let .off(offset): log(String(format: "lyrics: their times are off by %+.2f s, by the fit of %d lines in %@", offset, outcome.starts.count, took))
                case .right: log("lyrics: their times hold, by the fit of \(outcome.starts.count) of \(outcome.sung) lines in \(took)")
                case .unclear: log("lyrics: the offset of their times is unclear, by the fit of \(outcome.starts.count) of \(outcome.sung) lines in \(took)")
                }
                guard lyricsSong == song, lyricsOriginal == lyrics else { return }
                let clicked = lyricsFixManual
                lyricsFixManual = false
                model.lyricsTimingKept = true
                switch check {
                case let .off(offset):
                    model.lyricsTiming = .found(offset)
                    if clicked { setLyricsShift(offset) }
                case .right: model.lyricsTiming = .onTime
                case .unclear: model.lyricsTiming = .unknown
                }
            } else {
                lyricsStore.setFit(LyricsStore.Fit(key: key, file: file, starts: outcome.usable ? outcome.starts : [:], offset: nil), for: song)
                guard outcome.usable else {
                    return log("lyrics: the fit found \(outcome.starts.count) of \(outcome.sung) lines in \(took), too few to time them by")
                }
                log("lyrics: \(outcome.starts.count) of \(outcome.sung) lines timed by the fit in \(took)")
                guard lyricsSong == song, case let .found(shown) = model.lyrics, LyricsFit.key(shown) == key else { return }
                lyricsSync.apply(fitted: outcome.starts)
                updateLyricLine()
            }
        }
    }

    /// Whisper as Settings has it: a server, the model on the Mac, or nothing for Apple's speech model.
    private func whisperBackend() -> WhisperBackend? {
        switch prefs.lyricsTranscription {
        case .apple: nil
        case .server: WhisperServer(prefs.whisperServer)
        case .model: WhisperModel.installed ? WhisperModel.shared : nil
        }
    }

    /// The lyrics show their timing as heard once a line starts at a heard word. Lyrics that Whisper wrote keep their
    /// timing, since each line starts where Whisper heard it.
    private func lyricsTimingChanged() {
        if model.lyricsDownloading != lyricsSync.downloading { model.lyricsDownloading = lyricsSync.downloading }
        guard case var .found(lyrics) = model.lyrics, lyrics.timing != .synced, lyrics.timing != .written else { return }
        let timing: Lyrics.Timing = lyricsSync.anchored > 0 ? .heard : .estimated
        guard lyrics.timing != timing else { return }
        lyrics.timing = timing
        model.lyrics = .found(lyrics)
        if timing == .heard { log("lyrics: timed by listening") }
    }

    private func retryLyrics() {
        if let track = model.track { lyricsFinder.forget(track) }
        loadLyrics(again: true)
    }

    /// Add Lyrics, and Edit Lyrics in the panel's menu: a window to paste or edit the lyrics of the song on the
    /// record, which take the place of LRCLIB's for that song. Saving an empty text goes back to LRCLIB's.
    private func editLyrics() {
        guard let track = model.track, let song = LyricsFinder.id(track) else { return }
        var text = lyricsStore.text(for: song) ?? ""
        if text.isEmpty, case let .found(lyrics) = model.lyrics { text = lyrics.text }
        lyricsEditor?.close()
        let editor = LyricsEditorWindowController(song: track.label, text: text) { [weak self] saved in
            guard let self else { return }
            let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            lyricsStore.setText(trimmed.isEmpty ? nil : saved, for: song)
            log(trimmed.isEmpty ? "lyrics: removed the added lyrics" : "lyrics: added by hand")
            if lyricsSong == song { loadLyrics(again: true) }
        }
        editor.onClose = { [weak self] in
            self?.lyricsEditor = nil
            self?.updateHoverKeys()
        }
        lyricsEditor = editor
        editor.show()
        updateHoverKeys()
    }

    /// For the log, which never has the song or its words.
    private static func describe(_ state: LyricsState) -> String {
        switch state {
        case let .found(lyrics): "\(lyrics.lines.count) lines, \(lyrics.timing == .synced ? "synced" : lyrics.otherVersion ? "times of another version" : "estimated timing")\(lyrics.source.map { ", from \($0.name)" } ?? "")"
        case .instrumental: "instrumental"
        case .notFound: "not found"
        case .failed: "request failed"
        case .loading: "loading"
        case .none: "no song"
        }
    }

    /// Moves the line sung now along with the song, five times a second while the lyrics show.
    private func updateLyricsClock(shown: Bool) {
        let wanted = shown && model.lyricsShown
        guard wanted != (lyricsClock != nil) else { return }
        lyricsClock?.invalidate()
        lyricsClock = wanted ? Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateLyricLine() } : nil
        if !wanted {
            lyricsSync.end()
            setLyricsDelay(false)
        }
    }

    private var droppedLogged = 0
    /// The second of the song that was heard at the last update of the line, which tells a seek back from a new time.
    private var lyricsHeardLast = 0.0

    private func updateLyricLine() {
        guard case let .found(lyrics) = model.lyrics, let position = model.track?.position(at: Date()) else {
            if model.lyricLine != nil { model.lyricLine = nil }
            return
        }
        lyricsSync.mark(position: model.track?.playing == true ? position : nil)
        if model.lyricsSkipped != lyricsSync.inTranscribedPart { model.lyricsSkipped = lyricsSync.inTranscribedPart }
        let times = lyricsSync.times(at: position) ?? lyrics.lines.map(\.time)
        // The stems and the lyrics delay play the song seconds behind, and the line sung is the one that is heard.
        let heard = position - pitch.stemsDelay
        let waiting = lyricsDelayed ? pitch.delayWaiting.map { Int($0.rounded(.up)) } : nil
        if model.lyricsWaiting != waiting { model.lyricsWaiting = waiting }
        checkSpins()
        // A line lights up a moment before it is sung, the way people read ahead.
        var line = times.lastIndex { $0 <= heard + 0.25 }
        // The lines after the last heard word are placed ahead, and the words that the transcriber hears a few
        // seconds later can move the start of the line that lit up a little later. The highlight then stepped back a
        // line and forward again moments later, so a line that lit up stays lit through a correction of up to 3
        // seconds. A seek back, or a larger correction, still goes back.
        if let shown = model.lyricLine, let new = line, new == shown - 1, shown < times.count,
           heard >= lyricsHeardLast - 0.5, times[shown] - (heard + 0.25) < 3 {
            line = shown
        }
        lyricsHeardLast = heard
        if model.lyricLine != line { model.lyricLine = line }
        logTimingError(times, position: position)
    }

    /// With `--lyrics-plain`, the gap between the heard times and the dropped ones for the lines sung so far, each
    /// time more lines are timed.
    private func logTimingError(_ times: [Double], position: Double) {
        guard let droppedTimes, droppedTimes.count == times.count, lyricsSync.anchored > droppedLogged else { return }
        droppedLogged = lyricsSync.anchored
        let sung = zip(times, droppedTimes).filter { $0.1 >= 0 && $0.1 < position - 3 }
        let errors = sung.map { abs($0.0 - $0.1) }.sorted()
        let signed = sung.map { $0.0 - $0.1 }.sorted()
        guard !errors.isEmpty, let last = sung.last else { return }
        log(String(format: "lyrics: at %.0fs, %d lines timed, error of the lines sung: median %.2fs (signed %+.2fs), %d of %d within 1s, last line %.1fs for %.1fs",
                   position, lyricsSync.anchored, errors[errors.count / 2], signed[signed.count / 2], errors.filter { $0 <= 1 }.count, errors.count,
                   last.0, last.1), .debug)
    }

    /// `--lyrics-lookup "TITLE|ARTIST|ALBUM|SECONDS"` asks the lyrics services for a song's lyrics the way the panel does,
    /// prints what came back and quits, for checking the matching from a terminal.
    private func lookUpLyrics(_ spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let track = NowPlaying.Track(title: parts.first, artist: parts.count > 1 ? parts[1] : nil, album: parts.count > 2 ? parts[2] : nil,
                                     duration: parts.count > 3 ? Double(parts[3]) : nil, elapsed: 0, timestamp: nil, rate: 0, bundleID: nil)
        let cleaned = LyricsFinder.clean(track.title ?? "", artist: track.artist ?? "")
        print("cleaned: \(cleaned.title) | \(cleaned.artist)")
        lyricsFinder.find(track) { state in
            print(Self.describe(state))
            if case let .found(lyrics) = state {
                for line in lyrics.lines.prefix(3) { print(String(format: "%6.2f  %@", line.time, line.text)) }
            }
            exit(0)
        }
    }

    /// `--key-lookup "Title|Artist|Album|Seconds"` asks Noiseblend for the key of that song, with an empty cache, and
    /// prints the answer.
    private func lookUpKeyForTesting(_ spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map { $0.isEmpty ? nil : String($0) }
        let track = NowPlaying.Track(title: parts.first ?? nil, artist: parts.count > 1 ? parts[1] : nil, album: parts.count > 2 ? parts[2] : nil,
                                     duration: parts.count > 3 ? parts[3].flatMap(Double.init) : nil, elapsed: 0, timestamp: nil, rate: 0, bundleID: nil)
        let cleaned = KeyLookup.clean(track.title ?? "", artist: track.artist ?? "")
        print("sent: \(cleaned.title) | \(cleaned.artist)")
        let lookup = KeyLookup(url: FileManager.default.temporaryDirectory.appending(path: "muskey-key-lookup-\(UUID().uuidString).json"))
        lookup.log.echo = { print($0) }
        lookup.find(track) { key in
            print(key.map { "key: \($0.name) (\($0.camelot))" } ?? "no key")
            exit(0)
        }
    }

    /// `--tempo FILE` finds the tempo of the part of FILE that a listen would hear: `--seconds` (20 by default) from
    /// `--tempo-at` (45 by default). Prints the tempo and quits.
    /// `--key-file PATH` prints the key and the tempo that a listen reads from a song's file, and how long it took.
    private func keyFileForTesting(_ path: String) {
        let started = Date()
        guard let read = KeyAnalyzer.read(path) else {
            print("can't read \(path)")
            exit(1)
        }
        let key = DetectedKey(read.result)
        print(String(format: "key: %@  strength %.3f  peak %.3f  tempo %@  %.1f s of song in %.2f s", key?.name ?? "none", read.result.strength, read.peak,
                     read.tempo.map { String(format: "%.1f BPM", $0.bpm) } ?? "none", read.seconds, Date().timeIntervalSince(started)))
        exit(0)
    }

    private func tempoForTesting(_ path: String) {
        let seconds = Self.stringOption("--seconds").flatMap(Double.init) ?? 20
        let start = Self.stringOption("--tempo-at").flatMap(Double.init) ?? 45
        exit(TempoDetector.printTempo(of: path, from: start, seconds: seconds))
    }

    /// `--lyrics-test FILE` plays a made-up song with the lyrics in FILE (LRC, or plain text for estimated timing),
    /// from `--lyrics-at` seconds or from `--lyrics-since`, and opens the lyrics, for testing them where nothing plays. `--lyrics-test failed`
    /// starts on a request that failed, and its Retry asks LRCLIB for the made-up song.
    private static let lyricsTest: (track: NowPlaying.Track, state: LyricsState)? = {
        guard let path = TestFlags.value("--lyrics-test") else { return nil }
        let text = path == "failed" ? "" : (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // `--lyrics-since TIME` starts the made-up song at that Unix time, to line it up with a file that afplay plays.
        let since = TestFlags.value("--lyrics-since").flatMap(Double.init).map { Date().timeIntervalSince1970 - $0 }
        let start = since ?? TestFlags.value("--lyrics-at").flatMap(Double.init) ?? 0
        let lyrics = Lyrics.parse(lrc: text) ?? Lyrics.estimate(plain: text, duration: 200)
        let duration = max(200, (lyrics?.lines.last?.time ?? 0) + 20)
        let track = NowPlaying.Track(title: "Test Song", artist: "Muskey", album: "Tests", duration: duration, elapsed: start,
                                     timestamp: Date().timeIntervalSince1970, rate: 1, bundleID: nil)
        return (track, path == "failed" ? .failed : lyrics.map { .found($0) } ?? .notFound)
    }()

    /// Holding Option with the pointer over the HUD flips the keys to the other mode. Without Accessibility
    /// the app gets no modifier changes from other apps, so it reads the modifiers 30 times a second while the HUD
    /// is up.
    private func watchOption(_ shown: Bool) {
        optionWatch?.invalidate()
        optionWatch = nil
        guard shown else {
            model.accidentals = false
            return model.flipped = false
        }
        optionWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let flags = NSEvent.modifierFlags
            // Only with the pointer over the HUD: Option held while typing in another app flipped the keys out of sight.
            let flipped = flags.contains(.option) && !flags.contains(.command) && model.key != nil && model.hovering
            if model.flipped != flipped { model.flipped = flipped }
            let accidentals = flags.contains(.shift) && !flags.contains(.command) && !flags.contains(.control) && model.key != nil && model.hovering
            if model.accidentals != accidentals { model.accidentals = accidentals }
        }
    }

    /// While the pointer is over a HUD that shows a key, its keys work without the HUD having keyboard focus,
    /// as hotkeys that go away when the pointer leaves.
    /// `--log-keys` logs the hover over the HUD and every key that reaches it, for testing the keys from a script.
    private static let logKeys = TestFlags.has("--log-keys")

    /// The key hints, the stems' number keys and the tempo keycaps show only with the pointer over the HUD. The keys
    /// also work while the HUD holds the keyboard, but the HUD stays compact then, as it does whenever the pointer is
    /// away from it.
    private func updateKeysActive() {
        let active = model.hovering
        if model.keysActive != active { model.keysActive = active }
    }

    private var hoverKeysForLyrics = false
    private var hoverKeysForStems = false
    private var hoverKeysForKaraoke = false
    private var hoverKeysForSpeed = false
    private var hoverKeysForSeek = false
    private var hoverKeysForRestart = false
    private var hoverKeysForSave = false
    private var hoverKeysForRecord = false
    private var hoverKeysForWaveform = false
    private var hoverKeysForBars = false
    private var hoverKeysForQueue = false
    private var hoverKeysForRecents = false
    private var hoverKeysForChords = false
    private var hoverKeysForLoopEnd = false
    private var hoverKeysForNotes = false
    private var hoverKeysForKey = false
    /// The clipboard when the keys were registered: ⌘V over the HUD is a key only while it holds files or a link.
    private var hoverKeysPasteboard = 0
    /// A save leaves the HUD only Escape, and the shortcuts only Escape and ?, which close them.
    private var hoverKeysLock = HoverKeysLock.none
    /// The key that types ? in the keyboard layout that was selected when the keys were registered.
    private var hoverKeysQuestion: LayoutKey?
    private enum HoverKeysLock { case none, saving, opening, shortcuts }
    private var overRecordChange: AnyCancellable?
    private var loopEndChange: AnyCancellable?
    private var waveHoverChange: AnyCancellable?
    private var barsChange: AnyCancellable?
    private var lockChange: AnyCancellable?
    private var keyChange: AnyCancellable?
    private var heldGlassChange: AnyCancellable?

    /// Open File… or Open URL… is open. Its text would otherwise reach the keys over the HUD, which are global
    /// hotkeys, whenever the pointer rests on the HUD.
    private var dialogOpen = false {
        didSet { if dialogOpen != oldValue { updateHoverKeys() } }
    }

    private func updateHoverKeys() {
        let settingsWanted = model.hovering && model.shown && !dialogOpen
        if settingsWanted != (settingsKey != nil) {
            settingsKey = settingsWanted ? try? HotKey(keyCode: kVK_ANSI_Comma, modifiers: cmdKey, action: { [weak self] in self?.showSettings() }) : nil
        }
        let lock: HoverKeysLock = model.saving != nil ? .saving : model.opening != nil ? .opening : model.shortcuts ? .shortcuts : .none
        // A listen that has no estimate yet leaves the HUD without a key. The keys that play, skip and move the song
        // work from the start, and the ones that change the key, the instruments or the tempo wait for the key.
        let keyed = model.key != nil
        let pasteboard = NSPasteboard.general.changeCount
        // A listen that heard silence or found no key still leaves the HUD to play, pause and skip the song.
        let wanted = model.hovering && model.shown && (model.picking || [.done, .listening, .idle, .silent, .failed].contains(model.phase))
            && lyricsEditor == nil && !dialogOpen && !loopTyping
        // The lyrics take fewer keys than the key row, so the keys change when the panel does.
        guard wanted == hoverKeys.isEmpty
            || (wanted && (hoverKeysForKey != keyed || hoverKeysPasteboard != pasteboard
                || hoverKeysForLyrics != model.lyricsShown || hoverKeysForStems != model.stemsAvailable || hoverKeysForKaraoke != model.lyricsFocus
                || hoverKeysForSpeed != model.speedAdjustable || hoverKeysForSeek != model.seekable
                || hoverKeysForRestart != model.restartable || hoverKeysForSave != model.savable
                || hoverKeysForRecord != model.overRecord || hoverKeysForWaveform != model.wave.hovered || hoverKeysForBars != waveformNumbersBars
                || hoverKeysForQueue != model.queueShown || hoverKeysForRecents != model.recentsFlipped || hoverKeysForLoopEnd != (model.wave.loopEnd != nil)
                || hoverKeysForChords != !model.chords.isEmpty || hoverKeysForNotes != (model.notesPicking != nil) || hoverKeysLock != lock || hoverKeysQuestion != LayoutKey.questionMark))
        else { return }
        if Self.logKeys, wanted == hoverKeys.isEmpty { log("keys over the HUD \(wanted ? "on" : "off")", .debug) }
        guard wanted else { return hoverKeys = [:] }
        // The keys are gathered first and compared with the ones registered: a pointer that crosses from the record
        // to the waveform changes a handful of them, and registering all of them again took 60 to 90 calls each time.
        var next: [HoverKey: () -> Void] = [:]
        func add(_ code: Int, _ modifiers: Int, _ kind: String = "key", _ action: (() -> Void)? = nil) {
            // A key that two lists add is registered once.
            guard !next.keys.contains(where: { $0.code == code && $0.modifiers == modifiers }) else { return }
            next[HoverKey(code: code, modifiers: modifiers, kind: kind)] = action ?? { [weak self] in
                _ = self?.pressKey(code, shift: modifiers & shiftKey != 0, option: modifiers & optionKey != 0)
            }
        }
        defer { registerHoverKeys(next) }
        hoverKeysForKey = keyed
        hoverKeysPasteboard = pasteboard
        hoverKeysForLyrics = model.lyricsShown
        hoverKeysForStems = model.stemsAvailable
        hoverKeysForKaraoke = model.lyricsFocus
        hoverKeysForSpeed = model.speedAdjustable
        hoverKeysForSeek = model.seekable
        hoverKeysForRestart = model.restartable
        hoverKeysForSave = model.savable
        hoverKeysForRecord = model.overRecord
        hoverKeysForWaveform = model.wave.hovered
        hoverKeysForBars = waveformNumbersBars
        hoverKeysForQueue = model.queueShown
        hoverKeysForRecents = model.recentsFlipped
        hoverKeysForLoopEnd = model.wave.loopEnd != nil
        hoverKeysForChords = !model.chords.isEmpty
        hoverKeysForNotes = model.notesPicking != nil
        hoverKeysLock = lock
        hoverKeysQuestion = LayoutKey.questionMark
        let question = hoverKeysQuestion.map { [($0.code, $0.modifiers)] } ?? []
        if lock != .none {
            let keys = lock == .shortcuts ? [(kVK_Escape, 0)] + question : lock == .opening ? [(kVK_Escape, 0), (kVK_Delete, 0)] : [(kVK_Escape, 0)]
            for (code, modifiers) in keys { add(code, modifiers) }
            // Another song can still be opened in place of the one that opens.
            if lock == .opening {
                add(kVK_ANSI_O, cmdKey, "open") { [weak self] in self?.openFile() }
                add(kVK_ANSI_L, cmdKey, "link") { [weak self] in self?.openLocation() }
                add(kVK_ANSI_V, cmdKey, "paste") { [weak self] in _ = self?.pasteSongs() }
            }
            return
        }
        // The stem picker of T takes only its own keys and Space.
        if let picking = model.notesPicking {
            // Tab picks the whole song or the region loop.
            let keys = [kVK_Escape, kVK_ANSI_T, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space] + Self.digitKeys[1 ... picking.stems.count]
                + (picking.region == nil ? [] : [kVK_Tab])
            for code in keys { add(code, 0) }
            // ⌥↩ captures the rest of a song from another app before transcribing it.
            if picking.heard != nil { add(kVK_Return, optionKey) }
            return
        }
        let modifiers = [0, shiftKey, optionKey, optionKey | shiftKey]
        // ? shows the shortcuts.
        var keys: [(Int, Int)] = [kVK_Escape, kVK_Space, kVK_ANSI_N, kVK_ANSI_P].map { ($0, 0) } + question
        if keyed { keys += [kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_S].map { ($0, 0) } + [(kVK_ANSI_W, 0), (kVK_ANSI_W, optionKey)] }
        if model.seekable || model.loop != nil { keys += [(kVK_ANSI_R, 0), (kVK_ANSI_R, optionKey), (kVK_ANSI_R, shiftKey)] }
        // Over the tab of an end of the region loop, the arrows nudge it.
        if model.loop != nil, model.wave.loopEnd != nil { keys += [kVK_LeftArrow, kVK_RightArrow].flatMap { [($0, 0), ($0, optionKey)] } }
        // Q shows the queue, which takes the arrows, Return and Delete while it shows, and M the mini player.
        if !model.lyricsFocus { keys += (model.otherPlayer ? [] : [(kVK_ANSI_Q, 0)]) + [(kVK_ANSI_T, 0)] }
        keys.append((kVK_ANSI_M, 0))
        if model.recentsFlipped { keys += [kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_ANSI_KeypadEnter].map { ($0, 0) } }
        if model.queueShown {
            keys += [kVK_UpArrow, kVK_DownArrow].flatMap { [($0, 0), ($0, shiftKey)] }
            keys += [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Delete, kVK_ForwardDelete].map { ($0, 0) }
        }
        if keyed, model.stemsAvailable {
            // V mutes the vocals or plays them again, in every layout.
            keys += Self.stemKeys.flatMap { code in [(code, 0), (code, optionKey)] } + [(kVK_ANSI_0, 0), (kVK_ANSI_V, 0)]
        }
        // A song in Muskey Player plays slower, faster or at its own tempo.
        if keyed, model.speedAdjustable { keys += Self.speedKeys.keys.map { ($0, 0) } }
        // Return shows the lyrics large, or back at their usual size, and the arrows seek while a seek is instant.
        if keyed, model.lyricsShown { keys += [kVK_Return, kVK_ANSI_KeypadEnter].map { ($0, 0) } }
        if model.lyricsShown, model.seekable { keys += [kVK_LeftArrow, kVK_RightArrow].map { ($0, 0) } }
        // Over the chords, the arrows transpose, and with Option they move the capo.
        if model.lyricsShown, !model.chords.isEmpty { keys += [kVK_LeftArrow, kVK_RightArrow].flatMap { [($0, 0), ($0, optionKey)] } }
        // Karaoke seeks with the number keys, and 0 starts the song over in every player.
        if model.lyricsFocus, model.seekable { keys += Self.digitKeys.map { ($0, 0) } }
        if model.lyricsFocus, model.restartable { keys.append((kVK_ANSI_0, 0)) }
        // The key row, and karaoke, change the key by its letter.
        if keyed, !model.lyricsShown || model.lyricsFocus {
            keys += Self.letters.keys.flatMap { code in modifiers.map { (code, $0) } }
            keys += [kVK_Delete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].map { ($0, 0) }
        }
        // Over the record, the arrows and the numbers move the song, and 0 starts it over.
        if model.overRecord, model.seekable { keys += [kVK_LeftArrow, kVK_RightArrow].map { ($0, 0) } }
        if model.overRecord { keys += Self.digitKeys.dropFirst().map { ($0, 0) } }
        if model.overRecord, model.restartable { keys.append((kVK_ANSI_0, 0)) }
        // Over the waveform, the arrows, 0 and the numbers of its bars move the song too, and do nothing while it can't move.
        if model.wave.hovered { keys += [kVK_LeftArrow, kVK_RightArrow, kVK_ANSI_0].map { ($0, 0) } }
        if model.wave.hovered, waveformNumbersBars { keys += Self.digitKeys.dropFirst().map { ($0, 0) } }
        for (code, modifiers) in keys { add(code, modifiers) }
        if keyed { add(kVK_ANSI_K, cmdKey, "karaoke") { [weak self] in self?.toggleKaraoke() } }
        // ⌘+ and ⌘− zoom the waveform in and out, with or without Shift for the +, and ⌘0 shows the whole song.
        if keyed {
            for (code, modifiers, factor) in [(kVK_ANSI_Equal, cmdKey, 1.5), (kVK_ANSI_Equal, cmdKey | shiftKey, 1.5), (kVK_ANSI_Minus, cmdKey, 1 / 1.5), (kVK_ANSI_0, cmdKey, 0)] {
                add(code, modifiers, "zoom") { [weak self] in self?.zoomWaveform(factor) }
            }
        }
        if model.savable { add(kVK_ANSI_S, cmdKey, "save") { [weak self] in self?.saveSong() } }
        if keyed { add(kVK_Delete, cmdKey, "reset") { [weak self] in self?.resetAll() } }
        // ⌘V over the HUD plays the files or the link on the clipboard. A clipboard with other text leaves ⌘V to the
        // app in front.
        // The clipboard is read once for each change of it, since the app that owns it is asked for its data.
        if pastedSongs?.count != pasteboard { pastedSongs = (pasteboard, !Self.pastedURLs().isEmpty) }
        let pasted = pastedSongs?.has ?? false
        if pasted { add(kVK_ANSI_V, cmdKey, "paste") { [weak self] in _ = self?.pasteSongs() } }
        add(kVK_ANSI_O, cmdKey, "open") { [weak self] in self?.openFile() }
        add(kVK_ANSI_L, cmdKey, "link") { [weak self] in self?.openLocation() }
        // ⇧⌘O, ⇧⌘L and ⇧⌘V add to the queue.
        add(kVK_ANSI_O, cmdKey | shiftKey, "add file") { [weak self] in self?.addFiles() }
        add(kVK_ANSI_L, cmdKey | shiftKey, "add link") { [weak self] in self?.addLocation() }
        if pasted { add(kVK_ANSI_V, cmdKey | shiftKey, "add copied") { [weak self] in _ = self?.addCopied() } }
        if model.queueShown {
            add(kVK_ANSI_A, cmdKey, "select all") { [weak self] in
                guard let self else { return }
                model.queueSelection = Set(model.queue.map(\.id))
            }
        }
        add(kVK_ANSI_C, cmdKey | optionKey, "home") { [weak self] in self?.panel.returnHome() }
    }

    /// A key over the HUD: its code and modifiers, and what it does, since one key can do another thing in another state.
    private struct HoverKey: Hashable {
        let code: Int, modifiers: Int
        let kind: String
    }

    /// Whether the clipboard holds songs, read at its last change.
    private var pastedSongs: (count: Int, has: Bool)?

    /// Registers the keys that weren't registered yet and frees the ones that are no longer wanted.
    /// A key that waits for its hold counts as released when its hotkey goes, since its release would never arrive.
    private func registerHoverKeys(_ next: [HoverKey: () -> Void]) {
        for key in hoverKeys.keys where next[key] == nil {
            hoverKeys[key] = nil
            if heldKey?.code == key.code { releaseKey(key.code) }
        }
        for (key, action) in next where hoverKeys[key] == nil {
            let code = key.code
            hoverKeys[key] = try? HotKey(keyCode: code, modifiers: key.modifiers, action: action, release: { [weak self] in self?.releaseKey(code) })
        }
    }

    /// Starts, changes or stops the pitch change. While the picker is open, going back to the original key keeps
    /// the tap running, so picking another key right after doesn't rebuild it.
    /// `byPerson` is false for a shift that moves a new song to the kept key; a key that a person picks becomes
    /// the kept key, and ends the moving of a new song.
    private func setShift(_ semitones: Int, relative: Bool? = nil, byPerson: Bool = true) {
        let semitones = min(max(semitones, Shift.range.lowerBound), Shift.range.upperBound)
        model.pitchFailed = false
        model.shift = semitones
        if let relative { model.relative = relative }
        if Self.logKeys { log("heard \(model.heard?.name ?? "no key"), \(Shift.text(semitones))", .debug) }
        pitch.semitones = semitones
        if byPerson {
            model.moved = nil
            model.pending = nil
            // A key picked while the listen still runs is the key the song stays in: if the final estimate finds
            // another key, the shift changes and the key doesn't.
            if state == .listening, let heard = model.heard {
                follow = heard
                followApplied = true
                followByPerson = true
                log("picked \(heard.name) during the listen, from an estimate of \(model.key?.name ?? "no key")")
            } else {
                follow = nil
            }
            if model.keepKey, let heard = model.heard { keptKey = heard }
        }
        refreshStatus()
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// The pitch change runs for a shift, for the stems, for the lyrics delay, which play through the same output, and
    /// for a song that Muskey Player plays faster or slower, which it keeps in its key.
    /// Stops the pitch change once nothing needs it and no key row shows, as after a slowed song caught up.
    private func stopPitchIfUnwanted() {
        if !pitchWanted, !model.picking, follow == nil, pitch.running { pitch.stopSmoothly { [self] in logShift() } }
    }

    /// The slowing of another player's song needs the pitch change until the output has caught up with the player.
    private var pitchWanted: Bool { changesNeedPitch || phoneListening }
    /// A change to the song needs the pitch change: a key, instruments, delayed lyrics, a tempo correction or a slowed
    /// song. A phone that listens keeps it running without a change, and a new song then gets its key read.
    private var changesNeedPitch: Bool {
        model.shift != 0 || model.stemsEngaged || lyricsDelayed || pitch.correction != 0 || slow.active
    }

    /// The speed of the song as the tap hears it: Muskey Player's speed while its song is the one that plays. A song
    /// from another player plays at its own speed, and only the output slows it down.
    private var playedSpeed: Double { playsInFilePlayer ? filePlayer.speed : 1 }
    /// The speed of the song that plays: Muskey Player's, or the one that another player's song is slowed down to.
    private var currentSpeed: Double { playsInFilePlayer ? filePlayer.speed : slow.speed }
    private var playsInFilePlayer: Bool { filePlayer.hasSong && nowPlaying.player?.bundleID == FilePlayer.bundleID }
    /// The pitch change hears only Muskey Player while it plays the song, so other sounds play as they are.
    private var heardProcess: pid_t? { playsInFilePlayer ? filePlayer.pid : nil }
    /// A song from another player can be slowed down while the player moves its songs, which keeps the output in step
    /// with it, and while it isn't recorded for a save.
    private var slowable: Bool {
        guard let player = nowPlaying.player, player.title?.isEmpty == false, (player.duration ?? 0) > 0, let id = player.bundleID,
              id != FilePlayer.bundleID, !unseekable.contains(id), songRecording == nil
        else { return false }
        return true
    }
    /// The fastest speed: a song from another player can only be slowed down, since the player plays it as fast as it
    /// comes.
    private var fastestSpeed: Double { playsInFilePlayer ? 1.5 : 1 }
    /// The speed that the listens running now hear the song at.
    private var heardSpeed = 1.0

    /// Retry on the red tempo pill: the player gets its moves tried again from the first way, and the song is slowed
    /// to the speed that was asked for.
    private func retrySlowing() {
        guard let wanted = model.slowFailed else { return }
        model.slowFailed = nil
        if let id = slowFailedPlayer {
            unseekable.remove(id)
            seekPaths[id] = nil
        }
        log(String(format: "slow: retry at %.0f%%", wanted * 100))
        syncSeekable()
        syncSpeed()
        playSpeed(wanted)
    }

    /// The keys of the tempo, for a song in Muskey Player.
    private static let speedKeys = [kVK_ANSI_LeftBracket: -1, kVK_ANSI_RightBracket: 1, kVK_ANSI_Equal: 0]

    /// The tempo keys and pills: 5 % slower or faster, from 50 % to 150 %, or the song's own tempo with 0.
    private func changeSpeed(by step: Int) {
        playSpeed(step == 0 ? 1 : min(max(((currentSpeed * 20).rounded() + Double(step)) / 20, 0.5), fastestSpeed))
    }

    /// `--speed S` plays the first song that Muskey Player opens at that speed, for testing the correction.
    private var testSpeed = TestFlags.value("--speed").flatMap(Double.init)

    private func playSpeed(_ target: Double) {
        guard model.speedAdjustable, target != currentSpeed else { return }
        model.slowFailed = nil
        if playsInFilePlayer {
            filePlayer.setSpeed(target)
        } else if let player = nowPlaying.player {
            slowedPlayer = player.bundleID
            slow.setSpeed(target, track: player)
        }
        log(String(format: "tempo %.0f%%", target * 100))
        syncSpeed()
    }

    /// Muskey Player's speed, and the correction that keeps its song in its key. The pitch change hears every app, so
    /// the correction applies only while Muskey Player is the player that macOS shows as playing.
    private func syncSpeed() {
        defer { syncStemsCache() }
        if pitch.heardProcess != heardProcess { pitch.heardProcess = heardProcess }
        // Another player taking over, or a save that records the song, ends the slowing: the output jumps to the player.
        if slow.active, nowPlaying.player?.bundleID != slowedPlayer || songRecording != nil {
            slow.stop(songRecording != nil ? "the song is recorded for a save" : "another player plays")
        }
        // The red tempo pill belongs to the player that couldn't be slowed.
        if model.slowFailed != nil, let id = nowPlaying.player?.bundleID, id != slowFailedPlayer { model.slowFailed = nil }
        let adjustable = playsInFilePlayer || slowable || slow.active
        if model.speedAdjustable != adjustable {
            model.speedAdjustable = adjustable
            log("tempo keys \(adjustable ? "on" : "off") (playing: \(nowPlaying.track?.bundleID ?? "nothing"))", .debug)
            updateHoverKeys()
            if adjustable, let speed = testSpeed {
                testSpeed = nil
                DispatchQueue.main.async { [self] in playSpeed(speed) }
            }
        }
        if model.speed != currentSpeed {
            model.speed = currentSpeed
            syncSavable()
        }
        if model.fastestSpeed != fastestSpeed { model.fastestSpeed = fastestSpeed }
        let speed = playedSpeed
        if speed != heardSpeed {
            heardSpeed = speed
            // A listen hears the song at one speed, so one that runs starts over at the new speed, with its whole
            // length ahead of it. A key from the few seconds left would be stored with the song.
            if let analyzer {
                analyzer.play(at: speed)
                startedAt = Date()
                log("the listen starts over at the new speed")
            }
            if autoAnalyzer != nil {
                cancelAutoListen()
                autoListenIfNeeded()
            }
        }
        lyricsSync.hearsSong = speed == 1 && !slow.active
        // The output reads a slowed song from another player as a record played slower, which the correction undoes.
        let read = playsInFilePlayer ? speed : slow.active ? slow.readSpeed : 1
        let correction = read == 1 ? 0 : -12 * log2(read)
        guard correction != pitch.correction else { return }
        // The stems and the lyrics delay play the song seconds behind the player, and the shifter keeps the old
        // correction for the part captured before this moment (`ps_set_correction`).
        log(String(format: "tempo correction of %+.2f semitones", correction))
        pitch.correction = correction
        updateWatching(shown: model.shown)
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// The song plays this far behind itself while Whisper writes its lyrics.
    private static let lyricsLead = 30.0
    private var lyricsDelayed = false

    /// While Whisper writes the lyrics, the song plays 30 seconds behind, so each line is written before it is heard.
    /// Until then the song plays as it is, and the lyrics count down to the step back. The delay ends with the lyrics.
    private func setLyricsDelay(_ on: Bool) {
        guard on != lyricsDelayed else { return }
        lyricsDelayed = on
        syncSeekable()
        // The delay holds the stems until it steps back, so karaoke's silent countdown would outlast it: the song plays
        // from its start as it is, under Whisper's countdown.
        if on, karaokeRestart != nil {
            log("karaoke: Whisper writes the lyrics of the start, the song plays during its countdown")
            endKaraokeRestart()
        }
        pitch.lyricsDelay = on ? Self.lyricsLead : 0
        log(on ? "lyrics: the song plays 30 seconds behind while Whisper writes them" : "lyrics: the song plays without the delay")
        if !on, model.lyricsWaiting != nil { model.lyricsWaiting = nil }
        updateWatching(shown: model.shown)
        if pitchWanted, !pitch.running {
            startPitch()
        } else if !pitchWanted, !model.picking, follow == nil, pitch.running {
            pitch.stopSmoothly { [self] in logShift() }
        }
    }

    /// Without the permission the tap would hear silence while still muting the Mac, so it is checked first.
    private func startPitch() {
        switch AudioCapturePermission.status {
        case .granted:
            do {
                let started = CACurrentMediaTime()
                pitch.heardProcess = heardProcess
                try pitch.start()
                log(String(format: "pitch change started (%.0f ms to build%@)", (CACurrentMediaTime() - started) * 1000,
                           pitch.hearsOneProcess ? ", hearing only Muskey Player" : ""), .notice)
            } catch {
                pitchFailed("\(error)")
            }
        case .denied:
            pitchFailed("system audio recording is not allowed")
        case .undetermined:
            AudioCapturePermission.request { [self] granted in
                guard pitchWanted, !pitch.running else { return }
                granted ? startPitch() : pitchFailed("system audio recording was not allowed")
            }
        }
    }

    private func pitchFailed(_ reason: String) {
        log("pitch change failed: \(reason)", .error)
        slow.stop("the pitch change failed")
        pitch.stop()
        model.shift = 0
        model.relative = false
        pitch.semitones = 0
        model.stemVolumes = [:]
        pitch.stemVolumes = [:]
        model.stemsMuted = []
        pitch.mutedStems = []
        model.stemsEngaged = false
        pitch.stemsEngaged = false
        endKaraokeRestart()
        updateStemMeters(shown: model.shown)
        model.pitchFailed = true
        follow = nil
        keptKey = nil
        if filePlayer.speed != 1 { filePlayer.setSpeed(1) }
        pitch.correction = 0
        model.speed = 1
    }

    /// Stop Pitch Change in the HUD and in the menu: back to the original key, no key kept for the next songs,
    /// and the HUD closes.
    /// The ✕ on the stems: every stem plays again and the stems close into the Separate button. The stems of the whole
    /// song stay in the cache, so separating the song again is instant.
    private func closeStems() {
        log("stems closed")
        model.stemsFailed = false
        model.stemVolumes = [:]
        pitch.stemVolumes = [:]
        model.stemsMuted = []
        pitch.mutedStems = []
        engageStems(false)
        refreshStatus()
    }

    /// ⌘⌫: the song as it was, at once: its key, its tempo and every stem, with Lock Key released. The HUD stays up.
    private func resetAll() {
        log("⌘⌫: the key, the tempo and the stems back to the original")
        if currentSpeed != 1 { playSpeed(1) }
        if !model.stemVolumes.isEmpty {
            model.stemVolumes = [:]
            pitch.stemVolumes = [:]
        }
        follow = nil
        model.pending = nil
        keptKey = nil
        model.stemsMuted = []
        pitch.mutedStems = []
        model.stemsEngaged = false
        pitch.stemsEngaged = false
        updateStemMeters(shown: model.shown)
        setShift(0, relative: false, byPerson: true)
        refreshStatus()
    }

    private func stopPitch() {
        follow = nil
        model.pending = nil
        keptKey = nil
        // The volumes set by a scroll go too, or the instruments would stay open at them over a song that plays whole.
        model.stemVolumes = [:]
        pitch.stemVolumes = [:]
        model.stemsMuted = []
        pitch.mutedStems = []
        model.stemsEngaged = false
        pitch.stemsEngaged = false
        endKaraokeRestart()
        updateStemMeters(shown: model.shown)
        setShift(0, relative: false, byPerson: false)
        if model.picking { dismiss() }
    }

    private func refreshStatus() {
        if mini.key != currentKey { mini.key = currentKey }
        syncQueueRow()
        fitChords()
        syncSavable()
        syncPauseStop()
        statusItem.update(shift: model.shift, from: shiftBase, heard: shiftBase.map { model.shown($0.transposed(by: model.shift)) }, kept: keptKey,
                          current: currentKey,
                          stems: model.stemsAdjusted ? Stem.shown.filter { !model.stemsMuted.contains($0) } : nil,
                          alwaysShown: prefs.menuBarIcon == .always, playing: filePlayer.hasSong, savable: model.savable, miniPlayer: prefs.miniPlayer,
                          hotkey: prefs.hotkey, micHotkey: prefs.micHotkey, recording: model.mic?.status)
    }

    private func logShift() {
        guard let base = shiftBase else { return }
        let shift = model.shift
        let gaps = pitch.running || pitch.gaps == 0 ? "" : ", \(pitch.gaps) gaps in the output"
        // With stems muted, the pitch change keeps running in the original key.
        if shift == 0, pitch.running, model.stemsEngaged { return log("original key, stems playing apart") }
        if shift == 0, pitch.running, lyricsDelayed { return log("original key, 30 seconds behind for the lyrics") }
        if shift == 0, pitch.running, pitch.correction != 0 {
            return log(String(format: "original key, corrected by %+.2f semitones for the tempo", pitch.correction))
        }
        log(shift == 0 ? "pitch change stopped\(gaps)" : "pitch change \(Shift.text(shift)): \(base.name) to \(model.shown(base.transposed(by: shift)).name)", .notice)
    }

    /// Cancels a listen in progress, or closes the result or the key picker. A pitch change keeps running.
    // MARK: Recording from the microphone

    private var micRecorder: MicRecorder?
    private var micHotKey: HotKey?
    /// The status that the menu bar shows, which it redraws only when this changes.
    private var micStatus: String?
    /// The recording from the microphone that Muskey Player plays.
    private var recordingPath: String?
    private var recordingRedetect: DispatchWorkItem?
    private var recoveredURL: URL?

    private func registerMicHotKey(_ shortcut: Shortcut?) {
        micHotKey = nil
        prefs.micHotkeyFailed = false
        guard let shortcut else { return }
        do {
            micHotKey = try HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in self?.toggleMic() }
        } catch {
            prefs.micHotkeyFailed = true
            log("\(error); is \(shortcut.symbols) taken by another app?", .error)
        }
    }

    /// The microphone hotkey, Microphone in Nothing playing and the menu: starts a recording, or stops the one that runs.
    private func toggleMic() {
        if micRecorder != nil { return stopMic() }
        if Self.stringOption("--mic-file") != nil { return startMic() }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startMic()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startMic() } else { self?.log("microphone: recording was not allowed", .error) }
                }
            }
        default:
            log("microphone: recording is not allowed in Privacy & Security", .error)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
        }
    }

    private func startMic() {
        guard micRecorder == nil else { return }
        if state != .idle { dismiss() }
        let recorder = MicRecorder(sensitivity: prefs.micSensitivity)
        recorder.onUpdate = { [weak self] analysis, seconds in
            guard let self, micRecorder === recorder, model.mic != nil else { return }
            model.mic?.analysis = analysis
            model.mic?.seconds = seconds
            if model.mic?.status != micStatus {
                micStatus = model.mic?.status
                refreshStatus()
            }
        }
        recorder.onKey = { [weak self] result, peak in
            guard let self, micRecorder === recorder, peak >= 0.0005, let key = DetectedKey(result) else { return }
            model.mic?.key = key
        }
        micRecorder = recorder
        model.mic = MicState(analysis: RecordingAnalysis(rate: 48000), hotkey: prefs.micHotkey.symbols)
        recorder.start(file: Self.stringOption("--mic-file"), deviceUID: Self.stringOption("--mic-device") ?? prefs.micDevice,
                       deviceName: prefs.micDeviceName.isEmpty ? nil : prefs.micDeviceName) { [weak self] error in
            guard let self, micRecorder === recorder else { return }
            if let error {
                model.mic?.failed = true
                return log("microphone: \(error.localizedDescription)", .error)
            }
            if let fallback = recorder.fallback {
                log("microphone: \(fallback.tried) is unavailable, recording from \(fallback.using)", .error)
            }
            log("microphone: recording from \(recorder.deviceName) to \(recorder.base)")
            model.mic?.device = recorder.deviceName
            model.mic?.tried = recorder.fallback?.tried
        }
        showMic()
        refreshStatus()
    }

    private func showMic() {
        guard model.mic != nil else { return }
        session += 1
        state = .showing
        stayOpen = true
        model.shown = true
        panel.setInteraction(clickable: true, keyboard: false)
        panel.present()
    }

    /// Stops the recording and plays it in Muskey Player once its song file is written.
    private func stopMic() {
        guard let recorder = micRecorder, model.mic?.finishing != true else { return }
        model.mic?.finishing = true
        log("microphone: stopping")
        let failed = model.mic?.failed == true
        recorder.stop { [weak self] url, analysis in
            guard let self else { return }
            micRecorder = nil
            micStatus = nil
            if !failed { prefs.micSensitivity = analysis.sensitivity }
            model.mic = nil
            refreshStatus()
            guard let url else {
                if analysis.duration > 0 {
                    log("microphone: the recording couldn't be written as a song file; its samples stay for the next launch", .error)
                }
                return dismiss()
            }
            log(String(format: "microphone: %.1f s in %@, %d parts of music", analysis.duration, url.lastPathComponent, analysis.regions().count))
            open([url])
        }
    }

    /// Cancel: the recording stops and its files are deleted.
    private func cancelMic() {
        guard let recorder = micRecorder, model.mic?.finishing != true else { return }
        log("microphone: cancelled, deleting \(recorder.base)")
        recorder.cancel { [weak self] in
            guard let self else { return }
            micRecorder = nil
            micStatus = nil
            model.mic = nil
            refreshStatus()
            dismiss()
        }
    }

    private func editMic(_ analysis: RecordingAnalysis) {
        guard let recorder = micRecorder else { return }
        model.mic?.analysis = analysis
        prefs.micSensitivity = analysis.sensitivity
        recorder.setSensitivity(analysis.sensitivity)
        recorder.setEdits(analysis.edits)
    }

    /// Muskey Player plays a recording from the microphone, whose parts show under the waveform.
    private func syncRecording() {
        let path = filePlayer.current?.path
        guard path != recordingPath else { return }
        recordingPath = path
        model.recording = path.flatMap(RecordingStore.analysis(forSong:))
    }

    /// A part of the recording that plays was added to the key or left out, or a sensitivity changed: the key is read
    /// again from the parts used for it, a moment after the last change.
    private func editRecording(_ analysis: RecordingAnalysis) {
        guard let path = recordingPath else { return }
        model.recording = analysis
        RecordingStore.save(analysis, forSong: path)
        prefs.micSensitivity = analysis.sensitivity
        recordingRedetect?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.redetect() }
        recordingRedetect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Recordings that a crash or a forced quit cut short become song files, and the pill at the top right plays the
    /// newest one.
    private func recoverRecordings() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let urls = RecordingStore.recover()
            guard let newest = urls.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                log("microphone: recovered \(urls.map(\.lastPathComponent).joined(separator: ", "))", .notice)
                recoveredURL = newest
                saveActivity = .recovered(name: newest.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private func dismiss() {
        stopCapture()
        analyzer = nil
        follow = nil
        stayOpen = false
        redetecting = false
        model.pending = nil
        if model.picking {
            if !panel.headless, NSApp.isActive, let lastOtherApp, lastOtherApp != .current { lastOtherApp.activate() }
            if pitchWanted {
                logShift()
            } else if pitch.running {
                pitch.stopSmoothly { [self] in logShift() }
            }
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.picking = false
        model.hovering = false
        model.moved = nil
        model.shortcuts = false
        model.openingGlass = nil
        model.lyricsShown = false
        model.lyricsFocus = false
        lyricsSong = nil
        lyricsSync.end()
        updateLyricsClock(shown: model.shown)
        panel.setInteraction(clickable: false, keyboard: false)
        session += 1
        state = .idle
        raisedForOpening = false
        let current = session
        panel.fadeOut { [self] in
            if session == current { panel.orderOut(nil); model.shown = false; model.overRecord = false; model.wave.clearEnd() }
        }
        autoListenIfNeeded()
    }

    /// Logs every time the main thread stops answering for half a second or more.
    private let hangWatch = HangWatch()

    /// The app delegate's lines go through here rather than straight to `appLog`, so that a line built from many parts
    /// stays one call, and so that `--log-keys` can add the host time to each of them.
    private func log(_ line: String, _ level: OSLogType = .info) {
        // With `--log-keys`, each line also gets the host time in seconds, to line up a recording with the keys.
        let host = Self.logKeys ? String(format: "  @%.3f", CACurrentMediaTime()) : ""
        appLog.log(level: level, "\(line, privacy: .public)\(host, privacy: .public)")
    }
}

extension EnvironmentValues {
    @Entry var renderingPreview = false
    /// The region loop of the song, for the time bar and the lyrics.
    @Entry var songLoop: LoopRegion?
    @Entry var songChords: SongChords?
    /// The Fix timing pill over lyrics with times, nil when no fit can run for the song.
    @Entry var lyricsTiming: LyricsTimingPill?
}

/// `--render <dir>` writes a PNG of each HUD state over a light and a dark backdrop, to check the design without the screen.
/// The mini player on each side of its record, with pills on the rim, as a plain vinyl, and the editor of Settings.
@MainActor func renderMiniPreviews(to dir: String) {
    let model = HUDSample.model(card: false, relative: false)
    model.tempo = SongTempo(song: nil, bpm: 124)
    model.queue = HUDSample.queue
    model.queueCurrent = model.queue[1].id
    func makeBackground(_ material: MiniMaterial, roundness: Double = 1, tint: (Double, Double, Double, Double)? = nil) -> MiniBackground {
        var background = MiniBackground()
        background.material = material
        background.roundness = roundness
        if let tint {
            background.tinted = true
            (background.red, background.green, background.blue, background.opacity) = tint
        }
        return background
    }
    let plain = MiniLayout(line: [], track: false, artist: false, album: false)
    let teal = (0.2, 0.49, 0.49, 0.55)
    let ember = (0.36, 0.09, 0.15, 0.4)
    // Every variant sets its background, so none of them shows the one saved in Settings.
    let variants: [(String, MiniTextSide, MiniLayout, MiniBackground)] = [
        ("below", .below, MiniLayout(), MiniBackground()),
        ("above", .above, MiniLayout(), MiniBackground()),
        ("right", .right, MiniLayout(), MiniBackground()),
        ("left", .left, MiniLayout(), MiniBackground()),
        ("pills", .below, MiniLayout(top: .key, bottom: .tempo, line: [.next]), MiniBackground()),
        ("plain", .below, plain, MiniBackground()),
        ("tempo-only", .below, MiniLayout(bottom: .tempo, line: [], track: false, artist: false, album: false), MiniBackground()),
        ("left-long", .left, MiniLayout(), MiniBackground()),
        ("right-long", .right, MiniLayout(line: [.key, .tempo, .timeLeft]), MiniBackground()),
        ("left-short", .left, MiniLayout(), MiniBackground()),
        ("below-long", .below, MiniLayout(), MiniBackground()),
        ("bg-glass-below", .below, MiniLayout(), makeBackground(.glass)),
        ("bg-glass-below-long", .below, MiniLayout(), makeBackground(.glass)),
        ("bg-glass-above-long", .above, MiniLayout(), makeBackground(.glass, tint: ember)),
        ("bg-thick-right", .right, MiniLayout(), makeBackground(.thick)),
        ("bg-thin-right-long", .right, MiniLayout(line: [.key, .tempo, .timeLeft]), makeBackground(.thin, roundness: 0.5)),
        ("bg-colour-left-short", .left, MiniLayout(), makeBackground(.colour, roundness: 0, tint: teal)),
        ("bg-thick-left-short", .left, MiniLayout(line: [.key, .tempo, .timeLeft]), makeBackground(.ultraThick)),
        ("bg-colour-left-long", .left, MiniLayout(), makeBackground(.colour, roundness: 0, tint: teal)),
        ("bg-clear-pills", .below, MiniLayout(top: .key, bottom: .tempo, line: [.next]), makeBackground(.clearGlass, roundness: 0.35, tint: ember)),
        ("bg-plain-circle", .below, plain, makeBackground(.glass)),
        ("bg-glass-pills", .below, MiniLayout(top: .key, bottom: .tempo, line: [.next]), makeBackground(.glass)),
        ("bg-glass-plain-pills", .below, MiniLayout(top: .key, bottom: .tempo, line: [], track: false, artist: false, album: false), makeBackground(.glass)),
        ("bg-plain-square", .below, MiniLayout(bottom: .tempo, line: [], track: false, artist: false, album: false), makeBackground(.colour, roundness: 0.25, tint: teal)),
        ("bg-mint-below", .below, MiniLayout(line: [.key, .speed, .timeLeft]), makeBackground(.colour, roundness: 0.35, tint: (0.9, 1, 0.93, 1))),
        ("bg-yellow-right", .right, MiniLayout(), makeBackground(.thick, roundness: 0.6, tint: (1, 0.85, 0.3, 0.85))),
    ]
    for (name, side, layout, background) in variants {
        let sample = HUDSample.track
        model.track = name.hasSuffix("-long")
            ? NowPlaying.Track(title: "Paper Lanterns (feat. Someone With a Long Name and Another One)", artist: sample.artist, album: sample.album,
                               duration: sample.duration, elapsed: sample.elapsed, timestamp: sample.timestamp, rate: 0, bundleID: nil)
            : name.hasSuffix("-short")
            ? NowPlaying.Track(title: "Tide", artist: "Mira Vale", album: "Low Tide Radio",
                               duration: sample.duration, elapsed: sample.elapsed, timestamp: sample.timestamp, rate: 0, bundleID: nil)
            : sample
        let mini = MiniState()
        mini.key = DetectedKey(pitchClass: 1, minor: true)
        mini.side = side
        mini.layout = layout
        mini.background = background
        mini.songOnRecord = false
        let view = MiniPlayerView(model: model, mini: mini)
            .background(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.5), Color(red: 0.62, green: 0.55, blue: 0.5)], startPoint: .top, endPoint: .bottom))
            .environment(\.renderingPreview, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "mini-\(name).png"))
        }
    }
    // The song on the record: three, two and one lines, long lines (a title of 72 characters), the smallest and the
    // largest record, a light cover, and pills beside the record, each over a light and a dark wallpaper.
    let darkCover = model.artwork
    let lightCover = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
        NSGradient(colors: [NSColor(white: 0.99, alpha: 1), NSColor(calibratedRed: 1, green: 0.93, blue: 0.74, alpha: 1)])?.draw(in: rect, angle: 90)
        NSColor(calibratedRed: 0.97, green: 0.83, blue: 0.52, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 160, y: 170, width: 90, height: 90)).fill()
        return true
    }
    let noAlbum = MiniLayout(line: [], track: true, artist: true, album: false)
    let titleOnly = MiniLayout(line: [], track: true, artist: false, album: false)
    let full = MiniLayout(line: [])
    let records: [(String, MiniLayout, Double, Bool, NSImage?)] = [
        ("record-3", full, 1, false, darkCover), ("record-2", noAlbum, 1, false, darkCover), ("record-1", titleOnly, 1, false, darkCover),
        ("record-long", full, 1, true, darkCover), ("record-1-long", titleOnly, 1, true, darkCover),
        ("record-small", full, MiniPlayerView.scales.lowerBound, false, darkCover), ("record-small-long", full, MiniPlayerView.scales.lowerBound, true, darkCover),
        ("record-large", full, MiniPlayerView.scales.upperBound, false, darkCover), ("record-large-long", full, MiniPlayerView.scales.upperBound, true, darkCover),
        ("record-light-cover", full, 1, false, lightCover), ("record-light-cover-long", full, 1, true, lightCover),
        ("record-pills", MiniLayout(line: [.key, .tempo, .timeLeft]), 1, false, darkCover),
        // A single pill hangs from the record's edge; two pills, or one in the line and one on the rim, stay under it.
        ("record-hang", MiniLayout(line: [.key]), 1, false, darkCover), ("record-hang-bg", MiniLayout(line: [.key]), 1, false, darkCover),
        ("record-hang-small", MiniLayout(line: [.key]), MiniPlayerView.scales.lowerBound, false, darkCover),
        ("record-hang-large", MiniLayout(line: [.key]), MiniPlayerView.scales.upperBound, false, darkCover),
        ("record-two-small", MiniLayout(line: [.key, .tempo]), MiniPlayerView.scales.lowerBound, false, darkCover),
        ("record-two-large", MiniLayout(line: [.key, .tempo]), MiniPlayerView.scales.upperBound, false, darkCover),
        ("record-rim-line", MiniLayout(bottom: .tempo, line: [.key]), 1, false, darkCover),
        ("record-hang-round", MiniLayout(line: [.key]), MiniPlayerView.scales.lowerBound, false, darkCover),
        ("record-hang-next", MiniLayout(line: [.next]), MiniPlayerView.scales.lowerBound, false, darkCover),
        ("record-hang-next-round", MiniLayout(line: [.next]), MiniPlayerView.scales.lowerBound, false, darkCover),
        // The pointer over the record: the lines make way for the buttons.
        ("record-hover", full, 1, false, darkCover),
    ]
    for (name, layout, scale, long, cover) in records {
        let sample = HUDSample.track
        model.track = long
            ? NowPlaying.Track(title: "Paper Lanterns Over the Harbour (Extended Version, Live at Harbour Hall)", artist: "Mira Vale and the Low Tide Orchestra",
                               album: "Low Tide Radio: The Complete Harbour Sessions", duration: sample.duration, elapsed: sample.elapsed,
                               timestamp: sample.timestamp, rate: 0, bundleID: nil)
            : sample
        model.artwork = cover
        MiniPlayerView.renderScale = scale
        for (scheme, wallpaper) in [("light", Color(white: 0.86)), ("dark", Color(white: 0.12))] {
            let mini = MiniState()
            mini.key = DetectedKey(pitchClass: 1, minor: true)
            mini.side = .below
            mini.layout = layout
            mini.songOnRecord = true
            if name.hasSuffix("-bg") { mini.background = makeBackground(.glass, roundness: 0.6, tint: ember) }
            if name.hasSuffix("-round") { mini.background = makeBackground(.colour, roundness: 1, tint: teal) }
            let view = MiniPlayerView(model: model, mini: mini)
                .background(wallpaper)
                .environment(\.renderingPreview, true)
                .environment(\.recordHovered, name == "record-hover")
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "mini-\(name)-\(scheme).png"))
            }
        }
    }
    MiniPlayerView.renderScale = nil
    model.artwork = darkCover
    model.track = HUDSample.track
    // Settings > Mini player > Record, in both schemes.
    for scheme in [ColorScheme.light, .dark] {
        let form = Form {
            Section("Record") { MiniRecordSizeRow(scale: .constant(1.25)) }
        }
        .formStyle(.grouped)
        renderOffscreen(form, size: CGSize(width: 520, height: 110), scheme: scheme,
                        to: URL(fileURLWithPath: dir).appending(path: "mini-record-size-\(scheme == .dark ? "dark" : "light").png"))
    }
    // The editor once more with the song on the record, where only the line's pills stay under it.
    for (name, background) in [("mini-editor", MiniBackground()), ("mini-editor-bg", makeBackground(.glass, roundness: 0.6, tint: ember)),
                               ("mini-editor-record", MiniBackground())] {
        let mini = MiniState()
        mini.layout = MiniLayout(top: .key, line: [.tempo, .pitch])
        mini.background = background
        mini.songOnRecord = name == "mini-editor-record"
        let editor = MiniPlayerView(model: model, mini: mini, editing: true)
            .padding(18)
            .background(Color(red: 0.16, green: 0.13, blue: 0.14))
            .environment(\.renderingPreview, true)
        let renderer = ImageRenderer(content: editor)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
    // Settings > Mini player > Background for a tinted glass, a colour and none. Its pickers, sliders and switches are
    // AppKit controls, which ImageRenderer leaves out, so these go through a window that never shows on screen.
    for scheme in [ColorScheme.light, .dark] {
        for (name, value) in [("glass", makeBackground(.glass, roundness: 0.6, tint: ember)), ("glass-untinted", makeBackground(.thin)),
                              ("colour", makeBackground(.colour, roundness: 0.3, tint: teal)), ("none", MiniBackground())] {
            let form = Form {
                Section("Background") { MiniBackgroundRows(background: .constant(value)) }
            }
            .formStyle(.grouped)
            renderOffscreen(form, size: CGSize(width: 520, height: 210), scheme: scheme,
                            to: URL(fileURLWithPath: dir).appending(path: "mini-background-\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
    // Settings > General > Menu bar icon, with the wallpaper behind each tile.
    for scheme in [ColorScheme.light, .dark] {
        var icon = MenuBarIcon.always
        let form = Form {
            Section("Menu bar icon") { MenuBarIconTiles(icon: Binding(get: { icon }, set: { icon = $0 })) }
        }
        .formStyle(.grouped)
        renderOffscreen(form, size: CGSize(width: 520, height: 200), scheme: scheme,
                        to: URL(fileURLWithPath: dir).appending(path: "menubar-icon-\(scheme == .dark ? "dark" : "light").png"))
    }
    // Settings > Mini player > Layout, with the wallpaper behind each tile.
    for scheme in [ColorScheme.light, .dark] {
        var direction = MiniDirection.onRecord
        let form = Form {
            Section("Layout") { MiniDirectionTiles(direction: Binding(get: { direction }, set: { direction = $0 })) }
        }
        .formStyle(.grouped)
        renderOffscreen(form, size: CGSize(width: 520, height: 300), scheme: scheme,
                        to: URL(fileURLWithPath: dir).appending(path: "mini-layout-\(scheme == .dark ? "dark" : "light").png"))
    }
    // The whole editor of Settings > Mini player, with its tray, in both schemes.
    for scheme in [ColorScheme.light, .dark] {
        let pane = MiniLayoutEditor(prefs: Preferences.shared)
            .frame(width: 440)
            .padding(18)
            .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
            .environment(\.colorScheme, scheme)
            .environment(\.renderingPreview, true)
        let renderer = ImageRenderer(content: pane)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "mini-settings-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}

/// Draws a view in a window that never shows on screen. Unlike ImageRenderer, this also draws AppKit controls.
@MainActor func renderOffscreen(_ view: some View, size: CGSize, scheme: ColorScheme, to url: URL) {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    // The Form lays its rows out over a few turns of the run loop.
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    window.contentView = nil
}

@MainActor func renderPreviews(to dir: String) {
    // `--render-only TEXT` renders only the states whose file name holds TEXT, and `--render-waveform FILE` draws the
    // waveform from a file of the waveform cache instead of the made-up one, for comparing a few variants on real songs.
    let only = TestFlags.value("--render-only")
    let realWaveform = TestFlags.value("--render-waveform").flatMap { FileManager.default.contents(atPath: $0) }
        .flatMap { try? JSONDecoder().decode(SongWaveform.self, from: $0) }
    if only == nil || only?.hasPrefix("mini") == true { renderMiniPreviews(to: dir) }
    let csm = EKResult(pitchClass: 1, minor: 1, strength: 0.8)
    let a = EKResult(pitchClass: 9, minor: 0, strength: 0.8)
    // Name, phase, key, progress, shift, picking, relative, Lock Key.
    let states: [(String, HUDModel.Phase, EKResult?, Double, Int, Bool, Bool, Bool)] = [
        ("listening-start", .listening, nil, 0.1, 0, false, false, false),
        ("listening-Csm", .listening, csm, 0.5, 0, false, false, false),
        ("listening-Csm+2", .listening, csm, 0.5, 2, false, false, false),
        ("done-Csm", .done, csm, 1, 0, false, false, false),
        ("done-Bb", .done, EKResult(pitchClass: 10, minor: 0, strength: 0.8), 1, 0, false, false, false),
        ("done-G", .done, EKResult(pitchClass: 7, minor: 0, strength: 0.8), 1, 0, false, false, false),
        ("done-Csm+2", .done, csm, 1, 2, false, false, false),
        ("listening-picking-Csm+2", .listening, csm, 0.4, 2, true, false, false),
        ("picking-Csm", .done, csm, 1, 0, true, false, false),
        ("picking-Csm-3", .done, csm, 1, -3, true, false, false),
        ("picking-Csm+7", .done, csm, 1, 7, true, false, true),
        ("picking-G+1", .done, EKResult(pitchClass: 7, minor: 0, strength: 0.8), 1, 1, true, false, false),
        // Control-C from A major: C minor in the second row, the relative of E♭ major, kept for the next songs.
        ("picking-A-to-Cm", .done, a, 1, -6, true, true, true),
        // A new song with C minor kept, before its first estimate: it plays in its own key, and the row still has the
        // last song's keys.
        ("listening-waiting-Cm", .listening, a, 0.1, 0, true, false, true),
        ("silent", .silent, nil, 0, 0, false, false, false),
        ("idle", .idle, nil, 0, 0, false, false, false),
    ]
    // Each state with no song, then with a song and its cover, then with a song that has no cover.
    let track = NowPlaying.Track(title: "Paper Lanterns", artist: "Mira Vale", album: "Low Tide Radio", duration: 238, elapsed: 102, timestamp: Date().timeIntervalSince1970, rate: 0, bundleID: nil)
    let cover = sampleCover()
    // Made-up lines for the lyrics panel.
    let sampleLyrics: [(Double, String)] = [
        (12, "Paper lanterns over the harbour"), (16.5, "Drifting slow across the tide"), (21, "Every light a little promise"),
        (25.5, "Burning low on the other side"), (30, ""), (34, "Hold the line until the morning"),
        (38.5, "Count the boats along the shore"), (43, "If the wind should change direction"), (47.5, "We'll be singing it once more"),
    ]
    var long = track
    long.title = "Paper Lanterns (Extended Version, Recorded Live at the Harbour Hall)"
    let songs: [(String, NowPlaying.Track?, NSImage?)] = [("", nil, nil), ("-song", track, cover), ("-nocover", track, nil), ("-long", long, cover)]
    // The single card for the states that change it most, with a song, and the shortcuts once from each layout.
    let cardStates = ["listening-start", "listening-Csm", "done-Csm+2", "picking-Csm-3", "picking-A-to-Cm", "listening-waiting-Cm", "silent"]
    for (name, phase, result, progress, shift, picking, relative, keep) in states {
        for (suffix, song, artwork) in songs {
        for layout in ["", "-card", "-card-shortcuts", "-shortcuts"] {
            if layout.isEmpty {
                // Only a few states with a song, and the cover-less record once.
                if song != nil, !["listening-start", "done-Csm+2", "picking-Csm-3", "picking-A-to-Cm", "listening-waiting-Cm"].contains(name) { continue }
                if song != nil, artwork == nil || suffix == "-long", name != "picking-Csm-3" { continue }
            } else {
                guard cardStates.contains(name), suffix == "-song" || (suffix.isEmpty && ["listening-start", "silent"].contains(name)) else { continue }
                if layout.hasSuffix("-shortcuts"), name != "picking-Csm-3" { continue }
            }
        // Two states once more without the relative keys, once more with Option held, and once with the lyrics.
        for variant in ["", "-clean", "-option", "-lyrics", "-lyrics-estimated", "-lyrics-heard", "-lyrics-downloading", "-lyrics-loading",
                        "-lyrics-missing", "-lyrics-instrumental", "-lyrics-failed", "-lyrics-nosong", "-stems", "-stems-solo", "-stems-volume", "-stems-waiting",
                        "-stems-failed", "-stems-button", "-stems-option", "-skip", "-skip-paused", "-tempo", "-tempo-return", "-saving", "-recording", "-mic", "-mic-fallback", "-mic-recording", "-lyrics-focus-skip", "-labels", "-lyrics-stems", "-lyrics-stems-button", "-lyrics-focus", "-lyrics-focus-stems", "-lyrics-focus-separate", "-lyrics-focus-keys", "-paused", "-lyrics-focus-paused", "-lyrics-waiting", "-lyrics-focus-waiting", "-lyrics-focus-rewind", "-lyrics-focus-restart", "-lyrics-focus-loading", "-lyrics-focus-ending", "-arriving", "-lyrics-focus-arriving", "-stems-idle", "-lyrics-idle", "-lyrics-focus-idle", "-key-hover", "-waveform-off", "-waveform-strip", "-waveform-zoom", "-waveform-lanes", "-waveform-streamed", "-waveform-stems", "-waveform-hover", "-waveform-hover-zoom", "-waveform-hover-loop-zoom", "-lanes-hover-loop-zoom", "-waveform-hover-loop", "-waveform-hover-stems", "-lanes-one", "-lanes-four", "-lanes-zoom", "-lanes-loop", "-lanes-loop-zoom", "-lanes-stems", "-lanes-loop-hover", "-lanes-separating", "-loop", "-loop-armed", "-loop-zoom", "-loop-hover", "-stems-loop-hover", "-lyrics-loop", "-lyrics-focus-loop", "-lyrics-chords", "-lyrics-focus-chords", "-lyrics-seek", "-lyrics-stems-seek", "-lyrics-stems-chords", "-queue", "-queue-labels", "-queue-drop", "-queue-drop-next", "-queue-drop-now", "-drop-live", "-notes-picker", "-notes-picker-region", "-notes-picker-whole", "-notes-outside-region", "-notes-outside-region-whole", "-notes-download", "-notes-outside", "-notes-outside-none", "-notes-outside-long", "-shift", "-lyrics-fix", "-lyrics-fix-working", "-lyrics-fix-checking", "-lyrics-fix-found", "-lyrics-fix-applied", "-lyrics-fix-ontime", "-lyrics-fix-unknown", "-lyrics-fix-failed", "-lyrics-focus-fix-found", "-lyrics-fix-hover", "-lyrics-fix-found-hover", "-lyrics-fix-applied-hover", "-lyrics-fix-idle", "-lyrics-fix-idle-hover", "-lyrics-fix-nudged", "-lyrics-focus-fix-found-hover"] {
            // The stems once without a record too, where the key column sets the height of the wide glass.
            let noRecord = suffix.isEmpty && layout.isEmpty && ["-stems", "-stems-button"].contains(variant)
            // Karaoke's record once more with a long title, and with no cover.
            let karaokeSong = variant == "-lyrics-focus" && ["-long", "-nocover"].contains(suffix)
            // The glyphs on the record once more over a plain label, the lightest cover there is.
            let lightCover = variant.hasPrefix("-skip") && suffix == "-nocover"
            if !variant.isEmpty, !["picking-Csm-3", "picking-A-to-Cm"].contains(name) || (suffix != "-song" && !noRecord && !karaokeSong && !lightCover) || layout.hasSuffix("-shortcuts") { continue }
            if variant.hasPrefix("-lyrics") || variant.hasPrefix("-stems"), name != "picking-Csm-3" { continue }
            // A trailing $ asks for that one state alone.
            if let only, only.hasSuffix("$") ? "\(name)\(suffix)\(layout)\(variant)" != only.dropLast() : !"\(name)\(suffix)\(layout)\(variant)".contains(only) { continue }
        for (scheme, backdrop) in [("light", Color(white: 0.93)), ("dark", Color(white: 0.12))] {
            let model = HUDModel()
            // The renders show both rows, and the "-clean" ones the single row that new installs start with.
            model.relativeKeys = variant != "-clean"
            // The renders show the hints as the pointer over the HUD does, and the "-idle" ones as they are without it.
            model.keysActive = !variant.hasSuffix("-idle")
            // A new song that is heard in 4 of its 6 seconds of waiting.
            if variant.hasSuffix("-arriving") { model.songArriving = Date().addingTimeInterval(-2) ... Date().addingTimeInterval(4) }
            model.flipped = variant == "-option" || variant == "-stems-option"
            model.accidentals = variant == "-shift"
            // A song in another key can be saved, so its renders show the Save button.
            model.savable = shift != 0 && suffix == "-song"
            if variant.hasPrefix("-lyrics") {
                model.lyricsShown = true
                let text = sampleLyrics.map { "[00:\(String(format: "%05.2f", $0.0))] \($0.1)" }.joined(separator: "\n")
                var lyrics = variant == "-lyrics" || variant.hasSuffix("-loop") || variant.hasSuffix("-chords") || variant.contains("-fix") ? Lyrics.parse(lrc: text) : Lyrics.estimate(plain: sampleLyrics.map(\.1).joined(separator: "\n"), duration: 238)
                lyrics?.source = variant.hasPrefix("-lyrics-focus") ? .lrcRed(isrc: "USQX91300108") : .lrclib
                model.lyrics = switch variant {
                case "-lyrics-loading": .loading
                case "-lyrics-missing": .notFound
                case "-lyrics-instrumental": .instrumental
                case "-lyrics-failed": .failed
                case "-lyrics-nosong": .none
                case "-lyrics-heard": lyrics.map { .found(Lyrics(lines: $0.lines, timing: .heard)) } ?? .notFound
                // Whisper waits for its first phrase, 23 seconds before the song steps back.
                case "-lyrics-waiting", "-lyrics-focus-waiting": .found(Lyrics(lines: [], timing: .written))
                default: lyrics.map { .found($0) } ?? .notFound
                }
                model.lyricsDownloading = variant == "-lyrics-downloading"
                // The Fix timing pill in each of its states, beside the credit of lyrics with times.
                model.lyricsTiming = switch variant {
                case "-lyrics-fix": .unchecked
                case "-lyrics-fix-working": .working(0.42)
                case "-lyrics-fix-checking": .working(nil)
                case "-lyrics-fix-found", "-lyrics-focus-fix-found", "-lyrics-focus-fix-found-hover": .found(3.98)
                case "-lyrics-fix-applied", "-lyrics-fix-applied-hover": .found(3.98)
                case "-lyrics-fix-found-hover": .found(3.98)
                case "-lyrics-fix-hover": .unchecked
                case "-lyrics-fix-idle", "-lyrics-fix-idle-hover", "-lyrics-fix-nudged": .idle
                case "-lyrics-fix-ontime": .onTime
                case "-lyrics-fix-unknown": .unknown
                case "-lyrics-fix-failed": .failed
                default: nil
                }
                model.lyricsShift = variant.hasPrefix("-lyrics-fix-applied") ? 3.98 : variant == "-lyrics-fix-nudged" ? -1 : 0
                model.lyricsTimingKept = (variant.hasPrefix("-lyrics-fix") || variant.hasPrefix("-lyrics-focus-fix")) && !["-lyrics-fix", "-lyrics-fix-hover", "-lyrics-fix-idle", "-lyrics-fix-idle-hover"].contains(variant)
                model.lyricsTimingHover = variant.hasSuffix("-hover")
                model.lyricsWriting = variant.hasSuffix("-waiting")
                model.lyricsWaiting = variant.hasSuffix("-waiting") ? 23 : nil
                model.lyricsFocus = variant.hasPrefix("-lyrics-focus")
                // The key row and the instruments as the pointer over the key or the cover shows them.
                model.karaokeKeys = variant == "-lyrics-focus-keys"
                model.karaokeStems = variant == "-lyrics-focus-stems" || variant == "-lyrics-focus-separate"
                model.lyricLine = 3
                // Karaoke's countdown while the vocals are separated: before the song rewinds to where karaoke opened,
                // before it starts over, and while the model loads.
                model.karaokeCountdown = switch variant {
                case "-lyrics-focus-rewind": KaraokeCountdown(seconds: 4, total: 6, restart: false, rewind: 6)
                case "-lyrics-focus-restart": KaraokeCountdown(seconds: 4, total: 6, restart: true, rewind: 6)
                case "-lyrics-focus-loading": KaraokeCountdown(seconds: nil, total: 6, restart: false, rewind: nil)
                // The last second, with the ring at its reddest.
                case "-lyrics-focus-ending": KaraokeCountdown(seconds: 1, total: 6, restart: true, rewind: 6)
                default: nil
                }
            }
            if variant.contains("-stems") || variant == "-lyrics-focus-separate" {
                model.stemsAvailable = true
                // Vocals and drums muted, or only the guitar playing, with the levels of a loud passage. The button
                // shows before the song is separated.
                switch variant {
                case "-stems-solo": model.stemsMuted = Set(Stem.allCases).subtracting([.guitar])
                case "-stems-failed": model.stemsFailed = true
                case "-stems-button", "-lyrics-stems-button", "-lyrics-focus-separate": break
                default: model.stemsMuted = [.vocals, .drums]
                }
                model.stemsEngaged = variant != "-stems-failed" && !variant.hasSuffix("-stems-button") && variant != "-lyrics-focus-separate"
                model.stemsProgress = variant == "-stems-waiting" ? .separating(0.6) : nil
                // Made-up levels of a loud passage.
                if variant != "-stems-waiting" { model.stemMeters.levels = [0.13, 0.2, 0.025, 0.16, 0.05, 0.07, 0.09] }
                // Volumes from a scroll: louder bass, quieter piano and guitar, and a muted stem at another volume.
                if variant == "-stems-volume" { model.stemVolumes = [.bass: 1.35, .piano: 0.4, .guitar: 0.7, .drums: 0.6] }
            }
            model.card = layout.hasPrefix("-card")
            model.shortcuts = layout.hasSuffix("-shortcuts")
            model.phase = phase
            model.key = result.flatMap(DetectedKey.init)
            model.progress = progress
            model.shift = shift
            model.picking = picking
            model.relative = relative
            model.keepKey = keep
            model.track = song
            model.artwork = artwork
            // The made-up waveform, whole, zoomed in, in the lanes of the stems, or half heard as a song from another
            // player is while it plays.
            if var song {
                var waveform = HUDSample.waveform
                if variant == "-waveform-lanes" || variant == "-waveform-hover-stems" || variant.hasPrefix("-lanes") && variant != "-lanes-separating" {
                    // The guitar is silent for the first third of the song, and the winds are only the bleed of the
                    // other instruments, which the lanes draw as silence.
                    let count = waveform.levels.count
                    waveform.stems = Dictionary(uniqueKeysWithValues: Stem.allCases.map { stem in
                        (stem.rawValue, Data(waveform.levels.enumerated().map { i, level in
                            if stem == .winds { return UInt8(4 + i % 9) }
                            if stem == .guitar, i < count / 3 { return UInt8(3 + i % 7) }
                            return UInt8(max(1, Double(level) * (0.35 + 0.65 * abs(sin(Double(i) / Double(180 + stem.rawValue * 47))))))
                        }))
                    })
                }
                if variant == "-waveform-streamed" { for i in Int(Double(waveform.levels.count) * 0.46) ..< waveform.levels.count { waveform.levels[i] = 0 } }
                if let realWaveform {
                    waveform = realWaveform
                    song.duration = realWaveform.duration
                    song.elapsed = realWaveform.duration * 0.43
                    model.track = song
                }
                model.wave.waveform = waveform
            }
            model.waveformShown = variant != "-waveform-off"
            model.waveformStyle = variant == "-waveform-strip" ? .strip : .ribbon
            model.wave.zoom = variant == "-waveform-zoom" || variant == "-waveform-hover-zoom" || variant.hasSuffix("-zoom") && variant.hasPrefix("-lanes") ? 10 : 1
            model.wave.lanes = variant == "-waveform-lanes" || variant.hasPrefix("-lanes")
            // ⌥W waits for the stems of the whole song.
            model.wave.lanesSeparating = variant == "-lanes-separating" ? 0.42 : nil
            model.wave.laneStems = switch variant {
            case "-lanes-one": [.guitar]
            case "-lanes-four": [.vocals, .bass, .guitar, .winds]
            default: [.vocals, .guitar]
            }
            // A song from Muskey Player, which can seek, so the lyrics list ← → for 5 s.
            // The waveform's keys show its arrows only for a song that can move.
            if variant.hasSuffix("-seek") || variant.hasPrefix("-waveform-hover") || variant.hasPrefix("-lanes-hover") { model.seekable = true }
            // The keys of the waveform, which show while the pointer is over it.
            model.wave.hovered = variant.hasPrefix("-waveform-hover") || variant.hasPrefix("-lanes-hover")
            // The B end of the region loop under the pointer: its arrows, its time and the thicker line.
            LoopFlags.hoveredInRenders = variant.hasSuffix("-loop-hover") ? .end : nil
            model.wave.loopEnd = LoopFlags.hoveredInRenders
            // A region loop with the dashed lines of the presses, one still waiting for its end, and one over lyric lines.
            if variant.hasSuffix("loop") || variant.hasPrefix("-loop") || variant.hasSuffix("-loop-hover") || variant.hasPrefix("-lanes-loop")
                || variant.hasPrefix("-waveform-hover-loop") || variant.hasPrefix("-lanes-hover-loop") {
                model.loop = variant.contains("lyrics") ? LoopRegion(start: 16.5, end: 30)
                    : LoopRegion(start: 86.2, end: variant == "-loop-armed" ? nil : 110.4, startPress: 86.6, endPress: variant == "-loop-armed" ? nil : 110.1)
                if variant == "-loop-zoom" { model.wave.zoom = 6 }
                // A close-up that holds the loop still, with its bars numbered for the keys 1 to 9.
                if variant == "-waveform-hover-loop-zoom" { model.wave.zoom = 8 }
            }
            // Chords over the lyrics, two semitones down with a capo on the second fret.
            if variant.hasSuffix("-chords") {
                model.chords = [(0, 9, true), (8, 5, false), (12.5, 0, false), (16.6, 7, false), (21, 9, true), (25, 2, true), (29.2, 4, false), (33, 9, true),
                                (37, 5, false), (41.5, 0, false), (45, 7, false), (50, 4, false)].map { ChordMark(time: $0.0, root: $0.1, minor: $0.2) }
                model.shift = -2
                model.capo = 2
            }
            // The queue on the back of the record, with two songs selected, and a drag of songs over the HUD.
            if variant.hasPrefix("-queue") {
                model.queue = HUDSample.queue
                model.queueCurrent = model.queue[1].id
                model.queueShown = variant == "-queue" || variant == "-queue-labels"
                model.queueSelection = variant == "-queue" ? [model.queue[3].id, model.queue[4].id] : []
                if variant.hasPrefix("-queue-drop") {
                    model.dropTargeted = true
                    model.dropZone = variant == "-queue-drop-next" ? .addNext : variant == "-queue-drop-now" ? .playNow : .add
                }
            }
            // A drag of songs over a song from another app, which has no queue: Play Now alone.
            model.otherPlayer = variant == "-drop-live"
            if variant == "-drop-live" { model.dropTargeted = true }
            // T's stem picker, with both models installed, with a model to download, and for a song outside Muskey
            // Player.
            if variant.hasPrefix("-notes") {
                // A song from another app: 72 seconds heard, nothing heard yet, and one too long to keep.
                let outside = variant.hasPrefix("-notes-outside")
                // The live picker picks Vocals, the longest name for its button.
                // A region loop of 12.5 seconds, picked first, and the whole song picked in its place.
                let region = variant.contains("-region") || variant == "-notes-picker-whole"
                model.notesPicking = NotesPicking(stems: [.vocals, .bass, .guitar, .piano, .winds, .other], selected: outside ? .vocals : .bass,
                                                  available: variant != "-notes-outside-long", duration: variant == "-notes-outside-long" ? 1500 : song?.duration ?? 222,
                                                  heard: outside ? (variant == "-notes-outside" || region ? 72 : 0) : nil,
                                                  missing: variant == "-notes-download" ? 33_437_377 : nil, region: region ? 62.4 ... 74.9 : nil,
                                                  wholeSong: variant.hasSuffix("-whole"))
            }
            if variant == "-waveform-stems" {
                model.stemsAvailable = true
                model.stemsEngaged = true
                model.stemsMuted = [.vocals]
                model.stemMeters.levels = [0.13, 0.2, 0.025, 0.16, 0.05, 0.07, 0.09]
            }
            // A finished listen found the tempo of the song, and a listen still running hasn't yet.
            if phase == .done { model.tempo = SongTempo(song: song?.song, bpm: 124) }
            // A song in Muskey Player at 85 % of its speed.
            model.speedAdjustable = variant.hasPrefix("-tempo")
            model.speed = variant == "-tempo" ? 0.85 : 1
            // A slowed song on its way back to 100 %, with the ring on the tempo pill part filled.
            model.tempoReturn = variant == "-tempo-return" ? 0.6 : nil
            // A save of the song in progress, rendered or recorded, which covers the HUD.
            // A recording from the microphone: 54 s of talk, a song and noise, while it records, and once it plays.
            model.mic = variant.hasPrefix("-mic") && variant != "-mic-recording"
                ? MicState(analysis: RecordingAnalysis.sample(), seconds: 54, key: variant == "-mic" ? DetectedKey(pitchClass: 1, minor: true) : nil,
                           hotkey: Shortcut.mic.symbols, device: "MacBook Pro Microphone", tried: variant == "-mic-fallback" ? "Studio Display Microphone" : nil)
                : nil
            model.recording = variant == "-mic-recording" ? RecordingAnalysis.sample() : nil
            model.saving = variant == "-saving" ? SavingState(name: "Paper Lanterns (C minor, 90%)", progress: 0.42, left: nil)
                : variant == "-recording" ? SavingState(name: "Paper Lanterns (no vocals)", progress: nil, left: "2:15 left") : nil
            // The arm on the record, or lifted off it with the pause glyph that Space shows.
            model.playing = !variant.hasSuffix("-paused")
            if variant.hasSuffix("-paused") { model.playFlash = PlayFlash(playing: false, id: 1) }
            if variant.hasSuffix("-skip") { model.playFlash = PlayFlash(playing: true, id: 1, skip: 1) }
            // The pill that Lock Key shows after it moved a new song.
            if name == "picking-A-to-Cm" { model.moved = KeyMove(from: DetectedKey(pitchClass: 9, minor: false), to: DetectedKey(pitchClass: 0, minor: true)) }
            if name == "listening-waiting-Cm" { model.pending = DetectedKey(pitchClass: 0, minor: true) }
            let view = HUDView(model: model)
                .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
                .background(backdrop)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                .environment(\.renderingPreview, true)
                .environment(\.cornerLabelsShown, variant == "-labels" || variant == "-queue-labels")
                .environment(\.recordHovered, variant.contains("-skip"))
                .environment(\.keyPillExpanded, variant == "-key-hover")
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)\(suffix)\(layout)\(variant)-\(scheme).png"))
            }
        }
        }
        }
        }
    }
    // The pill at the top right of the screen for a song that Muskey opens.
    let pills: [(String, OpenActivity)] = [
        ("pill-downloading", .opening(step: .downloading, name: "Never Gonna Give You Up", artist: "Rick Astley", progress: 0.45)),
        ("pill-starting", .opening(step: .reading, name: "youtube.com", progress: nil)),
        ("pill-installing", .installing(progress: 0.3)), ("pill-failed", .failed(name: "Never Gonna Give You Up")),
        ("pill-needs-downloader", .needsDownloader(name: "youtube.com")), ("pill-install-failed", .installFailed), ("pill-unplayable", .unplayable(name: "Concert.mkv")),
    ]
    // Open URL, empty, with a link that was downloaded before and the songs under it, and after Return on text
    // that can't be opened.
    let recent = [
        OpenLocationModel.Recent(title: "Never Gonna Give You Up", artist: "Rick Astley", site: "youtube.com"),
        OpenLocationModel.Recent(title: "Midnight City", artist: "M83", site: "soundcloud.com"),
        OpenLocationModel.Recent(title: "Around the World", artist: "Daft Punk", site: "youtube.com"),
    ]
    let locations: [(String, String, [OpenLocationModel.Recent], Bool)] = [
        ("open-location-empty", "", [], false),
        ("open-location-recent", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", recent, false),
        ("open-location-error", "not a link", recent, true),
    ]
    for (name, text, songs, submit) in locations {
        for (scheme, backdrop) in [("light", Color(white: 0.85)), ("dark", Color(white: 0.12))] {
            let model = OpenLocationModel()
            model.reset(text: text, recent: songs)
            if submit { model.submit() }
            let view = OpenLocationView(model: model)
                .frame(width: OpenLocationView.width + 40, height: songs.isEmpty ? 140 : 330)
                .padding(.top, 20)
                .background(backdrop)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                .environment(\.renderingPreview, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(scheme).png"))
            }
        }
    }
    // The HUD while a song opens, in the wide layout and on the card: each step, and each failure. With `-song`, a
    // song plays meanwhile and keeps its record, and with `-held`, the glass keeps the size that it had with that
    // record, here the size of a result with its keys.
    let openings: [(String, OpenActivity)] = [
        ("opening-reading", .opening(step: .reading, name: "youtube.com", progress: nil)),
        ("opening-downloading", .opening(step: .downloading, name: "Never Gonna Give You Up", artist: "Rick Astley", progress: 0.45)),
        ("opening-downloading-file", .opening(step: .downloading, name: "Moonlight Sonata", progress: 0.62)),
        ("opening-downloading-long", .opening(step: .downloading, name: "Paper Lanterns (Extended Version, Recorded Live at the Harbour Hall)",
                                              artist: "Mira Vale and the Low Tide Radio Orchestra of the Harbour Hall", progress: 0.07)),
        ("opening-converting", .opening(step: .converting, name: "Never Gonna Give You Up", artist: "Rick Astley", progress: nil)),
        ("opening-network-file", .opening(step: .reading, name: "Harbour Hall rehearsal take 3", progress: nil)),
        ("opening-installing", .installing(progress: 0.3)), ("opening-updating", .opening(step: .updating, name: "youtube.com", progress: nil)),
        ("opening-failed", .failed(name: "Never Gonna Give You Up")), ("opening-needs-downloader", .needsDownloader(name: "youtube.com")),
        ("opening-install-failed", .installFailed), ("opening-unplayable", .unplayable(name: "Concert.mkv")),
        ("opening-failed-long", .failed(name: "Paper Lanterns (Extended Version, Recorded Live at the Harbour Hall)")),
    ]
    let overSong: Set<String> = ["opening-reading", "opening-downloading", "opening-downloading-file", "opening-downloading-long", "opening-converting",
                                 "opening-installing", "opening-failed", "opening-unplayable"]
    for (name, activity) in openings {
        for song in ["", "-song", "-held"] where song.isEmpty || overSong.contains(name) && (song == "-song" || name.hasSuffix("downloading") || name.hasSuffix("failed")) {
        for layout in ["", "-card"] {
            if let only, !"\(name)\(song)\(layout)".contains(only.hasSuffix("$") ? String(only.dropLast()) : only) { continue }
            for (scheme, backdrop) in [("light", Color(white: 0.93)), ("dark", Color(white: 0.12))] {
                let model = HUDModel()
                model.phase = song.isEmpty ? .idle : .done
                model.card = layout == "-card"
                model.opening = OpeningState(activity)
                if !song.isEmpty {
                    model.track = HUDSample.track
                    model.artwork = HUDSample.cover
                    model.playing = true
                    model.openingOverSong = true
                    if song == "-held" { model.openingGlass = layout == "-card" ? CGSize(width: 344, height: 498) : CGSize(width: 786, height: 314) }
                }
                let view = HUDView(model: model)
                    .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
                    .background(backdrop)
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    .environment(\.renderingPreview, true)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)\(song)\(layout)-\(scheme).png"))
                }
            }
        }
        }
    }
    // Nothing plays, and the record turned over to the recents, in both layouts, with the pointer over a row once.
    for (name, hover) in [("idle-recents", false), ("idle-recents-hover", true), ("idle-recents-front", false)] {
        for layout in ["", "-card"] {
            if let only, !"\(name)\(layout)".contains(only.hasSuffix("$") ? String(only.dropLast()) : only) { continue }
            for (scheme, backdrop) in [("light", Color(white: 0.93)), ("dark", Color(white: 0.12))] {
                let model = HUDModel()
                model.phase = .idle
                model.card = layout == "-card"
                model.recents = HUDSample.queue
                // An album opened as a folder, kept in Recents as the folder.
                model.recents[2].folder = model.recents[2].url
                model.recents[2].title = "Low Tide Radio"
                model.recents[2].detail = "Mira Vale · 11 songs"
                model.recents[3].folder = model.recents[3].url
                model.recents[3].title = "Sunday Playlist"
                model.recents[3].artwork = nil
                model.recents[3].detail = "Saffron June · 42 songs"
                for at in [2, 3] { model.recents[at].key = nil; model.recents[at].bpm = nil }
                model.recentsShown = name != "idle-recents-front"
                model.recentsSelection = model.recents[0].id
                RecentsView.previewHover = hover ? model.recents[1].id : nil
                let view = HUDView(model: model)
                    .frame(width: HUDPanel.size.width, height: HUDPanel.size.height)
                    .background(backdrop)
                    .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                    .environment(\.renderingPreview, true)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)\(layout)-\(scheme).png"))
                }
            }
        }
    }
    RecentsView.previewHover = nil
    for (name, activity) in pills {
        for (scheme, backdrop) in [("light", Color(white: 0.93)), ("dark", Color(white: 0.12))] {
            let model = ActivityPillModel()
            model.activity = activity
            let view = ActivityPillView(model: model)
                .frame(width: 460, height: 64)
                .background(backdrop)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
                .environment(\.renderingPreview, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(scheme).png"))
            }
        }
    }
    exit(0)
}
