import Foundation

/// Source-aware native loaders; no second model stack or server required.
enum StructuredDocumentLoader {
    struct Segment: Equatable, Sendable { let location: String; let text: String }
    enum Failure: LocalizedError {
        case format, size
        var errorDescription: String? { self == .format ? "Filen har et ugyldigt JSON- eller CSV-format. Kontrollér især citationstegn og kolonner." : "Del filen op i mindre dele med højst 24.000 tegn." }
    }
    static func load(_ data: Data, type: String) throws -> [Segment] {
        guard data.count <= 100_000, var text = String(data: data, encoding: .utf8), !text.contains("\0"), text.unicodeScalars.count <= 24_000 else { throw Failure.size }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let result: [Segment]
        if type == "csv" { result = try csv(text) }
        else if type == "json" { result = try json(Data(text.utf8)) }
        else { throw Failure.format }
        guard !result.isEmpty, result.reduce(0, { $0 + $1.text.unicodeScalars.count }) <= 24_000 else { throw Failure.size }
        return result
    }
    private static func csv(_ text: String) throws -> [Segment] {
        let chars = Array(text); var quoted = false, counts: [Character: Int] = [",":0,";":0,"\t":0]
        for char in chars { if char == "\"" { quoted.toggle() }; if !quoted { if char.isNewline { break }; if counts[char] != nil { counts[char, default: 0] += 1 } } }
        let separator: Character = [",", ";", "\t"].max { counts[$0, default: 0] < counts[$1, default: 0] } ?? ","
        var rows: [(number: Int, fields: [String])] = [], fields: [String] = [], field = "", closed = false, index = 0, record = 0
        quoted = false
        func pushField() throws { guard field.count <= 12_000, fields.count < 64 else { throw Failure.size }; fields.append(field); field = ""; closed = false }
        func pushRow() throws {
            try pushField(); record += 1
            if fields.contains(where: { !$0.isEmpty }) { rows.append((record, fields)) }
            fields = []; guard record <= 500 else { throw Failure.size }
        }
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(char) }
            } else if char == separator { try pushField() }
            else if char.isNewline { try pushRow() }
            else if char == "\"" { guard field.isEmpty, !closed else { throw Failure.format }; quoted = true }
            else if closed { guard char == " " || char == "\t" else { throw Failure.format } }
            else { field.append(char) }
            index += 1
        }
        guard !quoted else { throw Failure.format }
        if !field.isEmpty || !fields.isEmpty || closed { try pushRow() }
        guard let first = rows.first else { throw Failure.format }
        let headers = first.fields
        var result = [Segment(location: "Række \(first.number) · kolonner", text: headers.enumerated().map { "Kolonne \($0.offset + 1): \($0.element)" }.joined(separator: "\n"))]
        for row in rows.dropFirst() {
            let values = row.fields.enumerated().map { column, value -> String in
                let header = headers.indices.contains(column) ? headers[column].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                return "\(header.isEmpty ? "Kolonne \(column + 1)" : header): \(value.isEmpty ? "(tom)" : value) [kolonne \(column + 1)]"
            }
            result.append(.init(location: "Række \(row.number)", text: values.joined(separator: "\n")))
        }
        return result
    }
    private static func json(_ data: Data) throws -> [Segment] {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch { throw Failure.format }
        var result: [Segment] = []
        func literal(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        func child(_ path: String, _ key: String) throws -> String {
            guard key.count <= 200 else { throw Failure.size }
            return key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil ? path + "." + key : path + "[" + (try literal(key)) + "]"
        }
        func walk(_ value: Any, path: String, depth: Int) throws {
            guard depth <= 16, path.count <= 800, result.count < 500 else { throw Failure.size }
            if let object = value as? [String: Any] {
                let leaves = object.keys.sorted().filter { !(object[$0] is [String: Any]) && !(object[$0] is [Any]) }
                if !leaves.isEmpty {
                    let lines = try leaves.map { key in "\(key): \(try literal(object[key]!))" }
                    result.append(.init(location: "JSON " + path, text: lines.joined(separator: "\n")))
                }
                for key in object.keys.sorted() where !leaves.contains(key) { try walk(object[key]!, path: child(path, key), depth: depth + 1) }
                if object.isEmpty { result.append(.init(location: "JSON " + path, text: "{}")) }
            } else if let array = value as? [Any] {
                if array.isEmpty { result.append(.init(location: "JSON " + path, text: "[]")) }
                for (index, item) in array.enumerated() { try walk(item, path: path + "[\(index)]", depth: depth + 1) }
            } else { result.append(.init(location: "JSON " + path, text: try literal(value))) }
        }
        try walk(value, path: "$", depth: 0); return result
    }
}
