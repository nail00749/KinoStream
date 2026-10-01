import SwiftUI

enum KinoPalette {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.073)
    static let sidebar = Color(red: 0.075, green: 0.086, blue: 0.094)
    static let card = Color(red: 0.105, green: 0.118, blue: 0.126)
    static let accent = Color(red: 0.65, green: 0.92, blue: 0.57)
    static let muted = Color(red: 0.55, green: 0.59, blue: 0.61)
    static let line = Color.white.opacity(0.075)
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(KinoPalette.muted)
                }
            }
            Spacer()
            trailing
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(KinoPalette.accent)
                .frame(width: 58, height: 58)
                .background(KinoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 17))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(KinoPalette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(KinoPalette.background)
            .padding(.horizontal, 15)
            .frame(height: 37)
            .background(KinoPalette.accent.opacity(configuration.isPressed ? 0.76 : 1), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(KinoPalette.line, lineWidth: 1))
    }
}
