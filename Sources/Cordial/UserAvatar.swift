import SwiftUI

struct UserAvatar: View {
    let user: DiscordUser?
    var size: CGFloat = 48
    var placeholder: String? = nil

    var body: some View {
        Group {
            if let url = user?.avatarURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty, .failure(_):
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(user?.displayName ?? placeholder ?? "User")
    }

    private var fallback: some View {
        Circle()
            .fill(Color(red: 0.13, green: 0.52, blue: 0.66).opacity(0.14))
            .overlay {
                Text(String((user?.displayName ?? placeholder ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.13, green: 0.52, blue: 0.66))
            }
    }
}

struct RemoteAvatarView: View {
    let url: URL?
    let title: String
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26))
        .accessibilityLabel(title)
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: size * 0.26)
            .fill(Color(red: 0.13, green: 0.52, blue: 0.66).opacity(0.14))
            .overlay {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.13, green: 0.52, blue: 0.66))
            }
    }
}
