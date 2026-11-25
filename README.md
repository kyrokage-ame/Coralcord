# Coralcord 1.0.0

Coralcordは、SwiftUI製のDiscord非公式クライアントです。

## 重要：教育・実験用プロトタイプ

このソフトウェアは教育・研究・個人的な実験を目的とした未完成のプロトタイプです。Discord公式アプリではなく、Discord Inc.による承認・提携・推奨を受けていません。Discordの現行規約、開発者ポリシー、ブランドガイドライン、および利用地域の法律を確認して使用してください。

現在のログイン実装は、通常アカウントのメールアドレスとパスワードをDiscordへ送り、非公開の`/api/v9/auth/login`経路でユーザーセッションを取得しようとします。これはDiscordが提供する公式OAuth2ログインではなく、安定性も保証されません。Discordのサポート記事は、OAuth2／Bot API以外で通常ユーザーアカウントを自動化する行為を禁止し、アカウント停止につながり得ると説明しています。Discord Developer Policyには、Discordユーザーの認証情報を要求・取得しないよう定めた項目もあります。[Self-Bots](https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots) [Developer Policy](https://support-dev.discord.com/hc/en-us/articles/8563934450327-Discord-Developer-Policy) [Terms of Service](https://discord.com/terms)

したがって、免責文や「教育目的」という表示だけで、非公開APIの使用が規約に適合したり、アカウント停止・法的責任・第三者の権利問題がなくなったりするわけではありません。実アカウントでのログイン、DM取得、メッセージ送受信、実機起動は未検証です。CAPTCHAには対応していません。使用する場合も、重要なアカウントでは試さず、まず公式クライアントでログインできる使い捨ての検証アカウントを検討してください。CAPTCHAや安全機能の回避は実装しません。

## 現在の機能

- メールアドレス／パスワードによる非公式ログイン。取得したセッショントークンは端末のKeychainに保存します。
- 自分のプロフィール、参加サーバー、DM、テキスト系チャンネル、選択チャンネルの直近50件のメッセージの取得。
- テキスト送信に加えて、写真ライブラリの画像またはファイルアプリのファイルをメッセージに添付するUI／multipart送信処理を追加。HTTPエラー詳細を表示し、成功応答の解析失敗は送信拒否と区別します。Discord側での受理・実送信はアカウント未検証です。送信時の全員メンションは既定で無効です。
- メッセージ長押しメニューからのUnicodeリアクション、同一サーバー絵文字リアクション、編集・削除・DM転送。編集／削除は自分のメッセージに限定し、削除前に確認します。転送は本文と添付URLを引用してDMへ再送する方式で、Discordのネイティブ転送ではありません。
- 「More」から通常のUnicode絵文字と、同じサーバーで利用可能なカスタム絵文字を選べます。Nitro限定の外部サーバー絵文字候補は出しません。作成メニューから同一サーバーの利用可能なカスタム絵文字を本文へ挿入し、サーバースタンプの送信も試せます。スタンプ送信は失敗時に選択画面を閉じず、再試行できます。APIの受理や権限はアカウント未検証です。
- 添付画像・ファイルおよび基本的なEmbed（タイトル、本文、画像、フィールド、リンク）の表示。
- DMとメッセージのユーザーアイコン、サーバーアイコンをDiscord CDN経由で遅延読み込みします。メッセージ内のユーザー名をタップするとプロフィール詳細を追加取得し、取得できた自己紹介・表示名・サーバータグ／二つ名・代名詞を連絡先風カードで表示します。
- You画面からユーザー名・表示名・自己紹介の更新を試行できます。ユーザーIDはDiscord割当のため変更できません。この編集経路は未公開APIであり、実アカウントでは未検証です。
- DM画面はDM一覧と検索のみで、「All／Inbox」等の切替バーはありません。サーバーの既存チャンネルカテゴリを折りたたみ可能なフォルダーとして表示します。チャンネルごとのローカルミュート設定も保存できますが、通知配信自体は未実装です。
- サーバー画面に一般設定（サーバー名／説明の更新）と、選択チャンネルの24時間・無制限招待リンク発行を追加しました。Discordの権限が必要で、設定APIの受理は未検証です。
- Embed・添付リンクは既定ブラウザで開きます。設定欄に`{url}`を含む外部ブラウザ用URLテンプレートを設定すると、そのURLスキームでの起動を試し、失敗した場合は既定ブラウザへフォールバックします。
- DM／サーバーの会話を開くと、取得済みメッセージの一番下へ移動します。更新方式はプロフィール設定で「引っ張って更新」または「自動・15秒ごと」を選べます。自動モードはREST APIの定期ポーリングであり、リアルタイムのGateway接続ではありません。
- 日本語／英語、ライト／ダーク切替。外観と言語の設定は端末内に保存されます。
- 下部バーはDM／サーバー／Youの3項目で固定表示します。Youの可変高コンテンツはスクロール領域に分け、タブバーの位置・表示を保ちます。
- 保存済みセッションではDM、サーバー一覧、自分のプロフィールを並列取得し、各結果を個別に反映します。アバターや他ユーザーのプロフィール詳細は表示時／タップ時に遅延取得し、固定の0.1秒待ちを挟まない設計です。iPhone実機でのコールド起動時間と白画面の消失はまだ計測・確認できていません。

## まだ未実装または未検証

プレゼンス／オンライン状態、Gatewayによるリアルタイム受信、プッシュ通知、Discordのスラッシュコマンド、音声通話は未実装です。Bot投稿はメッセージ／DM表示でBOTバッジを付けますが、Bot管理・コマンド実行はできません。プッシュ通知にはAPNs登録とサーバー側配信構成が必要で、iOSのバックグラウンド制限にも対応していません。画面共有（共有・視聴とも）は今回実装していません。

## ビルド

必要なものはTheos、Swift対応iOSクロスコンパイラ、iPhoneOS 15.6 SDK、および`ldid`等のTheosビルド要件です。ローカルの通常ビルドはarm64／iOS 15.0を既定とします。

### Linux x86_64

TheosとiPhoneOS SDKをセットアップした後、リポジトリのルートで実行します。

```sh
export THEOS="$HOME/theos"
export PATH="$THEOS/toolchain/linux/host/bin:$THEOS/toolchain/linux/iphone/bin:$PATH"
make clean package -j2
```

アーキテクチャ別スクリプトは`.github/Workflow/<arch>/build-linux.sh`です。たとえばarm64では次のとおりです。

```sh
bash .github/Workflow/arm64/build-linux.sh
```

### Linux ARM64ホスト

TheosのLinux ARM64ホスト対応ツールチェーンがセットアップされている環境で、対象別スクリプトを実行します。

```sh
bash .github/Workflow/arm64/build-linux-arm64-host.sh
```

GitHub Actionsでは`ubuntu-24.04-arm`ランナーを使うジョブを用意しています。ホストCPUがARM64であることと、生成アプリのiOS CPUアーキテクチャは別の指定です。

### macOS

Xcodeのコマンドラインツール、iPhoneOS SDK、Theosを用意し、対象別スクリプトを実行します。

```sh
bash .github/Workflow/arm64/build-macos.sh
```

XcodeGenを使う既存の`.github/workflows/ios-build.yml`は、未署名の`.app`をビルドする別経路です。IPAのTheosビルドとは別です。

### Windows

ネイティブWindows上ではなく、WSL2のUbuntu 24.04にTheosと必要SDKを入れてビルドします。PowerShellからは次を実行できます。

```powershell
.\.github\Workflow\arm64\build-windows.ps1
```

GitHub Actions用のWindowsジョブは`Vampire/setup-wsl`でWSLをセットアップしてから同じLinuxスクリプトを呼び出します。サードパーティActionやビルド用ツールは、公開運用前にソースとバージョンを確認してください。

### アーキテクチャ別GitHub Actions

Github Action用ビルドスクリプトとYAMLテンプレートは`.github/Workflow/armv7/`、`.github/Workflow/arm64/`、`.github/Workflow/arm64e/`にあります。

- `.github/workflows/build-armv7.yml`
- `.github/workflows/build-arm64.yml`
- `.github/workflows/build-arm64e.yml`

指定アーキテクチャのビルドを試み、成功時にIPAをArtifactとして保存します。

#### この作業環境での試験結果

- arm64: Linux x86_64上でIPAのビルドに成功しました。
- arm64e: コンパイルとリンクの試行中にリンカーから`incompatible arm64e ABI compiler`警告が出ました。生成物を有効なarm64e IPAとは見なせません。arm64e Linux／macOSスクリプトはこの警告を検出するとエラー終了し、CIで成功扱いにしないようにしました。
- armv7: 現在のツールチェーンはiOS 11以降を対象にarmv7バイナリ／IRを出力できないとしてビルドを拒否しました。iOS 15.0ターゲットのままarmv7対応を保証することはできません。
- GitHub-hostedの各OS・Linux ARM64ホストでの実行は未確認です。スクリプトは成功を装わず、各環境の実際の結果を返します。
Theos／`ldid`で作るIPAはApple Developer証明書による署名ではなく、App Store用ではありません。インストールには対応する署名・インストール手段が別途必要です。

## 公開、著作権、商標、免責

このリポジトリには`LICENSE`ファイルがありません。したがって、現時点で第三者へコードの再利用・改変・再配布を許すオープンソースライセンスは付与していません。GitHubの説明によると、ライセンスがない場合は通常の著作権法が適用され、作者が権利を保持します。一方、公開GitHubリポジトリの閲覧者にはGitHub上で閲覧・フォークする権利が認められます。[GitHub: Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)

公開前に、ソースコード、アプリアイコン、画像、フォント、依存ツール、参照・流用したコードの出所と各ライセンスを確認してください。第三者のコードや素材は、その権利者の条件に従う必要があります。権利者が確認できない素材は公開物から外すのが安全です。ライセンスを付ける場合は、すべての権利者と素材のライセンスを確認してから選択してください。

Discordおよび関連ロゴ・ブランド資産はDiscord側の権利です。Discordのブランドガイドラインは、許可なくブランド資産を使うこと、Discordの製品名・ロゴに紛らわしいブランドを作ること、Discordアプリの見た目を模倣すること等に制限を示しています。Coralcordという名称・アイコン・画面デザインの公開利用について、Discordから許諾を得たとは扱わないでください。[Discord Brand Guidelines](https://discord.com/branding)

本ソフトウェアは現状有姿で提供され、作者は正確性、安全性、継続動作、特定目的への適合性、アカウントやデータの保全を保証しません。利用によるアカウント制限、データ損失、端末障害、第三者の権利侵害その他の損害について、法令で認められる最大限の範囲で責任を負わない旨を意図します。ただし、この記載はDiscordの規約・法律を上書きせず、適用法で放棄できない責任を免除するものでもありません。これは法律相談ではありません。

**公開してよいか：現状のまま公開することは勧めません。** 理由は、通常アカウントの非公開ログイン経路と資格情報入力、Discordのセルフボット／開発者ポリシー、ブランドガイドライン、未監査の画像・コードの権利です。公開するなら、まず公式OAuth2／Bot APIだけを使う設計へ切り替え、Discordのブランドに依存しない名称・ロゴ・画面を用意し、すべての素材の権利を確認し、ライセンスとワークフローの依存Actionを監査してください。判断に迷う場合は公開を保留して非公開リポジトリで管理し、必要に応じて専門家へ相談してください。

## 主なソース

- Discord [Automated User Accounts (Self-Bots)](https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots)
- Discord [Developer Policy](https://support-dev.discord.com/hc/en-us/articles/8563934450327-Discord-Developer-Policy)
- Discord [Terms of Service](https://discord.com/terms)
- Discord [Brand Guidelines](https://discord.com/branding)
- GitHub [Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)
- GitHub [Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions)

## ソース構成

- `Sources/Cordial/DiscordClient.swift` — Discord HTTPS通信、非公式ログイン試行、REST操作、Keychain
- `Sources/Cordial/ChatModel.swift` — 認証状態、サーバー／DM／チャンネル／メッセージの状態管理
- `Sources/Cordial/InboxView.swift` — DM・サーバー・プロフィールのUI
- `Sources/Cordial/ConversationView.swift` — メッセージ表示・送信UI、更新方式
- `Sources/Cordial/UserAvatar.swift` / `UserProfileView.swift` — 遅延アバターと読み取り専用ユーザーカード
- `.github/Workflow/{armv7,arm64,arm64e}/` — アーキテクチャ別のLinux／macOS／Windows-WSLビルドスクリプト
- `.github/workflows/build-arm*.yml` — GitHub Actionsの実行入口
- `RESEARCH_NOTES.md` — 過去のAPI・音声実装調査メモ
