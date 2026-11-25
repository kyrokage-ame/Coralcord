import SwiftUI
import UIKit

struct ExternalBrowserLink<Label: View>: View {
    let url: URL
    @ViewBuilder let label: () -> Label
    @AppStorage("externalBrowserURLTemplate") private var template = ""

    var body: some View {
        Button(action: open) { label() }
            .buttonStyle(.plain)
            .accessibilityHint("Opens in your selected browser")
    }

    private func open() {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }
        let safeCharacters = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
        let encodedURL = url.absoluteString.addingPercentEncoding(withAllowedCharacters: safeCharacters) ?? url.absoluteString
        let customString = template.replacingOccurrences(of: "{url}", with: encodedURL)
        guard let customURL = URL(string: customString), customURL.scheme != nil else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }
        UIApplication.shared.open(customURL, options: [:]) { opened in
            if !opened { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
        }
    }
}
