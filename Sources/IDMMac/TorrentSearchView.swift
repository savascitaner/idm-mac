import AppKit
import SwiftUI

/// The "Torrent ara" tab: searches legal, openly licensed sources and queues the chosen torrent.
struct TorrentSearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query: String
    private let autoSearch: Bool

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
        autoSearch = !initialQuery.isEmpty
    }
    @State private var source = "all"
    @State private var results: [TorrentResult] = []
    @State private var errors: [String] = []
    @State private var searching = false
    @State private var searched = false
    @State private var added = Set<String>()

    private var chosen: [TorrentSource] {
        source == "all" ? TorrentSearch.sources : TorrentSearch.sources.filter { $0.name == source }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Ara: film adı, albüm, kitap, ubuntu, debian…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Picker("", selection: $source) {
                    Text("Tüm kaynaklar").tag("all")
                    ForEach(TorrentSearch.sources, id: \.name) { s in Text(s.name).tag(s.name) }
                }
                .labelsHidden()
                .frame(width: 180)
                Button(action: search) {
                    if searching { ProgressView().controlSize(.small) } else { Text("Ara") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            Text("Yalnızca yasal kaynaklarda arar: Internet Archive (kamu malı ve serbest lisanslı film, müzik, kitap, yazılım) ve resmi Linux dağıtımları. Magnet linkleri ve .torrent dosyaları da tarayıcıdan ya da \"+\" ile eklenebilir.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(errors, id: \.self) { e in
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(searching ? L("Aranıyor…") : searched ? L("Sonuç bulunamadı") : L("Aramak istediğini yaz"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { r in row(r) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(16)
        .onAppear { if autoSearch { search() } }
    }

    private func row(_ r: TorrentResult) -> some View {
        HStack(spacing: 12) {
            Group {
                if let t = r.thumbnail, let u = URL(string: t) {
                    AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                        Color.secondary.opacity(0.12)
                    }
                } else {
                    ZStack {
                        Color.teal.opacity(0.15)
                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.teal)
                    }
                }
            }
            .frame(width: 56, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(r.source).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.teal.opacity(0.18)))
                    Text(r.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let p = r.page, let u = URL(string: p) {
                Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help("Sayfasını aç")
            }
            Button(added.contains(r.id) ? L("Eklendi") : L("İndir")) {
                model.addTorrent(r.link, name: r.title, pageURL: r.page)
                added.insert(r.id)
            }
            .disabled(added.contains(r.id))
        }
        .padding(.vertical, 2)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searching else { return }
        searching = true
        errors = []
        let sources = chosen
        Task {
            let (found, errs) = await TorrentSearch.run(q, in: sources)
            results = found
            errors = errs
            searching = false
            searched = true
        }
    }
}
