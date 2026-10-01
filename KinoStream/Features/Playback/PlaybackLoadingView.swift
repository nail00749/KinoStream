import SwiftUI

struct PlaybackLoadingView: View {
    @ObservedObject var controller: PlaybackController
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let state = controller.loadingState {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if state.isFailure {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.title).font(.system(size: 14, weight: .semibold))
                        Text(controller.loadingTitle).font(.system(size: 11)).foregroundStyle(KinoPalette.muted).lineLimit(1)
                    }
                    Spacer()
                    Button { model.player?.pause(); model.stopVLCPlaybackMonitoring(); controller.cancelLoading() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Скрыть сообщение и отменить ожидание")
                }
                Text(state.message).font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
                if let detail = controller.connectionDetail(in: model.torrents) {
                    Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(KinoPalette.accent)
                }
                HStack(spacing: 18) {
                    if state.isFailure {
                        Button("Повторить") { Task { await controller.retry() } }.buttonStyle(AccentButtonStyle())
                    }
                    Button("Выбрать другую раздачу") { controller.chooseAlternative() }
                        .buttonStyle(.plain).foregroundStyle(KinoPalette.accent)
                }
            }
            .foregroundStyle(.white).padding(18)
            .frame(maxWidth: 580, alignment: .leading)
            .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        }
    }
}
