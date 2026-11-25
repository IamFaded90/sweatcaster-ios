# Scan og gem

Fra hjemmet eller agentværktøjerne kan man scanne papir med Apples
perspektivrettede dokumentkamera, fotografere en QR-kode eller importere
op til ti fotos. Vision laver lokal OCR og QR-læsning. Der er ingen ny
server eller modelhentning for at scanne.

PDF-eksport tegner originalen og lægger en usynlig Core Text-tekstlinje
ved hver genkendt position. Før eksport accepteres, genåbnes PDF'en med
PDFKit for at kontrollere sidetal og faktisk søgbar tekst. Kopien, OCR og
kvitteringscitater gemmes afgrænset pr. agent. Titel kan rettes. Deling,
sletning og import til det eksisterende dokumentbibliotek er koblet på.

Kvitteringer viser mulige trykte totalbeløb og deres præcise citat, ikke
en påstået verificeret betaling. Noter/kalender/påmindelser går gennem
Fang og følg op og brugerens gennemgang. QR viser indhold/domæne og
åbner kun et http(s)-link ved et aktivt tryk; andre typer forbliver tekst.

Dette er en selvstændig native implementering inspireret af 6pm/scan og
de nævnte scannerarbejdsgange. ORIX' ikke-frie kode er ikke kopieret.
Tre portable prøver dækker trykte beløb, QR-linktyper og afgrænsede
PDF-kopier/sletning. Den faktiske kamera/OCR/PDF-tekstlag-kontrol og
deling skal køres på en Apple-enhed; de foregives ikke udført på Windows.
