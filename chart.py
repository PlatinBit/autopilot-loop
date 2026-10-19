#!/usr/bin/env python3
"""Progress chart: reads .autopilot/log/progress.csv (+ grades.csv) and writes .autopilot/chart.html.
Usage: chart.py <state-dir> <name> [target]   (normally via `autopilot chart`)"""
import csv, html, sys
from collections import defaultdict
from pathlib import Path


def read_csv(path):
    try:
        with open(path, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f, delimiter=";"))
    except FileNotFoundError:
        return []


def polyline(values, colour, width, height, margin, top):
    """Polyline for a series of values; None values are skipped."""
    points = [(i, v) for i, v in enumerate(values) if v is not None]
    if not points:
        return "", []
    n = max(len(values) - 1, 1)
    xy = [(margin + i * (width - 2 * margin) / n, height - margin - v * (height - 2 * margin) / top) for i, v in points]
    path = " ".join(f"{x:.1f},{y:.1f}" for x, y in xy)
    return f'<polyline points="{path}" fill="none" stroke="{colour}" stroke-width="2"/>', xy


def diagram(title, values, results, target=None, width=760, height=220, margin=36):
    top = max([v for v in values if v is not None] + [target or 0, 1])
    parts = [f'<svg viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(title)}">',
             f'<line x1="{margin}" y1="{height - margin}" x2="{width - margin}" y2="{height - margin}" class="axis"/>',
             f'<text x="{margin}" y="{margin - 12}" class="label">{html.escape(title)} (max {top})</text>']
    if target:
        y = height - margin - target * (height - 2 * margin) / top
        parts.append(f'<line x1="{margin}" y1="{y:.1f}" x2="{width - margin}" y2="{y:.1f}" class="target"/>'
                     f'<text x="{width - margin}" y="{y - 4:.1f}" class="label" text-anchor="end">Target {target}</text>')
    line, xy = polyline(values, "var(--line)", width, height, margin, top)
    parts.append(line)
    present = [i for i, v in enumerate(values) if v is not None]
    for (x, y), i in zip(xy, present):
        cls = "good" if results[i] == "accepted" else "bad"
        parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.5" class="{cls}"><title>Run {i + 1}: {results[i]}, {values[i]}</title></circle>')
    parts.append("</svg>")
    return "".join(parts)


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def main():
    state, name = Path(sys.argv[1]), sys.argv[2]
    target = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else None
    rows = read_csv(state / "log" / "progress.csv")
    if not rows:
        print("No runs recorded yet.")
        return 1
    results = [r["result"] for r in rows]
    tests = [number(r["tests"]) for r in rows]
    accept = [number(r.get("accept")) for r in rows]
    cost = sum(number(r.get("cost_usd")) or 0 for r in rows)
    cost += sum(number(r.get("cost")) or 0 for r in read_extra(state / "log" / "costs-extra.csv"))
    accepted = results.count("accepted")

    grades = defaultdict(list)
    for r in read_grades(state / "grades.csv"):
        grades[r[1]].append(int(r[2]))
    table = "".join(
        f"<tr><td>{html.escape(kind)}</td><td>{len(g[-20:])}</td><td>{100 * sum(g[-20:]) // len(g[-20:])} %</td>"
        f"<td>{'yes' if (state / 'licence' / kind).exists() else 'no'}</td></tr>" for kind, g in sorted(grades.items()))

    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Autopilot {html.escape(name)}</title><style>
:root {{ --text:#1d1d1f; --bg:#fbfbfa; --line:#3a6ea5; --good:#2e8b57; --bad:#c0392b; --muted:#8a8a8a; }}
@media (prefers-color-scheme: dark) {{ :root {{ --text:#ececec; --bg:#1c1c1e; --line:#7fb0e0; --good:#5cc98a; --bad:#ef7a6c; --muted:#9a9a9a; }} }}
body {{ font: 15px/1.5 system-ui, sans-serif; color: var(--text); background: var(--bg); max-width: 800px; margin: 24px auto; padding: 0 16px; }}
svg {{ width: 100%; height: auto; margin: 8px 0 20px; }}
.axis {{ stroke: var(--muted); }} .target {{ stroke: var(--good); stroke-dasharray: 4 4; }}
.label {{ fill: var(--muted); font-size: 12px; }} .good {{ fill: var(--good); }} .bad {{ fill: var(--bad); }}
table {{ border-collapse: collapse; }} td, th {{ padding: 4px 12px; border-bottom: 1px solid var(--muted); text-align: left; }}
</style></head><body>
<h1>Autopilot – {html.escape(name)}</h1>
<p>{len(rows)} runs, {accepted} of them accepted ({100 * accepted // len(rows)} %), cost approx. {cost:.2f} USD.
Points: <span style="color:var(--good)">accepted</span>, <span style="color:var(--bad)">rejected</span>.</p>
{diagram("Passed tests", tests, results)}
{diagram("Acceptance: met conditions", accept, results, target) if any(a for a in accept if a) or target else ""}
<h2>Grades</h2><table><tr><th>Kind</th><th>Grades (last 20)</th><th>Rate</th><th>Licence</th></tr>{table or '<tr><td colspan=4>none yet</td></tr>'}</table>
</body></html>"""
    out = state / "chart.html"
    out.write_text(page, encoding="utf-8")
    print(out)
    return 0


def read_extra(path):
    try:
        return [{"cost": z.split(";")[2]} for z in path.read_text(encoding="utf-8").splitlines() if z.count(";") >= 2]
    except FileNotFoundError:
        return []


def read_grades(path):
    try:
        return [z.split(";") for z in path.read_text(encoding="utf-8").splitlines() if z.count(";") == 2]
    except FileNotFoundError:
        return []


if __name__ == "__main__":
    sys.exit(main())
