import SwiftUI

struct LocalImportBanner: View {
    @ObservedObject var model: LocalImportViewModel
    let onCancel: () -> Void

    var body: some View {
        if model.isImporting {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Importing \(model.completedFiles + 1) of \(model.totalFiles)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.seal)
                }
                if let progress = model.current {
                    Text(progress.fileName).font(.footnote).foregroundStyle(Ink.secondary)
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .tint(Ink.seal)
                } else {
                    ProgressView().tint(Ink.seal)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.hairline))
            .padding(.horizontal, Gutter.page)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Importing files")
        } else if !model.errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.errors, id: \.self) { Text($0).font(.footnote) }
            }
            .foregroundStyle(Ink.seal)
            .padding(.horizontal, Gutter.page)
        }
    }
}
