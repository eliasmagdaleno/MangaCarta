import Foundation

/// The identity of the WeebCentral package that builds under ADR-0003 Amendment 5 shipped
/// inside the app. The package itself is withdrawn (Amendment 6); these constants remain
/// because devices that ran those builds still hold its repository record and data under
/// them — `ExtensionComposition.retireBundledSources()` retires the record, and
/// `InstalledSourceIDMigration` reconnects the data when the reader chooses to.
enum BundledRepositories {
    static let weebCentralRepositoryID = UUID(uuidString: "9C6A1C65-2AB0-4B53-8F91-55BDFDEB8E55")!
}
