//
//  DetailSectionPicker.swift
//  MangaCarta
//

import SwiftUI

struct DetailSectionPicker: View {
    @Binding var section: DetailSection
    let availability: DetailSectionAvailability
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            picker
                .pickerStyle(.menu)
                .frame(minHeight: 44)
        } else {
            picker
                .pickerStyle(.segmented)
        }
    }

    private var picker: some View {
        Picker("Sections", selection: $section) {
            ForEach(availability.sections) { section in
                Text(section.title).tag(section)
            }
        }
        .tint(Ink.seal)
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, Gutter.page)
        .accessibilityIdentifier("detailSectionPicker")
    }
}
