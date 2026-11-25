import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct PickedAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let mimeType: String
}

struct ConversationView: View {
    let channel: DiscordChannel
    @EnvironmentObject private var model: ChatModel
    @Environment(\.openURL) private var openURL
    @AppStorage("messageReceiveMode") private var messageReceiveMode = "manual"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("mutedChannelIDs") private var mutedChannelIDsData = ""
    @AppStorage("externalBrowserURLTemplate") private var externalBrowserURLTemplate = ""
    @State private var draft = ""
    @State private var selectedProfile: DiscordUser?
    @State private var sending = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showAttachmentMenu = false
    @State private var showEmojiPicker = false
    @State private var showStickerPicker = false
    @State private var pickedAttachment: PickedAttachment?
    @State private var editingMessage: DiscordMessage?
    @State private var forwardingMessage: DiscordMessage?
    @State private var reactionMessage: DiscordMessage?
    @State private var pendingDelete: DiscordMessage?
    @State private var showDeleteConfirmation = false
    @State private var showCallSheet = false

    var body: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty && model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty {
                Text(model.text("No messages returned yet. Pull down to refresh.", "メッセージがありません。下に引いて更新してください。"))
                    .font(.system(size: 14)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.messages) { item in
                                MessageRow(
                                    message: item,
                                    isMine: item.author.id == model.currentUser?.id,
                                    onTapAuthor: { selectedProfile = item.author },
                                    onEdit: { editingMessage = item },
                                    onDelete: { pendingDelete = item; showDeleteConfirmation = true },
                                    onForward: { forwardingMessage = item },
                                    onMoreReactions: { reactionMessage = item }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(16)
                    }
                    .refreshable {
                        if messageReceiveMode == "manual" { await model.refreshMessages() }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: model.messages.count) { _ in
                        if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let pickedAttachment {
                HStack(spacing: 10) {
                    attachmentPreview(pickedAttachment)
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(pickedAttachment.filename).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Button { self.pickedAttachment = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .accessibilityLabel(model.text("Remove attachment", "添付を削除"))
                }
                .padding(.horizontal, 14).padding(.top, 8)
            }

            HStack(spacing: 9) {
                Button { showAttachmentMenu = true } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 27)).foregroundColor(.indigo)
                }
                .accessibilityLabel(model.text("Add attachment", "添付を追加"))
                TextField(model.text("Message", "メッセージ"), text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onSubmit { send() }
                Button(action: send) {
                    if sending { ProgressView().frame(width: 30, height: 30) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundColor(canSend ? .indigo : .gray) }
                }
                .disabled(sending || !canSend)
                .accessibilityLabel(model.text("Send message", "メッセージを送信"))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .environment(\.openURL, OpenURLAction { url in handleOpenURL(url) })
        .sheet(item: $selectedProfile) { user in
            UserProfileSheet(user: user).environmentObject(model)
        }
        .sheet(item: $editingMessage) { message in
            MessageEditSheet(message: message) { content in
                Task { _ = await model.editMessage(message, content: content) }
            }
        }
        .sheet(item: $forwardingMessage) { message in
            ForwardMessageSheet(message: message) { destination in
                Task { _ = await model.forwardMessage(message, to: destination) }
            }
        }
        .sheet(item: $reactionMessage) { message in
            ReactionPickerSheet(channel: channel, message: message) { emoji in
                Task { await model.addReaction(message: message, emoji: emoji) }
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { image in pickedAttachment = image }
        }
        .sheet(isPresented: $showEmojiPicker) {
            ComposerEmojiPickerSheet(channel: channel) { draft += $0 }
        }
        .sheet(isPresented: $showStickerPicker) {
            StickerPickerSheet(channel: channel) { sticker in
                await model.sendSticker(sticker)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                pickedAttachment = PickedAttachment(data: data, filename: url.lastPathComponent, mimeType: mime)
            } catch {
                model.alertMessage = error.localizedDescription
            }
        }
        .confirmationDialog(model.text("Add to message", "メッセージに添付"), isPresented: $showAttachmentMenu, titleVisibility: .visible) {
            Button(model.text("Photo Library", "写真ライブラリ")) { showPhotoPicker = true }
            Button(model.text("Choose File", "ファイルを選択")) { showFileImporter = true }
            Button(model.text("Emoji", "絵文字")) { showEmojiPicker = true }
            Button(model.text("Sticker", "スタンプ")) { showStickerPicker = true }
            Button(model.text("Cancel", "キャンセル"), role: .cancel) { }
        }
        .confirmationDialog(model.text("Delete this message?", "このメッセージを削除しますか？"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(model.text("Delete Message", "メッセージを削除"), role: .destructive) {
                if let pendingDelete { Task { _ = await model.deleteMessage(pendingDelete) } }
            }
            Button(model.text("Cancel", "キャンセル"), role: .cancel) { pendingDelete = nil }
        }
        .sheet(isPresented: $showCallSheet) {
            VoiceCallSheet(channel: channel).environmentObject(model)
        }
        .navigationTitle(channel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { toggleChannelNotifications() } label: {
                    Image(systemName: notificationsEnabled && channelNotificationsEnabled ? "bell.fill" : "bell.slash")
                        .foregroundColor(notificationsEnabled && channelNotificationsEnabled ? .indigo : .secondary)
                }
                .accessibilityLabel(model.text("Toggle notifications for this conversation", "この会話の通知を切り替え"))
                .accessibilityHint(model.text("OS alerts also require the global Notifications setting in Settings.", "OS通知にはSettingで全体通知を有効にする必要があります。"))
                if channel.guildID == nil {
                    Button { showCallSheet = true } label: {
                        Image(systemName: "phone.fill").foregroundColor(.indigo)
                    }
                    .accessibilityLabel(model.text("Open in-app Discord call", "アプリ内Discord通話を開く"))
                }
            }
        }
        .onAppear {
            if model.selectedChannel?.id != channel.id || model.messages.isEmpty {
                Task { await model.openChannel(channel) }
            }
        }
        .task(id: messageReceiveMode) {
            guard messageReceiveMode == "auto" else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { break }
                guard !Task.isCancelled, model.selectedChannel?.id == channel.id else { break }
                await model.refreshMessages()
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pickedAttachment != nil
    }

    private var mutedChannelIDs: Set<String> {
        Set(mutedChannelIDsData.split(separator: ",").map(String.init))
    }

    private var channelNotificationsEnabled: Bool { !mutedChannelIDs.contains(channel.id) }

    private func toggleChannelNotifications() {
        var ids = mutedChannelIDs
        if ids.contains(channel.id) { ids.remove(channel.id) } else { ids.insert(channel.id) }
        mutedChannelIDsData = ids.sorted().joined(separator: ",")
    }

    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        let trimmedTemplate = externalBrowserURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return .handled
        }
        let safeCharacters = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: safeCharacters) ?? url.absoluteString
        let candidate = trimmedTemplate.replacingOccurrences(of: "{url}", with: encoded)
        guard let browserURL = URL(string: candidate), browserURL.scheme != nil else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return .handled
        }
        UIApplication.shared.open(browserURL, options: [:]) { opened in
            if !opened { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
        }
        return .handled
    }

    @ViewBuilder
    private func attachmentPreview(_ attachment: PickedAttachment) -> some View {
        if attachment.mimeType.hasPrefix("image/"), let image = UIImage(data: attachment.data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color(.systemGray5)
                Image(systemName: "doc.fill").font(.system(size: 20)).foregroundColor(.secondary)
            }
        }
    }

    private func send() {
        guard !sending, canSend else { return }
        let text = draft
        sending = true
        Task {
            let sent: Bool
            if let attachment = pickedAttachment {
                sent = await model.sendAttachment(attachment.data, filename: attachment.filename, mimeType: attachment.mimeType, content: text)
            } else {
                sent = await model.sendMessage(text)
            }
            if sent {
                draft = ""
                pickedAttachment = nil
            }
            sending = false
        }
    }
}

private struct MessageEditSheet: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let message: DiscordMessage
    let onSave: (String) -> Void
    @State private var content: String

    init(message: DiscordMessage, onSave: @escaping (String) -> Void) {
        self.message = message
        self.onSave = onSave
        _content = State(initialValue: message.content)
    }

    var body: some View {
        NavigationView {
            TextEditor(text: $content).padding(12)
                .navigationTitle(model.text("Edit message", "メッセージを編集"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.text("Cancel", "キャンセル")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(model.text("Save", "保存")) { onSave(content); dismiss() }
                            .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private struct ForwardMessageSheet: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let message: DiscordMessage
    let onForward: (DiscordChannel) -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(model.directMessages.filter { $0.id != message.channelID }) { destination in
                    Button {
                        onForward(destination)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            UserAvatar(user: destination.recipients?.first, size: 36, placeholder: destination.displayName)
                            Text(destination.displayName).foregroundColor(.primary)
                        }
                    }
                }
            }
            .navigationTitle(model.text("Forward to DM", "DMへ転送"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.text("Cancel", "キャンセル")) { dismiss() }
                }
            }
        }
    }
}

private struct ReactionPickerSheet: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let channel: DiscordChannel
    let message: DiscordMessage
    let onSelect: (String) -> Void
    @State private var serverEmojis: [DiscordGuildEmoji] = []
    @State private var loading = false
    private let unicodeEmojis = ["👍", "👎", "❤️", "🧡", "💛", "💚", "💙", "💜", "😂", "🤣", "😊", "😍", "🥰", "😎", "😮", "😢", "😭", "😡", "🙏", "👏", "🎉", "🔥", "✅", "❌", "👀", "💯", "🤔", "🙌", "💀", "✨"]
    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 8)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.text("Standard emoji", "標準絵文字"))
                        .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 4)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(unicodeEmojis, id: \.self) { emoji in
                            Button { choose(emoji) } label: {
                                Text(emoji).font(.system(size: 27)).frame(width: 48, height: 48)
                                    .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !serverEmojis.isEmpty {
                        Text(model.text("This server", "このサーバー"))
                            .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 4).padding(.top, 4)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(serverEmojis) { emoji in
                                Button { choose(emoji.reactionCode) } label: {
                                    Group {
                                        if let url = emoji.imageURL {
                                            AsyncImage(url: url) { phase in
                                                if let image = phase.image { image.resizable().scaledToFit() }
                                                else { Text("?") }
                                            }
                                        } else { Text("?") }
                                    }
                                    .frame(width: 36, height: 36).frame(width: 48, height: 48)
                                    .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(emoji.name)
                            }
                        }
                    } else if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .navigationTitle(model.text("More reactions", "その他のリアクション"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.text("Cancel", "キャンセル")) { dismiss() }
                }
            }
        }
        .task {
            loading = true
            serverEmojis = await model.loadGuildEmojis(for: channel)
            loading = false
        }
    }

    private func choose(_ emoji: String) {
        onSelect(emoji)
        dismiss()
    }
}

private struct ComposerEmojiPickerSheet: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let channel: DiscordChannel
    let onInsert: (String) -> Void
    @State private var serverEmojis: [DiscordGuildEmoji] = []
    @State private var loading = false
    private let unicodeEmojis = ["😀", "😃", "😄", "😁", "😆", "😂", "😊", "😍", "🥰", "😎", "🤔", "😮", "😢", "😭", "😡", "👍", "👎", "❤️", "💙", "🙏", "👏", "🎉", "🔥", "✅", "❌", "👀", "💯", "✨"]
    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 8)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.text("Standard emoji", "標準絵文字")).font(.headline)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(unicodeEmojis, id: \.self) { emoji in
                            Button { insert(emoji) } label: {
                                Text(emoji).font(.system(size: 27)).frame(width: 48, height: 48)
                                    .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !serverEmojis.isEmpty {
                        Text(model.text("This server", "このサーバー")).font(.headline)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(serverEmojis) { emoji in
                                Button { insert(emoji.messageMarkup) } label: {
                                    Group {
                                        if let url = emoji.imageURL {
                                            AsyncImage(url: url) { phase in
                                                if let image = phase.image { image.resizable().scaledToFit() }
                                                else { Text("?") }
                                            }
                                        } else { Text("?") }
                                    }
                                    .frame(width: 36, height: 36).frame(width: 48, height: 48)
                                    .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain).accessibilityLabel(emoji.name)
                            }
                        }
                    } else if loading { ProgressView().frame(maxWidth: .infinity) }
                }
                .padding(16)
            }
            .navigationTitle(model.text("Insert emoji", "絵文字を挿入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.text("Done", "閉じる")) { dismiss() }
                }
            }
        }
        .task {
            loading = true
            serverEmojis = await model.loadGuildEmojis(for: channel)
            loading = false
        }
    }

    private func insert(_ value: String) {
        onInsert(value)
        dismiss()
    }
}

private struct StickerPickerSheet: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    let channel: DiscordChannel
    let onSend: (DiscordGuildSticker) async -> Bool
    @State private var stickers: [DiscordGuildSticker] = []
    @State private var loading = false
    @State private var sendingStickerID: String?

    var body: some View {
        NavigationView {
            Group {
                if loading { ProgressView() }
                else if stickers.isEmpty {
                    Text(model.text("No usable server stickers were found.", "使用可能なサーバースタンプがありません。"))
                        .foregroundColor(.secondary).multilineTextAlignment(.center).padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                            ForEach(stickers) { sticker in
                                Button {
                                    guard sendingStickerID == nil else { return }
                                    sendingStickerID = sticker.id
                                    Task {
                                        let sent = await onSend(sticker)
                                        sendingStickerID = nil
                                        if sent { dismiss() }
                                    }
                                } label: {
                                    VStack(spacing: 8) {
                                        if sendingStickerID == sticker.id {
                                            ProgressView().frame(height: 88)
                                        } else if let url = sticker.imageURL {
                                            AsyncImage(url: url) { phase in
                                                if let image = phase.image { image.resizable().scaledToFit() }
                                                else if phase.error == nil { ProgressView() }
                                            }
                                            .frame(height: 88)
                                        }
                                        Text(sticker.name).font(.caption).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity).padding(8)
                                    .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain).foregroundColor(.primary)
                                .disabled(sendingStickerID != nil)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(model.text("Server stickers", "サーバースタンプ"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.text("Cancel", "キャンセル")) { dismiss() }
                }
            }
        }
        .task {
            loading = true
            stickers = await model.loadGuildStickers(for: channel)
            loading = false
        }
    }
}

private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: (PickedAttachment) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.84) {
                parent.onPick(PickedAttachment(data: data, filename: "image-\(UUID().uuidString.prefix(8)).jpg", mimeType: "image/jpeg"))
            }
            parent.dismiss()
        }
    }
}

private struct MessageRow: View {
    @EnvironmentObject private var model: ChatModel
    let message: DiscordMessage
    let isMine: Bool
    let onTapAuthor: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onForward: () -> Void
    let onMoreReactions: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    UserAvatar(user: message.author, size: 24)
                    Button(action: onTapAuthor) {
                        Text(message.author.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isMine ? .white.opacity(0.8) : .secondary)
                    }
                    .buttonStyle(.plain)
                    if message.author.bot == true {
                        Text("BOT")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .foregroundColor(.white)
                            .background(Color.indigo)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                if !message.content.isEmpty {
                    Text(.init(message.content)).font(.system(size: 15))
                        .foregroundColor(isMine ? .white : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(message.attachments ?? []) { attachment in
                    if let url = attachment.url {
                        if attachment.contentType?.hasPrefix("image/") == true || ["png", "jpg", "jpeg", "gif", "webp"].contains(URL(fileURLWithPath: attachment.filename).pathExtension.lowercased()) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 10))
                                } else if phase.error != nil {
                                    attachmentLink(attachment.filename, url: url)
                                } else {
                                    ProgressView().frame(width: 160, height: 90)
                                }
                            }
                        } else {
                            attachmentLink(attachment.filename, url: url)
                        }
                    }
                }
                ForEach(message.embeds ?? []) { embed in
                    EmbedCard(embed: embed, isMine: isMine)
                }
                if let reactions = message.reactions, !reactions.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(reactions) { reaction in
                            Text("\(reaction.emoji.name ?? "❔")  \(reaction.count)")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(reaction.me ? Color.indigo.opacity(0.18) : Color.primary.opacity(0.07))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(isMine ? Color.indigo : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .contextMenu {
                ForEach(["👍", "❤️", "😂", "🎉", "😮", "😢"], id: \.self) { emoji in
                Button(emoji) { Task { await model.addReaction(message: message, emoji: emoji) } }
                }
                Button(action: onMoreReactions) {
                    Label(model.text("More…", "その他…"), systemImage: "face.smiling")
                }
                Divider()
                if isMine {
                    Button(action: onEdit) { Label(model.text("Edit", "編集"), systemImage: "pencil") }
                    Button(role: .destructive, action: onDelete) {
                        Label(model.text("Delete", "削除"), systemImage: "trash")
                    }
                }
                Button(action: onForward) {
                    Label(model.text("Forward", "転送"), systemImage: "arrowshape.turn.up.right")
                }
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    private func attachmentLink(_ name: String, url: URL) -> some View {
        ExternalBrowserLink(url: url) {
            Label(name, systemImage: "doc").font(.system(size: 13)).lineLimit(1)
                .padding(8).background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct EmbedCard: View {
    let embed: DiscordEmbed
    let isMine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title = embed.title { Text(title).font(.system(size: 14, weight: .semibold)) }
            if let description = embed.description { Text(description).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
            if let url = embed.image?.url ?? embed.thumbnail?.url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    else if phase.error == nil { ProgressView() }
                }
            }
            if let fields = embed.fields {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.name).font(.system(size: 12, weight: .semibold))
                        Text(field.value).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let urlString = embed.url, let link = URL(string: urlString) {
                ExternalBrowserLink(url: link) { Text(urlString).font(.system(size: 11)).lineLimit(1) }
            }
        }
        .foregroundColor(isMine ? .white : .primary)
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(isMine ? Color.white.opacity(0.12) : Color(.systemBackground))
        .overlay(alignment: .leading) { Rectangle().fill(Color(red: 0.13, green: 0.52, blue: 0.66)).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
