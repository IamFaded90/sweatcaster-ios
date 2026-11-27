import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var model: CastAppModel
    @ObservedObject private var browser: BrowserController
    @AppStorage(FilmAppearance.storageKey) private var appearance = FilmAppearance.followApp.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.dismiss) private var dismiss
    @State private var showingDirectDiagnostics = false
    @State private var directSourceURL: URL?

    init(model: CastAppModel) {
        self.model = model
        _browser = ObservedObject(wrappedValue: model.browser)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    private var theme: Binding<FilmAppearance> {
        Binding(get: { FilmAppearance(storedValue: appearance) }, set: { appearance = $0.rawValue })
    }

    private var themePicker: some View {
        Picker("Udseende i Film", selection: theme) {
            ForEach(FilmAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Udseende") {
                    if typeSize.isAccessibilitySize { themePicker.pickerStyle(.menu) }
                    else { themePicker.pickerStyle(.segmented) }
                }.listRowBackground(Style.card)
                Section("Browser") {
                    Toggle("Blokér reklamer", isOn: Binding(get: { browser.adBlockingEnabled }, set: browser.setAdBlocking))
                        .disabled(browser.settingAdBlocking)
                    if browser.settingAdBlocking { ProgressView("Gør reklameblokering klar…") }
                    if let notice = browser.adBlockingNotice {
                        Text(notice).font(Style.meta).foregroundStyle(Style.muted)
                        if browser.webView.url != nil {
                            Button("Genindlæs siden") { browser.reload() }.disabled(browser.settingAdBlocking)
                        }
                    }
                }.listRowBackground(Style.card)
                Section("Afspilning på TV") {
                    Text("Find filmen i Browser, start afspilningen, og vælg den under Videoer.")
                    Text("iPhone og Chromecast skal være på samme Wi-Fi.")
                }.font(Style.body).listRowBackground(Style.card)
                Section {
                    DisclosureGroup("Fejlfinding") {
                        Button(model.is404TestRunning ? "Tester videokilden…" : "Test og kopiér videokildens fejllog") {
                            model.copy404Test()
                        }.disabled(!model.canRun404Test)
                        Text(model.copy404TestMessage).font(Style.meta).foregroundStyle(Style.muted)
                        Button("Test Chromecast direkte") {
                            directSourceURL = model.directDiagnosticSourceURL
                            model.prepareDirectDiagnostics()
                            showingDirectDiagnostics = true
                        }.disabled(model.directDiagnosticSourceURL == nil)
                        Text("Start en video først. Den direkte test kan afbryde afspilningen på TV’et.")
                            .font(Style.meta).foregroundStyle(Style.muted)
                    }
                    LabeledContent("Version", value: version).font(Style.meta)
                }.listRowBackground(Style.card)
            }
            .scrollContentBackground(.hidden).background { FilmBackground() }
            .navigationTitle("Indstillinger · Film").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Færdig") { dismiss() } } }
        }
        .sheet(isPresented: $showingDirectDiagnostics) { DirectCastDiagnosticsView(sourceURL: directSourceURL) }
        .presentationDetents([.large]).presentationBackground { FilmBackground() }
    }
}
