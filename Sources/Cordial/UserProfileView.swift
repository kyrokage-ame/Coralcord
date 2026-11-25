import SwiftUI

struct UserProfileSheet: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let user: DiscordUser
    @State private var profile: DiscordUserProfile?
    @State private var isLoadingProfile = false

    private let accent = Color(red: 0.13, green: 0.52, blue: 0.66)

    private var displayUser: DiscordUser { profile?.user ?? user }
    private var biography: String? { profile?.userProfile?.bio ?? profile?.bio ?? displayUser.bio }

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(spacing: 12) {
                        UserAvatar(user: displayUser, size: 96)
                        Text(displayUser.displayName)
                            .font(.system(size: 23, weight: .bold))
                        Text("@\(displayUser.username)")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                        if let tag = displayUser.clan?.tag, !tag.isEmpty {
                            Label(tag, systemImage: "tag.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(accent.opacity(0.12)).clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }

                if isLoadingProfile {
                    Section { ProgressView(model.text("Loading profile…", "プロフィールを読み込み中…")) }
                }

                if let biography, !biography.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(model.text("About", "自己紹介")) {
                        Text(biography).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let pronouns = profile?.userProfile?.pronouns ?? profile?.pronouns, !pronouns.isEmpty {
                    Section(model.text("Pronouns", "代名詞")) { Text(pronouns) }
                }

                Section(model.text("Contact", "連絡先")) {
                    if let globalName = displayUser.globalName, !globalName.isEmpty {
                        infoRow(model.text("Display name", "表示名"), value: globalName)
                    }
                    infoRow(model.text("Username", "ユーザー名"), value: "@\(displayUser.username)")
                    infoRow("ID", value: displayUser.id)
                    if let tag = displayUser.clan?.tag, !tag.isEmpty {
                        infoRow(model.text("Server tag / title", "サーバータグ／二つ名"), value: tag)
                    }
                    if let discriminator = displayUser.discriminator, discriminator != "0" {
                        infoRow(model.text("Discriminator", "識別タグ"), value: discriminator)
                    }
                }

                Section(model.text("Availability", "状態")) {
                    Label(model.text("Presence isn't available in this prototype.", "この試作ではプレゼンスを取得できません。"), systemImage: "circle.dashed")
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(model.text("Contact", "連絡先"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.text("Done", "完了")) { dismiss() }
                        .foregroundColor(accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(accent)
        .task(id: user.id) {
            isLoadingProfile = true
            profile = await model.loadUserProfile(id: user.id)
            isLoadingProfile = false
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
