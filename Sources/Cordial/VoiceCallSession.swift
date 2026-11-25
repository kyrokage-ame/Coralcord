import SwiftUI

@MainActor
final class VoiceCallSession: ObservableObject {
    @Published private(set) var status: String
    @Published private(set) var isSignalingReady = false
    @Published private(set) var participantIDs: [String] = []
    @Published private(set) var speakingUserIDs = Set<String>()
    @Published private(set) var isMuted = false

    private let channel: DiscordChannel
    private var gateway: DiscordGatewayClient?
    private var voiceGateway: DiscordVoiceGatewayClient?
    private var udpTransport: DiscordVoiceUDPTransport?
    private var transportCipher: DiscordVoiceTransportCipher?
    private var daveBridge: CoralcordDAVEBridge?
    private var audioIO: DiscordAudioIO?
    private var codec: OpusCodec?
    private var mediaPipeline: DiscordVoiceMediaPipeline?
    private var latestVoiceState: GatewayVoiceStateUpdate?
    private var latestVoiceServer: GatewayVoiceServerUpdate?
    private var sawVoiceSession = false
    private var sawVoiceServer = false
    private var didStartVoiceGateway = false
    private var didSelectUDPProtocol = false
    private var didStartMedia = false
    private var transitionExecuted = false
    private var groupInitialized = false
    private var daveVersion: UInt16 = 0
    private var pendingExternalSender: Data?
    private var knownParticipantIDs = Set<String>()
    private var userIDBySSRC: [UInt32: String] = [:]
    private var storedLocalSSRC: UInt32?
    private var ended = false

    init(channel: DiscordChannel) {
        self.channel = channel
        guard let token = DiscordClient.shared.gatewayToken() else {
            status = "Sign in to connect to Discord voice."
            return
        }
        status = "Connecting to Discord Gateway…"
        gateway = DiscordGatewayClient(token: token, eventHandler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }, stateHandler: { [weak self] value in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                if value == "Disconnected" {
                    self.status = "Discord Gateway disconnected."
                } else if ["recovering", "reconnect", "failed", "rejected", "ended", "could not"]
                    .contains(where: value.localizedCaseInsensitiveContains) {
                    self.status = "Discord Gateway: \(value)"
                }
            }
        })
    }

    func begin() { gateway?.connect() }

    func end() {
        guard !ended else { return }
        ended = true
        mediaPipeline?.stop()
        audioIO?.stop()
        voiceGateway?.disconnect()
        udpTransport?.close()
        if let gateway {
            Task { [weak self] in
                guard let self else { return }
                try? await gateway.updateVoiceState(guildId: self.channel.guildID, channelId: nil)
                gateway.disconnect()
            }
        }
        status = "Call ended."
        isSignalingReady = false
    }

    private func handle(_ event: DiscordGatewayEvent) {
        guard !ended else { return }
        switch event {
        case .ready:
            guard let gateway else { return }
            if let userID = gateway.userId { addParticipant(userID) }
            Task {
                do {
                    try await gateway.updateVoiceState(guildId: channel.guildID, channelId: channel.id)
                    if !ended { status = "Joining voice channel…" }
                } catch {
                    status = "Could not join the voice channel: \(error.localizedDescription)"
                }
            }
        case .voiceStateUpdate(let state):
            guard state.channelId == channel.id else { return }
            if let currentID = gateway?.userId, let eventID = state.userId, currentID != eventID { return }
            latestVoiceState = state
            sawVoiceSession = state.sessionId != nil
            refreshReadiness()
        case .voiceServerUpdate(let server):
            guard server.guildId == channel.guildID else { return }
            latestVoiceServer = server
            sawVoiceServer = server.endpoint != nil && server.token != nil
            refreshReadiness()
        case .callCreate(let call), .callUpdate(let call):
            guard call.channelId == channel.id else { return }
            status = "Discord reported the DM call; negotiating its voice session…"
        case .other:
            break
        }
    }

    private func refreshReadiness() {
        guard sawVoiceSession, sawVoiceServer else { return }
        isSignalingReady = true
        startVoiceGatewayIfReady()
    }

    private func startVoiceGatewayIfReady() {
        guard !didStartVoiceGateway,
              let state = latestVoiceState,
              let sessionID = state.sessionId,
              let server = latestVoiceServer,
              let endpoint = server.endpoint,
              let token = server.token,
              let userID = gateway?.userId else { return }
        didStartVoiceGateway = true
        status = "Connecting to Discord Voice Gateway…"
        let voice = DiscordVoiceGatewayClient(endpoint: endpoint, serverID: channel.guildID ?? channel.id,
                                              channelID: channel.id,
                                              userID: userID, sessionID: sessionID, token: token) { [weak self] event in
            Task { @MainActor in self?.handleVoiceEvent(event) }
        }
        voiceGateway = voice
        do { try voice.connect() }
        catch { status = "Voice Gateway connection failed: \(error.localizedDescription)" }
    }

    private func handleVoiceEvent(_ event: DiscordVoiceGatewayEvent) {
        guard !ended else { return }
        switch event {
        case .ready(let ready):
            storedLocalSSRC = ready.ssrc
            guard ready.modes.contains(DiscordVoiceTransportCipher.xchachaMode) else {
                status = "Discord did not offer the supported XChaCha RTP-size transport mode."
                return
            }
            guard let voiceGateway, !didSelectUDPProtocol else { return }
            status = "Discovering the UDP media endpoint…"
            Task { @MainActor in
                do {
                    let discovered = try await DiscordUDPDiscovery.discover(
                        serverIP: ready.ip, serverPort: ready.port, ssrc: ready.ssrc
                    )
                    let transport = try DiscordVoiceUDPTransport(address: ready.ip, port: ready.port)
                    try await transport.connect()
                    guard !ended else { transport.close(); return }
                    udpTransport = transport
                    try await voiceGateway.selectUDPProtocol(address: discovered.address,
                                                             port: discovered.port,
                                                             mode: DiscordVoiceTransportCipher.xchachaMode)
                    didSelectUDPProtocol = true
                    status = "UDP selected; waiting for encrypted session keys…"
                } catch {
                    status = "UDP negotiation failed: \(error.localizedDescription)"
                }
            }
        case .sessionDescription(let description):
            do {
                transportCipher = try DiscordVoiceTransportCipher(mode: description.mode,
                                                                   secretKey: description.secretKey)
                guard let version = description.daveProtocolVersion, version > 0,
                      version <= Int(UInt16.max) else {
                    status = "Discord did not negotiate DAVE. Audio remains disabled."
                    return
                }
                daveVersion = UInt16(version)
                guard daveVersion == 1 else {
                    status = "DAVE protocol v\(version) is not supported by this build. Audio remains disabled."
                    return
                }
                status = "Waiting for Discord DAVE/MLS group keys…"
            } catch {
                status = "Could not initialize transport encryption: \(error.localizedDescription)"
            }
        case .dave(let opcode, let payload):
            handleDAVE(opcode: opcode, payload: payload)
        case .clientsConnect(let userIDs):
            for id in userIDs { addParticipant(id) }
            do { try addKnownParticipantsToDAVE() }
            catch { status = "Could not register DAVE participants: \(error.localizedDescription)" }
        case .clientDisconnect(let userID):
            knownParticipantIDs.remove(userID)
            participantIDs = participantIDs.filter { $0 != userID }
            speakingUserIDs.remove(userID)
            daveBridge?.removeRecognizedUser(userID)
            userIDBySSRC = userIDBySSRC.filter { $0.value != userID }
        case .speaking(let userID, let ssrc, let flags):
            if let userID, let ssrc {
                userIDBySSRC[ssrc] = userID
                addParticipant(userID)
                registerRecognizedUser(userID)
            }
            if let userID, (flags ?? 0) & 1 != 0 { speakingUserIDs.insert(userID) }
            else if let userID { speakingUserIDs.remove(userID) }
        case .disconnected(let error):
            stopMedia()
            status = error.map { "Voice Gateway disconnected: \($0.localizedDescription)" }
                ?? "Voice Gateway disconnected."
        case .heartbeatAck, .other:
            break
        }
    }

    private func handleDAVE(opcode: Int, payload: Data) {
        switch opcode {
        case 21:
            guard let values = jsonObject(payload), let transitionID = values["transition_id"] as? Int else { return }
            if let version = values["protocol_version"] as? Int, version == 0 {
                stopMedia()
                transitionExecuted = false
                status = "Discord requested a non-DAVE transition; media remains blocked."
            }
            sendTransitionReady(transitionID)
        case 22:
            transitionExecuted = true
            startMediaIfReady()
        case 24:
            guard let values = jsonObject(payload),
                  let version = values["protocol_version"] as? Int,
                  let epoch = values["epoch"] as? Int,
                  version == 1 else {
                status = "Unsupported or malformed DAVE epoch negotiation."
                return
            }
            do {
                guard let userID = gateway?.userId, let groupID = UInt64(channel.id) else {
                    throw VoiceSessionError.invalidIdentity
                }
                if epoch == 1 || daveBridge == nil {
                    let bridge = try CoralcordDAVEBridge(selfUserID: userID)
                    try bridge.initializeGroupChecked(withID: groupID, version: UInt16(version))
                    daveBridge = bridge
                    groupInitialized = true
                    daveVersion = UInt16(version)
                    try addKnownParticipantsToDAVE()
                    if let pendingExternalSender { try bridge.setExternalSenderChecked(pendingExternalSender) }
                    guard let voiceGateway else { throw VoiceGatewayError.notConnected }
                    let keyPackage = try bridge.keyPackageDataChecked()
                    Task { try? await voiceGateway.sendDAVEBinary(opcode: 26, payload: keyPackage) }
                    status = "DAVE key package sent; waiting for the group commit…"
                } else {
                    groupInitialized = true
                    status = "Preparing the next DAVE epoch…"
                }
            } catch {
                status = "DAVE group setup failed: \(error.localizedDescription)"
            }
        case 25:
            pendingExternalSender = payload
            guard let bridge = daveBridge, groupInitialized else { return }
            do {
                try bridge.setExternalSenderChecked(payload)
                try addKnownParticipantsToDAVE()
                status = "DAVE external sender installed."
            } catch {
                status = "DAVE external sender was rejected: \(error.localizedDescription)"
            }
        case 27:
            guard let bridge = daveBridge, groupInitialized, let voiceGateway else { return }
            do {
                let commitWelcome = try bridge.processProposalsChecked(payload)
                let (commit, _) = try Self.splitCommitWelcome(commitWelcome)
                try bridge.processCommitChecked(commit)
                Task { try await voiceGateway.sendDAVEBinary(opcode: 28, payload: commitWelcome) }
                status = "MLS proposals committed; waiting for the transition broadcast…"
            } catch {
                status = "DAVE proposal processing failed: \(error.localizedDescription)"
            }
        case 29:
            guard let (transitionID, commit) = Self.readTransitionPayload(payload),
                  let bridge = daveBridge else { return }
            do {
                try bridge.processCommitChecked(commit)
                sendTransitionReady(transitionID)
                startMediaIfReady()
            } catch {
                sendInvalidCommit(transitionID)
                status = "DAVE commit rejected; requested group recovery."
            }
        case 30:
            guard let (transitionID, welcome) = Self.readTransitionPayload(payload),
                  let bridge = daveBridge else { return }
            do {
                try bridge.processWelcomeChecked(welcome)
                sendTransitionReady(transitionID)
                startMediaIfReady()
                status = "Joined the DAVE/MLS media group."
            } catch {
                sendInvalidCommit(transitionID)
                status = "DAVE welcome rejected; requested group recovery."
            }
        case 31:
            stopMedia()
            status = "Discord reported an invalid DAVE commit/welcome. Media remains blocked."
        default:
            break
        }
    }

    private func addKnownParticipantsToDAVE() throws {
        guard let bridge = daveBridge, groupInitialized else { return }
        for id in knownParticipantIDs { try bridge.addRecognizedUserChecked(id) }
    }

    private func addParticipant(_ id: String) {
        knownParticipantIDs.insert(id)
        if !participantIDs.contains(id) { participantIDs.append(id) }
    }

    func toggleMute() {
        isMuted.toggle()
        audioIO?.setMuted(isMuted)
        if let voiceGateway, let ssrc = storedLocalSSRC {
            let speaking = !isMuted
            Task { try? await voiceGateway.sendSpeaking(ssrc: ssrc, speaking: speaking) }
        }
    }

    private func registerRecognizedUser(_ userID: String) {
        do { try daveBridge?.addRecognizedUserChecked(userID) }
        catch { status = "Could not register a DAVE participant: \(error.localizedDescription)" }
    }

    private func sendTransitionReady(_ transitionID: Int) {
        guard let voiceGateway else { return }
        Task { try? await voiceGateway.sendDAVEJSON(opcode: 23, data: ["transition_id": transitionID]) }
    }

    private func sendInvalidCommit(_ transitionID: Int) {
        guard let voiceGateway else { return }
        Task { try? await voiceGateway.sendDAVEJSON(opcode: 31, data: ["transition_id": transitionID]) }
    }

    private func startMediaIfReady() {
        guard !ended, !didStartMedia, transitionExecuted,
              daveVersion > 0, let bridge = daveBridge, bridge.isSenderReady(),
              let transport = udpTransport, let cipher = transportCipher,
              let ssrc = storedLocalSSRC, let voiceGateway else { return }
        do {
            let audio = DiscordAudioIO()
            audio.setMuted(isMuted)
            let opus = try OpusCodec()
            let pipeline = DiscordVoiceMediaPipeline(
                audioIO: audio, codec: opus, transport: transport,
                transportCipher: cipher, ssrc: ssrc,
                daveEncrypt: { data, streamSSRC in try bridge.encryptFrameChecked(data, ssrc: streamSSRC) },
                daveDecrypt: { [weak self] data, remoteSSRC in
                    guard let self, let remoteUser = self.userIDBySSRC[remoteSSRC] else {
                        throw VoiceSessionError.unknownSSRC
                    }
                    return try bridge.decryptFrameChecked(data, userID: remoteUser)
                })
            pipeline.onDiagnostic = { [weak self] message in
                Task { @MainActor in
                    guard let self, !self.ended else { return }
                    self.status = message
                }
            }
            try pipeline.start()
            didStartMedia = true
            audioIO = audio
            codec = opus
            mediaPipeline = pipeline
            DiscordAudioIO.requestRecordPermission { [weak self] allowed in
                Task { @MainActor in
                    guard let self, !self.ended else { return }
                    guard allowed else {
                        self.stopMedia()
                        self.status = "Microphone permission denied; call audio is disabled."
                        return
                    }
                    audio.start { result in
                        Task { @MainActor in
                            guard !self.ended else { return }
                            switch result {
                            case .success:
                                do {
                                    try await voiceGateway.sendSpeaking(ssrc: ssrc, speaking: true)
                                    self.status = "Audio engine started; encrypted media is running. Remote audio is not verified."
                                } catch {
                                    self.status = "Audio engine started, but Discord speaking state failed: \(error.localizedDescription)"
                                }
                            case .failure(let error):
                                self.stopMedia()
                                self.status = "Audio engine could not start: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
        } catch {
            status = "Could not start encrypted voice media: \(error.localizedDescription)"
        }
    }

    private func stopMedia() {
        mediaPipeline?.stop()
        audioIO?.stop()
        mediaPipeline = nil
        audioIO = nil
        codec = nil
        didStartMedia = false
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readTransitionPayload(_ data: Data) -> (Int, Data)? {
        guard data.count > 2 else { return nil }
        let id = (Int(data[data.startIndex]) << 8) | Int(data[data.startIndex + 1])
        return (id, data.dropFirst(2))
    }

    private static func splitCommitWelcome(_ data: Data) throws -> (commit: Data, welcome: Data) {
        var reader = MLSWireReader(data: data)
        _ = try reader.read(4)
        try reader.skipOpaque()
        _ = try reader.read(8)
        let senderType = try reader.read(1)
        _ = try reader.read(4)
        try reader.skipOpaque()
        guard try reader.read(1) == 3 else { throw VoiceSessionError.invalidMLSMessage }
        try reader.skipOpaque()
        if try reader.read(1) == 1 {
            try reader.skipOpaque()
            try reader.skipOpaque()
            _ = try reader.read(2)
            try reader.skipOpaque()
            for _ in 0..<5 { try reader.skipOpaque() }
            let source = try reader.read(1)
            if source == 1 { _ = try reader.read(16) }
            else if source == 3 { try reader.skipOpaque() }
            try reader.skipOpaque()
            try reader.skipOpaque()
            try reader.skipOpaque()
        }
        try reader.skipOpaque()
        try reader.skipOpaque()
        if senderType == 1 { try reader.skipOpaque() }
        guard reader.offset > 0, reader.offset <= data.count else { throw VoiceSessionError.invalidMLSMessage }
        return (Data(data.prefix(reader.offset)), Data(data.dropFirst(reader.offset)))
    }
}

private extension CoralcordDAVEBridge {
    func initializeGroupChecked(withID groupID: UInt64, version: UInt16) throws {
        var error: NSError?
        initializeGroup(withID: groupID, version: version, error: &error)
        if let error { throw error }
    }
    func setExternalSenderChecked(_ data: Data) throws {
        var error: NSError?
        setExternalSenderData(data, error: &error)
        if let error { throw error }
    }
    func addRecognizedUserChecked(_ userID: String) throws {
        var error: NSError?
        addRecognizedUser(userID, error: &error)
        if let error { throw error }
    }
    func keyPackageDataChecked() throws -> Data {
        var error: NSError?
        let data = keyPackageData(&error)
        if let error { throw error }
        return data
    }
    func processProposalsChecked(_ data: Data) throws -> Data {
        var error: NSError?
        let result = processProposals(data, error: &error)
        if let error { throw error }
        return result
    }
    func processCommitChecked(_ data: Data) throws {
        var error: NSError?
        processCommit(data, error: &error)
        if let error { throw error }
    }
    func processWelcomeChecked(_ data: Data) throws {
        var error: NSError?
        processWelcome(data, error: &error)
        if let error { throw error }
    }
    func encryptFrameChecked(_ data: Data, ssrc: UInt32) throws -> Data {
        var error: NSError?
        let result = encryptFrame(data, ssrc: ssrc, error: &error)
        if let error { throw error }
        return result
    }
    func decryptFrameChecked(_ data: Data, userID: String) throws -> Data {
        var error: NSError?
        let result = decryptFrame(data, userID: userID, error: &error)
        if let error { throw error }
        return result
    }
}

private struct MLSWireReader {
    let bytes: [UInt8]
    var offset = 0
    init(data: Data) { bytes = Array(data) }

    mutating func read(_ count: Int) throws -> Int {
        guard count >= 0, offset + count <= bytes.count else { throw VoiceSessionError.invalidMLSMessage }
        var result = 0
        for _ in 0..<count { result = (result << 8) | Int(bytes[offset]); offset += 1 }
        return result
    }

    mutating func skipOpaque() throws {
        guard offset < bytes.count else { throw VoiceSessionError.invalidMLSMessage }
        let first = bytes[offset]
        let prefixSize = 1 << (first >> 6)
        guard prefixSize == 1 || prefixSize == 2 || prefixSize == 4 else { throw VoiceSessionError.invalidMLSMessage }
        let length = try read(prefixSize) & ((1 << (prefixSize * 8 - 2)) - 1)
        guard length <= bytes.count - offset else { throw VoiceSessionError.invalidMLSMessage }
        offset += length
    }
}

private enum VoiceSessionError: LocalizedError {
    case invalidIdentity
    case unknownSSRC
    case invalidMLSMessage
    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "The Discord channel or user ID is invalid."
        case .unknownSSRC: return "No Discord user is mapped to this RTP SSRC yet."
        case .invalidMLSMessage: return "The DAVE MLS message framing is malformed."
        }
    }
}

struct VoiceCallSheet: View {
    @EnvironmentObject private var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: VoiceCallSession
    @State private var resolvedUsers: [String: DiscordUser] = [:]
    let channel: DiscordChannel

    init(channel: DiscordChannel) {
        self.channel = channel
        _session = StateObject(wrappedValue: VoiceCallSession(channel: channel))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 22) {
                Image(systemName: channel.guildID == nil ? "phone.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 42, weight: .medium)).foregroundColor(.indigo)
                Text(channel.displayName).font(.system(size: 22, weight: .semibold))
                HStack(spacing: 9) {
                    if !session.isSignalingReady { ProgressView().controlSize(.small) }
                    Text(session.status).font(.system(size: 14)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }.padding(.horizontal, 22)
                if !session.participantIDs.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 22) {
                        ForEach(session.participantIDs, id: \.self) { id in
                            VStack(spacing: 9) {
                                UserAvatar(user: user(for: id), size: 78, placeholder: String(id.suffix(4)))
                                    .overlay(Circle().stroke(session.speakingUserIDs.contains(id) ? Color.green : Color.clear, lineWidth: 4))
                                    .padding(4)
                                Text(user(for: id)?.displayName ?? String(id.suffix(6)))
                                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 25)
                }
                Text(model.text(
                    "Encrypted Discord voice. Participants appear here; screen sharing is not included.",
                    "Discordの暗号化音声通話です。参加者はここに表示されます。画面共有には対応していません。"
                )).font(.system(size: 13)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20)
                Spacer()
                HStack(spacing: 0) {
                    Button { session.toggleMute() } label: {
                        Label(session.isMuted ? model.text("Unmute", "ミュート解除") : model.text("Mute", "ミュート"),
                              systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                    }
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 30)
                    Button(role: .destructive) { session.end(); dismiss() } label: {
                        Label(model.text("End", "終了"), systemImage: "phone.down.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.red)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                    }
                }
                .background(Color(.systemGray6))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.35), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            .padding(.top, 35)
            .navigationTitle(model.text("Discord call", "Discord通話"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.text("Close", "閉じる")) { session.end(); dismiss() }
                }
            }
        }
        .onAppear { session.begin() }
        .onDisappear { session.end() }
        .task(id: session.participantIDs.sorted().joined(separator: ",")) {
            for id in session.participantIDs where resolvedUsers[id] == nil {
                if id == model.currentUser?.id, let user = model.currentUser {
                    resolvedUsers[id] = user
                } else if let user = channel.recipients?.first(where: { $0.id == id }) {
                    resolvedUsers[id] = user
                } else if let profile = await model.loadUserProfile(id: id), let user = profile.user {
                    resolvedUsers[id] = user
                }
            }
        }
    }

    private func user(for id: String) -> DiscordUser? {
        resolvedUsers[id] ?? channel.recipients?.first(where: { $0.id == id }) ?? (model.currentUser?.id == id ? model.currentUser : nil)
    }
}
