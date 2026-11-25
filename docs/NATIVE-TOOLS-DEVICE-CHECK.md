# Enhedskontrol efter næste Apple-build

Koden og PC-prøverne er gennemført i C1–C15-rækkefølge. Disse punkter er
ikke prøvet på iPhone i denne omgang. Der er ikke startet build eller push.

1. **Kamerahjælp:** Åbn en almindelig agentchat → værktøjer → kamerahjælp.
   Tag et tydeligt foto, spørg om en knap, ret markeringen og tag næste foto.
   Tjek at gamle markeringer forsvinder, og at tekstkilde/modelgæt skelnes.
2. **Genstande i rum:** Åbn et landsbyrum. Tilføj en egen gemt sang, et billede
   og et projekt. Åbn hver, flyt/fjern/fortryd, og prøv efter slettet original.
3. **Agentbrowser:** Åbn en neutral hjemmeside fra agentbrowseren på iPhone.
   Prøv pause/overtag/stop, en opgave med login og den særskilte resultatkontrol.
   Der kræves ikke en kørende PC til telefonmodellen/browseren.
4. **Egne stemmer:** Hent klonemodellen særskilt. Optag/importér en lovligt
   anvendt prøve på 10–60 sekunder. Opret, prøv, godkend og vælg hver stemme
   pr. agent. Vurder dansk udtale, lighed, afbrydelse og hukommelsesforbrug.
5. **Skills/kontakter:** Importér en lille SKILL.md, gennemgå og aktivér den
   for én agent. Find en kontakt og vælg kilden til en opfølgning. Prøv afvist
   kontaktadgang og fjern kilden igen. En Skill giver ikke nye iOS-rettigheder.
6. **Lokalt arbejdsrum:** Lav et lille værktøj, fx sammenlægning af en JSON-liste.
   Gennemgå koden, kør, afbryd en uendelig løkke og kør en ny prøve bagefter.
   Åbn det gemte resultat. Skriv derefter “Åbn terminalen” til agenten, og hent
   Linux-pakken. Slå nettet fra og kør den viste optælling. Tjek, at æble
   forekommer to gange og pære én gang. Brug resultatet i chatten.
7. **Hukommelse:** Gem en egen besked fra dens menu. Spørg om samme emne,
   åbn kilderne, skift model og prøv igen. Slet/afbryd hukommelse og kontrollér,
   at glemte kilder ikke bruges. Privat sessionshukommelse har fortsat eget liv.
8. **Dokumenter:** Tilføj PDF, dansk semikolon-CSV og JSON. Søg i biblioteket,
   vælg filen og spørg om et bestemt punkt. Kontrollér side/række/JSON-sti.
9. **Fang og følg op:** Prøv skrevet tekst, dansk diktering og foto-OCR.
   Ret et forslag og gem en note. Gennemgå en påmindelse før oprettelse.
   Kontrollér kvittering og citat, og fjern en kildekopi.
10. **Optagelser:** Importér længere lyd, start transskription, stop og fortsæt.
    Afspil fra tidskode, ret tekst og gem. Hent talermodeller separat og prøv
    to talere. Kontroller grove tidskoder/flere talere og faktisk RAM/kvalitet.
11. **Drift:** Start to lokale opgaver, brug Stop lokale AI-opgaver under
    Fejlfinding → Ressourcer, og prøv en ny. Prøv GGUF-pause/fortsæt, nettab,
    genåbning og et udløbet downloadlink. Den fungerende FLUX bevares.
12. **Modelskift:** Prøv samme almindelige danske opgave på telefon/PC/cloud.
    Kontrollér sprogønske, rettelser, valgt kontakt og viste hukommelseskilder.
    PC-kontekst må ikke klippe mailadresser/citater/formatdefinitioner over.
13. **Scan og gem:** Scan et brev/kvittering, læs QR, gem/del PDF og søg efter
    en genkendt linje i den eksporterede PDF. Kontrollér trykte beløb. Prøv
    import til agentbibliotek, opfølgning og slet PDF/tekst.
14. **Dagsplan:** Læs kalender/Påmindelser, justér varighed og pauser. Prøv
    flyt/kort ned/spring over og en overfyldt dag. Gennemgå én booking,
    kontrollér den i Kalender og tjek, at gentaget forsøg ikke dublerer.
15. **Gennemgå arbejde:** Lav et dokument med inputfil. Åbn opgavens kilder
    og resultat, kør indholdskontrol og redigér filen. Den gamle vurdering skal
    blive forældet. Slet output og kontrollér, at færdig-status viser manglen.
    Find optagelser/dagsplaner/scanninger igen i Fortsæt og personlig søgning.

Native Apple-kompilering er den første manglende kontrol. Linux/PC-prøverne
beviser de portable regler og projektkobling; de beviser ikke UIKit,
Core ML-modelkvalitet, mikrofon/kamera, EventKit eller faktisk iPhone-RAM.
