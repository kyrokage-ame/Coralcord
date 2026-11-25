import SwiftUI

struct ProfileEditorSheet: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let user: DiscordUser
    @State private var username: String
    @State private var globalName: String
    @State private var bio: String
    @State private var saving = false
    @State private var localError: String?

    init(user: DiscordUser) {
        self.user = user
        _username = State(initialValue: user.username)
        _globalName = State(initialValue: user.globalName ?? "")
        _bio = State(initialValue: user.bio ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(model.text("Profile", "プロフィール")) {
                    TextField(model.text("Username", "ユーザー名"), text: $username)
                        .textInputAutocapitalization(.never)
                    TextField(model.text("Display name", "表示名"), text: $globalName)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.text("About me", "自己紹介"))
                            .font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $bio).frame(minHeight: 100)
                    }
                }
                Section(model.text("Account ID", "アカウントID")) {
                    HStack {
                        Text(user.id).textSelection(.enabled)
                        Spacer()
                        Text(model.text("Discord-assigned", "Discordが割り当て"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Text(model.text("User IDs cannot be edited.", "ユーザーIDは変更できません。"))
                        .font(.footnote).foregroundColor(.secondary)
                }
                if let localError {
                    Section { Text(localError).foregroundColor(.red) }
                }
            }
            .navigationTitle(model.text("Edit profile", "プロフィールを編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.text("Cancel", "キャンセル")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if saving { ProgressView() }
                        else { Text(model.text("Save", "保存")) }
                    }
                    .disabled(saving || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        localError = nil
        Task {
            let success = await model.updateCurrentProfile(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                globalName: globalName.trimmingCharacters(in: .whitespacesAndNewlines),
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if success { dismiss() }
            else {
                localError = model.alertMessage ?? model.text("Profile update failed.", "プロフィールを更新できませんでした。")
                model.alertMessage = nil
            }
            saving = false
        }
    }
}
