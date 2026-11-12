import SwiftUI
import UIKit

/// Where feedback goes: an email to the developer (the Mail app, or Gmail
/// when it is installed) or an issue on the app's GitHub repository. These
/// are the only links Blender Local opens, and only when the user picks one.
enum Feedback {
    static let address = "euler.yu@gmail.com"
    static let issues = URL(string: "https://github.com/yu314-coder/blender-local/issues/new")!

    static var subject: String { "Blender Local feedback (\(version))" }

    /// The version, the device and its system, so a report says what it ran on.
    static var body: String {
        "\n\n\n—\nBlender Local \(version)\n\(model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n"
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static var model: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessInfo.processInfo.isiOSAppOnMac ? "Mac (\(machine))" : machine
    }

    private static func query(_ items: [(String, String)]) -> String {
        var c = URLComponents()
        c.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.percentEncodedQuery ?? ""
    }

    static var mail: URL {
        URL(string: "mailto:\(address)?" + query([("subject", subject), ("body", body)]))!
    }

    /// Gmail's app if it is installed, else Gmail's compose page.
    static func openGmail() {
        let app = URL(string: "googlegmail:///co?" + query([("to", address), ("subject", subject), ("body", body)]))!
        let web = URL(string: "https://mail.google.com/mail/?" + query([("view", "cm"), ("to", address), ("su", subject), ("body", body)]))!
        UIApplication.shared.open(app, options: [:]) { opened in
            if !opened { UIApplication.shared.open(web) }
        }
    }

    /// When no mail app answers the mailto link: the address on the
    /// clipboard, so it can be pasted into any mail app.
    static func openMail() {
        UIApplication.shared.open(mail, options: [:]) { opened in
            if !opened { UIPasteboard.general.string = address }
        }
    }
}

/// The Help menu's feedback entries.
struct FeedbackMenuItems: View {
    var body: some View {
        Menu("Send Feedback") {
            Button("Email (Mail)") { Feedback.openMail() }
            Button("Email (Gmail)") { Feedback.openGmail() }
            Button("Copy Email Address") { UIPasteboard.general.string = Feedback.address }
        }
        Button("Report a Bug") { UIApplication.shared.open(Feedback.issues) }
    }
}
