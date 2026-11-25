import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: ChatModel
    @State private var email = ""
    @State private var password = ""
    @State private var mfaCode = ""

    private let accent = Color(red: 0.13, green: 0.52, blue: 0.66)

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundColor(accent)
            VStack(spacing: 6) {
                Text("Coralcord")
                    .font(.system(size: 30, weight: .bold))
                Text(model.text("Sign in to your Discord account", "Discordアカウントにログイン"))
                    .font(.system(size: 15)).foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                if model.pendingMFATicket == nil {
                    TextField(model.text("Email or phone", "メールアドレスまたは電話番号"), text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .textContentType(.username)
                        .padding(14)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    SecureField(model.text("Password", "パスワード"), text: $password)
                        .textContentType(.password)
                        .padding(14)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Button {
                        let submittedPassword = password
                        password = ""
                        Task { await model.signIn(email: email, password: submittedPassword) }
                    } label: {
                        actionLabel(model.text("Sign In", "ログイン"))
                    }
                    .disabled(model.isLoading || email.isEmpty || password.isEmpty)
                } else {
                    Text(model.text("Two-factor authentication", "二要素認証"))
                        .font(.system(size: 18, weight: .semibold))
                    TextField(model.text("Authenticator code", "認証コード"), text: $mfaCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .padding(14)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Button {
                        Task { await model.submitMFA(code: mfaCode) }
                    } label: {
                        actionLabel(model.text("Verify", "確認"))
                    }
                    .disabled(model.isLoading || mfaCode.isEmpty)
                    Button(model.text("Cancel sign in", "ログインをキャンセル")) {
                        model.pendingMFATicket = nil
                        mfaCode = ""
                    }
                    .font(.system(size: 14))
                }
            }

            if model.isLoading { ProgressView() }

            Text(model.text(
                "Unofficial sign-in. Credentials are sent directly to discord.com over HTTPS and are not saved by Coralcord. The returned session is stored in iOS Keychain. Discord may block this unsupported login or restrict the account.",
                "非公式ログインです。認証情報はHTTPSでdiscord.comへ直接送信し、Coralcordには保存しません。取得したセッションはiOS Keychainに保存します。未対応のログインとしてDiscordに拒否されたり、アカウントが制限されたりする可能性があります。"
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color(.systemBackground).ignoresSafeArea())
        .alert(model.text("Sign in failed", "ログインできませんでした"), isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button(model.text("OK", "閉じる"), role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private func actionLabel(_ title: String) -> some View {
        HStack {
            Spacer()
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer()
        }
        .padding(.vertical, 14)
        .foregroundColor(.white)
        .background(accent)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
