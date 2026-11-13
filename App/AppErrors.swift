// Samler brugerens fejltekst, tekniske detaljer og næste handling.

import Foundation

struct AppErrorPresentation {
    enum FixAction {
        case retry, connect, reviseInput, review, usePhone

        var title: String {
            switch self {
            case .retry: "Prøv igen"
            case .connect: "Tjek forbindelsen"
            case .reviseInput: "Ret input"
            case .review: "Gennemgå status"
            case .usePhone: "Brug Telefon imens"
            }
        }
    }

    let title: String
    let detail: String?
    let fixAction: FixAction

    init(_ error: Error, title: String? = nil) {
        let presentation = Self.describe(error)
        self.init(title: title ?? presentation.title, detail: presentation.detail, fixAction: presentation.fixAction)
    }

    private init(title: String, detail: String? = nil, fixAction: FixAction = .retry) {
        self.title = title
        self.detail = detail
        self.fixAction = fixAction
    }

    static func pcBusy(_ error: Error) -> Self? {
        if case .http(503, _)? = error as? APIError {
            return .init(title: "PC’en arbejder eller skifter model. Prøv igen om lidt.", detail: "HTTP 503", fixAction: .usePhone)
        }
        if case .http(status: 503, code: _, message: _)? = error as? V2Failure {
            return .init(title: "PC’en skifter måske model eller har travlt. Vent et øjeblik.", detail: "HTTP 503", fixAction: .usePhone)
        }
        return nil
    }

    private static func describe(_ error: Error) -> Self {
        if let api = error as? APIError {
            let fix: FixAction = switch api {
            case .address, .addressLeadingZeros, .token, .http(401, _): .connect
            case .input, .http(422, _): .reviseInput
            case .http(409, _): .review
            default: .retry
            }
            return .init(title: api.title, detail: api.detail, fixAction: fix)
        }
        if let busy = pcBusy(error) { return busy }
        if let v2 = error as? V2Failure {
            let detail: String? = if case .http(let status, _, _) = v2 { "HTTP \(status)" } else { nil }
            let (title, fix): (String, FixAction) = switch v2 {
            case .http(status: 401, code: _, message: _): ("PC’en afviste tokenet. Tjek det under Indstillinger.", .connect)
            case .http(status: 404, code: _, message: _): ("PC’en kunne ikke finde modellen eller funktionen.", .reviseInput)
            case .http(status: 409, code: _, message: _): ("Beskeden er allerede sendt.", .review)
            case .invalidInput, .http(status: 422, code: _, message: _): ("Skriv en besked på mellem 1 og 2.000 tegn.", .reviseInput)
            default: ("Svaret blev afbrudt. Tjek forbindelsen til PC’en.", .retry)
            }
            return .init(title: title, detail: detail, fixAction: fix)
        }
        if let grok = error as? GrokFailure { return .init(title: grok.message) }
        return .init(title: (error as? ChatFailure ?? .interrupted).message)
    }
}
