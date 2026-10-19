#!/bin/bash
# Selbsttest für autopilot-loop mit vorgetäuschtem `claude` (test/fake-claude): kostet nichts, startet nichts Echtes,
# fasst keine echten Einstellungen an (eigenes XDG_CONFIG_HOME). Ausgabe „ok“ = alles bestanden.
set -u
WERKZEUG=$(readlink -f "$(dirname "$0")/..")
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fehlschlag() { echo "FEHLER: $1"; for v in "$T"/.autopilot/log/verlauf.txt "$T"/p2/.autopilot/log/verlauf.txt; do [ -f "$v" ] && { echo "--- $v"; cat "$v"; }; done; exit 1; }
mkdir -p "$T/bin" "$T/config"
ln -s "$WERKZEUG/test/fake-claude" "$T/bin/claude"
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/config" FAKE_DIR="$T/fake" AUTOPILOT_WARTEN=0 AUTOPILOT_NACHFRAGE=1 MAX=30 MAX_FEHLER=10
neue_runde() { rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR/schritte"; }
haken='sed -i "0,/^- \[ \]/s//- [x]/" TASKS.md'
probeprojekt() { # ORDNER: Git-Projekt mit Prüf- und Abnahmeskript
    mkdir -p "$1" && cd "$1" || exit 1
    git init -q -b main . && git config user.email test@example.org && git config user.name Test
    echo check >checks.txt
    echo 'test -e rot && exit 1; echo "PRUEFUNGEN: $(grep -c check checks.txt) bestanden"' >pruefe.sh
    echo 'echo "ABNAHME: $(grep -c ziel checks.txt) von 2"' >abnahme.sh
    echo "Plan: Zahlen zählen." >plan.md
}

# ================================ Teil A: der Regelkreis ================================
neue_runde
probeprojekt "$T/projekt"
printf -- '- [ ] 1. [kern] eins\n- [ ] 2. [kern] zwei\n- [ ] 3. [rand] drei\n- [ ] 4. [rand] vier\n- [ ] 5. [rand] fünf\n' >TASKS.md
echo "Datei des Nutzers" >geheim.txt
git add -A && git commit -qm start && git checkout -qb autopilot
cat >"$T/autopilot.conf" <<'EOF'
NAME=selbsttest
ARBEITSORDNER=projekt
PRUEFEN='bash pruefe.sh'
ABNAHME='bash abnahme.sh'
ABNAHME_DATEIEN=(abnahme.sh)
PLAN_DATEI=projekt/plan.md
GESPERRT=(plan.md)
ERLAUBT='^(checks\.txt|code\.txt|rot|plan\.md|TASKS\.md|BLOCKED\.md|ENTSCHEIDUNGEN\.md)$'
VERBOTEN_INHALT='VERBOTEN'
FUEHRERSCHEIN_AB=2
STILLSTAND=1
EOF
s=$FAKE_DIR/schritte
echo "echo check >>checks.txt; $haken"                          >"$s/1.sh"   # angenommen (Stillstand: Abnahme bleibt 0)
echo "echo check >>checks.txt"                                  >"$s/2.sh"   # nicht abgehakt
echo "$haken"                                                   >"$s/3.sh"   # ohne neue Prüfung
echo "echo check >>checks.txt; echo x >>abnahme.sh; $haken"     >"$s/4.sh"   # Abnahme-Datei: außerhalb ERLAUBT
echo "echo check >>checks.txt; echo x >>plan.md; $haken"        >"$s/5.sh"   # Plan-Datei: erlaubt, aber gesperrt
echo "echo check >>checks.txt; echo VERBOTEN >code.txt; $haken" >"$s/6.sh"   # verbotener Inhalt
echo "echo check >>checks.txt; echo \"echo 'PRUEFUNGEN: 99'\" >code.txt; $haken" >"$s/7.sh"  # fälscht die Zählzeile
echo "echo check >>checks.txt; mv geheim.txt code.txt; $haken"  >"$s/8.sh"   # Umbenennung: fremde Datei weg
echo "echo check >>checks.txt; $haken"                          >"$s/9.sh"   # Gutachter lehnt ab
echo "echo check >>checks.txt; $haken"                          >"$s/10.sh"  # … zweimal: blockiert
echo "sed -i 1d checks.txt; $haken"                             >"$s/11.sh"  # Prüfungen gesunken
echo "echo check >>checks.txt; touch rot; $haken"               >"$s/12.sh"  # Prüfung rot
echo "printf 'check ziel\nziel\n' >>checks.txt; $haken"         >"$s/13.sh"  # Abnahme 2 von 2
echo "echo check >>checks.txt; $haken"                          >"$s/14.sh"
echo "echo check >>checks.txt; $haken"                          >"$s/15.sh"
echo "printf '[core]\n\tfsmonitor = touch $T/boese\n' >>.git/config; echo check >>checks.txt; $haken" >"$s/16.sh"  # .git-Eingriff
printf 'URTEIL: ANNEHMEN\nURTEIL: ABLEHNEN: zu dünn\nURTEIL: ABLEHNEN: zu dünn\nURTEIL: ANNEHMEN\nURTEIL: ANNEHMEN\nURTEIL: ANNEHMEN\n' >"$FAKE_DIR/urteile"
export AUTOPILOT_CONF="$T/autopilot.conf"

"$WERKZEUG/menu.sh" status >/dev/null 2>&1; [ $? = 4 ] || fehlschlag "nicht bestätigte Konfiguration wurde geladen"
"$WERKZEUG/menu.sh" vertrauen "$T/autopilot.conf" >/dev/null || fehlschlag "vertrauen fehlgeschlagen"
"$WERKZEUG/autopilot.sh" >/dev/null 2>&1 && fehlschlag "Start ohne Freigabe nicht verweigert"
grep -q "nicht freigegeben" "$T/.autopilot/log/verlauf.txt" || fehlschlag "keine Meldung zur fehlenden Freigabe"
[ -f "$FAKE_DIR/schritt-nr" ] && fehlschlag "Claude wurde trotz fehlender Freigabe gestartet"
"$WERKZEUG/menu.sh" start 5 gpt >/dev/null && fehlschlag "ungültiges Modell angenommen"
"$WERKZEUG/menu.sh" freigeben >/dev/null || fehlschlag "freigeben fehlgeschlagen"
"$WERKZEUG/autopilot.sh" >"$T/ausgabe.txt" 2>&1 || fehlschlag "Lauf endete mit Fehler: $(tail -3 "$T/ausgabe.txt")"

v=$T/.autopilot/log/verlauf.txt
for erwartet in "Ziel erreicht" "keine Aufgabe abgehakt" "ohne neue Prüfung" "außerhalb erlaubter Pfade: abnahme.sh" \
                "gesperrte Datei geändert: plan.md" "verbotener Inhalt" "Gutachter: zu dünn" "Aufgabe blockiert" \
                "von 2 auf 1 gesunken" "Prüfung rot" "Stillstand" "Führerschein für Aufgabenart „rand“" \
                "Zählzeile des Prüfbefehls" "außerhalb erlaubter Pfade: geheim.txt"; do
    grep -q "$erwartet" "$v" || fehlschlag "im Verlauf fehlt: $erwartet"
done
[ "$(grep -c '^- \[x\]' TASKS.md)" = 4 ] && grep -q '^- \[~\] 2\.' TASKS.md || fehlschlag "Aufgabenliste falsch: $(tr '\n' ' ' <TASKS.md)"
[ "$(git log --oneline | wc -l)" = 6 ] || fehlschlag "erwartet 6 Commits: $(git log --oneline | tr '\n' '|')"
git diff --quiet main -- abnahme.sh plan.md || fehlschlag "gesperrte Datei wurde geändert"
[ -z "$(git status --porcelain)" ] || fehlschlag "Arbeitsordner nicht sauber: $(git status --porcelain)"
[ ! -e code.txt ] && [ ! -e rot ] || fehlschlag "verworfene Änderungen liegen noch herum"
grep -qx 3 "$FAKE_DIR/mit-rueckmeldung" && ! grep -qx 1 "$FAKE_DIR/mit-rueckmeldung" || fehlschlag "Rückmeldung nicht (nur) nach Ablehnung weitergegeben"
grep -qx 1 "$FAKE_DIR/mit-plan" || fehlschlag "Plan wurde dem Umsetzer nicht mitgegeben"
grep -q ";angenommen;.*;0.0200;" "$T/.autopilot/log/fortschritt.csv" || fehlschlag "Kosten (Umsetzer + Gutachter) fehlen in der CSV"
"$WERKZEUG/menu.sh" noten | grep -q "^kern" || fehlschlag "Notentafel ohne Art „kern“"
"$WERKZEUG/menu.sh" kosten | grep -q "Durchläufe gesamt: 0.21 USD" || fehlschlag "Kostenübersicht falsch: $("$WERKZEUG/menu.sh" kosten | head -1)"
"$WERKZEUG/menu.sh" status | grep -q "4 erledigt, 0 offen, 1 blockiert" || fehlschlag "Status falsch"
"$WERKZEUG/menu.sh" ergebnis | grep -q "Autopilot: \[x\] 5. \[rand\] fünf" || fehlschlag "Ergebnis falsch"
k=$("$WERKZEUG/menu.sh" kurve) && grep -q "<svg" "$k" || fehlschlag "Kurve nicht erzeugt"
grep -qx "Datei des Nutzers" geheim.txt || fehlschlag "fremde Datei über Umbenennung verloren"
# Eingriff in .git/config (fsmonitor würde beim nächsten git status Code ausführen): sofort anhalten
printf -- '- [ ] 6. [rand] sechs\n' >>TASKS.md && git add -A && git commit -qm "neue Aufgabe"
"$WERKZEUG/autopilot.sh" >/dev/null 2>&1 && fehlschlag "Änderung an .git/config nicht bemerkt"
grep -q "hat .git (config, info oder hooks) verändert" "$v" || fehlschlag "keine Meldung zur .git-Änderung"
[ ! -e "$T/boese" ] || fehlschlag "Code aus .git/config wurde ausgeführt"
unset AUTOPILOT_CONF

# ======== Teil B: Vorhaben aus Plan-Datei, Sicherheitsfilter, Fahrschule, Planer, Bericht ========
neue_runde
probeprojekt "$T/p2"
plan="$T/p2/Plan 'x' \$(touch ausgeloest).md"   # Dateiname mit eingeschleustem Befehl
printf '# Zählwerk\nEs soll gezählt werden.\n' >"$plan"
git add -A && git commit -qm start
cat >"$FAKE_DIR/einrichten.txt" <<'EOF'
Ich habe mir das Projekt angesehen.
===KONF===
PRUEFEN='bash pruefe.sh'
PRUEF_ZAEHLER='grep -o "PRUEFUNGEN: [0-9]*" | grep -o "[0-9]*"'
ERLAUBT='^checks\.txt$'
UMSETZER_WERKZEUGE=(Read Edit 'Bash(bash pruefe.sh:*)')
UMSETZER_WERKZEUGE=(Read Bash)
UMSETZER_WERKZEUGE=(Read 'Bash(*)')
PRUEF_ZAHL='(.*) passed'
rm -rf "$HOME"
PRUEFEN2=$(touch /tmp/eingeschleust)
ERLAUBT='.'; touch /tmp/eingeschleust
===AUFGABEN===
# Aufgaben: Zählwerk
Nur checks.txt ändern.

- [ ] 1. [neu] eins. Fertig, wenn eine Prüfung mehr besteht.
EOF
"$WERKZEUG/menu.sh" plan "$plan" >"$T/entwurf.txt" 2>&1 || fehlschlag "Entwurf fehlgeschlagen: $(tail -3 "$T/entwurf.txt")"
grep -q "rm -rf" "$T/entwurf.txt" && grep -q "Aus Sicherheitsgründen nicht übernommen" "$T/entwurf.txt" || fehlschlag "gefährliche Zeilen nicht als verworfen gemeldet"
[ ! -e "$T/p2-autopilot" ] || fehlschlag "Entwurf hat schon eingerichtet"
"$WERKZEUG/menu.sh" plan annehmen >/dev/null || fehlschlag "Annehmen fehlgeschlagen"
konf=$T/p2/autopilot.conf
grep -q "rm -rf\|PRUEFEN2\|eingeschleust\|(Read Bash)\|Bash(\*)\|(\.\*) passed" "$konf" && fehlschlag "gefährliche Zeile in die Konfiguration übernommen: $(cat "$konf")"
( . "$konf"; [ "$PLAN_DATEI" = "$plan" ] && [ "${GESPERRT[0]}" = "${plan#"$T/p2/"}" ] ) || fehlschlag "Plan nicht korrekt eingetragen"
[ -z "$(find "$T" -name ausgeloest)" ] || fehlschlag "Befehl aus dem Dateinamen wurde ausgeführt"
grep -q "^PRUEF_ZAEHLER=" "$konf" || fehlschlag "PRUEF_ZAEHLER nicht übernommen"
[ "$(readlink -f "$T/config/autopilot-loop/standard.conf")" = "$konf" ] || fehlschlag "standard.conf zeigt nicht auf das neue Vorhaben"
[ -f "$T/p2-autopilot/AUTOPILOT-AUFGABEN.md" ] || fehlschlag "Aufgabenliste nicht im Arbeitszweig"
git -C "$T/p2" status --porcelain | grep -q . && fehlschlag "Projekt durch Statusdateien verschmutzt: $(git -C "$T/p2" status --porcelain)"
echo "FAHRSCHULE=an" >>"$konf"
"$WERKZEUG/menu.sh" status >/dev/null 2>&1; [ $? = 4 ] || fehlschlag "geänderte Konfiguration ohne neue Bestätigung geladen"
"$WERKZEUG/menu.sh" vertrauen "$konf" >/dev/null || fehlschlag "erneutes Vertrauen fehlgeschlagen"

mkdir -p "$T/woanders" && cd "$T/woanders" || exit 1   # ab jetzt ohne Pfadangabe: standard.conf
echo "echo check >>checks.txt; sed -i '0,/^- \[ \]/s//- [x]/' AUTOPILOT-AUFGABEN.md" >"$FAKE_DIR/schritte/1.sh"
echo "URTEIL: ANNEHMEN" >"$FAKE_DIR/urteile"
"$WERKZEUG/autopilot.sh" >"$T/ausgabe2.txt" 2>&1 &
for _ in $(seq 1 40); do [ -e "$T/p2/.autopilot/WARTET" ] && break; sleep 0.5; done
[ -e "$T/p2/.autopilot/WARTET" ] || fehlschlag "Fahrschule wartet nicht auf das OK"
"$WERKZEUG/menu.sh" status | grep -q "WARTET auf dein OK" || fehlschlag "Status zeigt das Warten nicht"
"$WERKZEUG/menu.sh" weiter | grep -q "OK gegeben" || fehlschlag "weiter fehlgeschlagen"
wait $! || fehlschlag "Lauf nach der Fahrstunde mit Fehler beendet: $(tail -3 "$T/ausgabe2.txt")"
grep -q "Ziel erreicht" "$T/p2/.autopilot/log/verlauf.txt" || fehlschlag "Vorhaben nicht abgeschlossen"

printf -- '- [ ] 2. [neu] zwei. Fertig, wenn zwei Prüfungen mehr bestehen.\nKein gültiger Satz\n- [ ] 3. ohne Kriterium\n' >"$FAKE_DIR/planer.txt"
"$WERKZEUG/menu.sh" planen | grep -q "1 Aufgaben vorgeschlagen" || fehlschlag "Planer-Vorschlag nicht gefiltert"
"$WERKZEUG/menu.sh" vorschlag annehmen | grep -q "übernommen" || fehlschlag "Vorschlag nicht übernommen"
grep -q '^- \[ \] 2\. \[neu\] zwei' "$T/p2-autopilot/AUTOPILOT-AUFGABEN.md" || fehlschlag "Vorschlag fehlt in der Aufgabenliste"
echo "Kurzbericht: alles gut." >"$FAKE_DIR/bericht.txt"
"$WERKZEUG/menu.sh" bericht | grep -q "Kurzbericht: alles gut" || fehlschlag "Bericht falsch"
[ -z "$("$WERKZEUG/menu.sh" status --kurz)" ] || fehlschlag "Statuszeile zeigt etwas, obwohl nichts läuft"
[ -z "$(find "$T" -name ausgeloest)" ] || fehlschlag "Befehl aus dem Dateinamen wurde später beim Laden ausgeführt"
echo ok
