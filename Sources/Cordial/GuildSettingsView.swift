import SwiftUI
import UIKit

struct GuildSettingsView: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let guild: DiscordGuild
    @State private var name: String
    @State private var description: String
    @State private var saving = false

    init(guild: DiscordGuild) {
        self.guild = guild
        _name = State(initialValue: guild.name)
        _description = State(initialValue: guild.description ?? "")
    }

    var body: some View {
        Form {
            Section(header: Text(model.text("General", "基本設定"))) {
                TextField(model.text("Server name", "サーバー名"), text: $name)
                    .textInputAutocapitalization(.never)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.text("Description", "説明"))
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $description).frame(minHeight: 110)
                }
            }
            Section {
                Text(model.text(
                    "Saving requires permission to manage this server. Discord may reject changes your account is not allowed to make.",
                    "保存にはサーバー管理権限が必要です。アカウントに権限がない変更はDiscordに拒否されます。"
                ))
                .font(.footnote).foregroundColor(.secondary)
            }
            Section {
                Button {
                    save()
                } label: {
                    HStack {
                        Spacer()
                        if saving { ProgressView() }
                        else { Text(model.text("Save changes", "変更を保存")) }
                        Spacer()
                    }
                }
                .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(model.text("Server settings", "サーバー設定"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let succeeded = await model.updateGuild(
                guild,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            saving = false
            if succeeded { dismiss() }
        }
    }
}

struct InviteLinkView: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let channel: DiscordChannel
    @State private var invite: DiscordInvite?
    @State private var loading = true
    @State private var copied = false

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                if loading {
                    ProgressView(model.text("Creating invite…", "招待リンクを発行中…"))
                } else if let url = invite?.url {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 54)).foregroundColor(.indigo)
                    Text(model.text("Invite link", "招待リンク"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(url.absoluteString)
                        .font(.system(size: 14, design: .monospaced))
                        .multilineTextAlignment(.center).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity)
                        .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 12))
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        copied = true
                    } label: {
                        Label(copied ? model.text("Copied", "コピーしました") : model.text("Copy link", "リンクをコピー"), systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    Text(model.text("This invite expires in 24 hours and has no use limit.", "この招待リンクは24時間で期限切れになり、使用回数の上限はありません。"))
                        .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                } else {
                    Text(model.text("Discord did not return an invite link. Check channel permissions and try again.", "Discordから招待リンクが返りませんでした。チャンネル権限を確認して再試行してください。"))
                        .multilineTextAlignment(.center).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle(model.text("Create invite", "招待リンクを発行"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.text("Done", "閉じる")) { dismiss() }
                }
            }
        }
        .task {
            guard invite == nil else { return }
            invite = await model.createInvite(channel: channel)
            loading = false
        }
    }
}
