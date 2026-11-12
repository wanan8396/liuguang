import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // flutter_inappwebview 1.1.2's CookieManager always uses the persistent
    // default store. This bridge addresses only our marked private WKWebView.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LiuguangSnifferCookies") {
      let channel = FlutterMethodChannel(
        name: "liuguang/native_web_sniffer_cookies",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        guard let args = call.arguments as? [String: Any],
              let scope = args["scope"] as? String,
              scope.hasPrefix("liuguang-native-sniff-"),
              let rawUrl = args["url"] as? String,
              let url = URL(string: rawUrl),
              let host = url.host,
              ["http", "https"].contains(url.scheme ?? ""),
              let view = self.snifferWebView(scope: scope) else {
          result(FlutterError(code: "sniffer_view_missing", message: "Private WKWebView unavailable", details: nil))
          return
        }
        let store = view.configuration.websiteDataStore.httpCookieStore
        switch call.method {
        case "setCookies":
          let header = args["cookie"] as? String ?? ""
          let group = DispatchGroup()
          for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
              .name: name, .value: value, .domain: host, .path: "/"
            ]
            if url.scheme == "https" { properties[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: properties) {
              group.enter()
              store.setCookie(cookie) { group.leave() }
            }
          }
          group.notify(queue: .main) { result(nil) }
        case "getCookies":
          store.getAllCookies { cookies in
            let path = url.path.isEmpty ? "/" : url.path
            let now = Date()
            let selected = cookies.filter { cookie in
              let domain = cookie.domain.lowercased()
              let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
              let candidate = host.lowercased()
              let domainMatches = candidate == bare || (domain.hasPrefix(".") && candidate.hasSuffix("." + bare))
              let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
              let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
              return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate == nil || cookie.expiresDate! > now)
            }.sorted { $0.path.count > $1.path.count }
            result(selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private func snifferWebView(scope: String) -> WKWebView? {
    let marker = "/*\(scope)*/"
    func search(_ root: UIView) -> WKWebView? {
      if let webView = root as? WKWebView,
         !webView.configuration.websiteDataStore.isPersistent,
         webView.configuration.userContentController.userScripts.contains(where: { $0.source.hasPrefix(marker) }) {
        return webView
      }
      for child in root.subviews {
        if let found = search(child) { return found }
      }
      return nil
    }
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        if let found = search(window) { return found }
      }
    }
    return nil
  }
}
