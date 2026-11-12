//
//  DetailSection.swift
//  MangaCarta
//

enum DetailSection: String, CaseIterable, Identifiable {
    case chapters
    case related
    case similar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chapters: return "Chapters"
        case .related: return "Related"
        case .similar: return "Similar"
        }
    }
}

struct DetailSectionAvailability: Equatable {
    var hasRelated: Bool
    var hasSimilar: Bool

    var sections: [DetailSection] {
        [.chapters]
            + (hasRelated ? [.related] : [])
            + (hasSimilar ? [.similar] : [])
    }

    var showsPicker: Bool { sections.count > 1 }

    func resolve(_ requested: DetailSection) -> DetailSection {
        sections.contains(requested) ? requested : .chapters
    }
}
