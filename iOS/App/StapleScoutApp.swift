import SwiftUI
import SwiftData
import StapleScoutKit

@main struct StapleScoutApp: App {
    private let result: Result<LibraryStore, Error>
    init() {
        result = Result {
            let directory = URL.applicationSupportDirectory.appending(path: "StapleScout", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configuration = ModelConfiguration(url: directory.appending(path: "Library.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: SavedLibrary.self, configurations: configuration)
            return try LibraryStore(context: ModelContext(container))
        }
    }
    var body: some Scene {
        WindowGroup {
            switch result {
            case .success(let store): RootView(store: store)
            case .failure:
                ContentUnavailableView {
                    Label("Couldn’t open your library", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Your saved data has been preserved. Check available device storage and reopen the app. If the library was created by a newer version, update Staple Scout.")
                }
            }
        }
    }
}

struct RootView: View {
    @Bindable var store: LibraryStore
    @Environment(\.colorScheme) private var appearance
    var body: some View {
        TabView {
            NavigationStack { StaplesView(store: store) }.tabItem { Label("Staples", systemImage: "list.bullet") }
            NavigationStack { CompareView(store: store) }.tabItem { Label("Compare", systemImage: "arrow.left.arrow.right") }
            NavigationStack { ShoppingView(store: store) }.tabItem { Label("This week", systemImage: "basket") }
            NavigationStack { StoresView(store: store) }.tabItem { Label("Stores", systemImage: "storefront") }
        }
        .tint(appearance == .dark ? Color(red: 0.46, green: 0.79, blue: 0.62) : Color(red: 0.09, green: 0.39, blue: 0.28))
        .alert("Couldn’t complete that", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
            Button("OK", role: .cancel) { store.failure = nil }
        } message: { Text(store.failure ?? "") }
        .alert("Refresh complete", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("Done", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
}

func money(_ amount: Decimal?) -> String { amount.map { $0.formatted(.currency(code: "USD")) } ?? "Unknown" }
func quantity(_ amount: Decimal) -> String { amount.formatted(.number.precision(.fractionLength(0...6))) }
func describe(_ error: Error) -> String { error.localizedDescription }

/// Decimal-pad input must consume the complete field; Decimal(string:) accepts trailing junk.
func entryDecimal(_ text: String) -> Decimal? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let separator = Locale.current.decimalSeparator ?? "."
    let escaped = NSRegularExpression.escapedPattern(for: separator)
    guard text.range(of: "^[0-9]+(?:" + escaped + "[0-9]+)?$", options: .regularExpression) != nil else { return nil }
    return Decimal(string: text, locale: Locale.current)
}
