# Agenthukommelse med kilder

Eksisterende sprog/personligheds- og præferencevalg bevares. Faste ønsker vises
også på den nye hukommelsesside. Gemt hukommelse kommer kun fra brugerens egne
noter eller “Husk det, jeg skrev” på en almindelig chatbesked. Agentens egne
påstande bliver ikke automatisk gemt som brugerfakta.

Hvert punkt har stabilt ID, ordret kildekopi, tidspunkt for gemning og eventuelt
den oprindelige beskeds ID. Det er uafhængigt af valgt model. Kopien bliver i
hukommelsen, indtil brugeren vælger Glem; almindelig chat gemmer kun de seneste
100 beskeder, så hukommelsen må ikke forsvinde ved den automatiske beskæring.
Der er højst 300 punkter pr. agent. Agenter deler ikke denne hukommelse.

Eksisterende Wax udbygges med et særskilt, vedvarende OrdinaryWaxLookup. Den
private sessions midlertidige indeks og oprydning ændres ikke. Der indekseres
kun aktuel, autoriseret hukommelse. Indeksopdatering har et dirty-mærke og kan
genopbygges efter afbrudt skrivning/manglende indeks. Sletning af et punkt rydder
også agentens søgecache; en manuel cacheknap giver genforsøg ved filbeskyttelse.

Opslag anvender Wax-tekstsøgning uden en ny embeddingmodel. Den eksisterende
ordbaserede genfinding er reserve ved indeksfejl; dette er ikke dokumentation
for semantisk/vektorbaseret søgning. Før kontekst gives til en chatmodel,
kontrolleres resultaterne mod de stadig gemte punkter. Højst to relevante,
kildeangivne uddrag medtages. Uddrag mærkes, og seneste input/rettelser har
forrang. Chatten viser en knap til de hukommelseskilder, modellen fik adgang til.

Data, indeks og importerede noter ligger i appens Application Support og er
ikke Git-filer. Lokal kode/prøver indeholder kun opdigtede kilder. Ni prøver
mod den rigtige Wax-motor dækker også uændret privat oprydning. Native chat,
filbeskyttelse og layout skal stadig prøves i Apple-/iPhone-miljøet.
