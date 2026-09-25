# The answers both semantic-search implementations must reproduce: token ids
# and embeddings from sentence-transformers itself (all-MiniLM-L6-v2).
import json, sys
from sentence_transformers import SentenceTransformer
m = SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2', device='cpu')
tok = m.tokenizer
strings = [
    "Elastic Weight Consolidation", "catastrophic forgetting in neural networks", "Almudévar", "naïve café résumé",
    "state-of-the-art", "self-supervised learning", "un-\nlearning", "the slicedWassersteindistance", "x^2 + y_1 = \\frac{a}{b}",
    "$f^{-1}(x)$", "https://arxiv.org/abs/2511.08544", "e-mail: almudevar@unizar.es", "ResNet-50 (He et al., 2016)",
    "Fig. 3: Top-1 accuracy (%)", "ImageNet-1K", "BERTology", "transformers", "supercalifragilisticexpialidocious",
    "a" * 120, "강화학습의 기초", "논문 없는 노트", "日本語のテキスト", "中文字符", "Ελληνικά", "Приветствие",
    "emoji 😀 test", "tab\tseparated\ttext", "  leading and trailing  ", "", "UPPER lower MiXeD", "don't won't can't",
    "“curly quotes” and ‘single’", "em—dash and en–dash", "1,234.56 and 1e-3", "O(n log n)", "∀x ∈ ℝ, ∃y",
    "α β γ δ ε", "ﬁ ligature ﬂ", "Ｆｕｌｌｗｉｄｔｈ", "C++ / C# / F#", "@username #hashtag", "path/to/file.pdf",
    "Section 2.1.3", "[1, 2, 3]", "(see Appendix A)", "i.e., e.g., etc.", "Dr. Smith's lab", "no-op", "A/B testing",
    "Wasserstein GAN with gradient penalty",
]
passages = [
    "We propose Elastic Weight Consolidation, which slows down learning on weights important for previous tasks.",
    "Catastrophic forgetting occurs when a network trained on a new task loses performance on earlier tasks.",
    "Machine unlearning aims to remove the influence of specific training data from a trained model.",
    "The Fisher information matrix approximates how sensitive the loss is to each parameter.",
    "Joint-embedding predictive architectures learn by predicting representations of masked regions.",
    "Scene graph generation predicts objects and the relations between them in an image.",
    "Test-time adaptation updates a model on unlabeled test data without access to the source data.",
    "Vision-language models such as CLIP align images and text in a shared embedding space.",
    "Reinforcement learning agents learn a policy by maximizing expected cumulative reward.",
    "The sufficiency principle states that a sufficient statistic contains all the information about the parameter.",
    "Federated learning trains a shared model across clients without centralizing their data.",
    "Gradient-based saliency identifies which weights matter most for forgetting a class.",
    "Isotropic Gaussian embeddings minimize downstream prediction risk under a broad family of tasks.",
    "Knowledge distillation transfers the behaviour of a large teacher model to a smaller student.",
    "Variational autoencoders maximize a lower bound on the data log-likelihood.",
]
queries = [
    "Fisher information penalty that prevents catastrophic forgetting",
    "remove a user's data from a trained model",
    "predict masked image regions in representation space",
    "objects and their relationships in a picture",
    "adapt to new data at inference time",
    "align images and captions",
    "learning from rewards",
    "a statistic that keeps everything about the parameter",
    "training on phones without sending data to a server",
    "which parameters to change to forget a class",
    "강화학습 보상",
    "variational lower bound",
    "small student learns from big teacher",
    "Wasserstein distance between distributions",
    "self-supervised learning without heuristics",
]
tokens = [{"text": s, "ids": tok(s, truncation=True, max_length=256)["input_ids"]} for s in strings]
long_text = " ".join(passages * 12)
tokens.append({"text": long_text, "ids": tok(long_text, truncation=True, max_length=256)["input_ids"], "note": "longer than 256 tokens: truncated"})
def emb(texts):
    return m.encode(texts, normalize_embeddings=True, convert_to_numpy=True, batch_size=16).tolist()
out = {
    "model": "sentence-transformers/all-MiniLM-L6-v2",
    "licence": "Apache-2.0",
    "max_seq_length": m.max_seq_length,
    "pipeline": "BERT uncased WordPiece; [CLS] ... [SEP]; truncation 256; mean pooling with attention mask; L2 normalise",
    "tokens": tokens,
    "passages": [{"text": t, "vector": v} for t, v in zip(passages, emb(passages))],
    "queries": [{"text": t, "vector": v} for t, v in zip(queries, emb(queries))],
}
import numpy as np
P = np.array([p["vector"] for p in out["passages"]]); Q = np.array([q["vector"] for q in out["queries"]])
out["top5"] = [{"query": q["text"], "passages": [int(i) for i in np.argsort(-(P @ np.array(q["vector"])))[:5]]} for q in out["queries"]]
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
print("tokens", len(tokens), "passages", len(passages), "queries", len(queries), "max_seq_length", m.max_seq_length)
