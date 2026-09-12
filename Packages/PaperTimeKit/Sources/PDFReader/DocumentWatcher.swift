import Foundation
import LibraryStore

/// Hears when an open paper's file, or its record folder, changes underneath
/// the reader — a highlight made on the Mac arriving on the iPad through
/// iCloud, a page of ink written on the iPad arriving on the Mac.
///
/// Two ears, because neither hears everything. A file presenter is what
/// iCloud and every coordinated writer talk to, and on iOS it is also what
/// keeps the file's newest version coming down. A kqueue on the folder hears
/// a plain write by anything else. Both report into one debounced callback;
/// the session then compares fingerprints, so a false alarm costs a stat.
final class DocumentWatcher: @unchecked Sendable {
    private var presenters: [Presenter] = []
    private var folders: [FolderWatcher] = []
    private let queue = DispatchQueue(label: "com.imtaeheon.PaperTime.DocumentWatcher")
    private var pending: DispatchWorkItem?
    private let onChange: @Sendable () -> Void

    init(document: URL, record: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let relay: @Sendable () -> Void = { [weak self] in self?.schedule() }
        presenters = [
            Presenter(url: document, onChange: relay),
            Presenter(url: record, onChange: relay),
        ]
        folders = [
            FolderWatcher(url: document.deletingLastPathComponent(), quietPeriod: .milliseconds(300), onChange: relay),
            FolderWatcher(url: record, quietPeriod: .milliseconds(300), onChange: relay),
        ]
        for presenter in presenters { NSFileCoordinator.addFilePresenter(presenter) }
        for folder in folders { folder.start() }
    }

    deinit {
        for presenter in presenters { NSFileCoordinator.removeFilePresenter(presenter) }
        for folder in folders { folder.stop() }
        pending?.cancel()
    }

    private func schedule() {
        queue.async { [self] in
            pending?.cancel()
            let work = DispatchWorkItem { [onChange] in onChange() }
            pending = work
            queue.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
        }
    }

    /// One presented URL. Presenting a folder also reports its sub-items.
    private final class Presenter: NSObject, NSFilePresenter {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        private let onChange: @Sendable () -> Void

        init(url: URL, onChange: @escaping @Sendable () -> Void) {
            presentedItemURL = url
            self.onChange = onChange
            presentedItemOperationQueue.maxConcurrentOperationCount = 1
        }

        func presentedItemDidChange() { onChange() }
        func presentedSubitemDidChange(at url: URL) { onChange() }
        func presentedSubitemDidAppear(at url: URL) { onChange() }
        func presentedItemDidGain(_ version: NSFileVersion) { onChange() }
    }
}
