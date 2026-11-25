# Lokal drift, stop og genoptagelse

FadedAIs eksisterende motorer og billeddownload bevares. OnDevice LLM's
idé om én kontrolleret inferenskø bruges i den eksisterende LocalCompute:
en aktiv native beregning beholder sin plads, indtil den faktisk returnerer,
også efter stop. Ventende opgaver har generationsbilletter og bliver
ugyldige ved stop/baggrundsskift. Et sent resultat kan ikke frigive en nyere
opgaves plads. Køen er begrænset, og RAM-beregning kan ikke overløbe.

Indstillinger → Fejlfinding → Ressourcer viser aktiv/køstatus og har Stop
lokale AI-opgaver. Der loves ikke øjeblikkeligt stop midt i en native
modelprediction. Opgaven beholder pladsen, indtil den kan afbrydes korrekt.

GGUF-download får Pause med URLSessions genoptagelsesdata. Afbrudte filer
kan fortsættes, når serveren understøtter det. Udløbne signerede links og
ugyldige HTTP-intervaller gemmes ikke som næste genoptagelsesgrundlag;
et nyt forsøg får et nyt link. En frisk overførsel starter også den viste
procent forfra. Filstørrelse og SHA-256 kontrolleres fortsat før installation.
Den fungerende FLUX-downloads validerings-/pauseflow ændres ikke.

Fem portable prøver dækker FIFO, afbrydelse, gamle billetter, køgrænse,
RAM-overløb, downloadstatus og fremdrift. Native URLSession-baggrundsforløb,
modelprediction-stop og målt iPhone-RAM kræver en Apple-prøve.
