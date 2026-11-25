import SwiftUI
import UserNotifications

private let ink = Color.primary
private let muted = Color.secondary
private let accent = Color(red: 0.13, green: 0.52, blue: 0.66)

struct InboxView: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceMode = "light"
    @AppStorage("messageReceiveMode") private var messageReceiveMode = "manual"
    @AppStorage("externalBrowserURLTemplate") private var externalBrowserURLTemplate = ""
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @State private var showProfileEditor = false

    var body: some View {
        Group {
            if model.isAuthenticated {
                authenticatedNavigation
            } else {
                LoginView()
            }
        }
    }

    private var authenticatedNavigation: some View {
        NavigationView {
            VStack(spacing: 0) {
                header
                if model.selectedTab == 2 { profile }
                else if model.selectedTab == 0 { directMessages }
                else { serverList }
                bottomBar
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .tint(accent)
        .alert(model.text("Discord request failed", "Discordへの接続に失敗しました"), isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button(model.text("OK", "閉じる"), role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task(id: notificationMonitorID) {
            if model.currentUser == nil { await model.refreshSession() }
            guard notificationsEnabled, scenePhase == .active else { return }
            await model.monitorIncomingNotifications()
        }
        .onChange(of: notificationsEnabled) { enabled in
            guard enabled else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                DispatchQueue.main.async {
                    if !granted {
                        notificationsEnabled = false
                        model.alertMessage = error?.localizedDescription ?? model.text(
                            "Notification permission was not granted. Background push delivery is not configured yet.",
                            "通知の許可がありません。バックグラウンドのプッシュ配信はまだ設定されていません。"
                        )
                    }
                }
            }
        }
    }

    private var notificationMonitorID: String {
        "\(notificationsEnabled)-\(scenePhase == .active)"
    }

    private var header: some View {
        Text(model.selectedTab == 0 ? "DM" : model.selectedTab == 1
             ? model.text("Server", "サーバー") : model.text("Setting", "設定"))
            .font(.system(size: 30, weight: .bold))
            .foregroundColor(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 16)
    }

    private var directMessages: some View {
        VStack(spacing: 0) {
            searchField
            if model.directMessages.isEmpty && model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.directMessages.isEmpty {
                emptyState(model.text("No direct messages were returned for this session.", "このセッションにはDMがありません。"))
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredDMs) { channel in
                            NavigationLink(destination: ConversationView(channel: channel)) {
                                ChannelRow(title: channel.displayName, subtitle: channel.type == 3 ? model.text("Group message", "グループメッセージ") : model.text("Direct message", "ダイレクトメッセージ"), avatarUser: channel.recipients?.first)
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(.top, 4)
                }
            }
        }
    }

    private var serverList: some View {
        VStack(spacing: 0) {
            searchField
            if model.guilds.isEmpty && model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.guilds.isEmpty {
                emptyState(model.text("No servers were returned for this session.", "このセッションにはサーバーがありません。"))
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredGuilds) { guild in
                            NavigationLink(destination: GuildChannelsView(guild: guild)) {
                                ChannelRow(title: guild.name, subtitle: model.text("Open server channels", "サーバーチャンネルを開く"), avatarURL: guild.iconURL)
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(.top, 4)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(muted)
            TextField(model.text("Search", "検索"), text: $model.search).font(.system(size: 15))
        }
        .padding(.horizontal, 14).frame(height: 44).background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tab("bubble.left.and.bubble.right.fill", title: "DM", index: 0).frame(maxWidth: .infinity)
            tab("person.2.fill", title: model.text("Server", "サーバー"), index: 1).frame(maxWidth: .infinity)
            tab("gearshape.fill", title: model.text("Setting", "設定"), index: 2).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 25).padding(.top, 12).padding(.bottom, 8)
        .background(Color(.systemBackground))
        .frame(height: 60)
    }

    private func tab(_ icon: String, title: String, index: Int) -> some View {
        Button { model.selectedTab = index } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }.foregroundColor(model.selectedTab == index ? accent : muted)
        }
    }

    private var profile: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            if let user = model.currentUser {
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName).font(.system(size: 18, weight: .semibold)).foregroundColor(ink)
                    Text("@\(user.username)").font(.system(size: 14)).foregroundColor(muted)
                    Button { showProfileEditor = true } label: {
                        Label(model.text("Edit profile", "プロフィールを編集"), systemImage: "pencil")
                    }
                    .padding(.top, 6)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle(model.text("Notifications", "通知"), isOn: $notificationsEnabled)
                    .font(.system(size: 16, weight: .semibold))
                Text(model.text("Checks up to 20 recent DMs and 10 loaded server channels every 45 seconds while the app is open. Background alerts require APNs, which is not configured.", "アプリを開いている間、最近のDM最大20件と読み込み済みサーバーチャンネル最大10件を45秒ごとに確認します。バックグラウンド通知には未設定のAPNsが必要です。"))
                    .font(.system(size: 12)).foregroundColor(muted)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text("Language", "言語")).font(.system(size: 16, weight: .semibold)).foregroundColor(ink)
                Picker(model.text("Language", "言語"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { lang in Text(lang.rawValue).tag(lang) }
                }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text("Color theme", "カラーテーマ")).font(.system(size: 16, weight: .semibold)).foregroundColor(ink)
                Picker(model.text("Color theme", "カラーテーマ"), selection: $appearanceMode) {
                    Text(model.text("Light", "ライト")).tag("light")
                    Text(model.text("Dark", "ダーク")).tag("dark")
                }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text("Message updates", "メッセージ更新方式")).font(.system(size: 16, weight: .semibold)).foregroundColor(ink)
                Picker(model.text("Message updates", "メッセージ更新方式"), selection: $messageReceiveMode) {
                    Text(model.text("Pull to refresh", "引っ張って更新")).tag("manual")
                    Text(model.text("Auto · 15 sec", "自動・15秒ごと")).tag("auto")
                }.pickerStyle(.segmented)
                Text(model.text("Automatic mode checks for new messages every 15 seconds; it is not a live Gateway connection.", "自動モードは15秒ごとに新着を確認します。Gatewayによるリアルタイム接続ではありません。"))
                    .font(.system(size: 12)).foregroundColor(muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.text("External browser", "外部ブラウザ")).font(.system(size: 16, weight: .semibold)).foregroundColor(ink)
                TextField("default browser or URL template", text: $externalBrowserURLTemplate)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                Text(model.text("Leave blank for the default browser. Custom URL templates must contain {url}, for example: googlechrome://navigate?url={url}", "空欄なら既定ブラウザを使います。カスタムURLテンプレートには{url}を含めてください。例: googlechrome://navigate?url={url}"))
                    .font(.system(size: 12)).foregroundColor(muted)
            }
            Button(role: .destructive) { model.logout() } label: {
                Label(model.text("Sign Out", "ログアウト"), systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("1.0.0").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(muted).frame(maxWidth: .infinity)
        }
        .padding(24).padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showProfileEditor) {
            if let user = model.currentUser {
                ProfileEditorSheet(user: user).environmentObject(model)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundColor(muted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
    }

    private var filteredDMs: [DiscordChannel] {
        model.search.isEmpty ? model.directMessages : model.directMessages.filter {
            $0.displayName.localizedCaseInsensitiveContains(model.search)
        }
    }

    private var filteredGuilds: [DiscordGuild] {
        model.search.isEmpty ? model.guilds : model.guilds.filter { $0.name.localizedCaseInsensitiveContains(model.search) }
    }
}

private struct ChannelRow: View {
    let title: String
    let subtitle: String
    var avatarUser: DiscordUser? = nil
    var avatarURL: URL? = nil

    var body: some View {
        HStack(spacing: 13) {
            if let avatarURL {
                RemoteAvatarView(url: avatarURL, title: title, size: 48)
            } else {
                UserAvatar(user: avatarUser, size: 48, placeholder: title)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(ink).lineLimit(1)
                    if avatarUser?.bot == true {
                        Text("BOT").font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 2)
                            .foregroundColor(.white).background(Color.indigo).clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(subtitle).font(.system(size: 13)).foregroundColor(muted).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(muted.opacity(0.7))
        }
        .padding(.horizontal, 20).padding(.vertical, 10).contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5).padding(.leading, 80) }
    }
}

private struct GuildChannelsView: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.openURL) private var openURL
    @AppStorage("mutedChannelIDs") private var mutedChannelIDsData = ""
    @State private var inviteChannel: DiscordChannel?
    @State private var voiceCallChannel: DiscordChannel?
    let guild: DiscordGuild

    var body: some View {
        List {
            ForEach(model.channelCategories) { category in
                DisclosureGroup {
                    ForEach(model.channels.filter { $0.parentID == category.id }) { channel in
                        channelRow(channel)
                    }
                } label: {
                    Text(category.name ?? model.text("Channels", "チャンネル"))
                }
            }
            ForEach(model.channels.filter { $0.parentID == nil }) { channel in
                channelRow(channel)
            }
            if !model.voiceChannels.isEmpty {
                Section(model.text("Voice channels", "ボイスチャンネル")) {
                    ForEach(model.voiceChannels) { channel in
                        Button { voiceCallChannel = channel } label: {
                            HStack(spacing: 10) {
                                Image(systemName: channel.type == 13 ? "person.3.fill" : "speaker.wave.2.fill")
                                    .foregroundColor(accent)
                                Text(channel.displayName).foregroundColor(ink)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(muted)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(model.text("Attempts to join through Coralcord's in-app call screen.", "Coralcordのアプリ内通話画面から参加を試みます。"))
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(guild.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: GuildSettingsView(guild: guild)) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(model.text("Server settings", "サーバー設定"))
            }
        }
        .sheet(item: $inviteChannel) { channel in
            InviteLinkView(channel: channel).environmentObject(model)
        }
        .sheet(item: $voiceCallChannel) { channel in
            VoiceCallSheet(channel: channel).environmentObject(model)
        }
        .overlay {
            if model.isLoading && model.channels.isEmpty { ProgressView() }
        }
        .onAppear {
            if model.selectedGuild?.id != guild.id || (model.channels.isEmpty && model.voiceChannels.isEmpty) {
                Task { await model.loadChannels(for: guild) }
            }
        }
    }

    private func channelRow(_ channel: DiscordChannel) -> some View {
        NavigationLink(destination: ConversationView(channel: channel)) {
            HStack(spacing: 10) {
                Image(systemName: channel.type == 5 ? "megaphone" : "number").foregroundColor(accent)
                Text(channel.displayName).foregroundColor(ink)
                if mutedChannelIDs.contains(channel.id) {
                    Image(systemName: "bell.slash.fill").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .contextMenu {
            Button {
                inviteChannel = channel
            } label: {
                Label(model.text("Create invite", "招待リンクを発行"), systemImage: "link")
            }
            Button {
                toggleMute(channel.id)
            } label: {
                Label(
                    mutedChannelIDs.contains(channel.id) ? model.text("Unmute locally", "ローカルミュートを解除") : model.text("Mute locally", "ローカルでミュート"),
                    systemImage: mutedChannelIDs.contains(channel.id) ? "bell" : "bell.slash"
                )
            }
        }
    }

    private var mutedChannelIDs: Set<String> {
        Set(mutedChannelIDsData.split(separator: ",").map(String.init))
    }

    private func toggleMute(_ id: String) {
        var ids = mutedChannelIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        mutedChannelIDsData = ids.sorted().joined(separator: ",")
    }
}
