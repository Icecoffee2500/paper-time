"""What Hugging Face's tokenizer says, for texts the shared fixture cannot hold.

    <venv>/bin/python Scripts/wordpiece-sweep.py codepoints <out.json>
    <venv>/bin/python Scripts/wordpiece-sweep.py texts <in.json> <out.json>

`codepoints` tokenizes "a<c>b" and "<c>" for every code point in the planes
Unicode has assigned anything in (0–3 and 14), plus samples of the private
planes — about half a million strings, which is how the Swift tokenizer's
Unicode rules are pinned to what the Rust library's tables actually say.
`texts` tokenizes a JSON list of strings, such as the passages
`Scripts/wordpiece-probe.swift dump` cuts from real papers, with the model's
256-token truncation. Either way the output is `{"cases": [[text, ids], …]}`,
which `wordpiece-probe.swift compare` reads.
"""
import json
import sys

from transformers import AutoTokenizer

tokenizer = AutoTokenizer.from_pretrained("sentence-transformers/all-MiniLM-L6-v2",
                                          revision="1110a243fdf4706b3f48f1d95db1a4f5529b4d41")
mode = sys.argv[1]
if mode == "codepoints":
    points = [c for c in range(0x40000) if not 0xD800 <= c <= 0xDFFF]
    points += list(range(0xE0000, 0xE1000)) + [0x50000, 0xF0000, 0xFFFFD, 0x100000, 0x10FFFD]
    texts = [f"a{chr(c)}b" for c in points] + [chr(c) for c in points]
    out = sys.argv[2]
else:
    texts = json.load(open(sys.argv[2]))
    out = sys.argv[3]
ids = tokenizer(texts, truncation=True, max_length=256)["input_ids"]
json.dump({"cases": [[t, i] for t, i in zip(texts, ids)]}, open(out, "w"), ensure_ascii=True)
print(f"{len(texts)} texts -> {out}")
