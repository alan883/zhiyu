import AVFoundation
import CoreAudio
import Foundation

/// Records microphone audio and returns it as a 16 kHz mono 16-bit PCM WAV.
final class AudioRecorder {
    /// Normalized 0...1 RMS level, delivered on the main queue at ~20 Hz.
    var onLevel: ((Float) -> Void)?
    /// Called once on the main queue when the first non-silent converted buffer of a recording arrives.
    var onReady: (() -> Void)?
    /// Apple voice processing (noise suppression / AGC, shows as "Voice Isolation" in Control Center).
    var noiseMode = true
    /// Record from the built-in mic when the default input is a Bluetooth headset.
    var preferBuiltIn = true
    /// UID of a mic pinned in Settings ("" = automatic). Used when that mic is plugged in.
    var pinnedMic = ""
    /// True when the engine in use runs with voice processing (may be false even if noiseMode is on).
    private(set) var voiceProcessingActive = false
    /// Input devices where voice processing produced no audio or stopped the engine. Plain capture is used for them.
    private static var vpBrokenDevices = Set<AudioDeviceID>()

    private static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 16_000, channels: 1, interleaved: false)!
    private static let minSamples = 4_000      // 0.25 s at 16 kHz
    private static let prerollSamples = 7_200  // 0.45 s at 16 kHz
    private static let warmSeconds: Double = 30
    private static let healthInterval: Double = 0.2  // continuous watchdog tick while a VP engine is current
    private static let healthGrace: Double = 0.4     // first tick waits this long for the first buffer

    private let lock = NSLock()
    private var engine: AVAudioEngine?         // non-nil while the tap is installed (recording or warm)
    private var builtVP = false                // whether the current engine runs with voice processing
    private var builtDevice: AudioDeviceID = 0  // input device the current capture was built for
    private var tapBuffers = 0                 // buffers delivered since the last health check (guarded by lock)
    private var healthTimer: DispatchSourceTimer?  // repeating main-queue watchdog for the current VP engine
    private var capture: AVCaptureSession?     // non-nil while built-in mic capture runs instead of the engine
    private var captureSink: CaptureSink?      // strong ref: AVCaptureAudioDataOutput does not retain its delegate
    private let captureQueue = DispatchQueue(label: "AudioRecorder.capture")

    /// Device the current or last take was recorded on.
    var activeDevice: AudioDeviceID { builtDevice }

    /// Current system default input device (changes when headphones are plugged/unplugged).
    static func defaultInputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
    private var idleTimer: DispatchWorkItem?
    private var ring: [Float] = []             // last prerollSamples of converted audio, always maintained
    private var samples: [Float] = []
    private var prerollCount = 0
    private var recording = false
    private var readyFired = false
    private var lastLevelTime: CFAbsoluteTime = 0 // touched only from the tap thread
    private var pendingDone: ((Data) -> Void)?    // set while a post-roll window is running (main queue only)
    private var postRollWork: DispatchWorkItem?

    var isRecording: Bool { lock.withLock { recording } }

    /// Samples captured so far in the current take (16 kHz mono, pre-roll included). Thread-safe.
    var sampleCount: Int { lock.withLock { samples.count } }

    /// A copy of samples[from..<to] of the current take (clamped). Thread-safe; used for live segment recognition.
    func samples(from: Int, to: Int) -> [Float] {
        lock.withLock {
            let a = max(0, min(from, samples.count)), b = max(a, min(to, samples.count))
            return Array(samples[a..<b])
        }
    }

    deinit { shutdown() }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func start() throws {
        if pendingDone != nil { finishPostRoll() } // deliver the pending post-roll take first
        guard !isRecording else { return }
        idleTimer?.cancel()
        idleTimer = nil
        // a warm engine stays bound to the device it was built on: rebuild if the mic changed (headphones unplugged)
        let target = DeviceInfo.recordingInput(preferBuiltIn: preferBuiltIn, pinnedUID: pinnedMic)
        let useCapture = target != Self.defaultInputDevice()
        let isRunningNow = engine?.isRunning == true || capture?.isRunning == true
        if !isRunningNow || builtDevice != target || (capture != nil) != useCapture || (!useCapture && builtVP != wantVP()) {
            shutdown()          // tear down any stopped/broken or mismatched engine or capture
            if useCapture {
                try buildCapture(device: target)
            } else {
                try buildEngine(allowVP: true)
            }
        } else if builtVP, let e = engine {
            scheduleHealthCheck(e) // warm VP engine reused: resume the watchdog for this take
        }
        lastLevelTime = 0
        lock.withLock {
            prerollCount = ring.count
            samples = ring
            readyFired = false
            recording = true
        }
    }

    /// Stops capture and returns WAV bytes, or empty Data if under 0.25 s was recorded.
    /// The engine stays warm for 30 s so the next start() has no cold-start clipping.
    /// Samples captured before the engine died are still returned.
    func stop() -> Data {
        guard isRecording else { return Data() }
        if voiceProcessingActive, engine?.isRunning != true { Self.vpBrokenDevices.insert(builtDevice) }
        cancelHealthCheck()
        let (pcm, pre) = lock.withLock { () -> ([Float], Int) in
            recording = false
            let s = samples
            samples = []
            return (s, prerollCount)
        }
        scheduleIdleShutdown()
        guard pcm.count - pre >= Self.minSamples else { return Data() }
        return Self.wav(from: pcm)
    }

    /// Keeps capturing for `postRoll` seconds (so a slightly early key release doesn't clip the last word),
    /// then finishes exactly like stop() and delivers the WAV on the main queue.
    func stop(postRoll: TimeInterval, _ done: @escaping (Data) -> Void) {
        guard isRecording, pendingDone == nil else {
            DispatchQueue.main.async { done(Data()) }
            return
        }
        pendingDone = done
        let work = DispatchWorkItem { [weak self] in self?.finishPostRoll() }
        postRollWork = work
        // Already quiet for 300 ms before the release: nothing left to clip, so don't wait.
        // 199 saved takes (10-24): 91% ended this way; on the 3 with sound after release, cutting changed no word.
        let quiet = lock.withLock { Self.endsQuiet(samples) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (quiet ? 0 : postRoll), execute: work)
    }

    /// True when the last 300 ms of the take are below the speech threshold (20 ms frames,
    /// threshold = max(3 × 10th-percentile level, 0.15 × 90th-percentile level)).
    static func endsQuiet(_ pcm: [Float]) -> Bool {
        let frame = 320, tailFrames = 15
        let n = pcm.count / frame
        guard n >= tailFrames * 3 else { return false }
        var rms = [Float](repeating: 0, count: n)
        pcm.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var sum: Float = 0
                for j in (i * frame)..<((i + 1) * frame) { sum += p[j] * p[j] }
                rms[i] = (sum / Float(frame)).squareRoot()
            }
        }
        let sorted = rms.sorted()
        let thr = max(sorted[n / 10] * 3, sorted[n * 9 / 10] * 0.15)
        return rms.suffix(tailFrames).allSatisfy { $0 <= thr }
    }

    /// Removes the tap, stops the engine and discards any in-progress recording.
    func shutdown() {
        if pendingDone != nil { finishPostRoll() } // deliver the pending post-roll take before tearing down
        idleTimer?.cancel()
        idleTimer = nil
        guard engine != nil || capture != nil else { return }
        teardownEngine()
        lock.withLock {
            recording = false
            samples = []
            ring = []
        }
    }

    // MARK: - Private

    private func wantVP() -> Bool {
        noiseMode && !Self.vpBrokenDevices.contains(Self.defaultInputDevice())
    }

    /// Builds and starts a fresh engine. Samples and pre-roll are left untouched, so this also serves mid-recording recovery.
    private func buildEngine(allowVP: Bool) throws {
        let device = Self.defaultInputDevice()
        let fresh = AVAudioEngine() // fresh engine per rebuild avoids stale device state
        let input = fresh.inputNode
        var vp = allowVP && noiseMode && !Self.vpBrokenDevices.contains(device)
        if vp {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false,
                                                                         duckingLevel: .min)
            } catch {
                vp = false // unavailable on this device: plain capture
                Self.vpBrokenDevices.insert(device)
            }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw Self.error(1, "No usable input format")
        }
        // With voice processing the pre-start format is wrong (reports 3 ch, stream is 5 ch): let the engine pick
        // the live format and build the converter from the first buffer's real format.
        let cache = ConverterCache()
        input.installTap(onBus: 0, bufferSize: 4096, format: vp ? nil : inFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.lock.withLock { self.tapBuffers += 1 }
            self.feed(buffer, cache: cache)
        }
        fresh.prepare()
        do {
            try fresh.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        engine = fresh
        builtVP = vp
        builtDevice = device
        voiceProcessingActive = vp
        lock.withLock { tapBuffers = 0 }
        if vp { scheduleHealthCheck(fresh) }
    }

    /// Builds and starts built-in mic capture (AVCaptureSession). Used when the default input is a Bluetooth headset:
    /// the headset then stays in music mode. Samples and pre-roll are left untouched.
    private func buildCapture(device: AudioDeviceID) throws {
        guard let cam = AVCaptureDevice(uniqueID: DeviceInfo.uid(device) ?? "") else {
            throw Self.error(2, "Microphone not found")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(input) else { throw Self.error(4, "Cannot add capture input") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput() // no audioSettings: deliver the device's native format
        guard session.canAddOutput(output) else { throw Self.error(4, "Cannot add capture output") }
        let cache = ConverterCache()
        let sink = CaptureSink { [weak self] buffer in
            guard let self = self else { return }
            self.lock.withLock { self.tapBuffers += 1 }
            self.feed(buffer, cache: cache)
        }
        output.setSampleBufferDelegate(sink, queue: captureQueue)
        session.addOutput(output)
        session.startRunning()
        guard session.isRunning else { throw Self.error(3, "Capture did not start") }
        capture = session
        captureSink = sink
        builtDevice = device
        builtVP = false
        voiceProcessingActive = false
        lock.withLock { tapBuffers = 0 }
    }

    /// Converts one input buffer to 16 kHz mono and passes it to process(). The cache keeps the converter
    /// while the input format stays the same.
    private func feed(_ buffer: AVAudioPCMBuffer, cache: ConverterCache) {
        let f = buffer.format
        if cache.converter == nil || cache.format != f {
            guard let c = AVAudioConverter(from: f, to: Self.outFormat) else { return }
            if f.channelCount > 1 {
                c.channelMap = [NSNumber(value: 0)] // voice processing or capture may report multichannel input
            }
            cache.converter = c
            cache.format = f
        }
        if let c = cache.converter { process(buffer, converter: c) }
    }

    private func teardownEngine() {
        cancelHealthCheck()
        capture?.stopRunning()
        capture = nil
        captureSink = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // voice processing lives in the shared IO unit: switch it off explicitly or the next plain engine gets no input
        if voiceProcessingActive { try? engine?.inputNode.setVoiceProcessingEnabled(false) }
        engine = nil
        voiceProcessingActive = false
    }

    /// Starts a repeating main-queue watchdog for a voice-processing engine. The first tick waits `healthGrace`
    /// for the first buffer, then ticks every `healthInterval`. Replaces any previous watchdog.
    private func scheduleHealthCheck(_ eng: AVAudioEngine) {
        cancelHealthCheck()
        lock.withLock { tapBuffers = 0 }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.healthGrace, repeating: Self.healthInterval)
        timer.setEventHandler { [weak self] in self?.checkHealth(eng) }
        healthTimer = timer
        timer.resume()
    }

    private func cancelHealthCheck() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    /// Runs on main every 0.2 s while a voice-processing engine is current. Broken = stopped, or no new buffer since the previous tick.
    private func checkHealth(_ eng: AVAudioEngine) {
        guard engine === eng else { cancelHealthCheck(); return } // already replaced or shut down
        let seen = lock.withLock { () -> Int in
            let n = tapBuffers
            tapBuffers = 0
            return n
        }
        if !eng.isRunning || seen == 0 {
            recoverFromBrokenVP(eng)
        }
    }

    /// Voice processing failed on this device: remember it, and if a take is running, continue it on a plain engine.
    private func recoverFromBrokenVP(_ eng: AVAudioEngine) {
        guard engine === eng else { return }
        Self.vpBrokenDevices.insert(builtDevice)
        teardownEngine()
        guard isRecording else { return } // idle: the next start() builds a plain engine
        try? buildEngine(allowVP: false)  // if this also fails, stop() still returns the captured samples
    }

    /// Ends a post-roll window exactly once: runs the synchronous stop() and hands the WAV to the pending callback.
    private func finishPostRoll() {
        guard let done = pendingDone else { return } // double-finish guard
        pendingDone = nil
        postRollWork?.cancel()
        postRollWork = nil
        done(stop())
    }

    private func scheduleIdleShutdown() {
        idleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.shutdown() }
        idleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmSeconds, execute: work)
    }

    private func process(_ input: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, convError == nil, let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        guard count > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        // Bluetooth delivers about 0.5 s of all-zero buffers before real audio: ready waits for a non-zero sample
        let audible = chunk.contains { $0 != 0 }

        let (live, firstBuffer) = lock.withLock { () -> (Bool, Bool) in
            ring.append(contentsOf: chunk)
            if ring.count > Self.prerollSamples {
                ring.removeFirst(ring.count - Self.prerollSamples)
            }
            guard recording else { return (false, false) }
            samples.append(contentsOf: chunk)
            let first = !readyFired && audible
            if first { readyFired = true }
            return (true, first)
        }
        guard live else { return }
        if firstBuffer {
            DispatchQueue.main.async { [weak self] in self?.onReady?() }
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelTime >= 0.05 {
            lastLevelTime = now
            let meanSquare = chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(count)
            let level = min(1, meanSquare.squareRoot() * 8)
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }
    }

    static func wav(from pcm: [Float]) -> Data {
        let dataBytes = UInt32(pcm.count * 2)
        var d = Data(capacity: 44 + Int(dataBytes))
        func append<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))      // fmt chunk size
        append(UInt16(1))       // PCM
        append(UInt16(1))       // mono
        append(UInt32(16_000))  // sample rate
        append(UInt32(32_000))  // byte rate
        append(UInt16(2))       // block align
        append(UInt16(16))      // bits per sample
        d.append(contentsOf: Array("data".utf8))
        append(dataBytes)
        for f in pcm {
            let clamped = max(-1, min(1, f))
            append(Int16((clamped * 32_767).rounded()))
        }
        return d
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Audio", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Holds the converter for one input format (used from the tap or capture thread only).
private final class ConverterCache {
    var converter: AVAudioConverter?
    var format: AVAudioFormat?
}

/// Receives AVCaptureSession audio and hands each block to `handler` as an AVAudioPCMBuffer.
private final class CaptureSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let handler: (AVAudioPCMBuffer) -> Void

    init(_ handler: @escaping (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let maybeFormat: AVAudioFormat? = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let format = maybeFormat, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        handler(buffer)
    }
}
