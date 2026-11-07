import Foundation
import Network

/// HTTP CONNECT-прокси для доступа к cursor.com из сетей, где он заблокирован/режется DPI.
enum ProxyResolver {
    struct HTTPProxy: Equatable, CustomStringConvertible {
        let host: String
        let port: Int

        var description: String { "\(host):\(port)" }

        var connectionProxyDictionary: [AnyHashable: Any] {
            [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host,
                kCFNetworkProxiesHTTPSPort: port,
            ]
        }
    }

    /// Авто: Cursor `http.proxy`, затем `HTTPS_PROXY` / `HTTP_PROXY` из окружения, затем напрямую.
    static func autoCandidates() -> [HTTPProxy?] {
        var list: [HTTPProxy] = []
        if let fromCursor = readCursorHTTPProxy() {
            list.append(fromCursor)
        }
        if let fromEnv = readEnvironmentProxy() {
            list.append(fromEnv)
        }

        var seen = Set<String>()
        var reachable: [HTTPProxy?] = []
        for p in list {
            let key = p.description
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            if isTCPOpen(host: p.host, port: p.port, timeoutMs: 250) {
                reachable.append(p)
            }
        }
        reachable.append(nil)
        return reachable
    }

    static func readCursorHTTPProxy() -> HTTPProxy? {
        let path = NSString(
            string: "~/Library/Application Support/Cursor/User/settings.json"
        ).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["http.proxy"] as? String else {
            return nil
        }
        return parseHTTPProxyURL(raw)
    }

    static func readEnvironmentProxy() -> HTTPProxy? {
        let env = ProcessInfo.processInfo.environment
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] {
            if let raw = env[key], let p = parseHTTPProxyURL(raw) {
                return p
            }
        }
        return nil
    }

    static func parseHTTPProxyURL(_ raw: String) -> HTTPProxy? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Допускаем host:port без схемы.
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else if trimmed.contains(":") {
            withScheme = "http://\(trimmed)"
        } else {
            return nil
        }

        guard let url = URL(string: withScheme),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        let scheme = (url.scheme ?? "http").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return HTTPProxy(host: host, port: port)
    }

    static func isTCPOpen(host: String, port: Int, timeoutMs: Int) -> Bool {
        let hostNw = NWEndpoint.Host(host)
        guard let portNw = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let conn = NWConnection(host: hostNw, port: portNw, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ok = true
                conn.cancel()
                sem.signal()
            case .failed, .cancelled:
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .utility))
        let ns = Double(timeoutMs) / 1000.0
        _ = sem.wait(timeout: .now() + ns)
        conn.cancel()
        return ok
    }
}
