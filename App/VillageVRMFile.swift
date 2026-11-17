import Foundation
import ImageIO

enum VillageVRMFile {
    static let maximumBytes = 24_000_000
    private static let maximumManifestBytes = 2_000_000
    private static let maximumNodes = 1024
    private static let maximumVertices = 400_000
    private static let maximumTexturePixels = 16_777_216
    private static let supportedExtensions: Set<String> = [
        "VRM", "VRMC_vrm", "VRMC_materials_mtoon", "VRMC_springBone", "VRMC_node_constraint",
        "KHR_materials_unlit", "KHR_texture_transform", "KHR_mesh_quantization",
        "KHR_materials_emissive_strength", "KHR_materials_specular", "KHR_materials_ior",
        "KHR_materials_clearcoat", "KHR_materials_sheen", "KHR_materials_iridescence",
        "KHR_materials_anisotropy", "KHR_materials_dispersion", "KHR_materials_transmission",
        "KHR_materials_volume", "KHR_materials_variants", "EXT_texture_webp"
    ]

    enum Failure: LocalizedError {
        case invalid, unsupported, oversized

        var errorDescription: String? {
            switch self {
            case .invalid: "Vælg en gyldig VRM 1.0- eller VRM 0.x-fil fra Filer."
            case .unsupported: "VRM-filen bruger billeder eller modeldata, som denne afspiller ikke kan åbne."
            case .oversized: "Vælg en lettere VRM-model på højst 24 MB."
            }
        }
    }

    static func validate(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw Failure.oversized }
        guard data.count >= 28, number(data, at: 0) == 0x46546c67, number(data, at: 4) == 2,
              number(data, at: 8) == data.count, number(data, at: 16) == 0x4e4f534a else {
            throw Failure.invalid
        }
        let manifestSize = number(data, at: 12)
        guard manifestSize > 0, manifestSize <= maximumManifestBytes, manifestSize % 4 == 0,
              manifestSize <= data.count - 28 else { throw Failure.invalid }
        let binary = 20 + manifestSize
        let binarySize = number(data, at: binary)
        guard number(data, at: binary + 4) == 0x004e4942,
              binarySize == data.count - binary - 8, binarySize % 4 == 0,
              let manifest = try? JSONSerialization.jsonObject(with: data.subdata(in: 20..<binary)),
              let document = manifest as? [String: Any],
              let asset = document["asset"] as? [String: Any], asset["version"] as? String == "2.0",
              let extensions = document["extensions"] as? [String: Any],
              extensions["VRMC_vrm"] is [String: Any] || extensions["VRM"] is [String: Any],
              let nodes = document["nodes"] as? [[String: Any]], !nodes.isEmpty,
              let meshes = document["meshes"] as? [[String: Any]], !meshes.isEmpty else { throw Failure.invalid }
        let required = document["extensionsRequired"] as? [String] ?? []
        guard supportedExtensions.isSuperset(of: required) else { throw Failure.unsupported }
        guard let buffers = document["buffers"] as? [[String: Any]], buffers.count == 1,
              buffers[0]["uri"] == nil, let length = buffers[0]["byteLength"] as? Int,
              length > 0, length <= binarySize, binarySize - length <= 3 else { throw Failure.unsupported }
        guard nodes.count <= maximumNodes, meshes.count <= 256 else { throw Failure.oversized }
        try validateNodes(nodes)
        let accessors = document["accessors"] as? [[String: Any]] ?? []
        let views = document["bufferViews"] as? [[String: Any]] ?? []
        try validateMeshes(meshes, accessors: accessors)
        try validateImages(document["images"] as? [[String: Any]] ?? [],
                           views: views, bufferStart: binary + 8, bufferLength: length, data: data)
    }

    private static func validateMeshes(_ meshes: [[String: Any]], accessors: [[String: Any]]) throws {
        guard accessors.count <= 8192 else { throw Failure.oversized }
        let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16]
        var elements = 0
        for accessor in accessors {
            guard let count = accessor["count"] as? Int, (1...maximumVertices * 3).contains(count),
                  let type = accessor["type"] as? String, let width = components[type] else {
                throw Failure.oversized
            }
            elements += count * width
            guard elements <= 16_000_000 else { throw Failure.oversized }
        }
        var vertices = 0
        for mesh in meshes {
            guard let primitives = mesh["primitives"] as? [[String: Any]], primitives.count <= 64 else {
                throw Failure.oversized
            }
            for primitive in primitives {
                guard let attributes = primitive["attributes"] as? [String: Int],
                      let position = attributes["POSITION"], accessors.indices.contains(position),
                      let count = accessors[position]["count"] as? Int else { throw Failure.invalid }
                vertices += count
                guard vertices <= maximumVertices else { throw Failure.oversized }
            }
        }
    }

    private static func validateNodes(_ nodes: [[String: Any]]) throws {
        var parents = [Int?](repeating: nil, count: nodes.count)
        for (node, details) in nodes.enumerated() {
            for child in details["children"] as? [Int] ?? [] {
                guard nodes.indices.contains(child), parents[child] == nil else { throw Failure.invalid }
                parents[child] = node
            }
        }
        for start in nodes.indices {
            var next = parents[start]
            var depth = 0
            while let parent = next {
                depth += 1
                guard depth <= 64 else { throw Failure.invalid }
                next = parents[parent]
            }
        }
    }

    private static func validateImages(_ images: [[String: Any]], views: [[String: Any]], bufferStart: Int,
                                       bufferLength: Int, data: Data) throws {
        guard images.count <= 32 else { throw Failure.oversized }
        var pixels = 0
        for image in images {
            guard image["uri"] == nil, let index = image["bufferView"] as? Int, views.indices.contains(index),
                  let mime = image["mimeType"] as? String, ["image/png", "image/jpeg", "image/webp"].contains(mime),
                  let length = views[index]["byteLength"] as? Int, views[index]["buffer"] as? Int == 0 else {
                throw Failure.unsupported
            }
            let offset = views[index]["byteOffset"] as? Int ?? 0
            guard offset >= 0, offset <= bufferLength, length > 0, length <= bufferLength - offset else {
                throw Failure.invalid
            }
            let imageRange = (bufferStart + offset)..<(bufferStart + offset + length)
            let bounds = try textureBounds(bytes: data.subdata(in: imageRange))
            pixels += bounds
            guard pixels <= maximumTexturePixels else { throw Failure.oversized }
        }
    }

    private static func textureBounds(bytes: Data) throws -> Int {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...4096).contains(width), (1...4096).contains(height) else { throw Failure.oversized }
        return width * height
    }

    private static func number(_ data: Data, at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | (Int(data[data.startIndex + offset + $1]) << ($1 * 8)) }
    }
}

struct VillageVRMLibrary {
    let botID: UUID
    private let root = URL.applicationSupportDirectory.appendingPathComponent("FadedAI/VillageVRM", isDirectory: true)

    private var file: URL { root.appendingPathComponent(botID.uuidString).appendingPathExtension("vrm") }

    func read() throws -> Data? {
        let checked = try LocalFileStore.safeWriteURL(file, within: root)
        do {
            let data = try LocalFileStore.readBytes(from: checked, maximumBytes: VillageVRMFile.maximumBytes)
            try VillageVRMFile.validate(data)
            return data
        } catch let error where LocalFileStore.isMissing(error) { return nil }
    }

    func save(_ data: Data) throws {
        try LocalFileStore.writeBytes(data, to: file, within: root)
    }

    func remove() throws {
        try LocalFileStore(root: root).delete(file)
    }

    static func importFile(_ url: URL) throws -> Data {
        guard url.pathExtension.lowercased() == "vrm" else { throw VillageVRMFile.Failure.invalid }
        let authorised = url.startAccessingSecurityScopedResource()
        defer { if authorised { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try LocalFileStore.readBytes(from: url, maximumBytes: VillageVRMFile.maximumBytes)
            try VillageVRMFile.validate(data)
            return data
        } catch LocalFileStore.Failure.tooLarge { throw VillageVRMFile.Failure.oversized }
    }

    static func sampleURL() -> URL? {
        Bundle.main.url(forResource: "orbit", withExtension: "vrm", subdirectory: "Village/vrm")
    }

    static func portraitURL(_ name: String) -> URL? {
        guard name == "harper" || name == "lumi" else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "vrm", subdirectory: "Village/vrm")
    }
}
