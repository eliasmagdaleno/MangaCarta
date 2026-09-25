//
//  InkComponents.swift
//  MangaCarta
//
//  Reusable "Ink & Seal" building blocks: the screentone placeholder that
//  stands in for loading art, the section header with its seal tick, small
//  metadata stamps, and empty-state scaffolding.
//

import SwiftUI

// MARK: - Screentone (halftone) placeholder

/// The signature motif: a halftone dot field, the way manga renders shading.
/// Used behind loading covers and pages instead of a flat gray box.
struct Screentone: View {
    var dot: CGFloat = 3
    var spacing: CGFloat = 7
    var color: Color = Ink.tertiary
    var opacity: Double = 0.35

    var body: some View {
        Canvas { context, size in
            let step = dot + spacing
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
                    x += step
                }
                y += step
            }
        }
        .background(Ink.surfaceAlt)
    }
}

/// A spinner that cannot be silent.
///
/// Issue #109, checklist row 7.3. Every loading indicator in the app used to be a bare
/// `ProgressView()`, which reaches VoiceOver as a focus stop that says nothing — not what
/// is loading, not what will be there when it finishes. Seven of them.
///
/// The label is a required initialiser argument, so the fix is structural rather than a
/// sweep that has to be repeated: an unlabelled spinner is now the thing you have to go
/// out of your way to write. Say what is loading and from where — "Searching MangaDex",
/// not "Loading" — because a reader who cannot see the empty screen has only this
/// sentence to tell them the app is working rather than stuck.
///
/// `caption` is the visible text where a site already drew one; it is spoken through the
/// label like everything else, so the two cannot drift.
struct InkLoading: View {
    let label: String
    var caption: String?

    init(_ label: String, caption: String? = nil) {
        self.label = label
        self.caption = caption
    }

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().tint(Ink.seal)
            if let caption {
                Text(caption)
                    .font(.inkMono(11, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A cover-shaped placeholder: screentone with a centered seal tick.
struct CoverPlaceholder: View {
    var showsSpinner = false

    var body: some View {
        Screentone()
            .overlay {
                if showsSpinner {
                    ProgressView().tint(Ink.seal)
                } else {
                    Image(systemName: "book.closed")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Ink.tertiary)
                }
            }
    }
}

// MARK: - Section header

/// Section title in the print voice: a vermilion seal tick, an optional monospaced
/// eyebrow, and a serif title. Only pass an eyebrow when it states something the
/// title doesn't (a feed's ordering, a count) — never a restatement of the title.
struct InkSectionHeader: View {
    let eyebrow: String?
    let title: String

    init(_ title: String, eyebrow: String? = nil) {
        self.title = title
        self.eyebrow = eyebrow
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Seal tick — the one spot of accent.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Ink.seal)
                .frame(width: 4, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                if let eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow.uppercased())
                        .font(.inkMono(10, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Ink.tertiary)
                }
                Text(title)
                    .font(.inkDisplay(22))
                    .foregroundStyle(Ink.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Gutter.page)
        // One stop, not two, and a stop the Headings rotor can find. The eyebrow is the
        // value rather than part of the label: see `SectionHeaderPresentation` for the
        // four XCUITests that depend on the label being the title verbatim.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue ?? "")
        .accessibilityAddTraits(.isHeader)
    }

    private var presentation: SectionHeaderPresentation {
        SectionHeaderPresentation(title: title, eyebrow: eyebrow)
    }
}

// MARK: - Metadata stamp

/// Small monospaced label, e.g. "CH·012" or "NEW". Reads like a spine stamp.
struct InkStamp: View {
    let text: String
    var tinted = false

    var body: some View {
        Text(text)
            .font(.inkMono(10, weight: .semibold))
            .tracking(0.5)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(tinted ? Ink.seal : Ink.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(tinted ? Ink.sealSoft : Ink.surfaceAlt)
            )
    }
}

// MARK: - Empty state

/// A calm, centered empty state for stubbed / unpopulated screens.
struct InkEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Ink.sealSoft)
                    .frame(width: 76, height: 76)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Ink.seal)
            }
            Text(title)
                .font(.inkDisplay(20))
                .foregroundStyle(Ink.primary)
            Text(message)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.seal))
                    .buttonStyle(.plain)
            }
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .font(.subheadline.bold())
                    .foregroundStyle(Ink.seal)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.background)
        .accessibilityElement(children: .contain)
    }
}
