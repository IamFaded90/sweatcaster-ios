# Stemmer fra optagelser

Agentprofil → Vælg og hør stemme → Egne stemmer fra optagelse.
Den eksisterende Supertonic-pakke med ti stemmer og alle nuværende valg bevares.
Nye stemmer får et UUID, et navn og en lokal conditioning-fil. Ingen tildeles
automatisk til agenter. En prøvestemme høres og godkendes i stemmelisten, før
den kan vælges. Sletning af modellen bevarer stemmer; sletning af en stemme
ændrer ingen anden stemme eller automatisk agenternes valg.

ChatterboxCoreMLs multilingual-variant bruges med `language: da`, ikke den
engelske Turbo/Nano. Dansk er stadig en kvalitetsprøve på den faktiske telefon.
Et rent referenceklip på 25–30 sekunder anbefales; 10–60 sekunder, højst 20 MB,
accepteres. Mikrofonen stopper ved 30 sekunder eller når skærmen lukkes.
Den importerede/optagede arbejdskopi slettes ved lukning. Kun stemmens lokale
conditioning-fil og metadata bevares i appens data. Intet personligt lydmateriale
eller nogen modelvægt er lagt i repoet.

Modeller hentes ved et udtrykkeligt tryk. Syntese, kloning og vandmærke indlæses
fra installerede lokale filer. Normal tale kontakter ikke Hub eller en PC.
Downloads markeres først klar, når alle udvalgte manifestfiler har den ventede
størrelse. SDK'ets bytekontrol er ikke en SHA-256-verifikation af hele modellen.
Afbrudte downloads kan fortsættes. Delvist installerede pakker indlæses ikke.

Modelarbejdet går gennem eksisterende LocalCompute; cache frigives før anden
inferens og efter tomgang. Oplæsning bruger samme afspiller og læbe-/taleanimation
som eksisterende stemmer. Valg i chat, rum, filmven, kreative projekter og miks
kontrollerer den valgte stemmes egen model, ikke alene Supertonic-installationen.

SwiftPM-opløsning med Swift 6.2.1 og lokale Foundation-prøver bestod. Det er ikke
en Apple-kompilering eller en prøvelytning. Dansk kvalitet, lighed, RAM, kolde
Core ML-indlæsninger og samtidig animation afventer iPhone. Ingen IPA/push.
