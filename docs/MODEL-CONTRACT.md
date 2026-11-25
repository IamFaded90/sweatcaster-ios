# Fælles modelkontekst

De eksisterende Apple/Core ML/GGUF-, PC- og cloudadaptere bevares.
AnyLanguageModels aktuelle Swift 6.3/Xcode 26.4-krav passer ikke til
projektets Xcode 26.3; en tvungen motor- eller værktøjsopgradering undgås.

AgentModelContract giver et fælles budget og hele kontekstblokke. Sprog,
verificerede handlinger og nødvendigt svar-/værktøjsformat får plads først.
Relevante kontaktkilder, rettelser, hukommelse, ønsker, Skills og personlighed
medtages i denne rækkefølge, når hele blokken passer. En lang profil kan
ikke skære en mailadresse, kildecitat eller JSON-definition midt over.
Hukommelseskilder vises kun i chatten, hvis hukommelsesblokken faktisk blev
medtaget. Der reserveres plads til en eventuel værktøjsopfølgning/rettelse.

PC-kontrakten på 2.000 prompttegn/3.000 instruktionstegn beholdes. Overlange
modelkald afvises før afsendelse frem for lydløs klipning. Historik sendes
som hele, begrænsede beskedpar; den ældre PC-fallback låner kun plads til
en hel historikblok. Nyeste brugerbesked bevares også ved værktøjsopfølgning.

Fire portable prøver kontrollerer prioritet, hele kilder, explicit fejl og
historikbudget. Providerkald, dansk kvalitet og native modelkompilering
kræver fortsat en faktisk PC/iPhone-/kontoprøve. Dette giver ikke alle
modeller identiske evner eller nye tjenestetilladelser.
