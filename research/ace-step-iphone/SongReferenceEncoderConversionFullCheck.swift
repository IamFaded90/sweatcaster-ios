// Standalone PC-only entrypoint for measuring the full streaming converter.
import Foundation

@main
struct SongReferenceEncoderConversionFullCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected input and new output paths") }
        try SongReferenceEncoderConversion.convert(input: URL(fileURLWithPath: CommandLine.arguments[1]),
                                                   staging: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("PASS: full encoder conversion completed")
    }
}
