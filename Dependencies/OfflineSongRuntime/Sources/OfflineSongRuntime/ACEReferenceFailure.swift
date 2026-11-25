import Foundation

/// A reference or remix is never silently downgraded to an unrelated song.
enum ACEReferenceFailure: LocalizedError {
    case encoderMissing, tokenizerMissing, timbreInvalid, remixInvalid, invalidOutput

    var errorDescription: String? {
        switch self {
        case .encoderMissing: "Hent først lydreference-delen til sangmodellen."
        case .tokenizerMissing: "Hent først remix-delen til sangmodellen."
        case .timbreInvalid: "Stemmereferencen kunne ikke klargøres som 30 sekunders lyd."
        case .remixInvalid: "Remixets lydkilde skal svare til den valgte længde."
        case .invalidOutput: "Lydreferencen kunne ikke behandles. Prøv et andet lydklip."
        }
    }
}
