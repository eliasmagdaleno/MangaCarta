import Foundation

/// A chapter number parsed into an exact, orderable value.
///
/// Only the numeric value participates in identity, so source relabeling such as
/// `"07"` to `"7"` remains the same chapter.
struct ChapterOrdinal: Hashable, Comparable, Codable {
    let value: Decimal

    init(value: Decimal) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self),
           let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) {
            self.value = value
            return
        }
        if let value = try? container.decode(Decimal.self) {
            self.value = value
            return
        }
        throw DecodingError.dataCorruptedError(in: container,
                                                debugDescription: "Chapter ordinal must be a decimal string or number")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.description)
    }

    static func parse(_ raw: String) -> ChapterOrdinal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = trimmed.startIndex

        while index < trimmed.endIndex, trimmed[index].isASCIIDigit {
            index = trimmed.index(after: index)
        }

        guard index != trimmed.startIndex else { return nil }

        if index < trimmed.endIndex, trimmed[index] == "." {
            let decimalPoint = index
            let fractionalStart = trimmed.index(after: decimalPoint)
            var fractionalEnd = fractionalStart

            while fractionalEnd < trimmed.endIndex, trimmed[fractionalEnd].isASCIIDigit {
                fractionalEnd = trimmed.index(after: fractionalEnd)
            }

            if fractionalEnd != fractionalStart {
                index = fractionalEnd
            }
        }

        let numericRun = String(trimmed[..<index])
        guard let value = Decimal(string: numericRun, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return ChapterOrdinal(value: value)
    }

    static func < (lhs: ChapterOrdinal, rhs: ChapterOrdinal) -> Bool {
        lhs.value < rhs.value
    }
}

struct ChapterFrontier: Codable, Equatable {
    private(set) var known: Set<ChapterOrdinal> = []
    private(set) var max: ChapterOrdinal?
    private(set) var unnumbered: Set<String> = []

    /// Returns only previously unseen ordinals above the frontier that existed
    /// before this observation. Older unseen ordinals are silent backfill.
    mutating func absorb(_ rawNumbers: [String]) -> [ChapterOrdinal] {
        var parsed: Set<ChapterOrdinal> = []

        for rawNumber in rawNumbers {
            if let ordinal = ChapterOrdinal.parse(rawNumber) {
                parsed.insert(ordinal)
            } else {
                unnumbered.insert(rawNumber)
            }
        }

        let previousMax = max
        let released = parsed.filter { ordinal in
            !known.contains(ordinal) && (previousMax == nil || ordinal > previousMax!)
        }

        known.formUnion(parsed)
        if let observedMax = parsed.max(), max == nil || observedMax > max! {
            max = observedMax
        }

        return released.sorted()
    }

    /// Establishes a first-observation baseline without exposing releases.
    mutating func seed(_ rawNumbers: [String]) {
        _ = absorb(rawNumbers)
    }

    /// Unions persisted evidence without interpreting either side as a new release.
    mutating func mergeEvidence(from other: ChapterFrontier) {
        known.formUnion(other.known)
        unnumbered.formUnion(other.unnumbered)
        if let otherMax = other.max, max == nil || otherMax > max! {
            max = otherMax
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { (48...57).contains($0.value) } == true
    }
}
