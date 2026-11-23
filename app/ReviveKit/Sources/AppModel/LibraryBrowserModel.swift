import Foundation
import Library
import Observation

/// The recording list of the Mac window (ADR-011, features.md X13, M5 step one): every recording
/// on this Mac, newest first, a search over titles, transcripts and summaries, and importing
/// files. No card and no network: pairing and sync come once they have Mac evidence (CLAUDE.md
/// rule 6). The iPhone keeps `HomeModel`, which also follows the card.
@MainActor
@Observable
public final class LibraryBrowserModel {
    /// Not in 最近删除, newest first.
    public private(set) var recordings: [Recording] = []
    /// Results of `query`; nil while it is empty.
    public private(set) var searchResults: [Recording]?
    public private(set) var isImporting = false
    public private(set) var loadError: String?
    public var toast: Toast?

    /// The search field. Searching runs on every change, on this Mac only.
    public var query = "" {
        didSet { if query != oldValue { search() } }
    }

    /// What the list shows.
    public var shown: [Recording] { searchResults ?? recordings }

    public let library: RecordingLibrary
    @ObservationIgnored private var observation: LibraryObservation?

    public init(library: RecordingLibrary) {
        self.library = library
    }

    public func start() {
        guard observation == nil else { return }
        observation = library.observeRecordings(
            onError: { [weak self] in self?.loadError = String(describing: $0) },
            onChange: { [weak self] in
                guard let self else { return }
                recordings = $0
                loadError = nil
                // Keep results current when a recording is added, renamed or deleted.
                if searchResults != nil { search() }
            })
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Imports audio or text files (`LibraryImport`); the caller has opened their security scope.
    public func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        toast = Toast(await LibraryImport.run(urls, into: library).text)
    }

    /// "11月7日 14:02" (or the title given) and "14:02 · 23 分钟 · 导入" for a list row, as on the iPhone.
    public func rowTitle(_ recording: Recording) -> String { RecordingText.title(recording) }

    public func rowSubtitle(_ recording: Recording) -> String {
        RecordingText.subtitle(recording, deviceName: nil)
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = trimmed.isEmpty ? nil : ((try? library.searchRecordings(trimmed)) ?? [])
    }
}
