import Foundation

/// The navigation sink a new-chapter notification routes into (ADR-0021: "Opening a
/// notification routes to the Work's chapter list"). The composition hands `open` to the
/// notifier as its `openWork`; the Library tab observes `requestedWork` and pushes the
/// Work's detail page.
@MainActor
final class WorkNavigator: ObservableObject {
    @Published var requestedWork: WorkID?

    func open(_ workId: WorkID) {
        requestedWork = workId
    }
}
