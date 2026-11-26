import Foundation

/// The navigation sink a new-chapter notification routes into. The composition hands `open`
/// to the notifier as its `openWork`; the Library tab observes `requestedWork` and pushes
/// Updates focused on the Work (Updates spec, owner decision 2). It never opens a chapter
/// (ADR-0021).
@MainActor
final class WorkNavigator: ObservableObject {
    @Published var requestedWork: WorkID?

    func open(_ workId: WorkID) {
        requestedWork = workId
    }
}
