import SwiftUI

struct AddTorrentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    init(initialLink: String = "") {
        _link = State(initialValue: initialLink)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Добавить раздачу")
                        .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text("Вставьте magnet-ссылку, хеш или ссылку на .torrent файл")
                        .font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(KinoPalette.muted) }
                    .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("ССЫЛКА ИЛИ ХЕШ")
                    .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(KinoPalette.muted)
                TextField("magnet:?xt=urn:btih:…", text: $link, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(3...5)
                    .padding(12)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KinoPalette.muted)
                    .padding(.trailing, 8)
                Button {
                    Task { await add() }
                } label: {
                    HStack(spacing: 8) {
                        if isAdding { ProgressView().controlSize(.small).tint(KinoPalette.background) }
                        else { Image(systemName: "plus") }
                        Text(isAdding ? "Добавляем…" : "Добавить")
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(KinoPalette.background)
    }

    private func add() async {
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do {
            try await model.addTorrent(link: link.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
