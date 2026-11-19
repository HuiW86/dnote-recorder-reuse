import Foundation
import Library
import Observation

/// 纠错词库 in settings (#75): the words the user corrected in transcripts, newest first, each
/// replaced in transcripts made afterwards. Local only.
@MainActor
@Observable
public final class CorrectionsModel {
    public private(set) var corrections: [Correction] = []
    public var toast: Toast?

    @ObservationIgnored private let library: RecordingLibrary

    public init(library: RecordingLibrary) {
        self.library = library
        reload()
    }

    public func reload() {
        corrections = (try? library.corrections()) ?? []
    }

    public func delete(_ correction: Correction) {
        do {
            try library.deleteCorrection(wrong: correction.wrong)
            reload()
        } catch {
            toast = Toast("删除失败，请重试")
        }
    }
}
