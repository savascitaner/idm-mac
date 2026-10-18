import Charts
import SwiftUI

/// IDM-style categories, chosen from the file extension.
enum Category: String, CaseIterable, Identifiable {
    case video, music, program, document, archive, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "Video"
        case .music: return "Müzik"
        case .program: return "Programlar"
        case .document: return "Belgeler"
        case .archive: return "Arşivler"
        case .other: return "Diğer"
        }
    }

    var icon: String {
        switch self {
        case .video: return "film.fill"
        case .music: return "music.note"
        case .program: return "app.badge.fill"
        case .document: return "doc.richtext.fill"
        case .archive: return "doc.zipper"
        case .other: return "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .video: return .pink
        case .music: return .purple
        case .program: return .blue
        case .document: return .orange
        case .archive: return .brown
        case .other: return .gray
        }
    }

    private static let map: [Category: Set<String>] = [
        .video: ["mp4", "m4v", "mkv", "avi", "mov", "wmv", "flv", "webm", "mpg", "mpeg", "ts", "3gp"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff"],
        .program: ["dmg", "pkg", "app", "exe", "msi", "apk", "deb", "rpm", "appimage", "iso", "img", "bin"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "epub", "pages", "numbers", "key", "csv", "rtf"],
        .archive: ["zip", "rar", "7z", "gz", "bz2", "xz", "tar", "tgz", "zst"],
    ]

    static func of(_ rec: DownloadRecord) -> Category {
        if rec.kind == .video { return rec.audioOnly ? .music : .video }
        let ext = (rec.fileName as NSString).pathExtension.lowercased()
        return map.first { $0.value.contains(ext) }?.key ?? .other
    }
}

enum SidebarItem: Hashable {
    case all, active, completed, failed
    case category(Category)
}

/// Shows each connection's byte range like IDM's "download progress" map:
/// light = still to download, solid = downloaded, bright edge = where a connection is writing now.
struct SegmentBar: View {
    let record: DownloadRecord
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(tint.opacity(0.15)))
            let total = Double(record.totalBytes)
            if record.segments.count > 0, total > 0 {
                for seg in record.segments {
                    let x = CGFloat(Double(seg.start) / total) * size.width
                    let w = CGFloat(Double(seg.done) / total) * size.width
                    guard w > 0 else { continue }
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(tint))
                    if !seg.isComplete && record.state == .downloading {
                        ctx.fill(Path(CGRect(x: x + w - 2, y: 0, width: 2, height: size.height)), with: .color(.white.opacity(0.9)))
                    }
                }
                // Thin separators between segment start points.
                for seg in record.segments where seg.start > 0 {
                    let x = CGFloat(Double(seg.start) / total) * size.width
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(.black.opacity(0.25)))
                }
            } else if record.totalBytes > 0 {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * record.progress, height: size.height)), with: .color(tint))
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Total download speed over the last minute.
struct SpeedChart: View {
    let samples: [Double]

    var body: some View {
        let peak = max(samples.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Hız").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(Format.speed(samples.last ?? 0).isEmpty ? "0 B/sn" : Format.speed(samples.last ?? 0))
                    .font(.caption.monospacedDigit().bold())
            }
            Chart(Array(samples.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", i), y: .value("hız", v))
                    .foregroundStyle(LinearGradient(colors: [.accentColor.opacity(0.5), .accentColor.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", i), y: .value("hız", v))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...(peak * 1.15))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 44)
            Text("En yüksek: " + (peak <= 1 ? "—" : Format.speed(peak)))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("İndirmeler") {
                    row(.all, "Tümü", "tray.full.fill", .accentColor, model.downloads.count)
                    row(.active, "Etkin", "arrow.down.circle.fill", .green, model.downloads.filter(\.isActive).count)
                    row(.completed, "Tamamlanan", "checkmark.circle.fill", .teal, model.downloads.filter { $0.state == .completed }.count)
                    row(.failed, "Hatalı", "exclamationmark.triangle.fill", .red, model.downloads.filter { $0.state == .failed }.count)
                }
                Section("Kategoriler") {
                    ForEach(Category.allCases) { c in
                        row(.category(c), c.title, c.icon, c.color, model.downloads.filter { Category.of($0) == c }.count)
                    }
                }
            }
            .listStyle(.sidebar)
            SpeedChart(samples: model.speedHistory).padding(10)
        }
    }

    private func row(_ item: SidebarItem, _ title: String, _ icon: String, _ color: Color, _ count: Int) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(title)
            Spacer()
            if count > 0 {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .tag(item)
    }
}

extension SidebarItem {
    func matches(_ d: DownloadRecord) -> Bool {
        switch self {
        case .all: return true
        case .active: return d.isActive || d.state == .paused
        case .completed: return d.state == .completed
        case .failed: return d.state == .failed
        case .category(let c): return Category.of(d) == c
        }
    }

    var title: String {
        switch self {
        case .all: return "Tüm indirmeler"
        case .active: return "Etkin"
        case .completed: return "Tamamlanan"
        case .failed: return "Hatalı"
        case .category(let c): return c.title
        }
    }
}
