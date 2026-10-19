Du richtest einen Autopiloten für dieses Projekt ein. Unten steht eine Plan-Datei mit dem, was gebaut werden soll. Ein anderer Claude wird danach Aufgabe für Aufgabe umsetzen, jedes Mal mit frischem Kontext; ein Skript prüft nach jeder Aufgabe automatisch, ob der Prüfbefehl grün ist und ob die Zahl der bestandenen Tests gestiegen ist.

Lies dazu den Plan und sieh dir das Projekt an (Sprache, Build-System, vorhandene Tests). Ändere nichts.

Antworte genau in diesem Format und mit nichts anderem nach der ersten Markierung:

===KONF===
PRUEFEN='<ein Befehl, der im Projektordner baut und alle Tests ausführt, z. B. npm test, pytest -q, ./gradlew test, cargo test>'
PRUEF_ZAHL='<regulärer Ausdruck (Bash, erweitert), dessen erste Gruppe aus der Ausgabe die Zahl bestandener Tests liest, z. B. ([0-9]+) passed>'
ERLAUBT='<regulärer Ausdruck auf Dateipfade relativ zum Projekt, die der Umsetzer ändern darf, z. B. ^(src/|tests/)>'
UMSETZER_WERKZEUGE=(Read Edit Write Glob Grep 'Bash(<Prüfbefehl ohne Argumente>:*)')

(Statt PRUEF_ZAHL darf PRUEF_ZAEHLER='<Befehl>' stehen: er bekommt die Ausgabe des Prüfbefehls auf stdin und gibt nur die Zahl aus – für Werkzeuge ohne Summenzeile. Bewährte Werte:
 pytest: PRUEFEN='pytest -q', PRUEF_ZAHL='([0-9]+) passed' · Jest/Vitest: PRUEF_ZAHL='Tests:? +([0-9]+) passed' ·
 Go: PRUEFEN='go test -v ./...', PRUEF_ZAEHLER='grep -c -- "--- PASS"' ·
 Rust: PRUEFEN='cargo test', PRUEF_ZAEHLER='grep -o "[0-9]* passed" | awk "{s+=\$1} END {print s}"' ·
 Maven: PRUEF_ZAHL='Tests run: ([0-9]+)' · .NET: PRUEF_ZAHL='Passed: +([0-9]+)' · PHPUnit: PRUEF_ZAHL='OK \(([0-9]+) tests?' ·
 RSpec: PRUEF_ZAHL='([0-9]+) examples?, 0 failures' ·
 Gradle/JUnit: PRUEFEN='./gradlew test', PRUEF_ZAEHLER='cat build/test-results/test/*.xml | grep -c "<testcase"')
===AUFGABEN===
# Aufgaben: <Titel des Vorhabens>

<zwei bis fünf Sätze mit den wichtigsten Regeln für den Umsetzer: Sprache, Stil, was nicht angefasst wird>

- [ ] 1. <kleine Aufgabe>. Fertig, wenn <automatisch prüfbares Kriterium, das ein Test belegen kann>.
- [ ] 2. …

Regeln für die Aufgaben:
- Klein schneiden: jede Aufgabe in höchstens 30 Minuten umsetzbar und durch neue automatische Tests belegbar. Lieber 30 kleine als 5 große.
- Die Reihenfolge baut aufeinander auf; die ersten Aufgaben legen bei Bedarf das Test-Gerüst an, damit der Prüfbefehl überhaupt eine Zahl liefert.
- Jede Aufgabe endet mit „Fertig, wenn …“ und nennt messbare Bedingungen (Eingaben, erwartete Ergebnisse, Grenzwerte), keine Gefühle.
- Was sich nicht automatisch prüfen lässt (Aussehen, Bedienung), gehört nicht in die Liste; nenn es stattdessen in einem Satz unter den Regeln als „Prüft der Mensch selbst“.
- Die Plan-Datei selbst wird nie geändert; ERLAUBT darf sie nicht umfassen.
- Gibt es noch keine Tests und keinen Testbefehl, wähle das übliche Test-Werkzeug der Sprache und lass Aufgabe 1 es einrichten; PRUEFEN muss auch vor Aufgabe 1 schon laufen (darf dann 0 Tests melden).
