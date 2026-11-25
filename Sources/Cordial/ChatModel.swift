import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class ChatModel: ObservableObject {
    @Published var selectedTab = 0
    @Published var language: AppLanguage = .english
    @Published var search = ""
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var currentUser: DiscordUser?
    @Published var guilds: [DiscordGuild] = []
    @Published var directMessages: [DiscordChannel] = []
    @Published var channels: [DiscordChannel] = []
    @Published var voiceChannels: [DiscordChannel] = []
    @Published var channelCategories: [DiscordChannel] = []
    @Published var selectedGuild: DiscordGuild?
    @Published var selectedChannel: DiscordChannel?
    @Published var messages: [DiscordMessage] = []
    @Published var pendingMFATicket: String?
    @Published var alertMessage: String?
    @Published var screenTitle = ""

    private let client = DiscordClient.shared
    private var isRefreshingSession = false
    private var notificationLatestIDs: [String: String] =
        UserDefaults.standard.dictionary(forKey: "notificationLatestMessageIDs") as? [String: String] ?? [:]

    init() {
        isAuthenticated = client.hasSavedSession
    }

    func signIn(email: String, password: String) async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            alertMessage = text("Enter your email and password.", "メールアドレスとパスワードを入力してください。")
            return
        }
        isLoading = true
        alertMessage = nil
        defer { isLoading = false }
        do {
            switch try await client.login(email: normalizedEmail, password: password) {
            case .success:
                pendingMFATicket = nil
                isAuthenticated = true
                await refreshSession()
            case .mfa(let ticket):
                pendingMFATicket = ticket
            case .captcha(let details):
                let challenge = text("Discord requested a CAPTCHA. This prototype cannot complete that challenge.", "DiscordからCAPTCHAが要求されました。この試作では認証できません。")
                alertMessage = [challenge, details].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func submitMFA(code: String) async {
        guard let ticket = pendingMFATicket else { return }
        isLoading = true
        alertMessage = nil
        defer { isLoading = false }
        do {
            try await client.submitTOTP(code: code, ticket: ticket)
            pendingMFATicket = nil
            isAuthenticated = true
            await refreshSession()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func loadUserProfile(id: String) async -> DiscordUserProfile? {
        do {
            return try await client.userProfile(id: id)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func updateCurrentProfile(username: String, globalName: String, bio: String) async -> Bool {
        do {
            currentUser = try await client.updateProfile(username: username, globalName: globalName, bio: bio)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func refreshSession() async {
        guard client.hasSavedSession else {
            isAuthenticated = false
            return
        }
        guard !isRefreshingSession else { return }
        isRefreshingSession = true
        isLoading = true
        defer {
            isLoading = false
            isRefreshingSession = false
        }
        var failures: [Error] = []
        async let dmRequest = client.directMessages()
        async let userRequest = client.currentUser()
        async let guildRequest = client.guilds()
        do { directMessages = try await dmRequest } catch { failures.append(error) }
        isLoading = false
        do { currentUser = try await userRequest } catch { failures.append(error) }
        do { guilds = try await guildRequest } catch { failures.append(error) }
        if !failures.isEmpty {
            let authenticationExpired = failures.contains { error in
                guard let clientError = error as? DiscordClientError,
                      case .http(401, _) = clientError else { return false }
                return true
            }
            if authenticationExpired {
                client.logout()
                isAuthenticated = false
                currentUser = nil
                guilds = []
                directMessages = []
            } else if alertMessage == nil {
                alertMessage = failures[0].localizedDescription
            }
        }
    }

    func loadChannels(for guild: DiscordGuild) async {
        selectedGuild = guild
        screenTitle = guild.name
        channels = []
        voiceChannels = []
        channelCategories = []
        isLoading = true
        defer { isLoading = false }
        do {
            let allChannels = try await client.channels(guildID: guild.id)
            channelCategories = allChannels.filter { $0.type == 4 }.sorted { ($0.name ?? "") < ($1.name ?? "") }
            channels = allChannels.filter { $0.isTextChannel }
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
            voiceChannels = allChannels.filter { $0.isVoiceChannel }
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func openChannel(_ channel: DiscordChannel) async {
        selectedChannel = channel
        screenTitle = channel.displayName
        messages = []
        await refreshMessages()
    }

    func refreshMessages() async {
        guard let channel = selectedChannel else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await client.messages(channelID: channel.id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func monitorIncomingNotifications() async {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }
        if notificationLatestIDs.isEmpty { await scanNotificationChannels(deliverNewMessages: false) }
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 45_000_000_000) }
            catch { return }
            guard !Task.isCancelled, UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }
            await scanNotificationChannels(deliverNewMessages: true)
        }
    }

    private func scanNotificationChannels(deliverNewMessages: Bool) async {
        var candidates = Array(directMessages.prefix(20)) + Array(channels.filter(\.isTextChannel).prefix(10))
        if let selectedChannel, !candidates.contains(where: { $0.id == selectedChannel.id }) {
            candidates.insert(selectedChannel, at: 0)
        }
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.id).inserted }
        let muted = Set((UserDefaults.standard.string(forKey: "mutedChannelIDs") ?? "")
            .split(separator: ",").map(String.init))
        for channel in candidates {
            guard let latest = try? await client.latestMessage(channelID: channel.id) else { continue }
            let previousID = notificationLatestIDs[channel.id]
            notificationLatestIDs[channel.id] = latest.id
            guard deliverNewMessages, previousID != nil, previousID != latest.id,
                  latest.author.id != currentUser?.id, !muted.contains(channel.id) else { continue }
            let content = UNMutableNotificationContent()
            content.title = channel.displayName
            content.body = latest.content.isEmpty
                ? "\(latest.author.displayName) sent a message"
                : "\(latest.author.displayName): \(latest.content)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "coralcord-\(channel.id)-\(latest.id)", content: content, trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
        UserDefaults.standard.set(notificationLatestIDs, forKey: "notificationLatestMessageIDs")
    }

    func sendMessage(_ content: String) async -> Bool {
        guard let channel = selectedChannel else { return false }
        return await sendMessage(channelID: channel.id, content: content)
    }

    func sendMessage(channelID: String, content: String) async -> Bool {
        do {
            let sent = try await client.sendMessage(channelID: channelID, content: content)
            if selectedChannel?.id == channelID, sent.channelID == channelID { messages.append(sent) }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func sendAttachment(_ data: Data, filename: String, mimeType: String, content: String) async -> Bool {
        guard let channel = selectedChannel else { return false }
        do {
            let sent = try await client.sendAttachment(channelID: channel.id, content: content, filename: filename, mimeType: mimeType, data: data)
            if selectedChannel?.id == channel.id, sent.channelID == channel.id { messages.append(sent) }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func addReaction(message: DiscordMessage, emoji: String) async {
        guard let channel = selectedChannel else { return }
        do {
            try await client.addReaction(channelID: channel.id, messageID: message.id, emoji: emoji)
            await refreshMessages()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func editMessage(_ message: DiscordMessage, content: String) async -> Bool {
        guard let channel = selectedChannel else { return false }
        do {
            let updated = try await client.editMessage(channelID: channel.id, messageID: message.id, content: content)
            if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = updated }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func deleteMessage(_ message: DiscordMessage) async -> Bool {
        guard let channel = selectedChannel else { return false }
        do {
            try await client.deleteMessage(channelID: channel.id, messageID: message.id)
            messages.removeAll { $0.id == message.id }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func forwardMessage(_ message: DiscordMessage, to channel: DiscordChannel) async -> Bool {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentLinks = (message.attachments ?? []).compactMap { $0.url?.absoluteString }
        let body = ([content] + attachmentLinks).filter { !$0.isEmpty }.joined(separator: "\n")
        return await sendMessage(channelID: channel.id, content: "↪︎ \(message.author.displayName):\n\(body)")
    }

    func loadGuildEmojis(for channel: DiscordChannel) async -> [DiscordGuildEmoji] {
        guard let guildID = channel.guildID else { return [] }
        do {
            return try await client.guildEmojis(guildID: guildID).filter { $0.available != false }
        } catch {
            alertMessage = error.localizedDescription
            return []
        }
    }

    func loadGuildStickers(for channel: DiscordChannel) async -> [DiscordGuildSticker] {
        guard let guildID = channel.guildID else { return [] }
        do {
            return try await client.guildStickers(guildID: guildID).filter { $0.available != false && $0.imageURL != nil }
        } catch {
            alertMessage = error.localizedDescription
            return []
        }
    }

    func sendSticker(_ sticker: DiscordGuildSticker) async -> Bool {
        guard let channel = selectedChannel else { return false }
        do {
            let sent = try await client.sendSticker(channelID: channel.id, stickerID: sticker.id)
            if selectedChannel?.id == channel.id, sent.channelID == channel.id { messages.append(sent) }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func updateGuild(_ guild: DiscordGuild, name: String, description: String) async -> Bool {
        do {
            let updated = try await client.updateGuild(guildID: guild.id, name: name, description: description)
            if let index = guilds.firstIndex(where: { $0.id == guild.id }) { guilds[index] = updated }
            if selectedGuild?.id == guild.id { selectedGuild = updated }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func createInvite(channel: DiscordChannel) async -> DiscordInvite? {
        do {
            return try await client.createInvite(channelID: channel.id)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func logout() {
        client.logout()
        isAuthenticated = false
        currentUser = nil
        guilds = []
        directMessages = []
        channels = []
        voiceChannels = []
        messages = []
        selectedGuild = nil
        selectedChannel = nil
        pendingMFATicket = nil
    }

    func text(_ english: String, _ japanese: String) -> String {
        language == .japanese ? japanese : english
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "English"
    case japanese = "日本語"
    var id: String { rawValue }
}
