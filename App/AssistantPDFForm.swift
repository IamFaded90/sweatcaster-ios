import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AssistantPDFProfileField: String, Codable, CaseIterable, Identifiable {
    case fullName, firstName, lastName, address, postalCode, city, email, phone
    var id: Self { self }

    var title: String {
        switch self {
        case .fullName: "Fulde navn"
        case .firstName: "Fornavn"
        case .lastName: "Efternavn"
        case .address: "Adresse"
        case .postalCode: "Postnummer"
        case .city: "By"
        case .email: "E-mail"
        case .phone: "Telefon"
        }
    }

    static func match(_ label: String) -> Self? {
        let key = label.lowercased().filter(\.isLetter)
        switch key {
        case "navn", "fuldenavn", "fulllegalname", "fullname", "name": return .fullName
        case "fornavn", "firstname", "givenname": return .firstName
        case "efternavn", "lastname", "surname", "familyname": return .lastName
        case "adresse", "gadeadresse", "address", "streetaddress": return .address
        case "postnummer", "postnr", "postalcode", "zipcode", "zip": return .postalCode
        case "by", "postby", "city", "town": return .city
        case "email", "emailadresse", "emailaddress": return .email
        case "telefon", "telefonnummer", "phone", "phonenumber", "mobile": return .phone
        default: return nil
        }
    }
}

@MainActor struct AssistantPDFEntry: View {
    @State private var showing = false
    var body: some View {
        FadedSecondaryButton("Udfyld PDF", icon: "doc.text") { showing = true }
            .sheet(isPresented: $showing) { AssistantPDFForm() }
    }
}

@MainActor struct AssistantPDFForm: View {
    struct Placement: Identifiable {
        let id = UUID()
        let page: Int
        let point: CGPoint
        var text = ""
        var fontSize: CGFloat = 12
    }

    private struct Field: Identifiable {
        let page: Int
        let annotation: Int
        let label: String
        let limit: Int
        var value: String
        let original: String
        var id: String { "\(page)-\(annotation)" }
    }

    private struct Export: FileDocument {
        static let readableContentTypes: [UTType] = [.pdf]
        let data: Data
        init(data: Data) { self.data = data }
        init(configuration: ReadConfiguration) throws {
            guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            self.data = data
        }
        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
    }

    let initial: Data?
    let initialTitle: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fadedai.pdf.approvedProfile.v1") private var savedProfile = Data()
    @State private var source: Data?
    @State private var fileName = "Formular"
    @State private var fields: [Field] = []
    @State private var placements: [Placement] = []
    @State private var positioning = false
    @State private var pendingPlacement: Placement?
    @State private var profile: [AssistantPDFProfileField: String] = [:]
    @State private var editingProfile = false
    @State private var importer = false
    @State private var exporter = false
    @State private var showPreview = false
    @State private var exportAfterPreview = false
    @State private var output: Export?
    @State private var status: String?

    init(initial: Data? = nil, title: String = "Formular") { self.initial = initial; initialTitle = title }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    controls
                    if !fields.isEmpty { fieldCard }
                    if !placements.isEmpty { placedTextCard }
                    if let status { FadedDetailText(status).accessibilityAddTraits(.updatesFrequently) }
                }
                .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background { FadedBackground() }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Udfyld PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .task { if let initial, source == nil { load(initial, title: initialTitle) } }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do { load(try LocalFileStore.readBytes(from: url, maximumBytes: 10 * 1_024 * 1_024), title: url.deletingPathExtension().lastPathComponent) }
                catch { status = "PDF’en kunne ikke læses. Vælg en fil på højst 10 MB." }
            }
            .fileExporter(isPresented: $exporter, document: output, contentType: .pdf, defaultFilename: fileName + " - udfyldt") { result in
                if case .success = result { status = "Kopien er gemt i Filer." }
                else { status = "Kopien blev ikke gemt. Du kan prøve igen." }
            }
            .sheet(isPresented: $editingProfile) { profileSheet }
            .sheet(isPresented: $positioning) { placementSheet }
            .sheet(isPresented: $showPreview, onDismiss: {
                if exportAfterPreview { exportAfterPreview = false; exporter = true }
            }) {
                if let output {
                    NavigationStack {
                        AssistantPDFPreview(data: output.data)
                            .navigationTitle("Gennemgå kopien")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("Luk") { showPreview = false } }
                                ToolbarItem(placement: .confirmationAction) { Button("Gem kopi") { exportAfterPreview = true; showPreview = false } }
                            }
                    }
                }
            }
        }
        .privacySensitive()
    }

    private var controls: some View {
        FadedCard(accent: FadedBrand.phone) {
            VStack(alignment: .leading, spacing: 8) {
                if source != nil { Text(fileName).font(.headline) }
                FadedDetailText("Gennemgå formularen og gem en udfyldt kopi i Filer.")
                FadedSecondaryButton(source == nil ? "Vælg PDF" : "Vælg en anden PDF", icon: "doc") { importer = true }
                FadedSecondaryButton("Mine formularoplysninger", icon: "person.crop.rectangle") {
                    profile = (try? JSONDecoder().decode([AssistantPDFProfileField: String].self, from: savedProfile)) ?? [:]
                    editingProfile = true
                }
                if !fields.isEmpty {
                    FadedSecondaryButton("Brug mine oplysninger", icon: "square.and.pencil", action: autofill)
                }
                if source != nil {
                    FadedSecondaryButton("Sæt tekst på PDF", icon: "text.cursor") { positioning = true }
                        .disabled(placements.count >= 100)
                }
                if !fields.isEmpty || !placements.isEmpty {
                    FadedPrimaryButton("Gennemgå kopi", icon: "doc.text.magnifyingglass", action: preview)
                }
            }
        }
    }

    private var placedTextCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tekst på siderne").font(.headline)
                ForEach(placements) { placement in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(placement.text).lineLimit(2)
                            FadedDetailText("Side \(placement.page + 1)")
                        }
                        Spacer()
                        Button(role: .destructive) { placements.removeAll { $0.id == placement.id }; status = nil } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Fjern \(placement.text)")
                    }
                }
            }
        }
    }

    private var placementSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let source {
                    AssistantPDFPreview(data: source, configure: { _ = addPlacementAnnotations(to: $0) }) { page, point in
                        if pendingPlacement == nil, placements.count < 100 {
                            pendingPlacement = Placement(page: page, point: point)
                        }
                    }
                }
                FadedDetailText(placements.count < 100 ? "Zoom ind, og tryk der, hvor teksten skal begynde." : "Du har tilføjet 100 tekstfelter.")
                    .padding(FadedSpacing.edge).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background { FadedBackground() }
            .navigationTitle("Placér tekst")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Færdig") { positioning = false } } }
            .sheet(item: $pendingPlacement) { placement in
                AssistantPDFPlacementEditor(placement: placement, profile: storedProfile) { value in
                    placements.append(value)
                    status = nil
                    pendingPlacement = nil
                }
            }
        }
    }

    private var storedProfile: [AssistantPDFProfileField: String] {
        (try? JSONDecoder().decode([AssistantPDFProfileField: String].self, from: savedProfile)) ?? [:]
    }

    private var fieldCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                let missing = fields.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                Text(missing == 0 ? "Tekstfelter udfyldt" : "Tomme tekstfelter · \(missing)").font(.headline)
                ForEach($fields) { $field in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(field.label, systemImage: field.value.isEmpty ? "circle" : "checkmark.circle")
                            .font(.subheadline)
                        TextField(field.label, text: $field.value, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private var profileSheet: some View {
        NavigationStack {
            Form {
                Section("Gem på denne iPhone") {
                    ForEach(AssistantPDFProfileField.allCases) { field in
                        TextField(field.title, text: Binding(get: { profile[field] ?? "" }, set: { profile[field] = String($0.prefix(240)) }))
                    }
                }
                Button("Ryd formularoplysninger", role: .destructive) { savedProfile = Data(); profile = [:] }
            }
            .navigationTitle("Mine oplysninger")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { editingProfile = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem") {
                        if let data = try? JSONEncoder().encode(profile.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                            savedProfile = data
                            editingProfile = false
                        }
                    }
                }
            }
        }
    }

    private func load(_ data: Data, title: String) {
        guard let document = PDFDocument(data: data), !document.isLocked, (1...100).contains(document.pageCount) else {
            status = "PDF’en skal kunne åbnes og have højst 100 sider."
            return
        }
        source = data
        let name = title.lowercased().hasSuffix(".pdf") ? String(title.dropLast(4)) : title
        fileName = String(name.replacingOccurrences(of: "/", with: "-").prefix(100))
        fields = []
        placements = []
        output = nil
        for index in 0..<document.pageCount {
            let textFields: [Field] = (document.page(at: index)?.annotations ?? []).enumerated().compactMap { offset, annotation in
                guard annotation.widgetFieldType == .text, !annotation.isReadOnly, !annotation.isPasswordField else { return nil }
                let name = annotation.fieldName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let value = annotation.widgetStringValue ?? ""
                return Field(page: index, annotation: offset, label: name.isEmpty ? "Felt \(offset + 1) · side \(index + 1)" : String(name.prefix(100)),
                             limit: annotation.maximumLength, value: value, original: value)
            }
            fields.append(contentsOf: textFields)
            if fields.count > 200 { fields = []; status = "Formularen har over 200 felter."; return }
        }
        status = fields.isEmpty ? "Tryk på Sæt tekst på PDF for at udfylde blanketten direkte på siden." : nil
    }

    private func autofill() {
        let stored = storedProfile
        var filled = 0
        for index in fields.indices where fields[index].value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let key = AssistantPDFProfileField.match(fields[index].label), let value = stored[key], !value.isEmpty,
                  fields[index].limit <= 0 || value.utf16.count <= fields[index].limit else { continue }
            fields[index].value = value
            filled += 1
        }
        status = filled == 0 ? "Jeg fandt ingen tomme felter med gemte oplysninger, der passer." : "Udfyldt · \(filled) felter. Gennemgå dem før du gemmer."
    }

    private func preview() {
        guard let source, let copy = PDFDocument(data: source), !copy.isLocked else { status = "Kopien kunne ikke åbnes."; return }
        for field in fields where field.value != field.original {
            guard let page = copy.page(at: field.page), page.annotations.indices.contains(field.annotation),
                  field.value.utf16.count <= 8_000, field.limit <= 0 || field.value.utf16.count <= field.limit else {
                status = "Tjek længden på feltet ‘\(field.label)’."; return
            }
            page.annotations[field.annotation].widgetStringValue = field.value
        }
        if let placement = addPlacementAnnotations(to: copy) {
            status = "Der er ikke plads til ‘\(placement.text)’ på side \(placement.page + 1). Placér den igen med mindre skrift."
            return
        }
        guard let filled = copy.dataRepresentation(), let verified = PDFDocument(data: filled),
              verified.pageCount == copy.pageCount else { status = "PDF-kopien kunne ikke dannes."; return }
        for field in fields where field.value != field.original {
            guard let annotations = verified.page(at: field.page)?.annotations,
                  annotations.indices.contains(field.annotation),
                  (annotations[field.annotation].widgetStringValue ?? "") == field.value else {
                status = "Kontrollér feltet ‘\(field.label)’. Det blev ikke bevaret i kopien."
                return
            }
        }
        for placement in placements {
            guard verified.page(at: placement.page)?.annotations.contains(where: {
                $0.userName == placement.id.uuidString && $0.contents == placement.text && $0.shouldPrint
            }) == true else { status = "Teksten på side \(placement.page + 1) blev ikke bevaret i kopien."; return }
        }
        output = Export(data: filled)
        showPreview = true
    }

    @discardableResult private func addPlacementAnnotations(to document: PDFDocument) -> Placement? {
        var firstFailure: Placement?
        for placement in placements {
            guard let page = document.page(at: placement.page) else { return placement }
            if page.annotations.contains(where: { $0.userName == placement.id.uuidString }) { continue }
            guard let annotation = Self.textAnnotation(placement, on: page) else {
                if firstFailure == nil { firstFailure = placement }
                continue
            }
            page.addAnnotation(annotation)
        }
        return firstFailure
    }

    static func textAnnotation(_ placement: Placement, on page: PDFPage) -> PDFAnnotation? {
        let pageBounds = page.bounds(for: .cropBox)
        let font = UIFont.systemFont(ofSize: placement.fontSize)
        let size = (placement.text as NSString).size(withAttributes: [.font: font])
        let width = ceil(size.width) + 8
        let height = ceil(size.height) + 6
        guard width <= pageBounds.width, height <= pageBounds.height else { return nil }
        let x = min(max(placement.point.x - 3, pageBounds.minX), pageBounds.maxX - width)
        let y = min(max(placement.point.y - 5, pageBounds.minY), pageBounds.maxY - height)
        let annotation = PDFAnnotation(bounds: CGRect(x: x, y: y, width: width, height: height),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = placement.text
        annotation.userName = placement.id.uuidString
        annotation.font = font
        annotation.fontColor = .black
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        return annotation
    }

    private struct AssistantPDFPlacementEditor: View {
        @Environment(\.dismiss) private var dismiss
        @State var placement: Placement
        let profile: [AssistantPDFProfileField: String]
        let add: (Placement) -> Void

        var body: some View {
            NavigationStack {
                Form {
                    TextField("Tekst", text: $placement.text)
                    Stepper("Skriftstørrelse · \(Int(placement.fontSize))", onIncrement: {
                        placement.fontSize = min(24, placement.fontSize + 1)
                    }, onDecrement: {
                        placement.fontSize = max(8, placement.fontSize - 1)
                    })
                    if cleanText.count > 240 { Text("Brug op til 240 tegn pr. tekstfelt.").font(.footnote) }
                    if !profile.values.allSatisfy(\.isEmpty) {
                        Menu("Mine formularoplysninger", systemImage: "person.crop.rectangle") {
                            ForEach(AssistantPDFProfileField.allCases) { field in
                                if let value = profile[field], !value.isEmpty {
                                    Button(field.title) { placement.text = value }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Tekst på side \(placement.page + 1)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Tilbage") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sæt ind") {
                            var value = placement
                            value.text = cleanText
                            add(value)
                        }.disabled(cleanText.isEmpty || cleanText.count > 240)
                    }
                }
            }
        }

        private var cleanText: String { placement.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }
}

private struct AssistantPDFPreview: UIViewRepresentable {
    let data: Data
    var configure: ((PDFDocument) -> Void)? = nil
    var onPlacement: ((Int, CGPoint) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onPlacement: onPlacement) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        let document = PDFDocument(data: data)
        if let document {
            for index in 0..<document.pageCount {
                document.page(at: index)?.annotations.forEach { $0.isReadOnly = true }
            }
        }
        view.document = document
        if onPlacement != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.place(_:)))
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
        }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPlacement = onPlacement
        if let document = view.document { configure?(document) }
    }

    @MainActor final class Coordinator: NSObject {
        var onPlacement: ((Int, CGPoint) -> Void)?

        init(onPlacement: ((Int, CGPoint) -> Void)?) { self.onPlacement = onPlacement }

        @objc func place(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PDFView, let document = view.document else { return }
            let location = gesture.location(in: view)
            guard let page = view.page(for: location, nearest: false) else { return }
            onPlacement?(document.index(for: page), view.convert(location, to: page))
        }
    }
}
