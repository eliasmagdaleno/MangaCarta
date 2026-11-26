import Foundation

/// Ordered title spellings contributed by one local Work's imported items.
/// Chapter numbers (ComicInfo Volume/Number and filename digits) are deliberately absent.
struct LocalTitleEvidence: Equatable {
    let titles: [String]

    init(items: [LocalItemRecord]) {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let filenameStem = URL(fileURLWithPath: item.sourceFilename)
                .deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            for candidate in [item.comicInfo?.series, item.comicInfo?.title, filenameStem].compactMap({ $0 }) {
                let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty && seen.insert(title).inserted { result.append(title) }
            }
        }
        titles = result
    }

    /// Adds evidence monotonically to Work matcher input; display title is untouched.
    func appending(to work: inout Work) {
        for title in titles { work.noteTitle(title) }
    }
}
