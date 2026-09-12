#!/usr/bin/env python3
"""Draws the state of the version's branches as a page you can look at.

`git log --graph` already exists and is already correct; what it is not is
scannable. The question this answers is the one asked while deciding what to do
next — what is on dev, what is on debug, how far either has drifted from the
version branch, and whether the version is ready to close — and that is four
numbers and a shape, not eighty lines of ASCII.

Reads the repository and writes `.build/board.html`. Nothing is cached: the
board is the repository, or it is worth nothing.

    python3 Scripts/board.py            # write and open
    python3 Scripts/board.py --no-open  # just write
"""

from __future__ import annotations

import html
import re
import subprocess
import sys
import webbrowser
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / ".build" / "board.html"
MAX_COMMITS = 40

# One colour per lane, reused round the ring. Deliberately not one colour per
# branch: a lane is where a commit sits, and a branch is a label on a commit.
LANE_COLOURS = [
    "#3b82f6", "#a855f7", "#14b8a6", "#f59e0b",
    "#ec4899", "#22c55e", "#6366f1", "#ef4444",
]


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


@dataclass
class Commit:
    sha: str
    parents: list[str]
    refs: list[str]
    subject: str
    author: str
    when: str
    lane: int = 0
    edges: list[tuple[int, int]] = field(default_factory=list)


def current_version() -> str | None:
    """The version branch this checkout belongs to.

    Taken from the branch name rather than from the app's Info.plist: which
    version you are working on is a fact about the repository, and the plist
    is one of the things a version changes.
    """
    head = git("rev-parse", "--abbrev-ref", "HEAD")
    match = re.match(r"^(?:dev/|debug/)?(v\d+\.\d+\.\d+)$", head)
    if match:
        return match.group(1)
    versions = [b for b in branches() if re.fullmatch(r"v\d+\.\d+\.\d+", b)]
    return sorted(versions)[-1] if versions else None


def branches() -> list[str]:
    return git("for-each-ref", "--format=%(refname:short)", "refs/heads").splitlines()


def counts(left: str, right: str) -> tuple[int, int]:
    """How far apart two branches are, in commits: (behind, ahead)."""
    try:
        behind, ahead = git("rev-list", "--left-right", "--count", f"{left}...{right}").split()
        return int(behind), int(ahead)
    except subprocess.CalledProcessError:
        return 0, 0


def history(refs: list[str]) -> list[Commit]:
    if not refs:
        return []
    raw = git(
        "log", "--topo-order", f"--max-count={MAX_COMMITS}",
        "--pretty=format:%H\x1f%P\x1f%D\x1f%s\x1f%an\x1f%ad",
        "--date=format:%Y-%m-%d",
        *refs,
    )
    commits = []
    for line in raw.splitlines():
        sha, parents, refnames, subject, author, when = line.split("\x1f")
        names = [
            r.strip().replace("HEAD -> ", "")
            for r in refnames.split(",") if r.strip() and "HEAD" != r.strip()
        ]
        commits.append(Commit(
            sha=sha, parents=parents.split() if parents else [],
            refs=names, subject=subject, author=author, when=when,
        ))
    return commits


def assign_lanes(commits: list[Commit]) -> int:
    """Puts each commit in a column, the way a graph viewer does.

    A lane is a chain waiting for a particular commit. Each commit takes the
    lane that was waiting for it (or opens a new one), then leaves its first
    parent waiting in that same lane so a straight line of history stays a
    straight line. Its other parents — a merge — go wherever there is room,
    and the pair is recorded as an edge so the drawing can join them.
    """
    lanes: list[str | None] = []
    for commit in commits:
        try:
            lane = lanes.index(commit.sha)
        except ValueError:
            lane = next((i for i, l in enumerate(lanes) if l is None), len(lanes))
            if lane == len(lanes):
                lanes.append(None)
        commit.lane = lane
        lanes[lane] = commit.parents[0] if commit.parents else None

        for parent in commit.parents[1:]:
            if parent in lanes:
                target = lanes.index(parent)
            else:
                target = next((i for i, l in enumerate(lanes) if l is None), len(lanes))
                if target == len(lanes):
                    lanes.append(None)
                lanes[target] = parent
            commit.edges.append((commit.lane, target))

        # A lane nobody is waiting on any more is free for the next branch.
        for i, waiting in enumerate(lanes):
            if waiting is not None and waiting not in {c.sha for c in commits}:
                continue
        if not commit.parents:
            lanes[lane] = None
    return max((c.lane for c in commits), default=0) + 1


ROW = 30
LANE_W = 18
GRAPH_LEFT = 16


def draw(commits: list[Commit], lane_count: int) -> str:
    """The graph as SVG, one row per commit."""
    width = GRAPH_LEFT * 2 + lane_count * LANE_W
    height = len(commits) * ROW + 12
    rows = {c.sha: i for i, c in enumerate(commits)}
    parts = []

    def x(lane: int) -> float:
        return GRAPH_LEFT + lane * LANE_W

    def y(row: int) -> float:
        return 16 + row * ROW

    for index, commit in enumerate(commits):
        colour = LANE_COLOURS[commit.lane % len(LANE_COLOURS)]
        for parent in commit.parents:
            if parent not in rows:
                continue
            target = commits[rows[parent]]
            x1, y1 = x(commit.lane), y(index)
            x2, y2 = x(target.lane), y(rows[parent])
            edge_colour = LANE_COLOURS[target.lane % len(LANE_COLOURS)]
            if commit.lane == target.lane:
                parts.append(
                    f'<path d="M{x1},{y1} L{x2},{y2}" stroke="{edge_colour}" '
                    f'stroke-width="2" fill="none"/>'
                )
            else:
                mid = y1 + ROW * 0.6
                parts.append(
                    f'<path d="M{x1},{y1} C{x1},{mid} {x2},{mid} {x2},{y2}" '
                    f'stroke="{edge_colour}" stroke-width="2" fill="none"/>'
                )
        merge = len(commit.parents) > 1
        parts.append(
            f'<circle cx="{x(commit.lane)}" cy="{y(index)}" r="{5 if merge else 4}" '
            f'fill="{"var(--bg)" if merge else colour}" stroke="{colour}" stroke-width="2"/>'
        )
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">' + "".join(parts) + "</svg>", width


def ref_chip(name: str) -> str:
    kind = (
        "dev" if name.startswith("dev/")
        else "debug" if name.startswith("debug/")
        else "main" if name == "main"
        else "version" if re.fullmatch(r"v\d+\.\d+\.\d+", name)
        else "other"
    )
    return f'<span class="chip {kind}">{html.escape(name)}</span>'


def card(title: str, branch: str, base: str | None, note: str, kind: str) -> str:
    if branch not in branches():
        return (
            f'<div class="card missing"><h3>{html.escape(title)}</h3>'
            f'<p class="empty">아직 없다</p></div>'
        )
    subject = git("log", "-1", "--pretty=%s", branch)
    when = git("log", "-1", "--pretty=%ad", "--date=format:%Y-%m-%d %H:%M", branch)
    line = ""
    if base and base in branches():
        behind, ahead = counts(base, branch)
        state = (
            f'<span class="ahead">앞선 커밋 {ahead}개</span>' if ahead else
            '<span class="level">합쳐져 있음</span>'
        )
        if behind:
            state += f' · <span class="behind">뒤처진 커밋 {behind}개</span>'
        line = f'<p class="counts">{base} 대비 {state}</p>'
    return (
        f'<div class="card {kind}">'
        f'<h3>{html.escape(title)} {ref_chip(branch)}</h3>'
        f'{line}'
        f'<p class="subject">{html.escape(subject)}</p>'
        f'<p class="when">{html.escape(when)} · {html.escape(note)}</p>'
        f"</div>"
    )


def main() -> int:
    version = current_version()
    if version is None:
        print("No version branch (vX.Y.Z) found. See the branch rules in CLAUDE.md.")
        return 1

    dev, debug = f"dev/{version}", f"debug/{version}"
    head = git("rev-parse", "--abbrev-ref", "HEAD")
    known = branches()
    refs = [b for b in (version, dev, debug, "main") if b in known]

    commits = history(refs)
    lane_count = assign_lanes(commits)
    graph, graph_width = draw(commits, lane_count)

    closed = version in known and counts("main", version)[1] == 0
    ready = (
        version in known
        and counts(version, dev)[1] == 0
        and counts(version, debug)[1] == 0
    )
    status = (
        ("닫힘", "main에 들어갔다.") if closed else
        ("합칠 준비됨", "dev와 debug가 모두 버전 가지에 들어와 있다. main으로 닫을 수 있다.") if ready else
        ("작업 중", "dev나 debug에 아직 버전 가지로 오지 않은 커밋이 있다.")
    )

    rows = []
    for index, commit in enumerate(commits):
        shown = commit.refs[:2]
        chips = "".join(ref_chip(r) for r in shown)
        if len(commit.refs) > len(shown):
            chips += f'<span class="chip other">+{len(commit.refs) - len(shown)}</span>'
        rows.append(
            f'<tr><td class="sha">{commit.sha[:7]}</td>'
            f'<td class="refs">{chips}</td>'
            f'<td class="subject">{html.escape(commit.subject)}</td>'
            f'<td class="when">{html.escape(commit.when)}</td></tr>'
        )

    page = TEMPLATE.format(
        version=html.escape(version),
        head=ref_chip(head),
        status=html.escape(status[0]),
        status_note=html.escape(status[1]),
        status_kind="closed" if closed else "ready" if ready else "open",
        cards="".join([
            card("이번 버전", version, "main", "main에서 갈라져 나온 가지", "version"),
            card("새 기능", dev, version, "기능은 여기서 쓴다", "dev"),
            card("오류 수정", debug, version, "고치는 일은 여기서 한다", "debug"),
            card("배포", "main", None, "닫힌 버전만 들어온다", "main"),
        ]),
        graph=graph,
        graph_width=graph_width,
        rows="".join(rows),
        count=len(commits),
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(page, encoding="utf-8")
    print(f"{OUT}  ({version} · {status[0]})")
    if "--no-open" not in sys.argv:
        webbrowser.open(OUT.as_uri())
    return 0


TEMPLATE = """<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<title>Paper Time · {version}</title>
<style>
:root {{
  --bg: #f6f7f9; --panel: #fff; --ink: #14161a; --muted: #6b7280; --faint: #9ca3af;
  --line: rgba(0,0,0,.07);
  --dev: #3b82f6; --debug: #f59e0b; --version: #a855f7; --main: #22c55e;
}}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg:#15171b; --panel:#1d2025; --ink:#e8eaed; --muted:#9aa1ab; --faint:#6b7280;
          --line: rgba(255,255,255,.09); }}
}}
* {{ box-sizing: border-box; }}
body {{ margin:0; padding:34px 30px 60px; background:var(--bg); color:var(--ink);
  font:14px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }}
h1 {{ font-size:26px; margin:0 0 2px; letter-spacing:-.02em; }}
.sub {{ color:var(--muted); margin:0 0 22px; }}
.status {{ display:inline-block; padding:3px 10px; border-radius:999px; font-size:12px;
  font-weight:600; margin-left:8px; vertical-align:3px; }}
.status.open {{ background:rgba(245,158,11,.16); color:#b45309; }}
.status.ready {{ background:rgba(34,197,94,.16); color:#15803d; }}
.status.closed {{ background:rgba(107,114,128,.16); color:var(--muted); }}
.cards {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:14px;
  margin-bottom:30px; }}
.card {{ background:var(--panel); border-radius:14px; padding:14px 16px;
  box-shadow:0 1px 2px rgba(0,0,0,.05), 0 6px 18px rgba(0,0,0,.04); }}
.card h3 {{ font-size:13px; margin:0 0 8px; font-weight:600; color:var(--muted); }}
.card .subject {{ margin:6px 0 4px; font-weight:500; }}
.card .when, .card .counts {{ margin:0; font-size:12px; color:var(--faint); }}
.card .counts {{ margin-bottom:6px; }}
.card.missing .empty {{ color:var(--faint); margin:0; }}
.ahead {{ color:#b45309; font-weight:600; }}
.behind {{ color:#b91c1c; }}
.level {{ color:#15803d; font-weight:600; }}
.chip {{ display:inline-block; padding:1px 7px; border-radius:6px; font-size:11px;
  font-weight:600; margin-right:4px; font-family:ui-monospace,SFMono-Regular,monospace; }}
.chip.dev {{ background:rgba(59,130,246,.16); color:var(--dev); }}
.chip.debug {{ background:rgba(245,158,11,.18); color:#b45309; }}
.chip.version {{ background:rgba(168,85,247,.16); color:var(--version); }}
.chip.main {{ background:rgba(34,197,94,.16); color:#15803d; }}
.chip.other {{ background:var(--line); color:var(--muted); }}
.graph {{ background:var(--panel); border-radius:14px; padding:8px 4px 8px 0; overflow-x:auto;
  box-shadow:0 1px 2px rgba(0,0,0,.05), 0 6px 18px rgba(0,0,0,.04); }}
/* Scrolls rather than crushes: below this the subject column is the one
   that gives, and a commit list with no subjects is a list of hashes. */
.graph table {{ border-collapse:collapse; table-layout:fixed; width:100%; min-width:620px; }}
.graph .rows {{ flex:1 1 0; min-width:0; }}
/* Every row is exactly as tall as a row of the drawing beside it. A subject
   that wrapped would push the text out of line with its own dot, and a graph
   whose dots point at the wrong commits is worse than no graph. */
.graph td {{ padding:0 10px; height:30px; line-height:30px; vertical-align:middle;
  white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }}
.graph td.sha {{ width:84px; }}
.graph td.refs {{ width:190px; }}
.graph td.when {{ width:100px; }}
.graph td.sha {{ font-family:ui-monospace,SFMono-Regular,monospace; color:var(--faint);
  font-size:12px; }}

.graph td.when {{ color:var(--faint); font-size:12px; text-align:right; }}
.row {{ display:flex; align-items:flex-start; }}
.svg-holder {{ flex:0 0 auto; padding-top:0; }}
footer {{ margin-top:24px; color:var(--faint); font-size:12px; }}
code {{ font-family:ui-monospace,SFMono-Regular,monospace; background:var(--line);
  padding:1px 5px; border-radius:5px; }}
</style></head><body>
<h1>Paper Time · {version}<span class="status {status_kind}">{status}</span></h1>
<p class="sub">{status_note} · 지금 있는 가지 {head}</p>
<div class="cards">{cards}</div>
<div class="graph"><div class="row">
  <div class="svg-holder">{graph}</div>
  <div class="rows"><table>{rows}</table></div>
</div></div>
<footer>커밋 {count}개 · <code>python3 Scripts/board.py</code>로 다시 그린다. 규칙은 CLAUDE.md에 있다.</footer>
</body></html>
"""

if __name__ == "__main__":
    raise SystemExit(main())
