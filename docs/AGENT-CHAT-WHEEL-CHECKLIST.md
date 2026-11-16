# Agentchat, fanehjul og modelrettelser — 16. november 2026

Lokale ændringer på `codex/fadedai-repo-pilot`. Ingen IPA er startet for denne pakke.

## Med i koden

- Agentchat og Lumi bruger samme glasflade, gradientbobler og Markdown-visning som almindelig Chat. Agentens profilbillede vises i agentchattens overskrift. Modeller, oplæsning, diktering, kilder, kortsvar, kladder og genforsøg bevares.
- Bundmenuen er et vandret fanehjul med perspektiv under swipe. Swipe flytter kun menuen; tryk åbner siden. Code Bot og tilsluttede PC-moduler er med. Mere, eksisterende sider og tilbage-navigation bevares. Pile giver et alternativ til swipe. Systemets Reducer bevægelse og appens rolige tilstand respekteres.
- Border Beam er en rigtig Swift Package-afhængighed fra `ismnoiet/border-beam-ios`, fastlåst til `a11d1b938b1cc8efad02e942f7590a0156bbd7da`. Den markerer igangværende arbejde omkring agentens/Lumis skrivefelt. Inaktiv i baggrunden, stille ved Reducer bevægelse. MIT-licensen pakkes med appen. README nævner version 1.0.0, men den ref kunne ikke hentes; derfor bruges den kontrollerede commit.
- LFM2.5 prøver CPU, hvis første Core ML-forsøg fejler før der kommer tekst. Ingen automatisk gentagelse efter delvist svar eller annullering. Samme indlæsning bruges ved modeltesten.
- Privat Studio forklarer tydeligt, at flytilstand og slukket Wi-Fi er påkrævet ved lokal privat billedgenerering. Kravet er bevaret. Billedmenuen i almindelig Chat kan åbnes uden prompt og forklarer, at der først skal skrives en beskrivelse.
- Lumis PC-instruktioner præciserer, at hun skal fortsætte samtalen og svare på den nyeste besked. Denne backendændring er endnu ikke installeret i PC-programmet.
- Store filer er delt i mindre filer, med samme eksisterende typer og lagrings-/API-nøgler.
- Agentprofiler, agentchat og Lumi deler en stemmevælger med individuelle prøveknapper og de faktisk tilgængelige danske/engelske Apple-stemmer. Valget opdaterer både botprofilens `voice` og den eksisterende agentspecifikke chatnøgle. Profilredigering opdaterer samme nøgle. Almindelig Chat respekterer også den valgte botstemme.
- Lumi brugte tidligere altid automatisk telefonstemme ved oplæsning; hendes gemte stemmevalg bruges nu. Et eksplicit valg skiftes ikke automatisk ved sprogskift. En manglende stemme giver en forklaring i stedet for tavst at blive erstattet. Ingen nye lydmodeller eller betalingskonti er installeret.

## Kontrolleret

- Xcode-projektets filreferencer og fælles testskema: bestået.
- Swift-syntaks kontrolleret med tree-sitter. Dette erstatter ikke Xcode-kompilering.
- To XCTest-regressionstests er tilføjet for fastholdt stemmeidentitet og manglende stemmer. De er ikke kørt på Windows.
- Fire eksisterende Lumi-backendtests: bestået med simuleret model/ComfyUI.
- Direkte PC-test med den rigtige Lumimaid-model og tre neutrale opfølgninger: ingen gentaget hilsen, men ét forkert svar om en cykels farve. Sidste svar huskede den rigtige farve. Relevans og gentagelsesproblemet er derfor ikke erklæret fuldt løst.

## Skal testes før frigivelse

- Xcode-kompilering, ContractTests og IPA-kontrol inkl. Frameworks-runpath og BorderBeam-resourcebundle.
- Agentchat: PC og telefon, send/stop/genforsøg, gemt kladde, diktering, oplæsning, tastaturets skjul-knap og Luk. Lumi: samtale, eksisterende scenebibliotek, billedreference og video.
- Swipe menuen uden sideskift; tryk hver fane, Mere og et PC-modul. Tilbage skal virke. Afbryd PC: gamle moduler skal forsvinde uden tom side. Afprøv større tekst, VoiceOver, lyst tema og Reducer bevægelse.
- Underholdning: afspil film, skift til Agenter med hjulet, og kontrollér fortsat afspilning.
- LFM2.5: send Hej, test model, stop under indlæsning og gentag. CPU-fallback er ikke prøvet på en fysisk iPhone endnu; den oprindelige telefonfejl er ikke diagnosticeret endeligt.
- Privat Studio: vælg hentet billedmodel, kontrollér forklaring online, slå flytilstand til og Wi-Fi fra, generér ét billede og prøv med reference. Genforbindelse må stadig stoppe privat generering. Faktisk billedgenerering er ikke testet på telefonen her.
- Lumi fra iPhone: en samtale med mindst tre opfølgninger. Installér først den kontrollerede backendændring og genstart PC-tjenesten; ingen model- eller privatlivsændring må gemmes skjult i testen.
- Stemmer: vælg forskellige faktiske stemmer til to agenter; hør prøver og svar, luk/genåbn, og kontrollér samme valg i profil, normal Chat og agentchat. Kontrollér Lumi særskilt. Slet en hentet stemme i iOS, og kontrollér beskeden om, at den mangler. Hent en stemme og vend tilbage: listen skal opdateres. Identificér Saras faktiske navn/ID fra telefonens liste; det kan ikke afgøres fra screenshots eller Windows.

## Nye links — undersøgt, ikke installeret

- [Mindstone MCP](https://github.com/mindstone/mcp-servers): mange forbindelser, herunder ElevenLabs, IMAP/SMTP og Google Workspace. ElevenLabs kræver nøgle og cloud-API; det giver ikke offline-stemmer. Google overlapper eksisterende Google/Composio. Apple Shortcuts-serveren bruger macOS CLI, ikke direkte iPhone-kontrol. Connector-licenserne er FSL-1.1-MIT, ikke almindelig MIT i dag. Ingen forbindelse er erstattet.
- [Google Workspace MCP](https://github.com/aaronsb/google-workspace-mcp): Gmail, Kalender, Drive, Docs, Sheets, Tasks, Meet og Kontakter samt flere konti. Kører på PC med Google OAuth; README kræver Node 22.12+. Overlapper Google/Composio og Mindstone Google. Skal vurderes som én fælles Google-forbindelse, ikke tre konkurrerende forbindelser. Apache-2.0 med medfølgende notices.
- [FastAPI/LangGraph-template](https://github.com/lizheng419/fastapi-langgraph-agent-production-ready-template): samme link blev sendt to gange. Kandidat til PC-job, supervisor/worker, genoptagelse, MCP og godkendelser. Det er en større alternativ backend med bl.a. PostgreSQL, Qdrant og monitoring; ikke noget, der automatisk er integreret i FadedAI ved at blive nævnt. Bevar FadedAIs eksisterende kontrakter, private netværk, lokale modeller og brugerens data ved eventuel adaptation.

## Musik og cast — opdateret

Se [MUSIC-AND-CAST.md](MUSIC-AND-CAST.md) for den nye Musik-fane og direkte cast med fallback til iPhone. Begge er lokale ændringer og ikke udgivet. Musik er ændret til en enkel Eevee/Spotify-genvej; separat Eevee-installation og åbning på iPhone er ikke bekræftet. Cast mangler en fysisk TV-test. PC-proxy til video er ikke implementeret. Ingen ny IPA er startet.
