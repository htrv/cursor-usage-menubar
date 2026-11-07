import Foundation
import SQLite3

enum TokenProvider {
    static let dbPath = NSString(
        string: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    ).expandingTildeInPath

    struct Auth {
        let accessToken: String
        let sub: String

        var sessionCookie: String {
            let raw = "\(sub)::\(accessToken)"
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
            return "WorkosCursorSessionToken=\(encoded)"
        }
    }

    static func load() throws -> Auth {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw AppError.noToken("не открыть state.vscdb — Cursor установлен и залогинен?")
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw AppError.noToken("ошибка чтения токена из state.vscdb")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else {
            throw AppError.noToken("cursorAuth/accessToken не найден — войди в Cursor")
        }
        let token = String(cString: cStr)
        let sub = try jwtSub(token)
        return Auth(accessToken: token, sub: sub)
    }

    private static func jwtSub(_ token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw AppError.noToken("accessToken не JWT") }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: b64),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else {
            throw AppError.noToken("не разобрать sub из JWT")
        }
        return sub
    }
}
