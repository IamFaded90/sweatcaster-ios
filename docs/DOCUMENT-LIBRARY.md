# Lokale dokumenter og kilder

Den eksisterende native dokumentlæser er bevaret. PDF (inklusive eksisterende
lokal OCR), tekst og Markdown suppleres med JSON og CSV med komma, semikolon
eller tabulator. CSV håndterer citationstegn, linjeskift i felter og danske
decimalkommaer. JSON holder søskendefakta sammen og angiver en entydig sti.

Biblioteket kan søge lokalt på tværs af agentens otte filer og vise det faktiske
uddrag med fil, side, række eller JSON-sti. Valg vedhæfter filen til næste
besked. Det eksisterende valgfrie embeddingindeks og kildebudget bevares;
viste chatkilder svarer til hele uddrag sendt til modellen. Frister kan ikke
låne datoer fra en anden CSV-række/JSON-post. Fjernelse sletter agentens kopi,
ikke den oprindelige fil.

Railtracks' nye Swift 6.3-afhængighed importeres ikke i Xcode 26.3-projektet.
Loaderen er selvstændigt implementeret. Importens eksisterende grænser
(24.000 tegn, 100 passager, PDF højst 30 sider) og lokal filbeskyttelse består.
Office-konvertering kræver fortsat den parrede PC og beskrives som sådan.

PC-kontrol: portable loaderprøver og Swift-syntaks. Native PDFKit/OCR,
filvælger, embeddingindlæsning og den faktiske chat prøves på Apple-enheden.
