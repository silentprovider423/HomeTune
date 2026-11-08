import SwiftUI

/// Mediathek: Abschnitte (ein-/ausblendbar, sortierbar) und „Zuletzt hinzugefügt“ – wie Apple.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("library.order") private var orderRaw = LibrarySection.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("library.hidden") private var hiddenRaw = ""
    @State private var editing = false

    private var order: [LibrarySection] {
        let saved = orderRaw.split(separator: ",").compactMap { LibrarySection(rawValue: String($0)) }
        return saved + LibrarySection.allCases.filter { !saved.contains($0) }
    }
    private var hidden: Set<LibrarySection> {
        Set(hiddenRaw.split(separator: ",").compactMap { LibrarySection(rawValue: String($0)) })
    }

    var body: some View {
        List {
            if let err = app.library.lastError, app.library.isOffline || !app.library.loadedOnce {
                Section {
                    Label(app.library.isOffline ? String(localized: "Offline – nur geladene Musik ist verfügbar.") : err,
                          systemImage: app.library.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if editing {
                Section {
                    ForEach(order) { s in
                        Button {
                            toggle(s)
                        } label: {
                            HStack {
                                Image(systemName: hidden.contains(s) ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(hidden.contains(s) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.accent))
                                    .font(.title3)
                                Label { Text(s.title) } icon: { Image(systemName: s.icon).foregroundStyle(.accent) }
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .onMove { from, to in
                        var o = order
                        o.move(fromOffsets: from, toOffset: to)
                        orderRaw = o.map(\.rawValue).joined(separator: ",")
                    }
                }
                .environment(\.editMode, .constant(.active))
            } else {
                Section {
                    ForEach(order.filter { !hidden.contains($0) }) { s in
                        NavigationLink(value: Route.section(s)) {
                            Label { Text(s.title).font(.title3) } icon: { Image(systemName: s.icon).foregroundStyle(.accent) }
                                .padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("section.\(s.rawValue)")
                    }
                }
                if !app.library.recentlyAdded.isEmpty {
                    Section {
                        Text("Zuletzt hinzugefügt").font(.title2.bold())
                            .padding(.top, 12)
                            .listRowSeparator(.hidden)
                        LazyVGrid(columns: albumGrid, spacing: 18) {
                            ForEach(app.library.recentlyAdded.prefix(12)) { AlbumTile(album: $0) }
                        }
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Mediathek")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? LocalizedStringKey("Fertig") : LocalizedStringKey("Bearbeiten")) {
                    withAnimation { editing.toggle() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.showSettings = true } label: { Image(systemName: "person.crop.circle") }
                    .accessibilityLabel(Text("Konto und Einstellungen"))
            }
        }
        .refreshable { await app.library.refresh() }
        .overlay {
            if app.library.isLoading && !app.library.loadedOnce { ProgressView() }
        }
    }

    private func toggle(_ s: LibrarySection) {
        var h = hidden
        if h.contains(s) { h.remove(s) } else { h.insert(s) }
        hiddenRaw = h.map(\.rawValue).joined(separator: ",")
    }
}
