import SwiftUI
import WebKit

/// Represents a file selected via the Google Picker
struct GooglePickerFile: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let url: String?
}

// MARK: - SwiftUI Wrapper

/// Sheet that hosts the Google Picker JS inside a WKWebView.
/// The user selects files from their Drive; selected file IDs
/// are returned via the `onFilesPicked` closure allowing
/// `drive.file` scoped access to those files.
struct GooglePickerView: View {
    let accessToken: String
    let apiKey: String
    let appId: String
    let onFilesPicked: ([GooglePickerFile]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Google Drive")
                    .font(.headline)
                Spacer()
                // Placeholder for symmetry
                Text("Cancel").hidden()
            }
            .padding()
            #if os(macOS)
            .background(Color(NSColor.windowBackgroundColor))
            #else
            .background(Color(UIColor.systemBackground))
            #endif

            GooglePickerWebView(
                accessToken: accessToken,
                apiKey: apiKey,
                appId: appId,
                onFilesPicked: onFilesPicked,
                onCancel: onCancel
            )
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 550)
        #endif
    }
}

// MARK: - Platform-specific WKWebView wrapper

#if os(macOS)
struct GooglePickerWebView: NSViewRepresentable {
    let accessToken: String
    let apiKey: String
    let appId: String
    let onFilesPicked: ([GooglePickerFile]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> PickerCoordinator {
        PickerCoordinator(onFilesPicked: onFilesPicked, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct GooglePickerWebView: UIViewRepresentable {
    let accessToken: String
    let apiKey: String
    let appId: String
    let onFilesPicked: ([GooglePickerFile]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> PickerCoordinator {
        PickerCoordinator(onFilesPicked: onFilesPicked, onCancel: onCancel)
    }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

// MARK: - Shared WKWebView factory

extension GooglePickerWebView {
    func makeWebView(coordinator: PickerCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // Register message handlers for Picker → Swift communication
        userContentController.add(coordinator, name: "pickerCallback")
        userContentController.add(coordinator, name: "pickerCancel")

        config.userContentController = userContentController

        // Allow inline media and JS
        config.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator

        // Load the Picker HTML
        let html = Self.pickerHTML(
            accessToken: accessToken,
            apiKey: apiKey,
            appId: appId
        )
        webView.loadHTMLString(html, baseURL: URL(string: "https://drive.google.com"))
        return webView
    }

    /// Generate the HTML page that hosts the Google Picker.
    /// We already have the OAuth token so we skip the GIS auth library entirely.
    static func pickerHTML(accessToken: String, apiKey: String, appId: String) -> String {
        // JSON-encode values for safe JS embedding. JSONEncoder produces
        // properly escaped strings (handles \, newlines, </script>, etc.)
        // and wraps them in double quotes, so they can be used directly as
        // JS string literals.
        let encoder = JSONEncoder()
        guard let tokenJSON = try? encoder.encode(accessToken),
              let keyJSON = try? encoder.encode(apiKey),
              let appIdJSON = try? encoder.encode(appId),
              let escapedToken = String(data: tokenJSON, encoding: .utf8),
              let escapedKey = String(data: keyJSON, encoding: .utf8),
              let escapedAppId = String(data: appIdJSON, encoding: .utf8) else {
            return "<html><body>Error: Failed to encode picker parameters</body></html>"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body {
                    margin: 0;
                    padding: 0;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    background: #1a1a2e;
                    color: #e0e0e0;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    height: 100vh;
                }
                .loading {
                    text-align: center;
                    font-size: 16px;
                    color: #a0a0c0;
                }
                .loading .spinner {
                    display: inline-block;
                    width: 32px; height: 32px;
                    border: 3px solid rgba(160,160,192,0.3);
                    border-top-color: #7c4dff;
                    border-radius: 50%;
                    animation: spin 0.8s linear infinite;
                    margin-bottom: 12px;
                }
                @keyframes spin { to { transform: rotate(360deg); } }
                .error { color: #ff6b6b; margin-top: 12px; font-size: 14px; }
            </style>
        </head>
        <body>
            <div id="status" class="loading">
                <div class="spinner"></div>
                <div>Loading Google Drive…</div>
                <div id="errorMsg" class="error" style="display:none;"></div>
            </div>

            <script>
                const ACCESS_TOKEN = \(escapedToken);
                const API_KEY = \(escapedKey);
                const APP_ID = \(escapedAppId);

                function onApiLoad() {
                    gapi.load('picker', createPicker);
                }

                function createPicker() {
                    try {
                        const docsView = new google.picker.DocsView()
                            .setIncludeFolders(true)
                            .setSelectFolderEnabled(false);

                        const picker = new google.picker.PickerBuilder()
                            .addView(docsView)
                            .addView(google.picker.ViewId.RECENTLY_PICKED)
                            .setOAuthToken(ACCESS_TOKEN)
                            .setDeveloperKey(API_KEY)
                            .setAppId(APP_ID)
                            .setCallback(pickerCallback)
                            .enableFeature(google.picker.Feature.MULTISELECT_ENABLED)
                            .setTitle('Select files for AICoven')
                            .setSize(window.innerWidth, window.innerHeight - 60)
                            .build();
                        picker.setVisible(true);
                    } catch (e) {
                        showError('Failed to create picker: ' + e.message);
                    }
                }

                function pickerCallback(data) {
                    if (data.action === google.picker.Action.PICKED) {
                        const files = data.docs.map(function(doc) {
                            return {
                                id: doc.id,
                                name: doc.name,
                                mimeType: doc.mimeType,
                                url: doc.url || null
                            };
                        });
                        window.webkit.messageHandlers.pickerCallback.postMessage(
                            JSON.stringify(files)
                        );
                    } else if (data.action === google.picker.Action.CANCEL) {
                        window.webkit.messageHandlers.pickerCancel.postMessage('cancel');
                    }
                }

                function showError(msg) {
                    document.getElementById('errorMsg').textContent = msg;
                    document.getElementById('errorMsg').style.display = 'block';
                }
            </script>
            <script async defer
                src="https://apis.google.com/js/api.js"
                onload="onApiLoad()">
            </script>
        </body>
        </html>
        """
    }
}

// MARK: - WKWebView Coordinator

/// Handles messages from the Picker JS and passes them back to Swift.
class PickerCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let onFilesPicked: ([GooglePickerFile]) -> Void
    let onCancel: () -> Void

    init(onFilesPicked: @escaping ([GooglePickerFile]) -> Void, onCancel: @escaping () -> Void) {
        self.onFilesPicked = onFilesPicked
        self.onCancel = onCancel
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "pickerCallback":
            guard let jsonString = message.body as? String,
                  let data = jsonString.data(using: .utf8) else {
                return
            }
            do {
                let files = try JSONDecoder().decode([GooglePickerFile].self, from: data)
                DispatchQueue.main.async { [weak self] in
                    self?.onFilesPicked(files)
                }
            } catch {
                print("[GooglePicker] Failed to decode picked files: \(error)")
            }

        case "pickerCancel":
            DispatchQueue.main.async { [weak self] in
                self?.onCancel()
            }

        default:
            break
        }
    }

    // Allow navigation to Google domains needed by the Picker
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}
