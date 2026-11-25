import CoreText
import CryptoKit
import UIKit

enum CreativeProjectExport {
    static func pdf(_ project: CreativeProject, store: CreativeProject.Store) throws -> URL {
        try store.save(project)
        guard let target = store.asset(project.id, name: "project.pdf") else { throw CreativeProject.Failure.invalid }
        let size = CGSize(width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let text = NSAttributedString(string: project.text, attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.black, .paragraphStyle: paragraph])
        let setter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let artwork = project.imageName.flatMap(StudioImageFiles.savedImage).flatMap { UIImage(contentsOfFile: $0.path) }
        var offset = 0; var pages = 0; var truncated = false
        let data = renderer.pdfData { output in
            repeat {
                output.beginPage(); pages += 1
                UIColor.white.setFill(); output.cgContext.fill(CGRect(origin: .zero, size: size))
                UIColor(red: 0.60, green: 0.90, blue: 0.15, alpha: 1).setFill(); output.cgContext.fill(CGRect(x: 48, y: 28, width: 46, height: 4))
                let heading: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: UIColor.black]
                let height = ceil((project.title as NSString).boundingRect(with: CGSize(width: 499, height: 180), options: .usesLineFragmentOrigin, attributes: heading, context: nil).height)
                (project.title as NSString).draw(in: CGRect(x: 48, y: 48, width: 499, height: height), withAttributes: heading)
                var top: CGFloat = 48 + height + 20
                if pages == 1, let artwork {
                    let box = CGRect(x: 48, y: top, width: 499, height: 235)
                    let fit = min(box.width / artwork.size.width, box.height / artwork.size.height)
                    let fitted = CGSize(width: artwork.size.width * fit, height: artwork.size.height * fit)
                    artwork.draw(in: CGRect(x: box.midX - fitted.width / 2, y: top, width: fitted.width, height: fitted.height))
                    top += fitted.height + 20
                }
                let cg = output.cgContext; cg.saveGState(); cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: CGRect(x: 48, y: 48, width: 499, height: size.height - top - 48), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
                CTFrameDraw(frame, cg); let count = CTFrameGetVisibleStringRange(frame).length; cg.restoreGState()
                if count == 0 && offset < text.length { truncated = true; break }
                offset += count
                ("FadedAI · \(pages)" as NSString).draw(at: CGPoint(x: 48, y: 811), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
            } while offset < text.length && pages < 30
        }
        guard !truncated, offset >= text.length else { throw CreativeProject.Failure.invalid }
        try data.write(to: target, options: .atomic); return target
    }
    static func publishRoom(_ project: CreativeProject, bot: VillageBot) throws -> UUID {
        guard let name = project.imageName, let file = StudioImageFiles.savedImage(name) else { throw CreativeProject.Failure.invalid }
        let data = try AgentRoomImages.sketch(Data(contentsOf: file))
        guard let image = UIImage(data: data), let pixels = image.cgImage else { throw CreativeProject.Failure.invalid }
        let digest = AgentRoomCache.hash(data)
        let figure = AgentRoom.Figure(id: bot.id, name: bot.name, character: bot.villageFigure, x: 0.5, y: 0.76, scale: 1.2)
        let existing = AgentRoomCache.list(server: "phone").first { $0.id == project.id }
        let revision = (existing?.revision ?? 0) + 1
        let version = AgentRoom.Version(revision: revision, instruction: project.brief, artwork: digest, width: pixels.width, height: pixels.height,
            figures: [figure], hotspots: [.init(id: "owner", title: bot.name, x: 0.5, y: 0.76, w: 0.18, h: 0.30, action: .bot, botID: bot.id)], checks: ["Billedformat og figurplacering valideret"])
        let room = AgentRoom(id: project.id, botID: bot.id, title: project.title.isEmpty ? "Mit agentrum" : project.title, brief: project.brief,
            state: .published, created: existing?.created ?? project.updated.timeIntervalSince1970, revision: revision, publishedRevision: revision,
            versions: Array((existing?.versions ?? []).suffix(23)) + [version], notice: nil)
        try AgentRoomCache.save(try room.validated(), server: "phone", image: data, digest: digest)
        return room.id
    }
}

enum AgentPhoneRoomEditor {
    static func isLocal(_ room: AgentRoom) -> Bool { AgentRoomCache.list(server: "phone").contains { $0.id == room.id } }
    static func resize(_ room: AgentRoom, figureID: UUID, scale: Double, instruction: String) throws -> AgentRoom {
        guard let old = room.current, old.figures.contains(where: { $0.id == figureID }), scale.isFinite,
              let bytes = AgentRoomCache.artwork(old.artwork) else { throw AgentRoomFailure.invalidData }
        let figures = old.figures.map { figure in
            figure.id == figureID ? AgentRoom.Figure(id: figure.id, name: figure.name, character: figure.character,
                x: figure.x, y: min(1 - 0.09 * scale, max(0.09 * scale, figure.y)), scale: scale) : figure
        }
        let revision = room.revision + 1
        let version = AgentRoom.Version(revision: revision, instruction: String(instruction.prefix(8_000)), artwork: old.artwork,
            width: old.width, height: old.height, figures: figures, hotspots: old.hotspots, checks: old.checks)
        let updated = AgentRoom(id: room.id, botID: room.botID, title: room.title, brief: room.brief, state: .published,
            created: room.created, revision: revision, publishedRevision: revision, versions: Array(room.versions.suffix(23)) + [version], notice: nil)
        try AgentRoomCache.save(try updated.validated(), server: "phone", image: bytes, digest: old.artwork)
        return updated
    }
}
