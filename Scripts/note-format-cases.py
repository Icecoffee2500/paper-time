#!/usr/bin/env python3
"""The questions `Scripts/note-format-fixture.sh` puts to the Mac's NoteFormat."""
import json, sys

notes = [
    "plain words here\nsecond line of it\n",
    "a **bold** and *slanted* word with `code` and $x^2$\n",
    "plain <span style=\"color:#d62e54\">red words</span> tail\n",
    "one =={green}marked== two ==yellow== three\n",
    "# Title here\n## Heading two\n### Sub three\nbody\n> quoted words\n",
    "- item one\n  - nested item\n1. first\n2. second\n- [ ] todo\n+ toggle\n",
    "<p align=\"center\">middle words</p>\nnext\n",
    "한글 낱말과 English 섞인 줄\n둘째 줄 🎉 이모지\n",
    "a [[id|Note]] and [3쪽](papertime://anchor?p=2&x=1&y=2&w=3&h=4) link\n",
    "mid<span style=\"font-size:20px;font-weight:bold\">dle</span>word and con=={pink}tin==uous\n",
    "  spaced   words  \n\nafter blank\n",
    "***both*** then <span style=\"color:#1f70d9;background-color:#fff3b0;text-decoration:underline line-through\">all of it</span>\n",
]
cases = []
def add(source, a, b, op, value=None):
    case = {"source": source, "from": a, "to": b, "op": op}
    if value is not None: case["value"] = value
    cases.append(case)

for note in notes:
    n = len(note.encode("utf-16-le")) // 2
    spots = sorted(set([0, 1, 3, 6, 9, 14, 20, 27, 40, n // 2, max(0, n - 2)]))
    spots = [s for s in spots if s <= n]
    ranges = [(s, s) for s in spots] + [(a, b) for a in spots for b in spots if a < b and b - a <= 30][:14] + [(0, n)]
    for a, b in ranges:
        add(note, a, b, "state")
        for op, value in [("color", "#d62e54"), ("color", ""), ("size", "20"), ("size", ""), ("family", "Georgia"),
                          ("highlight", "green"), ("highlight", ""), ("bold", "1"), ("bold", "0"), ("italic", "1"),
                          ("underline", "1"), ("strike", "1")]:
            add(note, a, b, op, value)
    for a, b in [(0, 0), (3, 3), (n // 2, n // 2), (0, n), (2, min(n, 25))]:
        for value in ["title", "heading", "subheading", "body", "quote"]: add(note, a, b, "para", value)
        for value in ["none", "bullet", "numbered", "task", "toggle"]: add(note, a, b, "list", value)
        for value in ["left", "center", "right", "justify"]: add(note, a, b, "align", value)
        add(note, a, b, "picture", ".assets/abc.png")

for line in [
    "plain", "a </span> b", "a <span style=\"color:#d62e54\">b", "a <span style=\"color:#d62e54\"></span> b",
    "a <span style=\"color:#d62e54\">b</span> c</span>", "<span style=\"color:#d62e54\"><span style=\"font-size:20px\">x</span>",
    "<p align=\"center\">words</p>", "<p align=\"center\">words</p>more", "before<p align=\"center\">words</p>",
    "<p align=\"center\">a</p><p align=\"right\">b</p>", "<p align=\"right\">a", "a</p>", "# <p align=\"center\">Title</p>tail",
    "- item </span> x", "> quote <span style=\"color:#d62e54\">q", "1 < 2 and 3 > 2", "",
]:
    add(line, 0, 0, "tidy")

json.dump(cases, sys.stdout, ensure_ascii=False)
