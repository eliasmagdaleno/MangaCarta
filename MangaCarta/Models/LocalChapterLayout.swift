import Foundation

enum LocalChapterLayout {
    static func normalize(_ chapters: [ZipArchiveReader.Chapter], itemTitle: String = "") -> [LocalChapter] {
        let sorted = chapters.sorted { natural($0.name, $1.name) }
        guard !sorted.isEmpty else { return [] }
        let root = sorted.first { $0.name == "Root" || $0.name.isEmpty }
        let folders = sorted.filter { $0.name != "Root" && !$0.name.isEmpty }
        let groups: [(String, [ZipArchiveReader.Entry])]
        if folders.count <= 1 {
            if let folder = folders.first, root != nil {
                groups = [("Root", root!.pages), (folder.name, folder.pages)]
            } else if let folder = folders.first {
                groups = [(itemTitle.isEmpty ? folder.name : itemTitle, folder.pages)]
            } else {
                groups = [(itemTitle, root?.pages ?? sorted[0].pages)]
            }
        } else {
            groups = (root.map { [("Root", $0.pages)] } ?? []) + folders.map { ($0.name, $0.pages) }
        }
        return groups.enumerated().map { index, group in
            LocalChapter(number: index + 1, title: group.0, pageCount: group.1.count,
                         pageFiles: group.1.map { URL(fileURLWithPath: $0.name).lastPathComponent })
        }
    }

    private static func natural(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
