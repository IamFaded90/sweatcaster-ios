# Fang og følg op

Åbn fra hjemmets opsamlingsfelt, agentens værktøjer eller delt indhold.
Skriv tekst, brug den eksisterende danske offline-diktering (hvis modellen
er hentet), eller genkend teksten i et foto med Vision. Et foto analyseres
her som tekst; der foregives ikke genkendelse af usynlige eller ulæselige data.

Den valgte telefonmodel foreslår højst otte oplysninger, beslutninger,
noter, påmindelser eller aftaler. Hvert forslag skal have et ordret citat i
den gennemgåede kildetekst. Forkert JSON, fremmede citater og for store
forslag afvises. Brugeren kan rette type/titel og selv oprette en note.

Noter gemmes kun efter valg, i agentens almindelige hukommelse. Kalender og
Påmindelser åbner den eksisterende native gennemgang med det samme job-ID
ved gentagne forsøg. Faktiske kvitteringer og valgte citater gemmes i et
beskyttet, agentafgrænset kildearkiv. Fjern uddrag fjerner denne kildekopi;
en allerede gemt note/aftale fjernes i den respektive hukommelse/app.

Memex' arbejdsgang inspirerer en selvstændig native implementering. Ingen
Flutter-app, parallel cloudmotor eller Kortsamling-fane er tilføjet.
Fire portable prøver dækker kildekrav, format, størrelsesgrænser, gentagne
gemninger og agentafgrænset sletning. Native kamera/mikrofon, modelkvalitet
og EventKit kræver fysisk iPhone-kontrol.
