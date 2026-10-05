#if os(macOS)
import CryptoKit
import Foundation
import Observation

/// The model the formula lasso reads handwriting with, and the files it is
/// made of.
///
/// Handwriting is not the formula OCR's job: pix2text learned printed
/// formulas, and on a page of lecture notes it read "P(∪ Aᵢ)" as a fraction
/// of nonsense and "pf) we have" as `\rho f)`. A vision-language model reads
/// both the words and the mathematics — tried on crops of real notes against
/// PaddleOCR-VL, GLM-OCR, Chandra, dots.mocr, Uni-MuMER and Qwen3-VL, Qwen3.5
/// read the most of them right, and the 9B more than the 4B. It runs here,
/// on this Mac, through MLX; the page never leaves it.
///
/// The weights are too big to ship in the app (6 GB and 3 GB), so they are
/// downloaded when asked for, from the MLX conversions on Hugging Face, at a
/// pinned revision: each file's size and SHA-256 are written down here and a
/// download that does not match them is thrown away.
enum HandwritingModel: String, CaseIterable, Identifiable, Sendable {
    /// Qwen3.5 9B, 4-bit — wants a Mac with 16 GB of memory.
    case precise
    /// Qwen3.5 4B, 4-bit — for 8 GB.
    case standard

    var id: String { rawValue }

    struct File: Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }

    var repository: String {
        switch self {
        case .precise: "mlx-community/Qwen3.5-9B-MLX-4bit"
        case .standard: "mlx-community/Qwen3.5-4B-MLX-4bit"
        }
    }

    var revision: String {
        switch self {
        case .precise: "938d8919941c6e7efd3c7150eff7fe9d12afa631"
        case .standard: "32f3e8ecf65426fc3306969496342d504bfa13f3"
        }
    }

    /// The folder it is kept in, named for the revision: a newer one is a
    /// new folder, never an overwrite of a model that works.
    var folderName: String {
        switch self {
        case .precise: "qwen3.5-9b-4bit-\(revision.prefix(7))"
        case .standard: "qwen3.5-4b-4bit-\(revision.prefix(7))"
        }
    }

    var files: [File] {
        let shared: [File] = [
            File(name: "chat_template.jinja", size: 7756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
            File(name: "preprocessor_config.json", size: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
            File(name: "processor_config.json", size: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
            File(name: "tokenizer_config.json", size: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
            File(name: "video_preprocessor_config.json", size: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
            File(name: "vocab.json", size: 6_722_759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
            File(name: "tokenizer.json", size: 19_989_343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        ]
        switch self {
        case .precise:
            return [
                File(name: "config.json", size: 3331, sha256: "a96942cb6a8a1d3f1d17514d81a1925d04362a6a3233b389d13012211baaa9f8"),
                File(name: "model.safetensors.index.json", size: 123_592, sha256: "dd023913fb87cfdae27fb11dcf695117c925833796ccac3c64117d6652d8ff1e"),
            ] + shared + [
                File(name: "model-00002-of-00002.safetensors", size: 600_449_850, sha256: "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d"),
                File(name: "model-00001-of-00002.safetensors", size: 5_349_771_222, sha256: "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd"),
            ]
        case .standard:
            return [
                File(name: "config.json", size: 3366, sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
                File(name: "model.safetensors.index.json", size: 101_944, sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
            ] + shared + [
                File(name: "model.safetensors", size: 3_034_300_695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
            ]
        }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    var title: String {
        switch self {
        case .precise: L("정밀", "Precise")
        case .standard: L("표준", "Standard")
        }
    }

    /// The model's name as its makers give it.
    var modelName: String {
        switch self {
        case .precise: "Qwen3.5 9B"
        case .standard: "Qwen3.5 4B"
        }
    }

    /// The one this Mac can hold comfortably: the 9B takes about 7 GB of
    /// memory while it reads.
    static var recommended: HandwritingModel {
        ProcessInfo.processInfo.physicalMemory >= 15 * (1 << 30) ? .precise : .standard
    }
}

/// The handwriting models on this Mac: which are here, which is downloading
/// and how far it has got.
@MainActor
@Observable
final class HandwritingModels {
    static let shared = HandwritingModels()

    enum State: Equatable {
        case absent
        /// Bytes so far of the whole model, across its files.
        case downloading(received: Int64, total: Int64)
        /// Stopped partway; what came stays, and the next download goes on
        /// from there.
        case stopped(received: Int64, total: Int64)
        /// Every file is here; their hashes are being checked.
        case checking
        case ready
        case failed(String)
    }

    private(set) var states: [HandwritingModel: State] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var downloading: HandwritingModel?

    /// Where models are kept: Application Support, not Caches — a download
    /// of six gigabytes that macOS may clear when space runs low is a
    /// download somebody makes twice. A probe reads another folder if it is
    /// told one (`--papertime-handwriting-model`), and never writes here.
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    private static var isProbe: Bool { Boot.setting("PAPERTIME_LIBRARY") != nil }

    init() {
        for model in HandwritingModel.allCases {
            if isInstalled(model) {
                states[model] = .ready
            } else {
                let here = bytesHere(of: model)
                states[model] = here > 0 ? .stopped(received: here, total: model.totalBytes) : .absent
            }
        }
        // `--papertime-handwriting-state=precise:downloading:2000000000,standard:stopped:900000000`
        // puts the rows in those states for a picture of Settings, in a
        // probe only and in memory only — nothing is downloaded or removed.
        if Self.isProbe, let asked = Boot.setting("PAPERTIME_HANDWRITING_STATE") {
            for item in asked.split(separator: ",") {
                let parts = item.split(separator: ":", maxSplits: 2).map(String.init)
                guard let model = HandwritingModel(rawValue: parts.first ?? "") else { continue }
                let bytes = Int64(parts.count > 2 ? parts[2] : "") ?? model.totalBytes / 3
                switch parts.count > 1 ? parts[1] : "" {
                case "downloading": states[model] = .downloading(received: bytes, total: model.totalBytes)
                case "stopped": states[model] = .stopped(received: bytes, total: model.totalBytes)
                case "checking": states[model] = .checking
                case "ready": states[model] = .ready
                case "failed": states[model] = .failed(parts.count > 2 ? parts[2] : ModelFileDownload.Failure.short.message)
                default: states[model] = .absent
                }
            }
        }
    }

    /// Bytes of the model already in its folder: whole files at their size,
    /// and what a stopped download left of the file it was in.
    func bytesHere(of model: HandwritingModel) -> Int64 {
        let folder = directory(for: model)
        func size(_ name: String) -> Int64? {
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
        }
        return model.files.reduce(Int64(0)) { sum, file in
            if size(file.name) == file.size { return sum + file.size }
            return sum + min(size(file.name + ".part") ?? 0, file.size)
        }
    }

    func directory(for model: HandwritingModel) -> URL {
        Self.root.appendingPathComponent(model.folderName, isDirectory: true)
    }

    /// Every file there at its size, and the mark that their hashes matched.
    func isInstalled(_ model: HandwritingModel) -> Bool {
        let folder = directory(for: model)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".verified").path) else { return false }
        return model.files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == file.size
        }
    }

    /// The folder the reader should load, if any model is here: the one
    /// asked for by a probe, else the recommended one, else the other.
    var readyDirectory: URL? {
        if let given = Boot.setting("PAPERTIME_HANDWRITING_MODEL") { return URL(fileURLWithPath: given, isDirectory: true) }
        return inUse.map(directory(for:))
    }

    var isDownloading: Bool { downloading != nil }

    func state(of model: HandwritingModel) -> State { states[model] ?? .absent }

    /// The model a reading uses when more than one is here.
    var inUse: HandwritingModel? {
        let order = [HandwritingModel.recommended] + HandwritingModel.allCases.filter { $0 != .recommended }
        return order.first { states[$0] == .ready }
    }

    /// Downloads a model's files one after another into its folder, each as
    /// `<name>.part` until it is whole. Stopped, the parts stay, and the next
    /// download asks the server for the rest of the file it was in (an HTTP
    /// range) — six gigabytes are not fetched twice because somebody pressed
    /// Stop. Every file is then checked against its pinned size and SHA-256;
    /// one that does not match is thrown away.
    func download(_ model: HandwritingModel) {
        guard downloading == nil, !Self.isProbe else { return }
        downloading = model
        let folder = directory(for: model)
        let total = model.totalBytes
        states[model] = .downloading(received: bytesHere(of: model), total: total)
        task = Task { [weak self] in
            var done: Int64 = 0
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Room first: six gigabytes that stop at five are a full disk
                // and nothing to show for it. What is already here counts.
                let needed = total - (self?.bytesHere(of: model) ?? 0) + (1 << 30)
                if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage, free < needed {
                    throw ModelFileDownload.Failure.room(needed)
                }
                for file in model.files {
                    try Task.checkCancellation()
                    let target = folder.appendingPathComponent(file.name)
                    let part = folder.appendingPathComponent(file.name + ".part")
                    let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
                    if size != file.size {
                        try? FileManager.default.removeItem(at: target)
                        let base = done
                        let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file.name)")!
                        try await ModelFileDownload.fetch(url, into: part, size: file.size) { received in
                            Task { @MainActor in
                                guard case .downloading = self?.states[model] else { return }
                                self?.states[model] = .downloading(received: base + received, total: total)
                            }
                        }
                        try FileManager.default.moveItem(at: part, to: target)
                    }
                    done += file.size
                    // What is here, parts too: a file skipped because it is
                    // already whole must not make the bar go back.
                    self?.states[model] = .downloading(received: self?.bytesHere(of: model) ?? done, total: total)
                }
                self?.states[model] = .checking
                for file in model.files {
                    let digest = try await Self.sha256(of: folder.appendingPathComponent(file.name))
                    guard digest == file.sha256 else {
                        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file.name))
                        throw ModelFileDownload.Failure.mismatch(file.name)
                    }
                }
                FileManager.default.createFile(atPath: folder.appendingPathComponent(".verified").path, contents: Data())
                self?.states[model] = .ready
            } catch is CancellationError {
                let here = self?.bytesHere(of: model) ?? 0
                self?.states[model] = here > 0 ? .stopped(received: here, total: total) : .absent
            } catch {
                self?.states[model] = .failed((error as? ModelFileDownload.Failure)?.message ?? error.localizedDescription)
            }
            self?.downloading = nil
            self?.task = nil
        }
    }

    /// Stops the download. What came stays, and the next download goes on
    /// from there.
    func cancel() {
        task?.cancel()
    }

    /// Takes a model off this Mac.
    func remove(_ model: HandwritingModel) {
        guard !Self.isProbe, downloading != model else { return }
        try? FileManager.default.removeItem(at: directory(for: model))
        states[model] = .absent
        Task { await HandwritingReader.shared.unload() }
    }

    /// A file's SHA-256, read a megabyte at a time off the main thread.
    nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// One file's download, with its progress.
enum ModelFileDownload {
    enum Failure: Error {
        case status(Int)
        case mismatch(String)
        /// Bytes of free space the download wants.
        case room(Int64)
        /// The connection closed before the file was whole.
        case short
        /// The file could not be written.
        case disk

        var message: String {
            switch self {
            case .status(let code): L("내려받지 못했어요 (\(code))", "Download failed (\(code))")
            case .mismatch: L("받은 파일이 맞지 않아요. 다시 받아 주세요.", "A downloaded file didn’t match. Try again.")
            case .short: L("받다가 끊겼어요. 다시 받으면 이어서 받아요.", "The download stopped partway. Download again to go on from there.")
            case .disk: L("받은 파일을 쓰지 못했어요.", "Couldn’t write the downloaded file.")
            case .room(let bytes):
                L("이 맥에 자리가 모자라요. \(UpdateMeasure.size(bytes))가 비어 있어야 해요.",
                  "There isn’t enough space on this Mac. It needs \(UpdateMeasure.size(bytes)) free.")
            }
        }
    }

    /// Downloads `url` into `part`, going on from what is already there:
    /// the request asks for the bytes after it (`Range`), and a server that
    /// sends the whole file instead has it written from the start. Progress
    /// is reported a few times a second, as bytes of this file so far.
    ///
    /// A data task writing to the file as it arrives, not a download task:
    /// the async `download(from:delegate:)` never calls `didWriteData` (on
    /// one file, no progress at all until it was over), and a cancelled
    /// download task leaves its half-file in the system's temporary folder,
    /// where nobody can go on from it and nothing removes it soon.
    static func fetch(_ url: URL, into part: URL, size: Int64,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        var have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if have > size {
            try? FileManager.default.removeItem(at: part)
            have = 0
        }
        if have == size { return }
        if have == 0 { FileManager.default.createFile(atPath: part.path, contents: nil) }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let delegate = Delegate(part: part, have: have, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        let got = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard got == size else {
            // Longer than the file is a part that cannot be gone on from.
            if got > size { try? FileManager.default.removeItem(at: part) }
            throw Failure.short
        }
    }

    /// The session's delegate. Its callbacks come one at a time on the
    /// session's own queue.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let part: URL
        let progress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var written: Int64
        private var handle: FileHandle?
        private var failure: Failure?
        private var said = Date.distantPast

        init(part: URL, have: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.part = part
            self.written = have
            self.progress = progress
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            do {
                switch status {
                case 206:
                    // The rest, after what is here.
                    handle = try FileHandle(forWritingTo: part)
                    try handle?.seekToEnd()
                case 200:
                    // The whole file: what was here is not part of it.
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                    handle = try FileHandle(forWritingTo: part)
                    written = 0
                default:
                    failure = .status(status)
                    return completionHandler(.cancel)
                }
            } catch {
                failure = .disk
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle?.write(contentsOf: data)
            } catch {
                failure = .disk
                return dataTask.cancel()
            }
            written += Int64(data.count)
            let now = Date()
            guard now.timeIntervalSince(said) > 0.2 else { return }
            said = now
            progress(written)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle?.close()
            handle = nil
            guard let continuation else { return }
            self.continuation = nil
            if let failure {
                continuation.resume(throwing: failure)
            } else if let error {
                continuation.resume(throwing: (error as NSError).code == NSURLErrorCancelled ? CancellationError() : error)
            } else {
                progress(written)
                continuation.resume()
            }
        }
    }
}
#endif
