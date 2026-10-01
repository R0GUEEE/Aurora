import SwiftUI
import WebKit
import AuroraCore

// MARK: - Package rows

/// The icon a repository advertises, with a placeholder while it loads and when
/// there is none at all.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct PackageIcon: View {

    let urlString: String?
    var size: CGFloat = 44
    var fallbackText: String? = nil

    var body: some View {
        Group {
            if let urlString = urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let fallbackText, let initial = fallbackText.first {
                    Text(String(initial).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundColor(.secondary)
                }
            }
    }
}

/// "Installed" / "Update 2.1" / "Older version". Nothing at all when the package
/// is simply not installed, because in a browse list that is the normal case.
@MainActor
struct StateBadge: View {

    let state: PackageState

    var body: some View {
        Group {
            if showsBadge {
                Text(state.label)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.18)))
                    .foregroundColor(color)
            }
        }
    }

    private var showsBadge: Bool {
        if case .notInstalled = state { return false }
        return true
    }

    private var color: Color {
        switch state {
        case .notInstalled: return .secondary
        case .installed: return .green
        case .update: return .blue
        case .olderThanInstalled: return .orange
        }
    }
}

/// One package in a list.
@MainActor
struct PackageRow: View {

    let record: PackageRecord
    let state: PackageState
    var showIcon: Bool = true
    var compact: Bool = false
    var showDescription: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            if showIcon {
                PackageIcon(urlString: resolvedIconURL, size: compact ? 34 : 44, fallbackText: record.displayName)
            }
            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(record.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if showDescription && !compact && !record.synopsis.isEmpty {
                    Text(record.synopsis)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            StateBadge(state: state)
        }
        .padding(.vertical, compact ? 0 : 2)
    }

    private var resolvedIconURL: String? {
        guard let icon = record.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty else { return nil }
        if URL(string: icon)?.scheme != nil { return icon }
        guard let base = record.origin?.url, let url = URL(string: icon, relativeTo: URL(string: base + "/")) else { return nil }
        return url.absoluteURL.absoluteString
    }

    private var subtitle: String {
        let section = record.section.isEmpty ? "Uncategorised" : record.section
        return "\(section) · \(record.version.raw)"
    }
}

// MARK: - Empty states

/// iOS 16 has no `ContentUnavailableView`, so here is one.
@MainActor
struct EmptyMessage: View {

    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Depiction

/// The in-app web view a depiction is shown in.
///
/// The project has no third-party dependency and no `SFSafariViewController`
/// wrapper, so this is a thin `UIViewRepresentable` over `WKWebView` — which also
/// means jailbreak repositories served over plain HTTP work (see
/// `NSAppTransportSecurity` in Resources/Info.plist).
struct DepictionWebView: UIViewRepresentable {

    let url: URL
    @Binding var isLoading: Bool
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The coordinator holds a copy of the representable so it can write back
        // through the bindings; keep that copy current.
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {

        var parent: DepictionWebView

        init(_ parent: DepictionWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.failure = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            parent.isLoading = false
            parent.failure = AuroraFormat.message(for: error)
        }
    }
}

/// A depiction page, presented as a sheet.
@MainActor
struct DepictionScreen: View {

    let title: String
    let url: URL

    @State private var isLoading = true
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                DepictionWebView(url: url, isLoading: $isLoading, failure: $failure)

                if isLoading {
                    ProgressView()
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                }

                if let failure = failure {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("This depiction could not be loaded")
                            .font(.headline)
                        Text(failure)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemBackground)))
                    .padding(24)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}


@MainActor
struct RepositoryIcon: View {
    let source: RepositorySource
    var size: CGFloat = 46

    private var iconURL: URL? {
        guard let base = URL(string: source.normalizedURL) else { return nil }
        // Most modern jailbreak repositories expose a Cydia-compatible icon at
        // the repository root. AsyncImage failure falls back to the monogram.
        return URL(string: "CydiaIcon.png", relativeTo: base.appendingPathComponent("/"))?.absoluteURL
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var fallback: some View {
        Text(String(source.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundColor(.secondary)
    }
}
