// Version-one backups use a standard, single-entry ZIP with a stored JSON payload.
import Foundation

enum BackupArchive {
    enum Failure: LocalizedError {
        case tooLarge
        case invalidArchive
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .tooLarge: "Sikkerhedskopien er større end 20 MB."
            case .invalidArchive: "Filen er ikke en gyldig FadedAI-sikkerhedskopi."
            case .checksumMismatch: "Sikkerhedskopien er beskadiget."
            }
        }
    }

    private static let entryName = Data("FadedAI-backup.json".utf8)
    private static let localChecksumOffset = 14
    private static let localHeaderLength = 30 + entryName.count
    private static let centralHeaderLength = 46 + entryName.count
    private static let endRecordLength = 22
    private static let overhead = localHeaderLength + centralHeaderLength + endRecordLength
    private static let maximumPayloadBytes = 20_000_000
    static let maximumArchiveBytes = maximumPayloadBytes + overhead

    static func encode(_ data: Data) throws -> Data {
        guard data.count <= maximumPayloadBytes else { throw Failure.tooLarge }
        let size = UInt32(data.count)
        let checksum = crc32(data)
        var archive = Data(capacity: data.count + overhead)
        archive.append(localHeader(checksum: checksum, size: size))
        archive.append(data)
        archive.append(centralHeader(checksum: checksum, size: size))
        archive.append(endRecord(centralOffset: UInt32(localHeaderLength) + size))
        return archive
    }

    static func decode(_ archive: Data) throws -> Data {
        guard archive.count <= maximumArchiveBytes else { throw Failure.tooLarge }
        guard archive.count >= overhead else { throw Failure.invalidArchive }

        // Derive every range from the bounded input length, never from archive offsets.
        let payloadLength = archive.count - overhead
        let size = UInt32(payloadLength)
        let centralOffset = localHeaderLength + payloadLength
        let checksum = archive.dropFirst(localChecksumOffset).prefix(4).enumerated().reduce(UInt32(0)) { result, field in
            result | (UInt32(field.element) << (field.offset * 8))
        }
        // Comparing all three records enforces one exact, relative filename, stored mode,
        // matching sizes/CRC, and no extra entries, metadata or trailing bytes.
        guard archive.prefix(localHeaderLength).elementsEqual(localHeader(checksum: checksum, size: size)),
              archive.dropFirst(centralOffset).prefix(centralHeaderLength)
                .elementsEqual(centralHeader(checksum: checksum, size: size)),
              archive.suffix(endRecordLength).elementsEqual(endRecord(centralOffset: UInt32(centralOffset)))
        else { throw Failure.invalidArchive }

        let payload = archive.dropFirst(localHeaderLength).prefix(payloadLength)
        guard crc32(payload) == checksum else { throw Failure.checksumMismatch }
        return Data(payload)
    }

    private static func localHeader(checksum: UInt32, size: UInt32) -> Data {
        var header = Data(capacity: localHeaderLength)
        append(UInt32(0x0403_4B50), to: &header) // Local file header signature.
        appendEntryFields(checksum: checksum, size: size, to: &header)
        header.append(entryName)
        return header
    }

    private static func centralHeader(checksum: UInt32, size: UInt32) -> Data {
        var header = Data(capacity: centralHeaderLength)
        append(UInt32(0x0201_4B50), to: &header) // Central directory signature.
        append(UInt16(20), to: &header) // Version made by, MS-DOS host.
        appendEntryFields(checksum: checksum, size: size, to: &header)
        append(UInt16(0), to: &header) // File comment length.
        append(UInt16(0), to: &header) // Disk containing the local header.
        append(UInt16(0), to: &header) // Internal file attributes.
        append(UInt32(0), to: &header) // External file attributes.
        append(UInt32(0), to: &header) // Local header offset.
        header.append(entryName)
        return header
    }

    private static func appendEntryFields(checksum: UInt32, size: UInt32, to header: inout Data) {
        append(UInt16(20), to: &header) // Version needed to extract.
        append(UInt16(0), to: &header) // Flags (ASCII filename, no descriptor or encryption).
        append(UInt16(0), to: &header) // Stored compression method.
        append(UInt16(0), to: &header) // DOS time: midnight.
        append(UInt16(0x0021), to: &header) // DOS date: January 1, 1980.
        append(checksum, to: &header)
        append(size, to: &header) // Compressed size.
        append(size, to: &header) // Uncompressed size.
        append(UInt16(entryName.count), to: &header)
        append(UInt16(0), to: &header) // Extra field length.
    }

    private static func endRecord(centralOffset: UInt32) -> Data {
        var record = Data(capacity: endRecordLength)
        append(UInt32(0x0605_4B50), to: &record) // End of central directory signature.
        append(UInt16(0), to: &record) // Disk number.
        append(UInt16(0), to: &record) // Disk containing the central directory.
        append(UInt16(1), to: &record) // Entries on this disk.
        append(UInt16(1), to: &record) // Total entries.
        append(UInt32(centralHeaderLength), to: &record)
        append(centralOffset, to: &record)
        append(UInt16(0), to: &record) // Archive comment length.
        return record
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var checksum = UInt32(value)
        for _ in 0..<8 {
            let polynomial: UInt32 = (checksum & 1) == 0 ? 0 : 0xEDB8_8320
            checksum = (checksum >> 1) ^ polynomial
        }
        return checksum
    }

    private static func crc32(_ data: Data) -> UInt32 {
        let checksum = data.reduce(UInt32.max) { value, byte in
            let index = Int((value ^ UInt32(byte)) & 0xFF)
            return (value >> 8) ^ crcTable[index]
        }
        return ~checksum
    }
}
