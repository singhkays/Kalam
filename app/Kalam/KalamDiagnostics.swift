import Foundation

func privacySafeErrorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

