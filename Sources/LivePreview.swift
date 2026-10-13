import Foundation

/// Live preview, the "2-pass" design (FunASR calls it 2pass): while the key is held, new audio goes to the server's
/// streaming Paraformer every 0.2 s and the partial text is shown in the HUD. The text that goes on screen still comes
/// from the accurate whole-take recognizer after release; the preview only shows the user they are being heard.
///
/// Measured (M1, 41 real takes): ~27 ms of CPU per 100 ms of audio, preview text differs from the final in ~11% of
/// characters. Cutting the take into segments for the FINAL text was rejected: 4–7% more errors (lost context).
final class LivePreview {
    /// Partial text, on the main queue.
    var onText: ((String) -> Void)?
    private(set) var available = false

    private let base: URL
    private weak var recorder: AudioRecorder?
    private var timer: Timer?
    private var id = ""
    private var sent = 0           // samples of the current take already streamed
    private var inFlight = false   // one request at a time keeps the audio in order
    private var gen = 0            // bumps on start/stop; stale replies are dropped
    private var downloadAsked = false

    init(base: URL) { self.base = base }

    /// Checks whether the streaming model is installed; asks the server to download it (~237 MB) once if not.
    func refreshStatus() {
        var req = URLRequest(url: base.appendingPathComponent("stream/status"))
        req.timeoutInterval = 2
        ASRClient.session.dataTask(with: req) { [weak self] data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let self, let obj else { return }
                self.available = obj["available"] as? Bool ?? false
                let downloading = obj["downloading"] as? Bool ?? false
                if !self.available, !downloading, !self.downloadAsked {
                    self.downloadAsked = true
                    self.post("stream/download", body: Data()) { _ in }
                }
            }
        }.resume()
    }

    func start(_ recorder: AudioRecorder) {
        guard available else { return }
        stop()
        self.recorder = recorder
        id = UUID().uuidString
        sent = 0
        inFlight = false
        gen += 1
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        guard !id.isEmpty else { return }
        gen += 1
        post("stream/end?id=\(id)", body: Data()) { _ in }   // frees the server-side stream
        id = ""
    }

    private func tick() {
        guard let rec = recorder, !inFlight, rec.isRecording else { return }
        let n = rec.sampleCount
        guard n > sent else { return }
        let pcm = rec.samples(from: sent, to: n)
        sent = n
        inFlight = true
        let myGen = gen
        let body = pcm.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian float32 on Apple silicon/Intel
        post("stream/feed?id=\(id)", body: body) { [weak self] text in
            guard let self, myGen == self.gen else { return }
            self.inFlight = false
            if let text, !text.isEmpty { self.onText?(text) }
        }
    }

    /// POST to the local server; completion on main with the "text" field (nil on failure).
    private func post(_ path: String, body: Data, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: path, relativeTo: base) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        ASRClient.session.dataTask(with: req) { data, _, _ in
            let text = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["text"] as? String
            DispatchQueue.main.async { completion(text) }
        }.resume()
    }
}
