import SwiftUI

struct NextEpisodeCountdownView: View {
    @ObservedObject var controller: PlaybackController

    var body: some View {
        if let next = controller.pendingNext {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Следующая серия через \(controller.countdown) сек.")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(next.title) · Сезон \(next.season ?? 1), серия \(next.episode ?? 1)")
                        .font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
                }
                Button("Смотреть сейчас") { controller.playNextNow() }.buttonStyle(AccentButtonStyle())
                Button("Отмена") { controller.cancelAutoplay() }.buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(KinoPalette.accent.opacity(0.4)))
        }
    }
}
