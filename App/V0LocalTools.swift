// De lokale beregninger og værktøjsdata fra v0's lib/faded-tools.ts.

import CoreFoundation
import CryptoKit
import Foundation

struct V0LocalTool: Identifiable {
    struct Field: Identifiable {
        enum Kind { case text, multiline, number }

        let id: String
        let label: String
        let example: String
        let kind: Kind
        var optional = false
    }

    enum Category: String, CaseIterable, Identifiable {
        case text = "Tekst", development = "Udvikling", calculation = "Tal & tid"
        var id: Self { self }

        var icon: String {
            switch self {
            case .text: "textformat"
            case .development: "curlybraces"
            case .calculation: "number"
            }
        }
    }

    let id: String
    let title: String
    let description: String
    let category: Category
    let fields: [Field]

    var example: [String: String] { Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.example) }) }

    static let all: [V0LocalTool] = [
        .init(id: "stats", title: "Tekstoverblik", description: "Tæl ord, tegn, linjer og anslå læsetid ved 200 ord/min.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "upper", title: "STORE BOGSTAVER", description: "Lav hele teksten om til versaler.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "lower", title: "små bogstaver", description: "Lav hele teksten om til små bogstaver.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "title", title: "Titelbogstaver", description: "Start hvert ord med stort bogstav.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "sentence", title: "Sætningsstart", description: "Stort begyndelsesbogstav efter punktum, spørgsmålstegn og udråbstegn.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "slug", title: "URL-slug", description: "Gør en titel til en URL-venlig tekst, også med æ, ø og å.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "Min blå idé", kind: .multiline)]),
        .init(id: "trim", title: "Trim linjer", description: "Fjern mellemrum i starten og slutningen af hver linje.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "spaces", title: "Ryd mellemrum", description: "Saml gentagne mellemrum og tabulatorer uden at miste linjeskift.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "blank", title: "Fjern tomme linjer", description: "Behold kun linjer med indhold.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "unique", title: "Fjern dubletter", description: "Behold første forekomst af hver linje; store og små bogstaver skelnes.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "sort", title: "Sortér alfabetisk", description: "Sortér linjer efter dansk alfabet og naturlige tal.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "reverse", title: "Vend rækkefølgen", description: "Vend linjerne, ikke bogstaverne.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "number", title: "Nummereret liste", description: "Giv hver linje sit eget nummer.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "bullets", title: "Punktliste", description: "Lav linjer om til en Markdown-punktliste.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "checklist", title: "Tjekliste", description: "Lav en Markdown-tjekliste med tomme afkrydsningsfelter.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "quote", title: "Citatblok", description: "Pak teksten ind som et Markdown-citat.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "replace", title: "Find og erstat", description: "Erstat alle præcise forekomster uden regulære udtryk.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "Hej verden, verden er stor.", kind: .multiline), .init(id: "find", label: "Find", example: "verden", kind: .text), .init(id: "replacement", label: "Erstat med (tomt = fjern)", example: "FadedAI", kind: .text, optional: true)]),
        .init(id: "links", title: "Udtræk links", description: "Find unikke http- og https-links i teksten.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "Læs https://vercel.com og https://nextjs.org.", kind: .multiline)]),
        .init(id: "emails", title: "Udtræk e-mails", description: "Find unikke e-mailadresser. Dette verificerer ikke deres eksistens.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "Skriv til hello@example.com eller team@example.com", kind: .multiline)]),
        .init(id: "paragraphs", title: "Luft mellem linjer", description: "Gør hver ikke-tom linje til et separat afsnit.",
              category: .text, fields: [.init(id: "input", label: "Din tekst", example: "En rolig start\nEn ny idé\nEn rolig start", kind: .multiline)]),
        .init(id: "jsonpretty", title: "Formatér JSON", description: "Validér JSON og indryk med to mellemrum.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "{\"navn\":\"FadedAI\",\"aktiv\":true}", kind: .multiline)]),
        .init(id: "jsonmin", title: "Komprimér JSON", description: "Fjern unødig whitespace i gyldig JSON.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "{\n  \"navn\": \"FadedAI\"\n}", kind: .multiline)]),
        .init(id: "jsonkeys", title: "JSON-nøgler", description: "List et JSON-objekts nøgler på øverste niveau.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "{\"navn\":\"FadedAI\",\"aktiv\":true}", kind: .multiline)]),
        .init(id: "base64encode", title: "Tekst til Base64", description: "Kod UTF-8-tekst. Base64 er ikke kryptering.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "Blå himmel", kind: .multiline)]),
        .init(id: "base64decode", title: "Base64 til tekst", description: "Afkod Base64 som UTF-8; binære filer afvises.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "QmzDpSB1bml2ZXJz", kind: .multiline)]),
        .init(id: "urlencode", title: "URL-kodning", description: "Kod en tekst som én URL-komponent.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "blå himmel & hav", kind: .multiline)]),
        .init(id: "urldecode", title: "URL-afkodning", description: "Afkod procentkodede tegn i en URL-komponent.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "bl%C3%A5%20himmel", kind: .multiline)]),
        .init(id: "htmlencode", title: "HTML-escape", description: "Erstat &, <, > og citationstegn med HTML-entiteter.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "<button title=\"Hej\">Åbn & læs</button>", kind: .multiline)]),
        .init(id: "htmldecode", title: "HTML-unescape", description: "Afkod de fem standardentiteter; resultatet vises kun som tekst.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "&lt;p&gt;Hej &amp; velkommen&lt;/p&gt;", kind: .multiline)]),
        .init(id: "queryjson", title: "Query til JSON", description: "Lav URL-parametre om til JSON; gentagne nøgler bliver til lister.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "?navn=FadedAI&tag=tekst&tag=kode", kind: .multiline)]),
        .init(id: "jsonquery", title: "JSON til query", description: "Kod flade JSON-værdier og lister til URL-parametre.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "{\"navn\":\"FadedAI\",\"tag\":[\"tekst\",\"kode\"]}", kind: .multiline)]),
        .init(id: "unixiso", title: "Unix til dato", description: "Konvertér hele Unix-sekunder til en ISO-dato i UTC.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "1704067200", kind: .multiline)]),
        .init(id: "isounix", title: "Dato til Unix", description: "Brug ISO 8601 med tidszone, fx 2026-11-11T12:00:00Z.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "2024-01-01T00:00:00Z", kind: .multiline)]),
        .init(id: "sha256", title: "SHA-256", description: "Beregn en checksum lokalt. Ikke egnet til lagring af adgangskoder.",
              category: .development, fields: [.init(id: "input", label: "Din tekst", example: "FadedAI", kind: .multiline)]),
        .init(id: "uuid", title: "Nyt UUID", description: "Generér en tilfældig UUID v4 på telefonen.",
              category: .development, fields: []),
        .init(id: "sum", title: "Sum", description: "Læg alle tal i listen sammen.",
              category: .calculation, fields: [.init(id: "input", label: "Ét tal pr. linje · komma er decimaltegn", example: "12\n25\n8\n15", kind: .multiline)]),
        .init(id: "average", title: "Gennemsnit", description: "Beregn listens aritmetiske gennemsnit.",
              category: .calculation, fields: [.init(id: "input", label: "Ét tal pr. linje · komma er decimaltegn", example: "12\n25\n8\n15", kind: .multiline)]),
        .init(id: "median", title: "Median", description: "Find midten i en numerisk sorteret liste.",
              category: .calculation, fields: [.init(id: "input", label: "Ét tal pr. linje · komma er decimaltegn", example: "12\n25\n8\n15", kind: .multiline)]),
        .init(id: "range", title: "Min, maks og spænd", description: "Find laveste, højeste og forskellen mellem dem.",
              category: .calculation, fields: [.init(id: "input", label: "Ét tal pr. linje · komma er decimaltegn", example: "12\n25\n8\n15", kind: .multiline)]),
        .init(id: "percent", title: "Procent af et tal", description: "Find fx 20 % af 500.",
              category: .calculation, fields: [.init(id: "n0", label: "Procent", example: "20", kind: .number), .init(id: "n1", label: "Tal", example: "500", kind: .number)]),
        .init(id: "partpercent", title: "Del af en helhed", description: "Hvor mange procent udgør delen?",
              category: .calculation, fields: [.init(id: "n0", label: "Del", example: "25", kind: .number), .init(id: "n1", label: "Helhed", example: "200", kind: .number)]),
        .init(id: "change", title: "Procentændring", description: "Sammenlign en ny værdi med en positiv startværdi.",
              category: .calculation, fields: [.init(id: "n0", label: "Før", example: "80", kind: .number), .init(id: "n1", label: "Efter", example: "100", kind: .number)]),
        .init(id: "discount", title: "Rabatberegner", description: "Find ny pris og besparelse ved 0–100 % rabat.",
              category: .calculation, fields: [.init(id: "n0", label: "Pris", example: "800", kind: .number), .init(id: "n1", label: "Rabat i procent", example: "25", kind: .number)]),
        .init(id: "vat", title: "Læg moms til", description: "Beregn pris inkl. moms med din egen sats.",
              category: .calculation, fields: [.init(id: "n0", label: "Pris ekskl. moms", example: "100", kind: .number), .init(id: "n1", label: "Momssats i procent", example: "25", kind: .number)]),
        .init(id: "unvat", title: "Træk moms fra", description: "Beregn pris ekskl. moms ud fra en bruttopris.",
              category: .calculation, fields: [.init(id: "n0", label: "Pris inkl. moms", example: "125", kind: .number), .init(id: "n1", label: "Momssats i procent", example: "25", kind: .number)]),
        .init(id: "split", title: "Del regningen", description: "Fordel et beløb ligeligt; afstem evt. afrunding til øre selv.",
              category: .calculation, fields: [.init(id: "n0", label: "Samlet beløb", example: "600", kind: .number), .init(id: "n1", label: "Antal personer", example: "4", kind: .number)]),
        .init(id: "celsius", title: "Celsius til Fahrenheit", description: "Omregn temperatur fra °C til °F.",
              category: .calculation, fields: [.init(id: "n0", label: "Grader Celsius", example: "20", kind: .number)]),
        .init(id: "fahrenheit", title: "Fahrenheit til Celsius", description: "Omregn temperatur fra °F til °C.",
              category: .calculation, fields: [.init(id: "n0", label: "Grader Fahrenheit", example: "68", kind: .number)]),
        .init(id: "kmMiles", title: "Kilometer til miles", description: "Omregn kilometer til internationale miles.",
              category: .calculation, fields: [.init(id: "n0", label: "Kilometer", example: "10", kind: .number)]),
        .init(id: "days", title: "Dage mellem datoer", description: "Beregn datoforskellen uden tidszone- eller sommertidsfejl; startdagen tælles ikke med.",
              category: .calculation, fields: [.init(id: "start", label: "Startdato · ÅÅÅÅ-MM-DD", example: "2026-11-11", kind: .text), .init(id: "end", label: "Slutdato · ÅÅÅÅ-MM-DD", example: "2026-12-01", kind: .text)]),
    ]
}

extension V0LocalTool {
    private static let danish = Locale(identifier: "da_DK")
    private static let entities = [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&#39;")]

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ detail: String) { errorDescription = detail }
    }

    func run(_ values: [String: String]) throws -> String {
        for field in fields {
            let value = values[field.id, default: ""]
            if !field.optional && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Failure("Udfyld feltet \(field.label).")
            }
            if value.utf16.count > 20_000 { throw Failure("Brug højst 20.000 tegn pr. felt.") }
        }
        switch category {
        case .text: return try textResult(values)
        case .development: return try developmentResult(values["input", default: ""])
        case .calculation: return try calculationResult(values)
        }
    }

    private func textResult(_ values: [String: String]) throws -> String {
        let input = values["input", default: ""]
        let lines = Self.lines(input)
        let nonempty = lines.filter { !Self.trim($0).isEmpty }
        switch id {
        case "stats":
            let words = input.split(whereSeparator: \.isWhitespace).count
            let readingMinutes = max(1, (words + 199) / 200)
            return "Ord: \(words)\nTegn: \(input.unicodeScalars.count)\nLinjer: \(lines.count)\nLæsetid: ca. \(readingMinutes) min."
        case "upper": return input.uppercased(with: Self.danish)
        case "lower": return input.lowercased(with: Self.danish)
        case "title": return try Self.uppercaseLetters(input, matching: #"(^|[^\p{L}\p{N}])(\p{L})"#)
        case "sentence": return try Self.uppercaseLetters(input, matching: #"(^\s*|[.!?]\s+)(\p{L})"#)
        case "slug":
            let danish = input.lowercased().replacingOccurrences(of: "æ", with: "ae")
                .replacingOccurrences(of: "ø", with: "oe").replacingOccurrences(of: "å", with: "aa")
            return danish.folding(options: .diacriticInsensitive, locale: Self.danish)
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        case "trim": return lines.map(Self.trim).joined(separator: "\n")
        case "spaces":
            return Self.trim(input.replacingOccurrences(of: #"[^\S\r\n]+"#, with: " ", options: .regularExpression))
        case "blank": return nonempty.joined(separator: "\n")
        case "unique": return Self.unique(nonempty.map(Self.trim)).joined(separator: "\n")
        case "sort":
            return nonempty.sorted {
                $0.compare($1, options: .numeric, range: nil, locale: Self.danish) == .orderedAscending
            }.joined(separator: "\n")
        case "reverse": return lines.reversed().joined(separator: "\n")
        case "number": return nonempty.enumerated().map { "\($0.offset + 1). \(Self.trim($0.element))" }.joined(separator: "\n")
        case "bullets": return nonempty.map { "- \(Self.trim($0))" }.joined(separator: "\n")
        case "checklist": return nonempty.map { "- [ ] \(Self.trim($0))" }.joined(separator: "\n")
        case "quote": return lines.map { "> \($0)" }.joined(separator: "\n")
        case "replace":
            let find = values["find", default: ""]
            guard !find.isEmpty else { throw Failure("Indtast den tekst, du vil erstatte.") }
            return input.replacingOccurrences(of: find, with: values["replacement", default: ""])
        case "links":
            let links = try Self.matches(#"https?://[^\s<>"']+"#, in: input).map {
                $0.replacingOccurrences(of: #"[.,;!?)]+$"#, with: "", options: .regularExpression)
            }
            return links.isEmpty ? "Ingen links fundet." : Self.unique(links).joined(separator: "\n")
        case "emails":
            let emails = try Self.matches(#"(?i)[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#, in: input)
            return emails.isEmpty ? "Ingen e-mailadresser fundet." : Self.unique(emails).joined(separator: "\n")
        case "paragraphs": return nonempty.joined(separator: "\n\n")
        default: throw Failure("Værktøjet er utilgængeligt.")
        }
    }

    private func developmentResult(_ input: String) throws -> String {
        switch id {
        case "jsonpretty", "jsonmin": return try Self.jsonString(Self.json(input), pretty: id == "jsonpretty")
        case "jsonkeys":
            let keys = try Self.object(input).keys.sorted()
            return keys.isEmpty ? "Objektet har ingen nøgler." : keys.joined(separator: "\n")
        case "base64encode": return Data(input.utf8).base64EncodedString()
        case "base64decode":
            let encoded = Self.trim(input)
            let remainder = encoded.utf8.count % 4
            let padded = remainder == 0 ? encoded : encoded + String(repeating: "=", count: 4 - remainder)
            guard let data = Data(base64Encoded: padded), let decoded = String(data: data, encoding: .utf8) else {
                throw Failure("Brug gyldig Base64 med UTF-8-tekst.")
            }
            return decoded
        case "urlencode": return try Self.encode(input, form: false)
        case "urldecode":
            guard let decoded = input.removingPercentEncoding else { throw Failure("URL-kodningen er ugyldig.") }
            return decoded
        case "htmlencode":
            return Self.entities.reduce(input) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        case "htmldecode":
            return Self.entities.reversed().reduce(input) { $0.replacingOccurrences(of: $1.1, with: $1.0) }
        case "queryjson": return try Self.queryAsJSON(input)
        case "jsonquery": return try Self.jsonAsQuery(input)
        case "unixiso":
            let seconds = try Self.number(input)
            guard seconds.rounded(.towardZero) == seconds, abs(seconds) <= 8_640_000_000_000 else {
                throw Failure("Brug hele Unix-sekunder inden for datoformatets interval.")
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        case "isounix":
            guard input.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$"#,
                              options: .regularExpression) != nil else {
                throw Failure("Brug en ISO-dato med klokkeslæt og Z eller en tidszone.")
            }
            _ = try Self.dateOnly(String(input.prefix(10)))
            let formatter = ISO8601DateFormatter()
            if input.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
            guard let date = formatter.date(from: input) else { throw Failure("Ugyldigt tidspunkt.") }
            return String(Int(date.timeIntervalSince1970.rounded(.down)))
        case "sha256": return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        case "uuid": return UUID().uuidString.lowercased()
        default: throw Failure("Værktøjet er utilgængeligt.")
        }
    }

    private func calculationResult(_ values: [String: String]) throws -> String {
        func number(_ index: Int) throws -> Double { try Self.number(values["n\(index)", default: ""]) }
        func list() throws -> [Double] {
            try Self.lines(values["input", default: ""]).filter { !Self.trim($0).isEmpty }.map(Self.number)
        }
        func format(_ value: Double) throws -> String {
            guard value.isFinite else { throw Failure("Resultatet er for stort. Prøv mindre tal.") }
            return value.formatted(.number.precision(.fractionLength(0...8)).locale(Self.danish))
        }
        func nonnegative(_ index: Int) throws -> Double {
            let value = try number(index)
            guard value >= 0 else { throw Failure("Værdien må ikke være negativ.") }
            return value
        }
        switch id {
        case "sum": return try format(list().reduce(0, +))
        case "average":
            let numbers = try list()
            return try format(numbers.reduce(0, +) / Double(numbers.count))
        case "median":
            let numbers = try list().sorted()
            guard !numbers.isEmpty else { throw Failure("Indtast mindst ét tal.") }
            let midpoint = numbers.count / 2
            return try format(numbers.count.isMultiple(of: 2) ? (numbers[midpoint - 1] + numbers[midpoint]) / 2 : numbers[midpoint])
        case "range":
            let numbers = try list()
            guard let minimum = numbers.min(), let maximum = numbers.max() else { throw Failure("Indtast mindst ét tal.") }
            return try "Min: \(format(minimum))\nMaks: \(format(maximum))\nSpænd: \(format(maximum - minimum))"
        case "percent": return try format(number(0) * number(1) / 100)
        case "partpercent":
            let total = try number(1)
            guard total != 0 else { throw Failure("Du kan ikke dividere med nul.") }
            return try "\(format(number(0) / total * 100)) %"
        case "change":
            let before = try number(0)
            guard before > 0 else { throw Failure("Værdien skal være større end nul.") }
            return try "\(format((number(1) - before) / before * 100)) %"
        case "discount":
            let price = try nonnegative(0)
            let percent = try nonnegative(1)
            guard percent <= 100 else { throw Failure("Rabat skal være mellem 0 og 100 %.") }
            return try "Ny pris: \(format(price * (1 - percent / 100)))\nBesparelse: \(format(price * percent / 100))"
        case "vat": return try "\(format(nonnegative(0) * (1 + nonnegative(1) / 100))) inkl. moms"
        case "unvat": return try "\(format(nonnegative(0) / (1 + nonnegative(1) / 100))) ekskl. moms"
        case "split":
            let count = try number(1)
            guard count > 0, count.rounded(.towardZero) == count else { throw Failure("Antal personer skal være et positivt helt tal.") }
            return try "\(format(nonnegative(0) / count)) pr. person"
        case "celsius":
            let celsius = try number(0)
            guard celsius >= -273.15 else { throw Failure("Temperaturen er under det absolutte nulpunkt.") }
            return try "\(format(celsius * 9 / 5 + 32)) °F"
        case "fahrenheit":
            let fahrenheit = try number(0)
            guard fahrenheit >= -459.67 else { throw Failure("Temperaturen er under det absolutte nulpunkt.") }
            return try "\(format((fahrenheit - 32) * 5 / 9)) °C"
        case "kmMiles": return try "\(format(nonnegative(0) / 1.609344)) miles"
        case "days":
            let start = try Self.dateOnly(values["start", default: ""])
            let end = try Self.dateOnly(values["end", default: ""])
            return try "\(format(end.timeIntervalSince(start) / 86_400)) dage"
        default: throw Failure("Værktøjet er utilgængeligt.")
        }
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }

    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }

    private static func uppercaseLetters(_ text: String, matching pattern: String) throws -> String {
        let lower = text.lowercased(with: danish)
        let result = NSMutableString(string: lower)
        let regex = try NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)).reversed() {
            let letter = match.range(at: 2)
            result.replaceCharacters(in: letter, with: result.substring(with: letter).uppercased(with: danish))
        }
        return result as String
    }

    private static func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func number(_ value: String) throws -> Double {
        let normalized = trim(value).replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let result = Double(normalized) else { throw Failure("Brug et tal uden tusindtalsseparator, fx 1250,50.") }
        guard result.isFinite, abs(result) <= 9_007_199_254_740_991 else { throw Failure("Tallet er for stort.") }
        return result
    }

    private static func dateOnly(_ value: String) throws -> Date {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw Failure("Brug datoformatet ÅÅÅÅ-MM-DD.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw Failure("Datoen findes ikke.")
        }
        return date
    }

    private static func json(_ input: String) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: Data(input.utf8), options: .fragmentsAllowed) }
        catch { throw Failure("Teksten er ikke gyldig JSON. Kontrollér kommaer og citationstegn.") }
    }

    private static func jsonString(_ value: Any, pretty: Bool = true) throws -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.fragmentsAllowed, .sortedKeys, .prettyPrinted] : [.fragmentsAllowed, .sortedKeys]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: options), as: UTF8.self)
    }

    private static func object(_ input: String) throws -> [String: Any] {
        guard let object = try json(input) as? [String: Any] else { throw Failure("Brug et JSON-objekt.") }
        return object
    }

    private static func encode(_ input: String, form: Bool) throws -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = form ? "*-._" : "-_.!~*'()"
        guard let encoded = input.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: letters + suffix)) else {
            throw Failure("URL-kodningen er ugyldig.")
        }
        return form ? encoded.replacingOccurrences(of: "%20", with: "+") : encoded
    }

    private static func queryAsJSON(_ input: String) throws -> String {
        let query = trim(input)
        let parameters = query.hasPrefix("?") ? query.dropFirst() : query[...]
        var grouped: [String: [String]] = [:]
        func decode(_ value: Substring) -> String {
            let raw = String(value).replacingOccurrences(of: "+", with: " ")
            return raw.removingPercentEncoding ?? raw
        }
        for parameter in parameters.split(separator: "&") {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first else { continue }
            let value = pair.count == 2 ? decode(pair[1]) : ""
            grouped[decode(key), default: []].append(value)
        }
        return try jsonString(grouped.mapValues { values -> Any in
            if values.count == 1, let value = values.first { return value }
            return values
        })
    }

    private static func jsonAsQuery(_ input: String) throws -> String {
        let values = try object(input)
        var parameters: [String] = []
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            let items = value as? [Any] ?? [value]
            for item in items {
                let text: String
                if item is NSNull { text = "" }
                else if let string = item as? String { text = string }
                else if let number = item as? NSNumber {
                    if CFGetTypeID(number) == CFBooleanGetTypeID() { text = number.boolValue ? "true" : "false" }
                    else { text = number.stringValue }
                } else {
                    throw Failure("Indlejrede objekter understøttes ikke.")
                }
                parameters.append(try "\(encode(key, form: true))=\(encode(text, form: true))")
            }
        }
        return parameters.joined(separator: "&")
    }
}
