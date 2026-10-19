# Regeln für den Autopiloten

(Vorlage – an das Projekt anpassen und in den Arbeitsordner legen.)

## Arbeitsfeld
- Du arbeitest nur in den Ordnern, die `ERLAUBT` in autopilot.conf freigibt, dazu Aufgabenliste, BLOCKED.md und ENTSCHEIDUNGEN.md. Andere Pfade lässt das Skript den Durchlauf verwerfen.

## Prüfer
- Der Prüfbefehl muss grün sein. Jede Aufgabe bekommt Prüfungen, die ihr Abnahmekriterium abdecken.
- Prüfungen werden nie gelöscht, gelockert oder umgangen. Das Skript zählt sie und verwirft den Durchlauf, wenn die Zahl sinkt.
- Nach deinem Durchlauf prüft das Skript selbst noch einmal und committet nur dann. Git brauchst du nicht.

## Abnahmetest (falls eingerichtet)
- Gesperrt: nie ändern. Er darf rot sein, aber die Zahl erfüllter Bedingungen darf durch deine Änderung nie sinken.
- Attrappen, die nur den Test bedienen (feste Zahlen, Sonderfälle für Testwerte), sind verboten; ein Gutachter prüft genau das.

## Gutachter
Nach dem Skript liest eine zweite Claude-Sitzung deine Änderung und lehnt ab, wenn Prüfungen das Kriterium nicht wirklich belegen. Lehnt sie ab, bekommst du im nächsten Durchlauf ihre Begründung als Rückmeldung.

## Stil
- Wenig Code, keine Abstraktion auf Vorrat, keine neuen Abhängigkeiten ohne Grund.

## Entscheidungen
Lässt eine Aufgabe eine Einzelheit offen, entscheide selbst, einfach und einstellbar, und schreib es als eine Zeile in ENTSCHEIDUNGEN.md (Datum, Aufgabe, was, warum).
