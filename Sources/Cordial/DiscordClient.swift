import Foundation
import Security

struct DiscordUser: Decodable, Identifiable {
    let id: String
    let username: String
    let globalName: String?
    let avatar: String?
    let discriminator: String?
    let bio: String?
    let clan: DiscordUserClan?
    let bot: Bool?

    enum CodingKeys: String, CodingKey {
        case id, username, avatar, discriminator, bio, clan, bot
        case globalName = "global_name"
    }

    var displayName: String { globalName ?? username }

    var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        let suffix = avatar.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).\(suffix)?size=128")
    }
}

struct DiscordUserClan: Decodable {
    let tag: String?
    let badge: String?
}

struct DiscordUserProfile: Decodable {
    let user: DiscordUser?
    let userProfile: Details?
    let bio: String?
    let pronouns: String?

    enum CodingKeys: String, CodingKey {
        case user, bio, pronouns
        case userProfile = "user_profile"
    }

    struct Details: Decodable {
        let bio: String?
        let pronouns: String?
    }
}

struct DiscordGuild: Decodable, Identifiable {
    let id: String
    let name: String
    let icon: String?
    let description: String?

    var iconURL: URL? {
        guard let icon, !icon.isEmpty else { return nil }
        let suffix = icon.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/icons/\(id)/\(icon).\(suffix)?size=128")
    }
}

struct DiscordChannel: Decodable, Identifiable {
    let id: String
    let name: String?
    let type: Int
    let guildID: String?
    let parentID: String?
    let recipients: [DiscordUser]?

    enum CodingKeys: String, CodingKey {
        case id, name, type, recipients
        case guildID = "guild_id"
        case parentID = "parent_id"
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let first = recipients?.first { return first.displayName }
        return "Direct Message"
    }

    var isTextChannel: Bool { [0, 5, 10, 11, 12].contains(type) }
    var isVoiceChannel: Bool { [2, 13].contains(type) }
}

struct DiscordGuildEmoji: Decodable, Identifiable {
    let id: String
    let name: String
    let animated: Bool?
    let available: Bool?
    var imageURL: URL? {
        URL(string: "https://cdn.discordapp.com/emojis/\(id).\(animated == true ? "gif" : "png")?size=64&quality=lossless")
    }
    var reactionCode: String { "\(name):\(id)" }
    var messageMarkup: String { "\(animated == true ? "<a:" : "<:")\(name):\(id)>" }
}

struct DiscordGuildSticker: Decodable, Identifiable {
    let id: String
    let name: String
    let tags: String?
    let formatType: Int?
    let available: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, tags, available
        case formatType = "format_type"
    }

    var imageURL: URL? {
        guard formatType != 3 else { return nil }
        let ext = formatType == 2 ? "apng" : "png"
        return URL(string: "https://cdn.discordapp.com/stickers/\(id).\(ext)?size=128")
    }
}

struct DiscordInvite: Decodable, Identifiable {
    let code: String
    var id: String { code }
    var url: URL? { URL(string: "https://discord.gg/\(code)") }
}

struct DiscordMessage: Decodable, Identifiable {
    let id: String
    let channelID: String
    let content: String
    let timestamp: String
    let author: DiscordUser
    let attachments: [DiscordAttachment]?
    let embeds: [DiscordEmbed]?
    let reactions: [DiscordReaction]?

    enum CodingKeys: String, CodingKey {
        case id, content, timestamp, author, attachments, embeds, reactions
        case channelID = "channel_id"
    }
}

struct DiscordReaction: Decodable, Identifiable {
    let count: Int
    let me: Bool
    let emoji: Emoji
    var id: String { emoji.reactionCode }

    struct Emoji: Decodable {
        let id: String?
        let name: String?
        var reactionCode: String {
            guard let id, let name else { return name ?? "❔" }
            return "\(name):\(id)"
        }
    }
}

struct DiscordAttachment: Decodable, Identifiable {
    let id: String
    let filename: String
    let url: URL?
    let contentType: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id, filename, url, width, height
        case contentType = "content_type"
    }
}

struct DiscordEmbed: Decodable, Identifiable {
    var id: String { url ?? title ?? UUID().uuidString }
    let title: String?
    let description: String?
    let url: String?
    let color: Int?
    let image: EmbedMedia?
    let thumbnail: EmbedMedia?
    let fields: [EmbedField]?

    struct EmbedMedia: Decodable {
        let url: URL?
    }
    struct EmbedField: Decodable, Identifiable {
        var id: String { "\(name)-\(value)" }
        let name: String
        let value: String
    }
}

enum DiscordLoginResult {
    case success(String)
    case mfa(ticket: String)
    case captcha(String?)
}

enum DiscordClientError: LocalizedError {
    case invalidResponse
    case http(Int, String)
    case keychain(OSStatus)
    case emptyMessage
    case responseDecoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an unreadable response."
        case .http(let status, let message):
            return message.isEmpty ? "Discord returned HTTP \(status)." : "Discord returned HTTP \(status): \(message)"
        case .keychain(let status):
            return "Could not securely store the session (Keychain status \(status))."
        case .emptyMessage:
            return "Enter a message before sending."
        case .responseDecoding(let details):
            return "The server returned a response the app could not read (\(details)). If this happened while sending, check the channel before retrying; the server may already have accepted it."
        }
    }
}

/// Unofficial user-session API client. This uses Discord's undocumented user login route.
/// Do not log credentials or session tokens, and do not use this as a supported Discord API.
final class DiscordClient {
    static let shared = DiscordClient()
    private let baseURL = URL(string: "https://discord.com/api/v9")!
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    var hasSavedSession: Bool { SessionTokenStore.load() != nil }

    /// Internal session token accessor for the Gateway transport; callers must not log or persist it elsewhere.
    func gatewayToken() -> String? { SessionTokenStore.load() }

    func login(email: String, password: String) async throws -> DiscordLoginResult {
        let url = baseURL.appendingPathComponent("auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Coralcord/1.0.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let loginBody: [String: Any] = [
            "login": email,
            "password": password,
            "undelete": false,
            "login_source": NSNull(),
            "gift_code_sku_id": NSNull()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: loginBody)
        let data: Data
        do {
            data = try await send(request)
        } catch let error as DiscordClientError {
            if case .http(_, let message) = error,
               message.localizedCaseInsensitiveContains("captcha") {
                return .captcha(message)
            }
            throw error
        }
        let response = try JSONDecoder().decode(LoginResponse.self, from: data)
        if let token = response.token, !token.isEmpty {
            try SessionTokenStore.save(token)
            return .success(token)
        }
        if response.mfa == true, let ticket = response.ticket {
            return .mfa(ticket: ticket)
        }
        if response.captchaKey?.contains("captcha-required") == true || response.captchaSitekey != nil {
            return .captcha(nil)
        }
        throw DiscordClientError.http(400, response.message ?? "Login did not return a session. Check the credentials and try again.")
    }

    func submitTOTP(code: String, ticket: String) async throws {
        let mfaBody: [String: Any] = [
            "code": code,
            "ticket": ticket,
            "login_source": NSNull(),
            "gift_code_sku_id": NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: mfaBody)
        let responseData = try await request(path: "auth/mfa/totp", method: "POST", body: data, authenticated: false)
        let response = try JSONDecoder().decode(LoginResponse.self, from: responseData)
        guard let token = response.token, !token.isEmpty else {
            throw DiscordClientError.http(400, response.message ?? "Multi-factor authentication was not completed.")
        }
        try SessionTokenStore.save(token)
    }

    func currentUser() async throws -> DiscordUser {
        try await get("users/@me")
    }

    func userProfile(id: String) async throws -> DiscordUserProfile {
        try await get("users/\(id)/profile")
    }

    func updateProfile(username: String, globalName: String, bio: String) async throws -> DiscordUser {
        let bodyObject: [String: Any] = [
            "username": username,
            "global_name": globalName,
            "bio": bio
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyObject)
        return try await request(path: "users/@me", method: "PATCH", body: body)
    }

    func guilds() async throws -> [DiscordGuild] {
        try await get("users/@me/guilds?limit=200")
    }

    func directMessages() async throws -> [DiscordChannel] {
        try await get("users/@me/channels")
    }

    func channels(guildID: String) async throws -> [DiscordChannel] {
        try await get("guilds/\(guildID)/channels")
    }

    func guildEmojis(guildID: String) async throws -> [DiscordGuildEmoji] {
        try await get("guilds/\(guildID)/emojis")
    }

    func guildStickers(guildID: String) async throws -> [DiscordGuildSticker] {
        try await get("guilds/\(guildID)/stickers")
    }

    func updateGuild(guildID: String, name: String, description: String) async throws -> DiscordGuild {
        var fields: [String: Any] = ["name": name]
        fields["description"] = description.isEmpty ? NSNull() : description
        let body = try JSONSerialization.data(withJSONObject: fields)
        return try await request(path: "guilds/\(guildID)", method: "PATCH", body: body)
    }

    func createInvite(channelID: String) async throws -> DiscordInvite {
        let body = try JSONSerialization.data(withJSONObject: [
            "max_age": 86400,
            "max_uses": 0,
            "temporary": false,
            "unique": true
        ])
        return try await request(path: "channels/\(channelID)/invites", method: "POST", body: body)
    }

    func messages(channelID: String) async throws -> [DiscordMessage] {
        let messages: [DiscordMessage] = try await get("channels/\(channelID)/messages?limit=50")
        return messages.reversed()
    }

    func latestMessage(channelID: String) async throws -> DiscordMessage? {
        let messages: [DiscordMessage] = try await get("channels/\(channelID)/messages?limit=1")
        return messages.first
    }

    func sendMessage(channelID: String, content: String) async throws -> DiscordMessage {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DiscordClientError.emptyMessage }
        let messageBody: [String: Any] = [
            "content": trimmed,
            "allowed_mentions": ["parse": [String]()]
        ]
        let body = try JSONSerialization.data(withJSONObject: messageBody)
        return try await request(path: "channels/\(channelID)/messages", method: "POST", body: body)
    }

    func sendSticker(channelID: String, stickerID: String) async throws -> DiscordMessage {
        let body = try JSONSerialization.data(withJSONObject: [
            "content": "",
            "sticker_ids": [stickerID],
            "allowed_mentions": ["parse": [String]()]
        ])
        return try await request(path: "channels/\(channelID)/messages", method: "POST", body: body)
    }

    func editMessage(channelID: String, messageID: String, content: String) async throws -> DiscordMessage {
        let body = try JSONSerialization.data(withJSONObject: [
            "content": content,
            "allowed_mentions": ["parse": [String]()]
        ])
        return try await request(path: "channels/\(channelID)/messages/\(messageID)", method: "PATCH", body: body)
    }

    func deleteMessage(channelID: String, messageID: String) async throws {
        _ = try await request(path: "channels/\(channelID)/messages/\(messageID)", method: "DELETE")
    }

    func sendAttachment(channelID: String, content: String, filename: String, mimeType: String, data: Data) async throws -> DiscordMessage {
        guard !data.isEmpty else { throw DiscordClientError.invalidResponse }
        let boundary = "Coralcord-\(UUID().uuidString)"
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentDescriptor: [String: Any] = ["id": 0, "filename": filename]
        let payload: [String: Any] = [
            "content": text,
            "allowed_mentions": ["parse": [String]()],
            "attachments": [attachmentDescriptor]
        ]
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        let safeFilename = filename
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(try JSONSerialization.data(withJSONObject: payload))
        append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"\(safeFilename)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        guard let token = SessionTokenStore.load(),
              let url = URL(string: "https://discord.com/api/v9/channels/\(channelID)/messages") else {
            throw DiscordClientError.http(401, "No saved session. Sign in again.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Coralcord/1.0.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let responseData = try await send(request)
        do { return try JSONDecoder().decode(DiscordMessage.self, from: responseData) }
        catch { throw DiscordClientError.responseDecoding(String(describing: error)) }
    }

    func addReaction(channelID: String, messageID: String, emoji: String) async throws {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        guard let encoded = emoji.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DiscordClientError.invalidResponse }
        _ = try await request(path: "channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)/@me", method: "PUT")
    }

    func logout() {
        SessionTokenStore.delete()
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path: path, method: "GET")
    }

    private func request<T: Decodable>(path: String, method: String, body: Data? = nil, authenticated: Bool = true) async throws -> T {
        let data: Data = try await request(path: path, method: method, body: body, authenticated: authenticated)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DiscordClientError.responseDecoding(String(describing: error)) }
    }

    private func request(path: String, method: String, body: Data? = nil, authenticated: Bool = true) async throws -> Data {
        guard let token = SessionTokenStore.load(), authenticated else {
            if authenticated { throw DiscordClientError.http(401, "No saved session. Sign in again.") }
            return try await perform(path: path, method: method, body: body, token: nil)
        }
        return try await perform(path: path, method: method, body: body, token: token)
    }

    private func perform(path: String, method: String, body: Data?, token: String?) async throws -> Data {
        let route = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: "https://discord.com/api/v9/\(route)") else {
            throw DiscordClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Coralcord/1.0.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue(token, forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DiscordClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let apiMessage = (try? JSONDecoder().decode(APIErrorBody.self, from: data).message) ?? ""
            var details = ""
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = object["errors"],
               JSONSerialization.isValidJSONObject(errors),
               let detailData = try? JSONSerialization.data(withJSONObject: errors, options: [.fragmentsAllowed]),
               let detailText = String(data: detailData, encoding: .utf8) {
                details = detailText
            }
            let message = [apiMessage, details].filter { !$0.isEmpty }.joined(separator: "\n")
            throw DiscordClientError.http(http.statusCode, message)
        }
        return data
    }
}

private struct LoginResponse: Decodable {
    let token: String?
    let mfa: Bool?
    let ticket: String?
    let captchaKey: [String]?
    let captchaSitekey: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case token, mfa, ticket, message
        case captchaKey = "captcha_key"
        case captchaSitekey = "captcha_sitekey"
    }
}

private struct APIErrorBody: Decodable {
    let message: String?
}

private enum SessionTokenStore {
    private static let service = "app.coralcord.client.session"
    private static let account = "discord-user-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw DiscordClientError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw DiscordClientError.keychain(status)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
