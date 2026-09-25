# The model the Windows and Linux builds run for «Search by Meaning», made from
# the same weights the reference answers came from (Scripts/semantic-reference.py).
#
# The graph takes token ids and an attention mask and hands back the finished
# sentence vector — mean pooling over the mask and L2 normalisation are inside
# it — so the TypeScript side cannot pool differently from sentence-transformers:
# it never pools at all.
#
# Three variants are written and each is held to the reference before one is
# chosen. The fp16 and int8 variants only *store* the weights smaller: every
# weight goes through a Cast (and, for int8, a per-row scale) back to float32,
# which ONNX Runtime folds into ordinary float32 weights when the session is
# made. So the arithmetic is float32 everywhere and the only error is the
# rounding of the weights themselves — the WebAssembly build of ONNX Runtime has
# few float16 kernels, and a model that needed them would not run there.
#
#   HF_HOME=… HF_HUB_OFFLINE=1 python Scripts/semantic-onnx.py <out-dir> <reference.json>
import json, os, sys, time
import numpy as np
import torch
import onnx
from onnx import helper, numpy_helper, TensorProto
import onnxruntime as ort
from sentence_transformers import SentenceTransformer

out_dir, reference_path = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
st = SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2', device='cpu')
tokenizer = st.tokenizer
bert = st[0].auto_model
bert.config._attn_implementation = 'eager'   # plain MatMul/Softmax: every kernel exists in the WASM build
bert.eval()


class Embedder(torch.nn.Module):
    def __init__(self, bert):
        super().__init__()
        self.bert = bert

    def forward(self, input_ids, attention_mask):
        hidden = self.bert(input_ids=input_ids, attention_mask=attention_mask,
                           token_type_ids=torch.zeros_like(input_ids)).last_hidden_state
        # sentence_transformers.models.Pooling (mean) and Normalize, as written there.
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        summed = (hidden * mask).sum(1)
        counts = torch.clamp(mask.sum(1), min=1e-9)
        return torch.nn.functional.normalize(summed / counts, p=2, dim=1)


model = Embedder(bert).eval()
sample = tokenizer(['a sample sentence', 'another, longer sample sentence here'], padding=True, return_tensors='pt')
fp32_path = os.path.join(out_dir, 'minilm-fp32.onnx')
with torch.no_grad():
    torch.onnx.export(
        model, (sample['input_ids'], sample['attention_mask']), fp32_path,
        input_names=['input_ids', 'attention_mask'], output_names=['embedding'],
        dynamic_axes={'input_ids': {0: 'batch', 1: 'tokens'}, 'attention_mask': {0: 'batch', 1: 'tokens'},
                      'embedding': {0: 'batch'}},
        opset_version=17, do_constant_folding=True, dynamo=False,
    )


def stored_smaller(source, target, kind):
    """Rewrites every large float initializer as float16 or int8 plus a Cast back."""
    m = onnx.load(source)
    graph = m.graph
    gathered = {n.input[0] for n in graph.node if n.op_type == 'Gather'}
    keep, casts = [], []
    for init in graph.initializer:
        # Only the matrices: biases and layer-norm vectors are a few kilobytes
        # all together and stay exactly as trained.
        if init.data_type != TensorProto.FLOAT or len(init.dims) != 2:
            keep.append(init)
            continue
        w = numpy_helper.to_array(init)
        name = init.name
        how = kind
        if kind == 'mixed':
            # The word table is half the model and each row is read alone, so
            # it takes int8 by blocks; the layers keep float16.
            how = 'int8b32' if (name in gathered and w.shape[0] > 10000) else 'fp16'
        if how == 'fp16':
            keep.append(numpy_helper.from_array(w.astype(np.float16), name + '__fp16'))
            casts.append(helper.make_node('Cast', [name + '__fp16'], [name], to=TensorProto.FLOAT))
        elif how == 'int8b32':
            # Symmetric int8 with one float16 scale per 32 weights that meet in
            # the same dot product: along the input axis of a MatMul weight
            # [in, out], along the row of an embedding table.
            B = 32
            if name in gathered:
                rows, cols = w.shape
                blocks = w.reshape(rows, cols // B, B)
                scale = np.abs(blocks).max(axis=2, keepdims=True) / 127.0
            else:
                rows, cols = w.shape
                blocks = w.reshape(rows // B, B, cols)
                scale = np.abs(blocks).max(axis=1, keepdims=True) / 127.0
            scale = scale.astype(np.float16).astype(np.float32)
            scale[scale == 0] = 1.0
            q = np.clip(np.round(blocks / scale), -127, 127).astype(np.int8)
            keep.append(numpy_helper.from_array(q, name + '__q'))
            keep.append(numpy_helper.from_array(scale.astype(np.float16), name + '__scale16'))
            keep.append(numpy_helper.from_array(np.array(w.shape, dtype=np.int64), name + '__shape'))
            casts.append(helper.make_node('Cast', [name + '__q'], [name + '__qf'], to=TensorProto.FLOAT))
            casts.append(helper.make_node('Cast', [name + '__scale16'], [name + '__scale'], to=TensorProto.FLOAT))
            casts.append(helper.make_node('Mul', [name + '__qf', name + '__scale'], [name + '__blocks']))
            casts.append(helper.make_node('Reshape', [name + '__blocks', name + '__shape'], [name]))
        else:
            # Symmetric int8 with one scale per slice that is used together: a
            # MatMul weight is [in, out] here, so one scale per output column
            # keeps each neuron's own range; an embedding table is read a row
            # at a time, so one scale per row.
            axis = 0 if name in gathered else 1
            reduce = 1 - axis
            scale = np.abs(w).max(axis=reduce, keepdims=True) / 127.0
            scale[scale == 0] = 1.0
            q = np.clip(np.round(w / scale), -127, 127).astype(np.int8)
            keep.append(numpy_helper.from_array(q, name + '__q'))
            keep.append(numpy_helper.from_array(scale.astype(np.float32), name + '__scale'))
            casts.append(helper.make_node('Cast', [name + '__q'], [name + '__qf'], to=TensorProto.FLOAT))
            casts.append(helper.make_node('Mul', [name + '__qf', name + '__scale'], [name]))
    del graph.initializer[:]
    graph.initializer.extend(keep)
    nodes = list(graph.node)
    del graph.node[:]
    graph.node.extend(casts + nodes)
    onnx.checker.check_model(m)
    onnx.save(m, target)


paths = {'fp32': fp32_path}
for kind in ('fp16', 'int8', 'int8b32', 'mixed'):
    paths[kind] = os.path.join(out_dir, f'minilm-{kind}.onnx')
    stored_smaller(fp32_path, paths[kind], kind)

reference = json.load(open(reference_path))
texts = [p['text'] for p in reference['passages']] + [q['text'] for q in reference['queries']]
expected = np.array([p['vector'] for p in reference['passages']] + [q['vector'] for q in reference['queries']])
n_passages = len(reference['passages'])

report = {}
for kind, path in paths.items():
    session = ort.InferenceSession(path, providers=['CPUExecutionProvider'])
    got = []
    for text in texts:   # one at a time, as the app embeds a query
        enc = tokenizer([text], truncation=True, max_length=256, return_tensors='np')
        got.append(session.run(['embedding'], {'input_ids': enc['input_ids'].astype(np.int64),
                                               'attention_mask': enc['attention_mask'].astype(np.int64)})[0][0])
    got = np.array(got)
    cos = (got * expected).sum(1) / np.linalg.norm(got, axis=1) / np.linalg.norm(expected, axis=1)
    P = got[:n_passages]
    same_top5 = sum(int(list(np.argsort(-(P @ got[n_passages + i]))[:5]) == t['passages'])
                    for i, t in enumerate(reference['top5']))
    # The same query through a padded batch must give the same vector.
    enc = tokenizer(texts[:4], truncation=True, max_length=256, padding=True, return_tensors='np')
    batched = session.run(['embedding'], {'input_ids': enc['input_ids'].astype(np.int64),
                                          'attention_mask': enc['attention_mask'].astype(np.int64)})[0]
    batch_cos = float(((batched * got[:4]).sum(1)).min())
    long_ids = tokenizer([' '.join(texts * 4)], truncation=True, max_length=256, return_tensors='np')
    t0 = time.perf_counter()
    for _ in range(5):
        session.run(['embedding'], {'input_ids': long_ids['input_ids'].astype(np.int64),
                                    'attention_mask': long_ids['attention_mask'].astype(np.int64)})
    ms = (time.perf_counter() - t0) / 5 * 1000
    report[kind] = {'bytes': os.path.getsize(path), 'cos_min': float(cos.min()), 'cos_mean': float(cos.mean()),
                    'top5_same': f'{same_top5}/{len(reference["top5"])}', 'batch_cos_min': batch_cos,
                    'ms_256_tokens_native': round(ms, 1)}
    print(kind, json.dumps(report[kind]))

json.dump(report, open(os.path.join(out_dir, 'variants.json'), 'w'), indent=1)
