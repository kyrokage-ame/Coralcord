# Build and voice research references

- Theos Linux installation: https://theos.dev/docs/installation-linux — Linux/WSL can target iOS; Theos installer downloads a prebuilt Swift-capable iOS toolchain (Linux x86_64) and expects SDKs under `$THEOS/sdks`.
- Theos iOS SDK repository: https://github.com/theos/sdks — public patched SDKs include iPhoneOS15.6.sdk; this environment's copy contains UIKit and SwiftUI `.swiftinterface` modules. The repo notes SDKs were generated using data from Xcode/device support files.
- Theos app packaging: https://theos.dev/docs/packaging — Theos supports `.ipa`; its IPA packager stores the staged app under `Payload/`.
- xtool installation: https://xtool.sh/documentation/xtool/installation-linux/ — an alternative Linux/WSL SwiftPM app builder, but docs require an Apple-authenticated Xcode `.xip` to extract Apple's SDK, and setup authentication for signing/install.
- TrollInstallerX install guide: https://ios.cfw.guide/installing-trollstore-trollinstallerx/ — it lists A9-and-later devices on iOS 15.2–15.8.6. iPhone 7 is A10; iOS 15.8.2 is in range. Coralcord device installation has not been tested.
- Official Discord developer platform: https://discord.com/developers/docs/intro — describes Bots & Apps, Activities, and Social Layer for Games; it does not advertise a general official replacement-client API.
- Enmity organization: https://github.com/enmity-mod — its public repos include a JS mod/addon runtime and a tweak for loading bundles/native functions into Discord; it is not a standalone voice client.
- Stossycord source: https://github.com/Stossycord/Stossycord — the README explicitly lists Voice Chat as unsupported/coming soon.


## Verified voice implementation details (follow-up)

- [Stossycord README](https://github.com/Stossycord/Stossycord) explicitly lists “Voice Chat” as “Unsupported / Coming Soon.”
- [StossycordAPI-Old README](https://github.com/Stossycord/StossycordAPI-Old) describes its Swift implementation as unfinished and does not document voice calls.
- [Enmity organization](https://github.com/enmity-mod) lists a mod/addon runtime and an iOS tweak for loading bundles/native functionality, not a standalone Swift voice stack.
- [Distra README](https://github.com/OMetaVR/Distra) says its Theos tweak injects JS into Discord's own runtime and its IPA patcher modifies a decrypted Discord IPA. Thus its voice-related plugins operate in the host Discord app; they are not an independent call implementation.
- [Discord Social SDK: Managing Voice Chat](https://docs.discord.com/developers/discord-social-sdk/development-guides/managing-voice-chat) says calls require active SDK-managed lobbies and configured OAuth communication scopes. Its documented scope is game/app social integration, not arbitrary existing DM/server calls.
- [Discord Voice Connections](https://docs.discord.com/developers/topics/voice-connections) documents a multi-stage Gateway exchange, a voice WebSocket with identification and heartbeats, plus UDP discovery/transport and encryption negotiation. It is protocol documentation, not a ready-made SwiftUI feature.

Conclusion: Coralcord cannot truthfully claim to place or join arbitrary Discord DM/server calls inside its own UI. Its call action should open the corresponding Discord channel in the official app, where the user completes authentication and joins/starts the call. Screen sharing remains unimplemented.

## Build/installation clarification

- [Theos Linux/Windows installation](https://theos.dev/docs/installation-linux) documents Linux and Windows via WSL as supporting iOS targets; [Theos packaging](https://theos.dev/docs/packaging) documents IPA packaging. This environment did build the current source with Theos, an iPhoneOS 15.6 SDK and ldid.
- [TrollInstallerX install guide](https://ios.cfw.guide/installing-trollstore-trollinstallerx/) says A9-and-later devices are supported on iOS 15.2–15.8.6. iPhone 7 is A10, so iOS 15.8.2 is in that range. This is general device compatibility only; the Coralcord IPA itself has not been installed or launched on hardware.
- `.github/workflows/ios-build.yml` creates an unsigned Xcode `.app` on macOS. `.github/workflows/ios-ipa-linux.yml` is configured to package an IPA on Ubuntu but has not yet been run on GitHub. `ldid` pseudo-signing is not an Apple Developer certificate or App Store signature.


## OAuth and live-message implementation check (Nov 2026)

- [Discord OAuth2 documentation](https://docs.discord.com/developers/topics/oauth2) documents OAuth scopes such as `identify` and `guilds` for user identity/basic guild listing. `dm_channels.read` is restricted to approved partners. `messages.read` is described for local RPC access to all client channels, otherwise restricted to channels/guilds the app creates. The docs state developer terms prohibit automating standard user accounts outside the OAuth2/bot API, and describe bots as distinct accounts that cannot join group DMs or have friends.
- [Discord Create Message endpoint](https://docs.discord.com/developers/resources/message) supports posts in guild text/DM channels and specifies channel permissions. This does not grant an ordinary OAuth user token general client access; the normal Discord user-session API is not offered as a replacement-client API.
- [Stossycord AuthService.swift](https://raw.githubusercontent.com/Stossycord/Stossycord/main/Stossycord/Services/User/AuthService.swift) and [Login.swift](https://raw.githubusercontent.com/Stossycord/Stossycord/main/Stossycord/Functions/Api/User/Login/Login.swift) show an email/password POST to `auth/login`, an MFA endpoint, and handling/storing a returned user token. [DiscordAPI.swift](https://raw.githubusercontent.com/Stossycord/Stossycord/main/Stossycord/Functions/Api/DiscordAPI.swift) shows API v9 requests with that token in `Authorization` and browser-context headers. This is not the documented OAuth authorization flow.
- Decision gate: do not expose a user-password/token login or copy the undocumented Stossycord auth route into Coralcord. A supportable route is either (a) OAuth identity/basic guild display only, or (b) a separately installed bot with a securely hosted backend, messaging only where that bot is present and permitted. Neither route provides a full official Discord replacement client or personal/group DMs as the logged-in user.


## Coralcord implementation update

Coralcord's current source contains an independent Swift implementation of a user/password POST to `discord.com/api/v9/auth/login`, TOTP submission, Keychain storage, current-user/guild/DM/channel/message reads, text sends, multipart attachment attempts, custom emoji markup, and guild sticker sends. It sends traffic directly to Discord and does not configure a proxy, credential broker, CAPTCHA solver, or third-party API. It does not implement Gateway realtime events or voice calls. Sending uses a non-public user-session route and has not been verified end-to-end with an account or device; build success is not proof that Discord accepts the requests. The official Bot/OAuth APIs are not a drop-in replacement for a full user-account client.

Source references reviewed: [Stossycord AuthService](https://raw.githubusercontent.com/Stossycord/Stossycord/main/Stossycord/Services/User/AuthService.swift), [Stossycord Login.swift](https://raw.githubusercontent.com/Stossycord/Stossycord/main/Stossycord/Functions/Api/User/Login/Login.swift), [Stossycord DiscordAPI.swift](https://raw.githubusercontent.com/Stossycord/Stossycord/main/Stossycord/Functions/Api/DiscordAPI.swift), [Discord OAuth2 docs](https://docs.discord.com/developers/topics/oauth2), [Discord message endpoint docs](https://docs.discord.com/developers/resources/message).

## 音声通話の追加調査（2026-11-25）

- Discord公式Voice Connections仕様では、通話は通常のGatewayだけで完結せず、Gateway上のVoice State／Voice Server Updateの両方を待ち、Voice WebSocket、UDPのIP discovery、暗号化メディア送受信、継続Heartbeatを実装する必要がある。公式仕様はVoice Gateway v8を推奨している。DM／グループDM／サーバー音声通話はDAVEによるE2EEの対象であり、公式資料は2026-03-01以降に対象会話でE2EEのみを受け入れると説明している。したがって、古いdiscord.js音声処理だけをSwiftUIに移植しても現在の通話接続として成立しない。
- 公式資料はDAVE実装にMLSベースの鍵交換とフレーム暗号化を要求し、オープンソースのlibdaveを案内している。
- `aiko-chan-ai/discord.js-selfbot-v13`のREADMEにはVoice & Video機能が挙がっている一方、リポジトリは2025-10-11にアーカイブされ、README自身が通常ユーザーアカウントでの使用はDiscord規約に反しアカウント停止につながると明記している。同READMEはトークン窃取・流出リスクも警告する。Coralcordへトークン抽出コードやアーカイブ済みselfbot実装をコピーしない。

Sources: [Discord Voice Connections](https://docs.discord.com/developers/topics/voice-connections), [DAVE protocol](https://daveprotocol.com/), [discord.js-selfbot-v13 archive](https://github.com/aiko-chan-ai/discord.js-selfbot-v13), [Discord Self-Bots policy](https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots).


## Discord Social SDK ロビー通話実装調査（2026-11-25）

- Discord公式iOS standalone構成は`discord_partner_sdk.xcframework`をEmbed & Signし、Objective-C++/C++から`<discord_partner_sdk/discordpp.h>`を利用、`DISCORDPP_IMPLEMENTATION`は一翻訳単位に一度だけ定義、`discordpp::RunCallbacks()`を定期実行する。
- モバイル認証はDeveloper Portalで`discord-APP_ID:/authorize/callback`を登録し、URL schemeと`LSApplicationQueriesSchemes=discord`をInfo.plistへ追加。OAuthのPKCEは必須。SDKの`Client::Authorize`、`CreateAuthorizationCodeVerifier`、`AuthorizationArgs::SetClientId`、`SetScopes`、`SetCodeChallenge`、`GetToken`、`UpdateToken`、`Connect`で認証・接続する。公式例ではクライアントシークレットをアプリへ埋め込まず、Public Clientでの交換またはconfidential clientのサーバー交換を区別する。
- 音声通話は`GetDefaultCommunicationScopes()`が返す`openid sdk.social_layer`を要求し、`CreateOrJoinLobby(secret, callback)`でロビーへ入り、成功時のlobby IDで`StartCall(lobbyId)`を呼ぶ。`StartCall`はCall objectを返しcallbackはない。切断は`EndCall(lobbyId, callback)`、ロビー退出は`LeaveLobby`。通話相手も同じApplicationのロビー参加者である必要がある。
- Communication featuresはdevelopment/test時rate-limited。full release rate limit増加にはDeveloper Portal Comms Accessから申請し、Account Linking、Rich Presence/Game Invites、Unified Friends List等の審査要件がある。
- このSDKは既存Discord DMやサーバーvoice channelの通話へ直接接続するSDKではない。Coralcordの既存チャンネル呼び出しをロビー通話へマッピングしてはいけない。
- 今回の実装環境に公式`.xcframework`は見つからず、SDKをリンクした実機ビルド・OAuth認証・通話は未検証。コードはSDK入手とApplication ID設定があれば統合できるObjective-C++ブリッジとして作成する。

Sources:
- https://docs.discord.com/developers/discord-social-sdk/development-guides/account-linking-on-mobile
- https://docs.discord.com/developers/discord-social-sdk/development-guides/account-linking-with-discord
- https://docs.discord.com/developers/discord-social-sdk/development-guides/managing-voice-chat
- https://docs.discord.com/developers/discord-social-sdk/development-guides/managing-lobbies
- https://docs.discord.com/developers/discord-social-sdk/core-concepts/oauth2-scopes
- https://docs.discord.com/developers/discord-social-sdk/core-concepts/communication-features
- https://discord.com/developers/docs/social-sdk/classdiscordpp_1_1Client.html

## Enmity公開リポジトリの通話実装確認（2026-11-25）

指定された`enmity-mod/enmity`と`enmity-mod/tweak`を公開ソースで確認。Enmity本体のREADMEはDiscord上で動作するプラグイン／テーマ基盤と説明し、tweak READMEはTheosベースのDiscord向けtweakがEnmity.jsを注入・ロードすると説明している。Enmity組織ページによると組織全体は2025-02-09にアーカイブ済み。両リポジトリの`src`、`headers`等をcheckoutして`voice|audio|call|webrtc|opus|rtc|voiceState`を検索したが、独自音声スタックまたは通話接続実装は確認できなかった（ヒットは一般的なcallback等のみ）。よって、この公開コードから単独のSwiftクライアント用通話SDKを移植できる根拠は見つからず、Enmity自体が独自Discord通話クライアントのソースを提供しているとは言えない。

Sources:
- https://github.com/enmity-mod/enmity
- https://github.com/enmity-mod/tweak
- https://github.com/orgs/enmity-mod/repositories

## Abaddon音声コード調査（2026-11-25）

`uowuo/abaddon`はEnmityと異なり実際に音声処理を持つ。公開ソースに`src/discord/voiceclient.cpp/.hpp`、`src/discord/dave.cpp/.hpp`、`src/audio/manager.cpp/.hpp`があり、Voice Gateway、UDP/Opus、DAVEを実装している。READMEの依存一覧はC++17に加え、IXWebSocket、miniaudio、libopus、libsodium、libdave、mlspp等。音声コードは`Abaddon::Get()`、Glib::Dispatcher、sigc++、音声管理クラス等へ直接結合しており、独立したiOS SDKではない。CoralcordはSwift/TheosでGateway接続自体が未実装のため、voice clientだけを移しても接続情報（Voice State/Voice Serverイベント）を供給できず、依存のiOS向けクロスコンパイル／Objective-C++ブリッジも必要。

AbaddonのLICENSEはGPL-3.0。ソースコードを派生利用・リンクして配布するならGPLの条件を確認し、Coralcordの配布ソースとライセンス表示を整える必要がある。公開リポジトリの現行masterは2026-09-09のコミットだが、Issue #407は2026-03-01のDiscord変更後にVoice Channel接続不可と報告され、取得時点で未解決のOpen issue。READMEの「Voice support」記載だけでは現行環境で通話可能とは保証できない。

Sources:
- https://github.com/uowuo/abaddon
- https://github.com/uowuo/abaddon/tree/master/src/discord
- https://github.com/uowuo/abaddon/tree/master/src/audio
- https://github.com/uowuo/abaddon/blob/master/LICENSE
- https://github.com/uowuo/abaddon/issues/407
- https://github.com/uowuo/abaddon/issues/326

## Dissentと公式Voice/DAVE仕様の照合（2026-11-25）

Dissent（diamondburned/dissent）はGPL-3.0のGo/GTK4 Linuxデスクトップクライアントで、READMEは「voice chatや高度機能はサポート対象外」と明記。公開ソースを確認し、`VOICE_STATE_UPDATE`はボイスチャンネル参加者表示用に使っているが、Voice Gateway client、UDP media transport、Opus、DAVEの実装や依存は見当たらなかった。従ってDissentから音声スタックを移植することはできない。サーバーvoice channel一覧やVoiceState表示の参考にはなる。

Discord公式Voice Connections資料は、Gateway Opcode 4でjoinを要求し、`VOICE_STATE_UPDATE`と`VOICE_SERVER_UPDATE`の両方を待ち、session_id/token/endpointを取得して別のVoice WebSocketに接続する流れを記載している。公式資料はVoice Gateway v8を推奨し、Hello/Heartbeatとseq_ack、Ready後のUDP IP discovery/Select Protocol、暗号化音声の送受信を必要とする。Voice GatewayはDiscordメインGatewayとは別接続であり、Coralcordの現在のREST-onlyクライアントにはこのリアルタイム処理がない。

Discord公式ブログは、2026-03-01以降、DM/GDM、サーバーvoice channel、Go LiveでDAVEに対応しないクライアントは通話参加できないと告知し、Social SDKにはDAVEが内蔵されていると説明している。公式DAVE whitepaperはMLSのグループ鍵交換、音声フレーム暗号化、参加／退出時のepoch遷移等を規定。公式の`discord/libdave`はDAVE用C++/JSライブラリを公開している。

結論：Dissentを通話実装のコードベースにはできない。一方、公式Voice/DAVE仕様、公式libdave、およびAbaddonの過去の実装を組み合わせれば独自クライアント実装は技術的には可能。ただしCoralcordにはGateway・Voice Gateway・UDP音声・Opus・DAVE/MLS・iOS audio session統合が必要で、現在のREST-only Swift appに数行追加する規模ではない。Abaddonの現行Issue #407はDiscord側変更後の接続不能を報告しており、互換性を実機で検証しなければ完成を主張できない。Dissent README自体も公式アプリ／Webを推奨し、非公式クライアント使用によるアカウント停止リスクを警告している。

Sources:
- https://github.com/diamondburned/dissent
- https://github.com/diamondburned/dissent/tree/main/internal
- https://docs.discord.com/developers/topics/voice-connections
- https://discord.com/blog/bringing-dave-to-all-discord-platforms
- https://daveprotocol.com/
- https://github.com/discord/libdave
- https://github.com/uowuo/abaddon/issues/407


## Coralcord voice-signaling implementation update (2026-11-25)

- Added `DiscordGatewayClient` in Swift using `URLSessionWebSocketTask` for Gateway v10 JSON, Hello/Heartbeat, Identify, READY, voice state/server events, DM CALL_CREATE/CALL_UPDATE dispatch, and Opcode 4 voice-state changes. Identify uses the `capabilities`-based user-session shape observed in Abaddon rather than Bot Gateway `intents`; this is undocumented, can be rejected/changed, has no Resume/reconnect implementation, and has not been tested against a real account.
- Added `DiscordAudioIO` as a local AVAudioEngine input/output layer: PCM16LE mono 48 kHz, 20 ms frames. It does not encode/decode Opus and is not connected to the Gateway or any voice transport. Bluetooth/route changes, audio interruptions and device tests remain unverified.
- Added `VoiceCallSession` and changed the DM phone button and server voice-channel rows to open an in-app signaling sheet. The session sends Opcode 4 and observes returned voice state/server data. The UI explicitly states that it cannot carry call audio. DM outgoing call initiation/ringing is not confirmed: the `CALL_CREATE` event model only observes call events, and no supported documented REST/API operation for starting a DM call has been established.
- Voice Gateway WebSocket, UDP discovery/RTP, voice encryption, Opus, DAVE/MLS and libdave integration are not implemented. Thus this is not a completed or usable audio-call feature; the new UI is a signaling prototype and may not be accepted by Discord.
- `project.yml` now declares microphone usage and background audio for XcodeGen. The Theos app uses `Resources/Info.plist`; Makefile links AVFoundation and Network.
- Verification: `export THEOS=/home/ubuntu/theos PATH="/home/ubuntu/theos/toolchain/linux/host/bin:/home/ubuntu/theos/toolchain/linux/iphone/bin:$PATH"; make clean package -j2` completed successfully for arm64 against the iOS 15.6 SDK. This confirms compilation/package generation only; no physical iPhone, microphone, account or Discord call was tested.

Additional sources:
- https://docs.discord.com/developers/topics/voice-connections
- https://github.com/discord/libdave
- https://github.com/uowuo/abaddon/blob/master/src/discord/discord.cpp
- https://github.com/uowuo/abaddon/blob/master/src/discord/objects.cpp


## 音声メディア層実装の再調査（2026-11-25）

Discord公式Voice Connections資料は、Voice Gatewayをv8推奨としており、通常Gatewayと別のWebSocket接続を要求する。通常GatewayでVOICE_STATE_UPDATEとVOICE_SERVER_UPDATEの双方を集めた後、Voice WSへOpcode 0 Identifyを送り、Opcode 2 ReadyのSSRC/IP/port/modesを使う。UDP IP discoveryはBig Endianの74-byte packet（type=1, length=70, SSRC, 66-byte address/port領域）を送り、返る外部アドレス・portと利用可能な暗号modeでSelect Protocolを一度だけ送信し、Opcode 4 Session Descriptionの32-byte transport keyを受ける。Voice WS v8 Heartbeatには直近server sequenceの`seq_ack`が必要。Voice packetはRTP header (0x80, PT 0x78, sequence, timestamp, SSRC)と暗号化Opusからなる。音声はstereo 48kHz Opus。現行transport modeでは`aead_xchacha20_poly1305_rtpsize`対応が必須で、AES-256-GCM modeは提示されれば優先できる。音声送信前にSpeaking opcode 5が必要。

Discord公式資料は2026-03-01以降、DM/GDM、server voice、Go LiveがDAVE E2EE必須となると明記する。DAVEはMLS group/key epochsと各送信者media ratchetを処理し、Opus framesは全体をDAVE暗号化したうえでtransport AEADも適用する。受信はtransport AEADを復号してからDAVE decryptorへ渡す。公式libdaveはC++17の静的ライブラリとして作れる設計で、依存はmlsppとOpenSSL 1.1/3またはBoringSSL。C APIは`cpp/includes/dave/dave.h`にあるが、公式Makefile/vcpkgはiOS-specific prebuilt binaryや公式iOS build recipeを提供していない。自前MLS/AEAD置き換えは行わず、公式C APIを使う。

実環境ではupstream OpusのCファイル1個がTheos ClangでMach-O arm64/iOS 15 objectとしてコンパイルできることを確認した。CMakeは当該sandboxに未導入で、Opus全体の静的library buildはまだ成功していない。libopus/libdaveは現行app binaryへまだリンクされていない。

Sources:
- https://docs.discord.com/developers/topics/voice-connections
- https://github.com/discord/dave-protocol/blob/main/protocol.md
- https://github.com/discord/libdave
- https://raw.githubusercontent.com/discord/libdave/main/cpp/README.md
- https://raw.githubusercontent.com/discord/libdave/main/cpp/Makefile
- https://github.com/xiph/opus
- https://github.com/uowuo/abaddon/blob/master/src/discord/voiceclient.cpp


## Opus／RTP／Voice Gateway実装追加（2026-11-25）

Discord公式Voice Connections資料で確認したRTP-size transport modeは、AES-256-GCMまたはXChaCha20-Poly1305を用い、32-bit incrementing nonceをpayload末尾に付ける。XChaCha20 modeは必須。nonceは暗号化前／復号後にpayloadから外し、RTP CSRCやextension preambleを含むRTP headerは平文で保持する。DiscordはAES modeが提供されれば推奨するが、現行実装は必須modeのXChaChaのみを選ぶ。Opus入力は48kHz stereoであり、Coralcordの既存audio engineはmono PCM16LEのため、codec wrapperでencode時にmonoをstereo複製し、decode時にmonoへdownmixする設計にした。

公開Abaddon実装のXChaCha送信処理は、nonce整数をlittle-endian 4-byteでXChaCha 24-byte nonce先頭へcopyし、暗号化後のUDP payload末尾にも同じ4 byteを付ける。Associated dataはRTP header bytes。これは公式docsの「incrementing nonce appended to payload」「RTP-size header clear」記述と一致する実装参考である。AbaddonはGPL-3.0なので、この箇所は仕様理解だけに利用し、Coralcordへコードコピーはしていない。

DAVE公式protocol specは、JSON opcodes 21–24（protocol transition／epoch）とbinary opcodes 25–34（MLS external sender、key package、proposals、commit/welcome等）を区別する。binary MLS messagesにはsequence/opcode envelopeがあり、libdaveのC APIはsession初期化、external sender、key-package、proposals、commit/welcome処理、鍵ratchet、Opus frame encrypt/decrypt関数を提供する。`libdave`の現在のC++ READMEはmlsppとOpenSSL/BoringSSLを必須依存とし、標準構築をvcpkg submodule経由としている。

実作業ではupstream Opus commit `fed7c79c09458560452a625fe5b3675593ee7627`を`Vendor/opus/upstream`へ含め、iOS 15.6 SDK／Theos Clang 13／arm64で静的libraryを再現ビルドするスクリプトを追加した。iOS arm64 application package buildは成功。Linux hostでは同じSwift `OpusCodec` wrapperとhost libopusを使った20ms PCM→Opus→PCM smoke testも成功（1,920 PCM bytes → 399 Opus bytes → 1,920 PCM bytes）。

現時点のCoralcordコードには、Voice Gateway v8 WebSocket client、Heartbeat/seq_ack、Identify、Ready/Session Description、UDP discovery、UDP datagram transport、RTP header/sequence/timestamp、required XChaCha RTP-size transport cipher、およびOpus wrapperが含まれる。通常Gatewayで両voice eventを受け取るとserver Voice Gatewayへ進み、Ready→UDP discovery→Select Protocol→Session Descriptionを試す。DAVE binary message dispatchは生payloadをイベントへ渡すが、MLS/libdave integrationは未完。media pipelineはDAVE encrypt/decrypt callbacksを必須とし、plaintext fallbackは持たないが、まだUI/sessionへ結線されておらず、音声送受信は行わない。DM call initiation、DAVEのepoch transitions、MLS key exchange、実アカウント接続／実機音声は未検証であり、通話完成とは主張しない。

References:
- https://docs.discord.com/developers/topics/voice-connections
- https://github.com/uowuo/abaddon/blob/master/src/discord/voiceclient.cpp
- https://github.com/discord/dave-protocol/blob/main/protocol.md
- https://raw.githubusercontent.com/discord/libdave/main/cpp/README.md
- https://raw.githubusercontent.com/discord/libdave/main/cpp/includes/dave/dave.h
- https://github.com/xiph/opus/commit/fed7c79c09458560452a625fe5b3675593ee7627


## 公式DAVE opcode統合とlibdave arm64ビルド（2026-11-25）

Discordの現在の公式Voice Connections資料を再確認した。Voice Gateway Identify opcode 0には`max_dave_protocol_version`が必要で、欠落または0はDAVE非対応として扱われる。Session Description opcode 4はtransport `mode`／`secret_key`だけでなく、初期`dave_protocol_version`も返す。Coralcord側Identifyへ`max_dave_protocol_version: 1`を追加した。Voice Gateway v8のHeartbeatには最新の数値シーケンスを`seq_ack`として入れる。

公式DAVE protocolのJSON opcodeは21 prepare-transition（`protocol_version`, `transition_id`）、22 execute-transition（`transition_id`）、23 ready-for-transition（`transition_id`）、24 prepare-epoch（`protocol_version`, `epoch`）である。epochが1ならMLS groupを初期化／再作成し、key packageを送る。binary opcode 25 external sender、26 key package、27 proposals、28 commit+optional welcome、29 announce-commit-transition、30 welcomeは、各仕様に従いsequence prefixを区別する。opcode 31 invalid commit/welcomeはJSONである。サーバーからクライアントへのbinary frameには2-byte big-endian sequence numberが付き、クライアントからのbinary frameには付かない。Commit/WelcomeはMLSMessage framingを持つ。Opcode 27の提案応答はlibdave ProcessProposalsの連結commitと任意welcomeをopcode 28として返す。

公式ソースはMITのDiscord libdave `b5463c443df74db75a713c775b09a847621e6d62`。vcpkg submodule commit `16c71a39e5a0fc0bdb3fad03beef8f38ee00ee3b`を取得した。初期CMake試行はホストGNU compilerを選び、ELF x86_64 objectになったため破棄した。修正後はTheos Clang 13、iPhoneOS 15.6 SDK、arm64-apple-ios15.0 tripleを直接指定してlibdave本体、OpenSSL 3.0.7、mlspp、nlohmann-json、GoogleTestを構築した。libdaveとmlsppのobject filesを`file`で確認し、Mach-O 64-bit arm64であることを実証した。`/tmp/libdave-ios-arm64-install/lib/libdave.a`が実際のiOS build artifactである。この成果物を現在のCoralcord projectへbridge経由で統合中。依存導入にはLinux上でOpenSSL portの`xcrun -sdk iphoneos`呼び出しをTheos Clangへ転送する一時wrapperを使用した。

参照:
- https://docs.discord.com/developers/topics/voice-connections
- https://github.com/discord/dave-protocol/blob/main/protocol.md
- https://github.com/discord/libdave
- https://github.com/microsoft/vcpkg/tree/16c71a39e5a0fc0bdb3fad03beef8f38ee00ee3b


## DAVE binary transition framingの追加照合（2026-11-25）

公式DAVE protocol whitepaperとDiscord Voice Connections docsを読み、server-originated DAVE binary framingを確定した。Opcode 29 payloadは2-byte BE sequence、opcode 29、2-byte transition ID、MLS Commit。Opcode 30 payloadは2-byte BE sequence、opcode 30、2-byte transition ID、MLS Welcome。Opcode 25もserver sequence付き。Opcode 27はsequence、opcode、operation type（append=0／revoke=1）に続き、MLSMessage proposal vectorまたはproposal reference vectorを含む。libdave `daveSessionProcessProposals`はこのopcode payloadからoperation byteを含めて受け取り、MLS TLS parserでbatchを読む。Opcode 28のclient payloadはopcode、MLS commit message、必要時MLS Welcomeでsequence prefixを付けない。

Commit transition（29）は受信commitの適用後に受信ratchetを準備し、同transition IDでopcode 23 readyを送る。Welcome（30）を処理した新参加者もopcode 23を送る。Opcode 22 execute後に新epochのsender ratchetへ切り替える。Opcode 24のepoch=1は新MLS group作成を意味し、new key packageをopcode 26で送る。epoch>1の仕様変更では既存MLS groupを維持する。DAVE protocol 1.0ではmedia session参加者全員がcommitting member。参加者追加proposalを処理する側は必須でWelcomeをopcode 28に含める。

参照:
- https://github.com/discord/dave-protocol/blob/main/protocol.md
- https://docs.discord.com/developers/topics/voice-connections
- https://daveprotocol.com/
- https://raw.githubusercontent.com/discord/libdave/main/cpp/src/mls/session.cpp

## 統合ビルドの検証状況（2026-11-25）
Theos `THEOS=/home/ubuntu/theos make clean package -j2`でSwift、Objective-C++ bridge、静的リンク、IPA生成まで成功した。arm64／iOS 15.0 minimumのパッケージを生成。依存archiveの形式とsymbol tableをTheos LLVM archiverで正規化し、DAVE依存をforce-loadせず通常リンクすることで、OpenSSL legacy objectの重複シンボルを解消した。`scripts/build-libdave-ios.sh`にもこの正規化を反映した。MLS group再初期化時は既存decryptor／ratchetを破棄してからsessionを再初期化するよう修正。メディア処理はtransportまたはDAVE変換に失敗したframeを送信せず、decryptに失敗した受信frameを破棄するfail-closed動作。DAVE passthroughは無効。

この確認はクロスコンパイルとIPA構造確認までであり、実機上のログイン、Discord側のVoice Gateway受理、DM／guildの実通話、相手との音声送受信、MLS遷移実データを用いた統合テストは未実施。したがって通話可能性は未検証であり、完成とは扱わない。

## Gateway session failure recovery（2026-11-25）
Discord Gateway opcode 7／9を単純切断していた処理を修正。opcode 9のresumable flagに応じ、Resume（opcode 6）または1〜5秒待機後の新規Identifyへ分岐。ResumeはREADYイベントの`resume_gateway_url`へ接続し、最後のsequenceを仕様どおり`seq`フィールドで送る。予期しないsocket終了も最大3回まで再接続し、READY受信で回数をリセットする。通話画面にもsession回復／拒否／接続終了を表示する。公式資料: https://docs.discord.com/developers/events/gateway と https://docs.discord.com/developers/events/gateway-events。

Theosのclean packageは成功。これはGatewayの実通信を含むruntime検証ではない。Discordが非公式の通常ユーザーIdentifyを拒否する場合、または保存済みtokenが無効な場合は、この再接続処理だけでは解消しない。
