import SwiftUI

struct DownloadsButton: View {
    @ObservedObject var controller: DownloadController
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle")
                if controller.activeCount > 0 { Text("\(controller.activeCount)") }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(KinoPalette.accent)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Загрузки")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Загрузки").font(.headline)
                if controller.activeCount > 0 {
                    Button("Отменить все загрузки") { controller.cancelAll() }.font(.caption)
                }
                Text("Для скачивания оставьте KinoStream и TorrServer включёнными.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.items.isEmpty { Text("Выберите «Скачать» у раздачи или серии.").font(.caption) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(controller.displayedItems) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                switch item.state {
                                case .queued:
                                    HStack {
                                        Text("В очереди").foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Отменить") { controller.cancel(item.id) }
                                    }.font(.caption)
                                case .downloading:
                                    DownloadProgressView(item: item)
                                    HStack {
                                        Spacer()
                                        Button("Отменить") { controller.cancel(item.id) }
                                    }.font(.caption)
                                case .completed:
                                    HStack {
                                        Label("Скачано", systemImage: "checkmark.circle").foregroundStyle(KinoPalette.accent)
                                        Spacer()
                                        Button("В Finder") { controller.reveal(item) }
                                    }.font(.caption)
                                case .cancelled: Text("Загрузка отменена").font(.caption).foregroundStyle(.secondary)
                                case .failed(let message): Text(message).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 420, height: 360)
        }
    }
}

struct FileDownloadStatusView: View {
    @ObservedObject var controller: DownloadController
    let torrentHash: String
    let fileID: Int

    var body: some View {
        if let item = controller.item(torrentHash: torrentHash, fileID: fileID) {
            VStack(alignment: .leading, spacing: 4) {
                switch item.state {
                case .downloading: DownloadProgressView(item: item)
                case .queued: Text("В очереди").foregroundStyle(KinoPalette.muted)
                case .completed: Label("Скачано", systemImage: "checkmark.circle.fill").foregroundStyle(KinoPalette.accent)
                case .cancelled: Text("Загрузка отменена").foregroundStyle(KinoPalette.muted)
                case .failed(let message): Text(message).foregroundStyle(.orange)
                }
            }
            .font(.system(size: 10))
        }
    }
}

private struct DownloadProgressView: View {
    let item: VideoDownload

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let speed = timeline.date.timeIntervalSince(item.lastProgressAt) < 3 ? item.bytesPerSecond : 0
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: item.progress).tint(KinoPalette.accent)
                HStack {
                    Text("\(Int(item.progress * 100))% · \(item.receivedBytes.fileSizeLabel) / \(item.expectedBytes.fileSizeLabel)")
                    Spacer(minLength: 8)
                    Text(item.receivedBytes == 0 ? "Ожидание данных…" : speed.speedLabel)
                }
                .font(.system(size: 10))
                .foregroundStyle(KinoPalette.muted)
            }
        }
    }
}
