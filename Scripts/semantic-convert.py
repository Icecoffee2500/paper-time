"""Builds the Core ML model that search-by-meaning ships, and refuses to write
it unless it still agrees with sentence-transformers.

    HF_HOME=<cache with the model> HF_HUB_OFFLINE=1 \
      <venv with torch, transformers, coremltools 9>/bin/python \
      Scripts/semantic-convert.py

It writes `Packages/PaperTimeKit/Sources/Semantic/Resources/MiniLM-L6-v2.mlmodelc`
(compiled, so nothing compiles it on a reader's machine — an uncompiled
package took 21 s to load the first time) and the model's `vocab.txt` next to
it. The reference it checks against is the fixture both test suites read,
`Packages/PaperTimeKit/Tests/SemanticTests/Fixtures/minilm-reference.json`,
made by `Scripts/semantic-reference.py`.

What was tried, measured against that fixture (15 passages and 15 queries;
"top-5" is the number of queries whose five best passages come back in the
same order as sentence-transformers'):

    fp32, flexible shapes      cos 1.000000            top-5 15/15   90.4 MB
    fp16, flexible shapes      cos ≥ 0.999998 GPU,     top-5 15/15   45.3 MB
                               cos ≥ 0.999975 CPU
    int8 symmetric weights     cos ≥ 0.999204          top-5 14/15   22.9 MB  (and the GPU refuses it)
    int8 affine weights        cos ≥ 0.999132          top-5 14/15   22.9 MB
    8-bit palette              cos ≥ 0.999649          top-5 13/15   22.7 MB
    fp16, enumerated shapes    20× slower on the GPU (52.7 ms a chunk against 2.7)

So it is fp16 with flexible shapes. Half the size was on offer, but the
reference's closest pair of neighbours is 0.00024 apart, and every 8-bit
version swapped at least one pair somewhere — the bar is "the same answer",
not "nearly the same numbers".

One thing is not the stock model: the attention mask. BERT's code turns the
mask into `(1 - mask) * float32.min`, which is −inf once the model runs in
fp16, and `0 * −inf` is NaN on every real token — the first fp16 conversion
answered NaN for everything. The wrapper below builds the mask with −10000,
which is what BERT itself used before that change: `exp(−10000)` is zero in
either precision, so padding still counts for nothing.
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import torch
import coremltools as ct
from huggingface_hub import hf_hub_download
from transformers import AutoModel, AutoTokenizer

MODEL = "sentence-transformers/all-MiniLM-L6-v2"
REVISION = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Packages/PaperTimeKit/Sources/Semantic/Resources"
REFERENCE = ROOT / "Packages/PaperTimeKit/Tests/SemanticTests/Fixtures/minilm-reference.json"
BAR = 0.999


class Pooled(torch.nn.Module):
    """The encoder, mean pooling over the real tokens, and L2 normalisation —
    what sentence-transformers' three modules do, as one graph."""

    def __init__(self, bert):
        super().__init__()
        self.bert = bert

    def forward(self, ids, mask):
        e = self.bert.embeddings(input_ids=ids)
        extended = (1.0 - mask[:, None, None, :].to(e.dtype)) * -10000.0
        h = self.bert.encoder(e, attention_mask=extended).last_hidden_state
        m = mask.unsqueeze(-1).to(h.dtype)
        v = (h * m).sum(1) / m.sum(1).clamp(min=1e-9)
        return torch.nn.functional.normalize(v, dim=-1)


def main():
    tokenizer = AutoTokenizer.from_pretrained(MODEL, revision=REVISION)
    bert = AutoModel.from_pretrained(MODEL, revision=REVISION, attn_implementation="eager").eval()
    example = torch.ones((2, 64), dtype=torch.int32)
    traced = torch.jit.trace(Pooled(bert).eval(), (example, example))
    # Batch up to 64 and any length up to the model's 256 tokens: a query is
    # a dozen tokens and a passage about 150, and a fixed 256 would make the
    # query pay for 244 tokens of padding.
    shape = (ct.RangeDim(lower_bound=1, upper_bound=64, default=1),
             ct.RangeDim(lower_bound=1, upper_bound=256, default=128))
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="ids", shape=shape, dtype=np.int32),
                ct.TensorType(name="mask", shape=shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    model.short_description = ("all-MiniLM-L6-v2 sentence embeddings: token ids and mask in, "
                               "a mean-pooled, L2-normalised 384-dimensional vector out.")
    model.author = "sentence-transformers (Apache-2.0); converted for Paper Time"
    model.license = "Apache-2.0"
    model.version = REVISION
    model.user_defined_metadata["source"] = f"{MODEL}@{REVISION}"

    reference = json.loads(REFERENCE.read_text())
    items = reference["passages"] + reference["queries"]
    worst = 1.0
    for units in (ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_ONLY):
        with tempfile.TemporaryDirectory() as scratch:
            package = pathlib.Path(scratch) / "check.mlpackage"
            model.save(str(package))
            check = ct.models.MLModel(str(package), compute_units=units)
            for item in items:
                e = tokenizer(item["text"], truncation=True, max_length=256, return_tensors="np")
                v = check.predict({"ids": e["input_ids"].astype(np.int32),
                                   "mask": e["attention_mask"].astype(np.int32)})["embedding"][0]
                v = v.astype(np.float64) / np.linalg.norm(v)
                worst = min(worst, float(v @ np.array(item["vector"])))
    print(f"lowest cosine to sentence-transformers over {len(items)} texts: {worst:.6f}")
    if worst < BAR:
        sys.exit(f"below the bar of {BAR}; not writing the model")

    RESOURCES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        package = pathlib.Path(scratch) / "MiniLM-L6-v2.mlpackage"
        model.save(str(package))
        target = RESOURCES / "MiniLM-L6-v2.mlmodelc"
        if target.exists():
            shutil.rmtree(target)
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(RESOURCES)], check=True)
    shutil.copyfile(hf_hub_download(MODEL, "vocab.txt", revision=REVISION), RESOURCES / "vocab.txt")
    size = sum(f.stat().st_size for f in target.rglob("*") if f.is_file())
    print(f"wrote {target.relative_to(ROOT)} ({size / 1e6:.2f} MB) and vocab.txt")


if __name__ == "__main__":
    main()
