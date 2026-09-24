//
//  ChapterRowPresentation.swift
//  MangaCarta
//
//  Issue #90. What a chapter row *says* — to the eye and to VoiceOver — decided in one
//  place, from one set of inputs.
//
//  It exists because those two answers were allowed to disagree. `ChapterRow` rendered a
//  read chapter by dimming it to `Ink.tertiary` and published no accessibility label at
//  all, so the row reached VoiceOver as three separate focus stops ("CH·12", the title,
//  the date) and its read state reached VoiceOver not at all. Colour-only state is exactly
//  what DESIGN.md's "Focus / State" rule forbids.
//
//  Deciding the dimming and the sentence together, here, makes that combination
//  unrepresentable rather than merely fixed once: `isDimmed` and `accessibilityLabel` are
//  computed from the same two booleans, and a test walks the whole input space asserting
//  they agree.
//
//  The read/in-progress rule is `ChapterRow`'s original one, unchanged: `pageCount > 0`
//  is not redundant with `!isComplete`, because an entry recorded before any page loaded
//  has a count of 0 — neither finished nor mid-read.
//

import Foundation

struct ChapterRowPresentation: Equatable {

    /// Genuinely mid-read: opened, past the first render, and not finished. This chapter
    /// is the user's current spot, so it stays undimmed and carries the resume marker.
    let isInProgress: Bool

    /// Read and not mid-read. Drives the dimmed foreground — and only ever in step with
    /// the sentence below.
    let isDimmed: Bool

    /// The whole row as one spoken sentence: which chapter, what it is called, when it
    /// landed, and where the reader left it.
    ///
    /// Deliberately *not* built from the on-screen strings. The stamp reads "CH·12", and
    /// a middle dot is not a word — VoiceOver would either swallow it or announce it.
    let accessibilityLabel: String

    /// The source's scanlation-group credit, formatted for the secondary row line.
    let groupCredit: String?

    init(chapter: Chapter, progress: ReadingEntry?, isRead: Bool) {
        let inProgress = progress.map { $0.pageCount > 0 && !$0.isComplete } ?? false
        self.isInProgress = inProgress
        self.isDimmed = isRead && !inProgress
        let nonemptyGroups = chapter.groups?.filter { !$0.isEmpty } ?? []
        self.groupCredit = nonemptyGroups.isEmpty ? nil : nonemptyGroups.joined(separator: ", ")

        var parts = ["Chapter \(chapter.number)"]
        if let title = chapter.title, !title.isEmpty { parts.append(title) }
        if let groupCredit { parts.append("Scanlation group: \(groupCredit)") }
        if let date = chapter.date {
            parts.append(date.formatted(.dateTime.month(.wide).day().year()))
        }
        if inProgress, let progress {
            parts.append("In progress, page \(progress.page + 1) of \(progress.pageCount)")
        } else {
            parts.append(isRead ? "Read" : "Unread")
        }
        self.accessibilityLabel = parts.joined(separator: ", ")
    }

    /// Selection state belongs in the *value*, not the label — it changes while the label
    /// does not, and iOS reads a changed value on its own. `nil` outside selection mode so
    /// an ordinary row does not claim to be unselected.
    func accessibilityValue(selecting: Bool, selected: Bool) -> String? {
        guard selecting else { return nil }
        return selected ? "Selected" : "Not selected"
    }
}
