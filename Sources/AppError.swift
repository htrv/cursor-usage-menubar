import Foundation

enum AppError: LocalizedError {
    case noToken(String)
    case network(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .noToken(let m), .network(let m), .parse(let m):
            return m
        }
    }
}
