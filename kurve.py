#!/usr/bin/env python3
"""Fortschrittskurve: liest .autopilot/log/fortschritt.csv (+ noten.csv) und schreibt .autopilot/kurve.html.
Aufruf: kurve.py <zustandsordner> <name> [ziel]   (normalerweise über `autopilot kurve`)"""
import csv, html, sys
from collections import defaultdict
from pathlib import Path


def lies(pfad):
    try:
        with open(pfad, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f, delimiter=";"))
    except FileNotFoundError:
        return []


def linie(werte, farbe, breite, hoehe, rand, oben):
    """Polyline für eine Wertereihe; None-Werte werden übersprungen."""
    punkte = [(i, w) for i, w in enumerate(werte) if w is not None]
    if not punkte:
        return "", []
    n = max(len(werte) - 1, 1)
    xy = [(rand + i * (breite - 2 * rand) / n, hoehe - rand - w * (hoehe - 2 * rand) / oben) for i, w in punkte]
    pfad = " ".join(f"{x:.1f},{y:.1f}" for x, y in xy)
    return f'<polyline points="{pfad}" fill="none" stroke="{farbe}" stroke-width="2"/>', xy


def diagramm(titel, werte, ergebnisse, ziel=None, breite=760, hoehe=220, rand=36):
    oben = max([w for w in werte if w is not None] + [ziel or 0, 1])
    teile = [f'<svg viewBox="0 0 {breite} {hoehe}" role="img" aria-label="{html.escape(titel)}">',
             f'<line x1="{rand}" y1="{hoehe - rand}" x2="{breite - rand}" y2="{hoehe - rand}" class="achse"/>',
             f'<text x="{rand}" y="{rand - 12}" class="beschriftung">{html.escape(titel)} (höchstens {oben})</text>']
    if ziel:
        y = hoehe - rand - ziel * (hoehe - 2 * rand) / oben
        teile.append(f'<line x1="{rand}" y1="{y:.1f}" x2="{breite - rand}" y2="{y:.1f}" class="ziel"/>'
                     f'<text x="{breite - rand}" y="{y - 4:.1f}" class="beschriftung" text-anchor="end">Ziel {ziel}</text>')
    zug, xy = linie(werte, "var(--linie)", breite, hoehe, rand, oben)
    teile.append(zug)
    gesetzt = [i for i, w in enumerate(werte) if w is not None]
    for (x, y), i in zip(xy, gesetzt):
        klasse = "gut" if ergebnisse[i] == "angenommen" else "schlecht"
        teile.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.5" class="{klasse}"><title>Durchlauf {i + 1}: {ergebnisse[i]}, {werte[i]}</title></circle>')
    teile.append("</svg>")
    return "".join(teile)


def zahl(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def main():
    zustand, name = Path(sys.argv[1]), sys.argv[2]
    ziel = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else None
    zeilen = lies(zustand / "log" / "fortschritt.csv")
    if not zeilen:
        print("Noch keine Durchläufe aufgezeichnet.")
        return 1
    ergebnisse = [z["ergebnis"] for z in zeilen]
    pruef = [zahl(z["pruefungen"]) for z in zeilen]
    abn = [zahl(z.get("abnahme")) for z in zeilen]
    kosten = sum(zahl(z.get("kosten_usd")) or 0 for z in zeilen)
    kosten += sum(zahl(z.get("kosten")) or 0 for z in lies_extra(zustand / "log" / "kosten-extra.csv"))
    angenommen = ergebnisse.count("angenommen")

    noten = defaultdict(list)
    for z in lies_noten(zustand / "noten.csv"):
        noten[z[1]].append(int(z[2]))
    tafel = "".join(
        f"<tr><td>{html.escape(art)}</td><td>{len(n[-20:])}</td><td>{100 * sum(n[-20:]) // len(n[-20:])} %</td>"
        f"<td>{'ja' if (zustand / 'fuehrerschein' / art).exists() else 'nein'}</td></tr>" for art, n in sorted(noten.items()))

    seite = f"""<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Autopilot {html.escape(name)}</title><style>
:root {{ --text:#1d1d1f; --grund:#fbfbfa; --linie:#3a6ea5; --gut:#2e8b57; --schlecht:#c0392b; --leise:#8a8a8a; }}
@media (prefers-color-scheme: dark) {{ :root {{ --text:#ececec; --grund:#1c1c1e; --linie:#7fb0e0; --gut:#5cc98a; --schlecht:#ef7a6c; --leise:#9a9a9a; }} }}
body {{ font: 15px/1.5 system-ui, sans-serif; color: var(--text); background: var(--grund); max-width: 800px; margin: 24px auto; padding: 0 16px; }}
svg {{ width: 100%; height: auto; margin: 8px 0 20px; }}
.achse {{ stroke: var(--leise); }} .ziel {{ stroke: var(--gut); stroke-dasharray: 4 4; }}
.beschriftung {{ fill: var(--leise); font-size: 12px; }} .gut {{ fill: var(--gut); }} .schlecht {{ fill: var(--schlecht); }}
table {{ border-collapse: collapse; }} td, th {{ padding: 4px 12px; border-bottom: 1px solid var(--leise); text-align: left; }}
</style></head><body>
<h1>Autopilot – {html.escape(name)}</h1>
<p>{len(zeilen)} Durchläufe, davon {angenommen} angenommen ({100 * angenommen // len(zeilen)} %), Kosten ca. {kosten:.2f} USD.
Punkte: <span style="color:var(--gut)">angenommen</span>, <span style="color:var(--schlecht)">verworfen</span>.</p>
{diagramm("Bestandene Prüfungen", pruef, ergebnisse)}
{diagramm("Abnahme: erfüllte Bedingungen", abn, ergebnisse, ziel) if any(a for a in abn if a) or ziel else ""}
<h2>Notentafel</h2><table><tr><th>Art</th><th>Noten (letzte 20)</th><th>Quote</th><th>Führerschein</th></tr>{tafel or '<tr><td colspan=4>noch keine</td></tr>'}</table>
</body></html>"""
    ziel_datei = zustand / "kurve.html"
    ziel_datei.write_text(seite, encoding="utf-8")
    print(ziel_datei)
    return 0


def lies_extra(pfad):
    try:
        return [{"kosten": z.split(";")[2]} for z in pfad.read_text(encoding="utf-8").splitlines() if z.count(";") >= 2]
    except FileNotFoundError:
        return []


def lies_noten(pfad):
    try:
        return [z.split(";") for z in pfad.read_text(encoding="utf-8").splitlines() if z.count(";") == 2]
    except FileNotFoundError:
        return []


if __name__ == "__main__":
    sys.exit(main())
