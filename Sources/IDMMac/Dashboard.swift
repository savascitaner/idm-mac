import AppKit
import Charts
import SwiftUI

// MARK: Building blocks

struct ProgressRing: View {
    var progress: Double
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(1, progress)))
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: progress)
        }
    }
}

/// Small area chart of speed samples.
struct Sparkline: View {
    let samples: [Double]
    var tint: Color = .accentColor

    var body: some View {
        let peak = max(samples.max() ?? 0, 1)
        Chart(Array(samples.enumerated()), id: \.offset) { item in
            AreaMark(x: .value("t", item.offset), y: .value("hız", item.element))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.03)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", item.offset), y: .value("hız", item.element))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...(peak * 1.15))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

struct StatCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let content: Content

    init(_ title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.bold()).foregroundStyle(tint)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.18), lineWidth: 1))
    }
}

/// Video thumbnail, the real file icon once finished, or a colored category tile.
struct FileThumb: View {
    let record: DownloadRecord
    var size: CGFloat = 36

    var body: some View {
        let cat = Category.of(record)
        if let t = record.thumbnail, let u = URL(string: t) {
            AsyncImage(url: u) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                tile(cat)
            }
            .frame(width: size * 16 / 9, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            .overlay(alignment: .bottomLeading) {
                Image(systemName: cat.icon).font(.system(size: size * 0.26, weight: .bold)).foregroundStyle(.white)
                    .padding(size * 0.08).background(Circle().fill(cat.color)).padding(size * 0.06)
            }
        } else if let icon = fileIcon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            tile(cat).frame(width: size, height: size)
        }
    }

    private func tile(_ cat: Category) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22).fill(cat.color.gradient)
            Image(systemName: cat.icon).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white)
        }
    }

    private var fileIcon: NSImage? {
        guard record.state == .completed, let f = record.finalPath, FileManager.default.fileExists(atPath: f) else { return nil }
        return NSWorkspace.shared.icon(forFile: f)
    }
}

// MARK: Header

struct DashboardHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            StatCard("Toplam ilerleme", icon: "chart.pie.fill", tint: .blue) {
                HStack(spacing: 12) {
                    ZStack {
                        ProgressRing(progress: model.overallProgress ?? 0, tint: .blue, lineWidth: 7)
                        Text(model.overallProgress.map { String(format: "%%%.0f", $0 * 100) } ?? "—")
                            .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    }
                    .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.activeCount > 0 ? Format.bytes(model.remainingBytes) : "—")
                            .font(.headline.monospacedDigit())
                        Text("kalan").font(.caption).foregroundStyle(.secondary)
                        let eta = Format.eta(remaining: model.remainingBytes, speed: model.totalSpeed)
                        if !eta.isEmpty { Text(eta).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(width: 220)

            StatCard("Anlık hız", icon: "speedometer", tint: .accentColor) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.speed(model.totalSpeed).isEmpty ? "0 B/sn" : Format.speed(model.totalSpeed))
                            .font(.title2.bold().monospacedDigit())
                        let peak = model.speedHistory.max() ?? 0
                        Text("son 1 dk en yüksek: " + (peak <= 1 ? "—" : Format.speed(peak)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    Sparkline(samples: model.speedHistory)
                }
            }

            StatCard("Etkin", icon: "arrow.down.circle.fill", tint: .green) {
                Text("\(model.activeCount)").font(.title.bold().monospacedDigit())
                Text("\(model.queuedCount) sırada · \(model.pausedCount) duraklatıldı")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 160)

            StatCard("Bugün", icon: "calendar", tint: .teal) {
                Text(Format.bytes(model.todayBytes)).font(.title2.bold().monospacedDigit()).lineLimit(1)
                Text("\(model.todayCount) dosya tamamlandı").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 160)
        }
        .frame(height: 100)
        .padding(12)
    }
}

/// Free space on the disk that downloads go to.
struct DiskCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let used = model.diskTotal > 0 ? 1 - Double(model.diskFree) / Double(model.diskTotal) : 0
        let tint: Color = used > 0.92 ? .red : used > 0.8 ? .orange : .accentColor
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Disk", systemImage: "internaldrive.fill").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.bytes(model.diskFree)) boş").font(.caption.monospacedDigit().bold())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint.gradient).frame(width: g.size.width * CGFloat(used))
                }
            }
            .frame(height: 6)
            Text("Toplam \(Format.bytes(model.diskTotal))").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: Detail panel (IDM's "download status" window)

struct DownloadInspector: View {
    @EnvironmentObject var model: AppModel
    let record: DownloadRecord

    var body: some View {
        let cat = Category.of(record)
        let progress = record.state == .completed ? 1 : record.progress
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    FileThumb(record: record, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.fileName.isEmpty ? record.url : record.fileName)
                            .font(.headline).lineLimit(3).textSelection(.enabled)
                        stateLabel
                    }
                }

                HStack {
                    Spacer()
                    ZStack {
                        ProgressRing(progress: progress, tint: record.state == .failed ? .red : cat.color, lineWidth: 12)
                        VStack(spacing: 2) {
                            Text(record.totalBytes > 0 || record.state == .completed ? String(format: "%%%.0f", progress * 100) : "—")
                                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                            Text(Format.bytes(record.receivedBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 140, height: 140)
                    Spacer()
                }

                if record.kind == .file, record.totalBytes > 0, !record.segments.isEmpty {
                    section("Parça haritası") {
                        SegmentBar(record: record, tint: cat.color, height: 20)
                        connections(tint: cat.color)
                    }
                }

                section("Hız") {
                    let series = model.speedSeries[record.id] ?? []
                    HStack {
                        Text(Format.speed(record.speed).isEmpty ? "—" : Format.speed(record.speed))
                            .font(.title3.bold().monospacedDigit())
                        Spacer()
                        if let avg = averageSpeed {
                            Text("ortalama \(Format.speed(avg))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if series.count > 1 {
                        Sparkline(samples: series, tint: cat.color).frame(height: 70)
                    } else {
                        Text("Grafik indirme sürerken çizilir.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("Bilgi") {
                    info("Boyut", Format.bytes(record.totalBytes))
                    info(record.kind == .torrent ? "Eş (peer)" : "Bağlantı", record.connections > 0 ? "\(record.connections)" : "—")
                    info("Eklendi", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let done = record.completedAt {
                        info("Bitti", done.formatted(date: .abbreviated, time: .shortened))
                        info("Süre", Self.duration(done.timeIntervalSince(record.createdAt)))
                    }
                    info("Klasör", record.directory)
                    info("Adres", record.url)
                    if let p = record.pageURL, !p.isEmpty { info("Sayfa", p) }
                    if let e = record.error { info("Hata", e) }
                }

                actions
            }
            .padding(16)
        }
        .frame(width: 330)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch record.state {
        case .queued: Label("Sırada", systemImage: "clock").foregroundStyle(.secondary)
        case .downloading: Label("İndiriliyor", systemImage: "arrow.down.circle.fill").foregroundStyle(.green)
        case .paused: Label("Duraklatıldı", systemImage: "pause.circle.fill").foregroundStyle(.orange)
        case .completed: Label("Tamamlandı", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
        case .failed: Label("Hata", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func connections(tint: Color) -> some View {
        VStack(spacing: 5) {
            ForEach(Array(record.segments.enumerated()), id: \.offset) { item in
                let s = item.element
                let length = s.end >= s.start ? Double(s.end - s.start + 1) : 0
                let fraction = length > 0 ? min(1, Double(s.done) / length) : 0
                HStack(spacing: 8) {
                    Text("\(item.offset + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    ProgressView(value: fraction).tint(s.isComplete ? .green : tint)
                    Text(s.isComplete ? "bitti" : String(format: "%%%.0f", fraction * 100))
                        .font(.caption2.monospacedDigit()).foregroundStyle(s.isComplete ? .green : .secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private var averageSpeed: Double? {
        guard record.state == .completed, let done = record.completedAt else { return nil }
        let t = done.timeIntervalSince(record.createdAt)
        let bytes = max(record.totalBytes, record.receivedBytes)
        return t > 0 && bytes > 0 ? Double(bytes) / t : nil
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return String(format: "%d sa %02d dk", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return String(format: "%d dk %02d sn", s / 60, s % 60) }
        return "\(s) sn"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold())
            content()
        }
    }

    private func info(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            switch record.state {
            case .downloading, .queued:
                Button { model.pause(record.id) } label: { Label("Duraklat", systemImage: "pause.fill") }
            case .paused, .failed:
                Button { model.resume(record.id) } label: { Label("Sürdür", systemImage: "play.fill") }
            case .completed:
                Button { model.open(record) } label: { Label("Aç", systemImage: "arrow.up.forward.app") }
                Button { model.reveal(record) } label: { Label("Finder", systemImage: "folder") }
            }
            Spacer()
            Button(role: .destructive) { model.remove(record.id) } label: { Label("Kaldır", systemImage: "trash") }
        }
        .controlSize(.regular)
    }
}

// MARK: Dock and menu bar

/// The app icon with a progress bar, shown in the Dock while downloading.
struct DockTileView: View {
    let progress: Double

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack(alignment: .bottom) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: w, height: h)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.65))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(h * 0.1, (w * 0.8 - 6) * CGFloat(min(1, progress))))
                        .padding(3)
                }
                .frame(width: w * 0.8, height: h * 0.15)
                .padding(.bottom, h * 0.08)
            }
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("slowMode") private var slowMode = false
    @AppStorage("slowModeKB") private var slowModeKB = 256
    @AppStorage("afterAll") private var afterAll = Schedule.AfterAll.none.rawValue
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        let items = Array(model.downloads.filter { $0.isActive || $0.state == .paused }.prefix(5))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("MDM").font(.headline)
                Spacer()
                Text(model.activeCount > 0 ? Format.speed(model.totalSpeed) : "Hazır")
                    .font(.callout.bold().monospacedDigit())
                    .foregroundStyle(model.activeCount > 0 ? Color.accentColor : .secondary)
            }
            Sparkline(samples: model.speedHistory).frame(height: 40)
            HStack(spacing: 10) {
                Toggle(isOn: $slowMode) { Label("Yavaş mod (\(slowModeKB) KB/sn)", systemImage: "tortoise") }
                    .toggleStyle(.button).controlSize(.small)
                Spacer()
                Picker("Bitince", selection: $afterAll) {
                    ForEach(Schedule.AfterAll.allCases) { a in Text(a.title).tag(a.rawValue) }
                }
                .controlSize(.small).fixedSize()
            }
            if let v = updater.available {
                Button { updater.install() } label: {
                    Label(updater.installing ? "Güncelleniyor…" : "Yeni sürüm var (\(v)), kur", systemImage: "arrow.down.app")
                }
                .controlSize(.small).disabled(updater.installing)
            }
            if items.isEmpty {
                Text("Etkin indirme yok").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(items) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            FileThumb(record: d, size: 18)
                            Text(d.fileName.isEmpty ? d.url : d.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(d.state == .paused ? "duraklatıldı" : d.totalBytes > 0 ? String(format: "%%%.0f", d.progress * 100) : "…")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        SegmentBar(record: d, tint: d.state == .paused ? .gray : Category.of(d).color, height: 5)
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Button {
                    MainWindow.show()
                } label: { Label("Pencere", systemImage: "macwindow") }
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { model.addFromUserInput(s) }
                } label: { Label("Panodan", systemImage: "doc.on.clipboard") }
                Spacer()
                if model.activeCount > 0 {
                    Button { model.pauseAll() } label: { Image(systemName: "pause.fill") }.help("Tümünü duraklat")
                } else {
                    Button { model.resumeAll() } label: { Image(systemName: "play.fill") }.help("Tümünü sürdür")
                }
                Button { AboutPanel.show() } label: { Image(systemName: "info.circle") }.help("Hakkında")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Çık")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: Demo data (only with --demo)

@MainActor
enum DemoData {
    static func fill(_ m: AppModel) {
        m.browsersLinked = ["Google/Chrome"]
        let dir = m.downloadDirectory
        func segments(total: Int64, n: Int, done: [Double]) -> [Segment] {
            let size = total / Int64(n)
            return (0..<n).map { i in
                let start = Int64(i) * size
                let end = i == n - 1 ? total - 1 : start + size - 1
                return Segment(start: start, end: end, done: Int64(Double(end - start + 1) * done[i % done.count]))
            }
        }
        func rec(_ kind: DownloadKind, _ name: String, _ state: DownloadState, _ total: Int64) -> DownloadRecord {
            var r = DownloadRecord(kind: kind, url: "https://example.com/" + name, fileName: name, directory: dir)
            r.state = state
            r.totalBytes = total
            r.createdAt = Date().addingTimeInterval(-600)
            return r
        }
        var dmg = rec(.file, "macOS-Tahoe-Installer.dmg", .downloading, 4_800_000_000)
        dmg.segments = segments(total: dmg.totalBytes, n: 8, done: [1, 0.82, 0.64, 0.9, 0.41, 1, 0.55, 0.3])
        dmg.connections = 8
        var video = rec(.video, "Lo-fi müzik, 1 saat (1080p)", .downloading, 860_000_000)
        video.thumbnail = "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg"
        video.receivedBytes = 310_000_000
        video.connections = 8
        var iso = rec(.file, "ubuntu-24.04-desktop-amd64.iso", .paused, 6_100_000_000)
        iso.segments = segments(total: iso.totalBytes, n: 8, done: [0.7, 0.35, 0.5, 0.2])
        var pdf = rec(.file, "Proje-Sunumu.pdf", .completed, 18_400_000)
        pdf.completedAt = Date().addingTimeInterval(-300)
        var mp3 = rec(.file, "podcast-bolum-42.mp3", .completed, 64_000_000)
        mp3.completedAt = Date().addingTimeInterval(-120)
        var zip = rec(.file, "Fotograflar-2026.zip", .failed, 1_200_000_000)
        zip.error = "Sunucu bağlantıyı kesti"
        dmg.receivedBytes = dmg.segments.reduce(0) { $0 + $1.done }
        iso.receivedBytes = iso.segments.reduce(0) { $0 + $1.done }
        m.downloads = [dmg, video, iso, zip, mp3, pdf]
        m.speedHistory = (0..<60).map { (i: Int) -> Double in 18_000_000 + 9_000_000 * sin(Double(i) / 6) + Double.random(in: 0...5_000_000) }
        m.speedSeries[dmg.id] = (0..<90).map { (i: Int) -> Double in 12_000_000 + 6_000_000 * sin(Double(i) / 9) + Double.random(in: 0...3_000_000) }
        m.speedSeries[video.id] = (0..<90).map { (_: Int) -> Double in Double.random(in: 4_000_000...9_000_000) }
    }

    /// Moves the sample downloads forward so the screenshot looks alive.
    static func advance(_ m: AppModel) {
        for i in m.downloads.indices where m.downloads[i].state == .downloading {
            let base: Double = m.downloads[i].kind == .file ? 18_000_000 : 6_000_000
            let sp = base * Double.random(in: 0.7...1.3)
            m.downloads[i].speed = sp
            if m.downloads[i].segments.isEmpty {
                m.downloads[i].receivedBytes = min(m.downloads[i].totalBytes, m.downloads[i].receivedBytes + Int64(sp))
                continue
            }
            let open = m.downloads[i].segments.indices.filter { !m.downloads[i].segments[$0].isComplete }
            for j in open {
                let s = m.downloads[i].segments[j]
                m.downloads[i].segments[j].done = min(s.end - s.start + 1, s.done + Int64(sp) / Int64(max(1, open.count)))
            }
            m.downloads[i].receivedBytes = m.downloads[i].segments.reduce(0) { $0 + $1.done }
        }
    }
}
