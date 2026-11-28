import Accelerate
import AVFoundation
import SoundAnalysis

/// What a part of a recording from the microphone sounds like, which decides whether its key counts.
enum SoundKind: String, Codable, CaseIterable {
    case music, speech, noise, silence
}

/// How readily each kind is heard, from 0 to 1. A higher Silence takes louder parts as silence, a higher Noise asks
/// the classifier to be surer before a part counts as music, and a higher Speech takes more parts as speech.
struct RecordingSensitivity: Codable, Equatable {
    var silence = 0.5
    var noise = 0.5
    var speech = 0.5

    /// The level under which a part is silent, in dBFS.
    var silenceLevel: Float { Float(-60 + 30 * silence) }
    /// The music score that a part needs to count as music.
    var musicScore: Float { Float(0.3 + 0.5 * noise) }
    /// The speech score that a part needs to count as speech.
    var speechScore: Float { Float(0.8 - 0.6 * speech) }
}

/// A recording from the microphone, in cells of a quarter second: the level of each cell, the scores that Apple's sound
/// classifier gave the window around it, and the parts that a person added to the key or left out of it. The parts
/// used for the key are worked out from these each time, so a change of sensitivity moves them at once.
struct RecordingAnalysis: Codable, Equatable {
    static let cell = 0.25
    /// Music shorter than this is left out, and a gap in music shorter than this is filled.
    static let shortest = 2.0

    var rate: Double
    var levels: [Float] = []
    /// -1 while the classifier hasn't reached the cell yet.
    var music: [Float] = []
    var speech: [Float] = []
    var silence: [Float] = []
    var sensitivity = RecordingSensitivity()
    var edits: [Edit] = []

    /// A part that a click or a drag added to the key or left out of it, applied in order over what was heard.
    struct Edit: Codable, Equatable {
        var start: Double
        var end: Double
        var include: Bool
    }

    struct Segment: Equatable {
        let kind: SoundKind
        let start: Double
        let end: Double
    }

    var duration: Double { Double(levels.count) * Self.cell }

    mutating func addCell(level: Float) {
        levels.append(level)
        music.append(-1)
        speech.append(-1)
        silence.append(-1)
    }

    /// Scores for the cells whose middles fall between `start` and `end`, in seconds.
    mutating func score(from start: Double, to end: Double, music m: Float, speech s: Float, silence q: Float) {
        guard !levels.isEmpty else { return }
        let first = max(0, Int((start / Self.cell).rounded(.down)))
        let last = min(levels.count - 1, Int((end / Self.cell).rounded(.up)) - 1)
        guard first <= last else { return }
        for i in first ... last {
            music[i] = m
            speech[i] = s
            silence[i] = q
        }
    }

    func kind(at i: Int) -> SoundKind {
        if levels[i] < sensitivity.silenceLevel || silence[i] > 0.6 { return .silence }
        let m = music[i], s = speech[i]
        if m < 0 { return .noise }
        let speaking = s >= sensitivity.speechScore && s > m
        if m >= sensitivity.musicScore, !speaking { return .music }
        return speaking ? .speech : .noise
    }

    func kinds() -> [SoundKind] { levels.indices.map(kind(at:)) }

    /// The cells used for the key: music, with its short gaps filled and its short bits left out, then the edits.
    func included() -> [Bool] {
        let count = levels.count
        var keep = kinds().map { $0 == .music }
        let short = Int(Self.shortest / Self.cell)
        // Gaps first, so two parts of a song with a breath between them stay one part.
        var i = 0
        while i < count {
            guard !keep[i] else { i += 1; continue }
            var j = i
            while j < count, !keep[j] { j += 1 }
            if i > 0, j < count, j - i < short { for k in i ..< j { keep[k] = true } }
            i = j
        }
        i = 0
        while i < count {
            guard keep[i] else { i += 1; continue }
            var j = i
            while j < count, keep[j] { j += 1 }
            if j - i < short { for k in i ..< j { keep[k] = false } }
            i = j
        }
        for edit in edits {
            let first = max(0, Int((edit.start / Self.cell).rounded()))
            let last = min(count, Int((edit.end / Self.cell).rounded()))
            if first < last { for k in first ..< last { keep[k] = edit.include } }
        }
        return keep
    }

    /// The parts used for the key, in seconds.
    func regions() -> [ClosedRange<Double>] {
        runs(of: included()).filter(\.value).map { Double($0.start) * Self.cell ... Double($0.end) * Self.cell }
    }

    /// Runs of cells of one kind, for drawing.
    func segments() -> [Segment] {
        runs(of: kinds()).map { Segment(kind: $0.value, start: Double($0.start) * Self.cell, end: Double($0.end) * Self.cell) }
    }

    private func runs<T: Equatable>(of values: [T]) -> [(value: T, start: Int, end: Int)] {
        var result: [(value: T, start: Int, end: Int)] = []
        var i = 0
        while i < values.count {
            var j = i
            while j < values.count, values[j] == values[i] { j += 1 }
            result.append((values[i], i, j))
            i = j
        }
        return result
    }

    /// A click on the strip: a part used for the key is left out, and the run of one kind under the pointer is added.
    mutating func toggle(at time: Double) {
        guard !levels.isEmpty else { return }
        let i = min(levels.count - 1, max(0, Int(time / Self.cell)))
        let keep = included()
        if let region = regions().first(where: { $0.contains(time) }), keep[i] {
            edits.append(Edit(start: region.lowerBound, end: region.upperBound, include: false))
        } else if let run = runs(of: kinds()).first(where: { $0.start <= i && i < $0.end }) {
            edits.append(Edit(start: Double(run.start) * Self.cell, end: Double(run.end) * Self.cell, include: true))
        }
    }

    /// A drag of an edge of a part used for the key, from `old` to `new`.
    mutating func moveEdge(of region: ClosedRange<Double>, start: Bool, to new: Double) {
        let new = min(duration, max(0, new))
        if start {
            let edge = min(new, region.upperBound - Self.cell)
            edits.append(edge < region.lowerBound ? Edit(start: edge, end: region.lowerBound, include: true)
                : Edit(start: region.lowerBound, end: edge, include: false))
        } else {
            let edge = max(new, region.lowerBound + Self.cell)
            edits.append(edge > region.upperBound ? Edit(start: region.upperBound, end: edge, include: true)
                : Edit(start: edge, end: region.upperBound, include: false))
        }
    }

    /// The classifier's labels that count as music or as speech.
    static let musicLabels: Set<String> = [
        "music", "singing", "choir_singing", "rapping", "humming", "whistling", "yodeling", "orchestra", "accordion", "acoustic_guitar",
        "bagpipes", "banjo", "bass_drum", "bass_guitar", "bassoon", "bowed_string_instrument", "brass_instrument", "cello", "clarinet",
        "cowbell", "cymbal", "didgeridoo", "disc_scratching", "double_bass", "drum", "drum_kit", "electric_guitar", "electric_piano",
        "electronic_organ", "flute", "french_horn", "glockenspiel", "gong", "guitar", "guitar_strum", "guitar_tapping", "hammond_organ",
        "harmonica", "harp", "harpsichord", "hi_hat", "keyboard_musical", "mallet_percussion", "mandolin", "marimba_xylophone", "oboe",
        "organ", "percussion", "piano", "plucked_string_instrument", "rattle_instrument", "saxophone", "shofar", "singing_bowl", "sitar",
        "snare_drum", "steel_guitar_slide_guitar", "steelpan", "synthesizer", "tabla", "tambourine", "theremin", "timpani", "trombone",
        "trumpet", "ukulele", "vibraphone", "violin_fiddle", "wind_instrument", "zither",
    ]
    static let speechLabels: Set<String> = [
        "speech", "whispering", "chatter", "babble", "shout", "yell", "laughter", "giggling", "chuckle_chortle", "belly_laugh", "snicker",
        "children_shouting",
    ]

    /// The scores of one window of the classifier: the surest label of each group.
    static func scores(_ result: SNClassificationResult) -> (music: Float, speech: Float, silence: Float) {
        var music: Float = 0, speech: Float = 0, silence: Float = 0
        for item in result.classifications {
            let confidence = Float(item.confidence)
            if musicLabels.contains(item.identifier) { music = max(music, confidence) }
            else if speechLabels.contains(item.identifier) { speech = max(speech, confidence) }
            else if item.identifier == "silence" { silence = confidence }
        }
        return (music, speech, silence)
    }

    static func level(_ squares: Float, count: Int) -> Float {
        guard count > 0 else { return -100 }
        return max(-100, 10 * log10(max(squares / Float(count), 1e-10)))
    }
}

/// The classifier's results for a window, handed to a closure on the thread that analyses.
private final class ClassifierObserver: NSObject, SNResultsObserving {
    let handle: (SNClassificationResult) -> Void
    init(_ handle: @escaping (SNClassificationResult) -> Void) { self.handle = handle }

    func request(_: SNRequest, didProduce result: SNResult) {
        if let result = result as? SNClassificationResult { handle(result) }
    }
}

/// Where the recordings live, how a recording on disk becomes a song file, and how one that a crash cut short is
/// brought back. A recording is written as it comes in, as raw samples beside a small file of what was heard, so a
/// crash loses at most the last seconds; it becomes an Apple Lossless file only once it is safely on disk.
enum RecordingStore {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Muskey/Recordings")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The raw samples, the file of what was heard, and the song file, for a recording named `base`.
    static func samples(_ base: String) -> URL { folder.appending(path: base + ".pcm") }
    static func analysisFile(_ base: String) -> URL { folder.appending(path: base + ".json") }
    static func song(_ base: String) -> URL { folder.appending(path: base + ".m4a") }

    static func newBase() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Recording " + formatter.string(from: Date())
    }

    /// The analysis of a recording's song file, for a file in the recordings folder.
    static func analysis(forSong path: String) -> RecordingAnalysis? {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else { return nil }
        let file = analysisFile(url.deletingPathExtension().lastPathComponent)
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(RecordingAnalysis.self, from: $0) }
    }

    static func save(_ analysis: RecordingAnalysis, base: String) {
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: analysisFile(base), options: .atomic)
    }

    static func save(_ analysis: RecordingAnalysis, forSong path: String) {
        save(analysis, base: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }

    /// The parts of a recording used for its key, nil for a song that isn't a recording or has too little music.
    static func keyRanges(forSong path: String) -> [ClosedRange<Double>]? {
        guard let regions = analysis(forSong: path)?.regions() else { return nil }
        return regions.reduce(0) { $0 + $1.upperBound - $1.lowerBound } >= 3 ? regions : nil
    }

    /// The cache cleanup: recordings that weren't recorded, edited or played for `age` seconds, kept until then even
    /// when they were never saved elsewhere. Raw samples that a crash left wait for the next launch to recover them.
    static func sweep(olderThan age: TimeInterval, keeping kept: Set<String>) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return 0 }
        let limit = Date().addingTimeInterval(-age)
        var deleted = 0
        for name in names where name.hasSuffix(".m4a") {
            let song = folder.appending(path: name), base = String(name.dropLast(4))
            guard !kept.contains(song.path), !manager.fileExists(atPath: samples(base).path) else { continue }
            let dates = [song, analysisFile(base)].compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
            }.flatMap { [$0.contentModificationDate, $0.contentAccessDate].compactMap(\.self) }
            guard let last = dates.max(), last < limit else { continue }
            try? manager.removeItem(at: song)
            try? manager.removeItem(at: analysisFile(base))
            deleted += 1
        }
        return deleted
    }

    /// Turns the raw samples of `base` into an Apple Lossless song file and deletes them once the song file reads back
    /// whole. Nil, with the samples kept, when anything fails.
    static func finish(_ base: String, rate: Double) -> URL? {
        let raw = samples(base), out = song(base)
        guard let input = try? FileHandle(forReadingFrom: raw),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return nil }
        defer { try? input.close() }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitDepthHintKey: 24]
        try? FileManager.default.removeItem(at: out)
        var written: AVAudioFramePosition = 0
        do {
            let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return nil }
            while let data = try input.read(upToCount: chunk * 4), !data.isEmpty {
                let frames = data.count / 4
                data.withUnsafeBytes { bytes in
                    guard let floats = bytes.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                    buffer.floatChannelData![0].update(from: floats, count: frames)
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                try file.write(from: buffer)
                written += AVAudioFramePosition(frames)
            }
        } catch {
            return nil
        }
        guard written > 0, let check = try? AVAudioFile(forReading: out), check.length >= written - 4096 else { return nil }
        try? FileManager.default.removeItem(at: raw)
        return out
    }

    /// Recordings that a crash or a forced quit left as raw samples, turned into song files, with what the classifier
    /// hears in them worked out again. Runs off the main thread.
    static func recover() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var recovered: [URL] = []
        for name in names where name.hasSuffix(".pcm") {
            let base = String(name.dropLast(4))
            var analysis = (try? Data(contentsOf: analysisFile(base))).flatMap { try? JSONDecoder().decode(RecordingAnalysis.self, from: $0) }
            let rate = analysis?.rate ?? 48000
            guard let url = finish(base, rate: rate) else { continue }
            if let fresh = analyze(url, keeping: analysis) { analysis = fresh }
            if let analysis { save(analysis, base: base) }
            recovered.append(url)
        }
        return recovered
    }

    /// The levels and the classifier's scores of a whole song file, keeping the sensitivity and the edits of `old`.
    static func analyze(_ url: URL, keeping old: RecordingAnalysis?) -> RecordingAnalysis? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        var analysis = RecordingAnalysis(rate: rate)
        if let old {
            analysis.sensitivity = old.sensitivity
            analysis.edits = old.edits
        }
        let cellFrames = AVAudioFrameCount(rate * RecordingAnalysis.cell)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cellFrames) else { return nil }
        while (try? file.read(into: buffer, frameCount: cellFrames)) != nil, buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] {
            var squares: Float = 0
            vDSP_svesq(channel, 1, &squares, vDSP_Length(buffer.frameLength))
            analysis.addCell(level: RecordingAnalysis.level(squares, count: Int(buffer.frameLength)))
        }
        guard let analyzer = try? SNAudioFileAnalyzer(url: url), let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return analysis }
        request.windowDuration = CMTime(seconds: MicRecorder.window, preferredTimescale: 1000)
        request.overlapFactor = 0.5
        let observer = ClassifierObserver { result in
            let scores = RecordingAnalysis.scores(result)
            let start = result.timeRange.start.seconds, length = result.timeRange.duration.seconds
            analysis.score(from: start + length / 4, to: start + length * 3 / 4, music: scores.music, speech: scores.speech, silence: scores.silence)
        }
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return analysis }
        analyzer.analyze()
        return analysis
    }
}

/// Records the microphone into the recordings folder and tells what it hears as it goes: the level and the kind of each
/// quarter second, and the key of the music, from its first two minutes of music. `--mic-file PATH` plays a file into it
/// in real time instead, for a Mac without a microphone.
final class MicRecorder: @unchecked Sendable {
    /// The classifier hears windows this long, half of each new.
    static let window = 1.5
    static let keySeconds = 120.0

    let base: String
    private(set) var rate: Double = 48000
    private let queue = DispatchQueue(label: "muskey.mic", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private var fileSource: DispatchSourceTimer?
    private var handle: FileHandle?
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: ClassifierObserver?
    private var monoFormat: AVAudioFormat?
    private var frames: AVAudioFramePosition = 0
    private var analysis: RecordingAnalysis
    private var cellSquares: Float = 0
    private var cellCount = 0
    /// The last seconds of samples, from frame `ringStart`, for the key of the music in them.
    private var ring: [Float] = []
    private var ringStart: AVAudioFramePosition = 0
    private var keyAnalyzer: KeyAnalyzer?
    private var keyFedUntil: AVAudioFramePosition = 0
    private var keyFed = 0.0
    private var lastSync = Date()
    private var lastSave = Date()
    private var lastPublish = Date.distantPast
    private var stopped = false

    /// The microphone that records, by its name.
    private(set) var deviceName = ""
    /// The microphone picked in Settings, when it isn't there or didn't start, and the one that records in its place.
    private(set) var fallback: (tried: String, using: String)?

    /// On the main queue, about ten times a second.
    var onUpdate: (RecordingAnalysis, Double) -> Void = { _, _ in }
    var onKey: (EKResult, Float) -> Void = { _, _ in }
    /// The level of each buffer of samples in dBFS, and the seconds recorded, on the main queue.
    var onLevel: (Float, Double) -> Void = { _, _ in }

    init(sensitivity: RecordingSensitivity) {
        base = RecordingStore.newBase()
        analysis = RecordingAnalysis(rate: 48000)
        analysis.sensitivity = sensitivity
    }

    /// Starts the microphone, the one with `deviceUID` when it is there and starts, or the file of `--mic-file`, on the
    /// recorder's queue: macOS can take seconds to open a microphone. `done` gets the error on the main queue, or nil.
    /// `deviceName` is the picked microphone's name, for the message when it is missing.
    func start(file: String? = nil, deviceUID: String? = nil, deviceName picked: String? = nil, done: @escaping (Error?) -> Void) {
        queue.async { [self] in
            var failure: Error?
            do { try begin(file: file, deviceUID: deviceUID, deviceName: picked) } catch { failure = error }
            DispatchQueue.main.async { done(failure) }
        }
    }

    /// The microphone runs, rather than a file played in.
    private var usesInput = false

    private func begin(file: String?, deviceUID: String?, deviceName picked: String?) throws {
        guard !stopped else { return }
        var inputFormat: AVAudioFormat
        var testFile: AVAudioFile?
        if let file {
            usesInput = false
            let audio = try AVAudioFile(forReading: URL(fileURLWithPath: file))
            testFile = audio
            inputFormat = audio.processingFormat
            deviceName = (file as NSString).lastPathComponent
        } else {
            usesInput = true
            let input = engine.inputNode
            let standard = MicDevices.defaultInput()
            deviceName = standard?.name ?? "Microphone"
            if let deviceUID, !deviceUID.isEmpty, deviceUID != standard?.uid {
                let tried = picked ?? deviceUID
                if let device = MicDevices.all().first(where: { $0.uid == deviceUID }), use(device.id) {
                    deviceName = device.name
                } else {
                    fallback = (tried, deviceName)
                }
            }
            inputFormat = engine.inputNode.outputFormat(forBus: 0)
            // A microphone that is listed but gives no audio, like one on the network that doesn't answer.
            if fallback == nil, deviceUID?.isEmpty == false, inputFormat.sampleRate == 0 || inputFormat.channelCount == 0, let standard, use(standard.id) {
                fallback = (deviceName, standard.name)
                deviceName = standard.name
                inputFormat = engine.inputNode.outputFormat(forBus: 0)
            }
        }
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw MicError.noInput }
        rate = inputFormat.sampleRate
        analysis = RecordingAnalysis(rate: rate)
        analysis.sensitivity = analysis.sensitivity
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { throw MicError.noInput }
        monoFormat = mono
        FileManager.default.createFile(atPath: RecordingStore.samples(base).path, contents: nil)
        handle = try FileHandle(forWritingTo: RecordingStore.samples(base))
        RecordingStore.save(analysis, base: base)

        let stream = SNAudioStreamAnalyzer(format: mono)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: Self.window, preferredTimescale: 1000)
        request.overlapFactor = 0.5
        let observer = ClassifierObserver { [weak self] in self?.classified($0) }
        try stream.add(request, withObserver: observer)
        analyzer = stream
        self.observer = observer
        keyAnalyzer = KeyAnalyzer(sampleRate: rate)

        if let testFile {
            playIn(testFile)
        } else {
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self, let mixed = Self.mono(buffer) else { return }
                queue.async { self.take(mixed) }
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                // The picked microphone didn't start: the default one records instead.
                guard fallback == nil, deviceUID?.isEmpty == false, let standard = MicDevices.defaultInput(), use(standard.id) else { throw error }
                fallback = (deviceName, standard.name)
                deviceName = standard.name
                input.removeTap(onBus: 0)
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate == rate else { throw error }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    guard let self, let mixed = Self.mono(buffer) else { return }
                    queue.async { self.take(mixed) }
                }
                engine.prepare()
                try engine.start()
            }
        }
    }

    /// Records from this device: false when the input won't take it.
    private func use(_ device: AudioObjectID) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var id = device
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr
    }

    enum MicError: LocalizedError {
        case noInput
        var errorDescription: String? { "no microphone input" }
    }

    /// Plays a file in as if it came from the microphone, 25 ms at a time.
    private func playIn(_ file: AVAudioFile) {
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 40)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.025)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0, let mixed = Self.mono(buffer) else {
                return
            }
            take(mixed)
        }
        fileSource = timer
        timer.resume()
    }

    private static func mono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        guard count > 0 else { return nil }
        if channelCount == 1 { return Array(UnsafeBufferPointer(start: channels[0], count: count)) }
        var mixed = [Float](repeating: 0, count: count)
        for channel in 0 ..< channelCount {
            vDSP_vsma(channels[channel], 1, [1 / Float(channelCount)], mixed, 1, &mixed, 1, vDSP_Length(count))
        }
        return mixed
    }

    /// On the recorder's queue: writes the samples, measures their level, and hands them to the classifier.
    private func take(_ samples: [Float]) {
        guard !stopped, let handle else { return }
        samples.withUnsafeBytes { handle.write(Data($0)) }
        var squares: Float = 0
        vDSP_svesq(samples, 1, &squares, vDSP_Length(samples.count))
        let level = RecordingAnalysis.level(squares, count: samples.count)
        let seconds = Double(frames + AVAudioFramePosition(samples.count)) / rate
        DispatchQueue.main.async { [weak self] in self?.onLevel(level, seconds) }
        let cellFrames = Int(rate * RecordingAnalysis.cell)
        for sample in samples {
            cellSquares += sample * sample
            cellCount += 1
            if cellCount == cellFrames {
                analysis.addCell(level: RecordingAnalysis.level(cellSquares, count: cellCount))
                cellSquares = 0
                cellCount = 0
            }
        }
        ring += samples
        let keep = Int(rate * 12)
        if ring.count > keep {
            ringStart += AVAudioFramePosition(ring.count - keep)
            ring.removeFirst(ring.count - keep)
        }
        if let monoFormat, let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(samples.count)) {
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            analyzer?.analyze(buffer, atAudioFramePosition: frames)
        }
        frames += AVAudioFramePosition(samples.count)
        let now = Date()
        // A crash loses at most two seconds of samples, and the file of what was heard is at most five seconds behind.
        if now.timeIntervalSince(lastSync) >= 2 {
            try? handle.synchronize()
            lastSync = now
        }
        if now.timeIntervalSince(lastSave) >= 5 {
            RecordingStore.save(analysis, base: base)
            lastSave = now
        }
        if now.timeIntervalSince(lastPublish) >= 0.1 { publish() }
    }

    private func publish() {
        lastPublish = Date()
        let analysis = analysis, seconds = Double(frames) / rate
        DispatchQueue.main.async { [weak self] in self?.onUpdate(analysis, seconds) }
    }

    /// On the recorder's queue, from inside `analyze`: the scores of a window, and its music for the key.
    private func classified(_ result: SNClassificationResult) {
        let scores = RecordingAnalysis.scores(result)
        let start = result.timeRange.start.seconds, length = result.timeRange.duration.seconds
        // The middle half of each window, since the next window starts halfway through it.
        let from = start + length / 4, to = start + length * 3 / 4
        analysis.score(from: from, to: to, music: scores.music, speech: scores.speech, silence: scores.silence)
        let first = max(0, Int((from / RecordingAnalysis.cell).rounded(.down)))
        guard first < analysis.levels.count, analysis.kind(at: first) == .music, keyFed < Self.keySeconds, let keyAnalyzer else { return }
        let lower = max(AVAudioFramePosition(from * rate), keyFedUntil, ringStart)
        let upper = min(AVAudioFramePosition(to * rate), ringStart + AVAudioFramePosition(ring.count))
        guard upper > lower else { return }
        let slice = Array(ring[Int(lower - ringStart) ..< Int(upper - ringStart)])
        keyFedUntil = upper
        keyFed += Double(slice.count) / rate
        keyAnalyzer.append(slice) { [weak self] result, peak in self?.onKey(result, peak) }
    }

    /// The sensitivity changes what counts as music from here on, and in what was recorded so far.
    func setSensitivity(_ sensitivity: RecordingSensitivity) {
        queue.async { [self] in
            analysis.sensitivity = sensitivity
            publish()
        }
    }

    func setEdits(_ edits: [RecordingAnalysis.Edit]) {
        queue.async { [self] in
            analysis.edits = edits
            publish()
        }
    }

    /// Stops recording, finishes the song file off the main queue, and hands its URL to `done` on the main queue, or
    /// nil when the samples couldn't be turned into a song file (they stay in the folder, for the next launch).
    func stop(_ done: @escaping (URL?, RecordingAnalysis) -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            if usesInput {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            fileSource?.cancel()
            analyzer?.completeAnalysis()
            if cellCount > Int(rate * RecordingAnalysis.cell) / 4 {
                analysis.addCell(level: RecordingAnalysis.level(cellSquares, count: cellCount))
            }
            try? handle?.synchronize()
            try? handle?.close()
            let started = handle != nil
            handle = nil
            // Nothing was recorded, so nothing is kept.
            guard started, frames > 0 else {
                try? FileManager.default.removeItem(at: RecordingStore.samples(base))
                try? FileManager.default.removeItem(at: RecordingStore.analysisFile(base))
                let analysis = analysis
                return DispatchQueue.main.async { done(nil, analysis) }
            }
            RecordingStore.save(analysis, base: base)
            let url = RecordingStore.finish(base, rate: rate)
            let analysis = analysis
            DispatchQueue.main.async { done(url, analysis) }
        }
    }

    /// Stops recording and deletes the samples and the analysis, then calls `done` on the main queue.
    func cancel(_ done: @escaping () -> Void) {
        queue.async { [self] in
            if !stopped {
                stopped = true
                if usesInput {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
                fileSource?.cancel()
                analyzer?.completeAnalysis()
                try? handle?.close()
                handle = nil
            }
            try? FileManager.default.removeItem(at: RecordingStore.samples(base))
            try? FileManager.default.removeItem(at: RecordingStore.analysisFile(base))
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Writes what is on disk so far without stopping, for a quit that leaves no time to finish the song file.
    func flush() {
        queue.sync {
            try? handle?.synchronize()
            RecordingStore.save(analysis, base: base)
        }
    }
}

/// The Mac's audio inputs, by their unique ID, which stays the same across launches and reconnections.
enum MicDevices {
    struct Device: Hashable {
        let id: AudioObjectID
        let uid: String
        let name: String
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            // Muskey's own aggregate devices, which it makes to hear other apps, aren't microphones.
            if uid.hasPrefix("Muskey") || name.hasPrefix("Muskey") { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func defaultInput() -> Device? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return Device(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "", name: string(id, kAudioObjectPropertyName) ?? "Microphone")
    }

    private static func inputChannels(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
