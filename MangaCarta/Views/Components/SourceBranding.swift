//
//  SourceBranding.swift
//  MangaCarta
//
//  Visual identity for sources: the logo (bundled asset per source id, with a
//  monogram-seal fallback), the Home chip bar that switches the browse source,
//  and the small logo+name stamp used on the detail screen.
//

import SwiftUI
import UIKit

// MARK: - Logo

/// A source's logo mark. Looks up "SourceLogo-<id>" in the asset catalog and
/// falls back to a seal-tinted serif monogram for sources without a bundled logo.
struct SourceLogoView: View {
    let sourceID: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = UIImage(named: "SourceLogo-\(sourceID)") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(Ink.sealSoft)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(sourceID.prefix(1).uppercased())
                            .font(.inkDisplay(size * 0.62))
                            .foregroundStyle(Ink.seal)
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Chip bar (Home source switcher)

/// The Home source switcher: one chip per visible source, logo + name, with the
/// active source seal-tinted. Replaces the old toolbar menu so the sources are
/// always visible and one tap away.
struct SourceChipBar: View {
    let sources: [any MangaSource]
    let activeID: String
    var accessibilityVerb = "Browse"
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources, id: \.id) { source in
                    chip(for: source)
                }
            }
            .padding(.horizontal, Gutter.page)
        }
    }

    private func chip(for source: any MangaSource) -> some View {
        let active = source.id == activeID
        return Button {
            onSelect(source.id)
        } label: {
            HStack(spacing: 6) {
                SourceLogoView(sourceID: source.id, size: 16)
                    .grayscale(active ? 0 : 1)
                    .opacity(active ? 1 : 0.7)
                Text(source.name.uppercased())
                    .font(.inkMono(10, weight: .bold))
                    .tracking(0.8)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Ink.seal : Ink.secondary)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active ? Ink.sealSoft : Ink.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(active ? Ink.seal : Ink.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("\(accessibilityVerb) \(source.name)")
        .accessibilityInputLabels([source.name, "\(accessibilityVerb) \(source.name)"])
        .accessibilityValue(active ? "Selected" : "Not selected")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

// MARK: - Source stamp (detail screen)

/// Logo + name in the metadata-stamp voice, for the detail screen's stamp row.
struct SourceStamp: View {
    let sourceID: String
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            SourceLogoView(sourceID: sourceID, size: 13)
            Text(name.uppercased())
                .font(.inkMono(10, weight: .semibold))
                .tracking(0.5)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(Ink.seal)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Ink.sealSoft)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source: \(name)")
    }
}

/// The source stamp when the Work has somewhere else to be read from (ADR-0004).
///
/// A native `Menu`, not a bespoke sheet: choosing among a handful of named options is what
/// menus are for, and it inherits selection semantics, dismissal, and VoiceOver for free.
/// The stamp keeps the plain one's shape and gains a chevron, so the affordance is visible
/// rather than discovered by pressing a label that used to be inert.
///
/// A **pinned** source wears the seal. That is the one honest use of the accent here: the
/// reader chose this, and the ranking is being overridden on their say-so. An automatic pick
/// stays neutral, because it is the app's guess and not a statement.
struct SourcePickerStamp: View {
    let presentation: SourcePickerPresentation
    let isPinned: Bool
    let select: (ListingKey) -> Void
    let useBestAvailable: () -> Void
    let addSource: () -> Void

    /// The row being fulfilled from, for the stamp's own label.
    private var current: SourceOptionPresentation? {
        presentation.rows.first { $0.isCurrent }
    }

    var body: some View {
        Menu {
            Section("Read from") {
                ForEach(presentation.rows) { row in
                    Button {
                        select(row.key)
                    } label: {
                        // A checkmark rather than colour alone — the design system's rule,
                        // and the only marker that survives Differentiate Without Color.
                        if row.isCurrent {
                            Label("\(row.name) · \(row.detail)", systemImage: "checkmark")
                        } else {
                            Text("\(row.name) · \(row.detail)")
                        }
                    }
                }
            }
            if isPinned {
                // Only offered once there is a pin to drop, so the menu does not carry a
                // control that would do nothing.
                Button("Use best available", systemImage: "arrow.uturn.backward") {
                    useBestAvailable()
                }
            }
            Divider()
            Button("Add a Source…", systemImage: "plus") {
                addSource()
            }
            .accessibilityIdentifier("addSourceMenuItem")
        } label: {
            stamp
        }
        .accessibilityIdentifier("sourcePicker")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Choose which source to read this from")
    }

    private var stamp: some View {
        HStack(spacing: 5) {
            SourceLogoView(sourceID: current?.key.sourceId ?? "", size: 13)
            Text((current?.name ?? "").uppercased())
                .font(.inkMono(10, weight: .semibold))
                .tracking(0.5)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .padding(.leading, -1)
        }
        .foregroundStyle(isPinned ? Ink.seal : Ink.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isPinned ? Ink.sealSoft : Ink.surfaceAlt)
        )
        // The stamp stays stamp-sized; the tappable region does not. 44pt is the release
        // accessibility baseline, and a 22pt-tall menu trigger misses it by half.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: String {
        guard let current else { return "Source" }
        let pinned = isPinned ? ", pinned" : ""
        return "Source: \(current.name), \(current.detail)\(pinned)"
    }
}
