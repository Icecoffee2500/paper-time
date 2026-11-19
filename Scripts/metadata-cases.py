"""The calls `papertime-metadata-fixtures pure` evaluates: hand-picked edge
cases plus, for every paper in the signals file, the calls that read it.
Usage: metadata-cases.py <unused> <signals.json> <cases.json>"""
import json, sys

rows = json.load(open(sys.argv[2]))
cases = []
def add(fn, *args): cases.append({'fn': fn, 'args': list(args)})
hand_dois = ['10.1073/pnas.1611835114', 'https://doi.org/10.1109/CVPR.2017.330.', 'DOI: 10.1145/3292500.3330701)', 'doi:10.48550/arXiv.2403.18293', 'http://dx.doi.org/10.1000/xyz', '10.12/ab', '11.1234/abc', ' 10.1234/ABC]; ', 'doi.org/10.5555/12345678', '']
for d in hand_dois: add('normalizeDOI', d)
hand_arxiv = ['arXiv:2403.18293v1', 'https://arxiv.org/abs/2403.18293', 'arxiv.org/abs/1312.6114v10', 'http://arxiv.org/pdf/2301.08243.pdf', 'cs/0501001', 'math.GT/0309136v2', 'hep-th/9901001', '2403.1829', 'ARXIV:1706.03762', '']
for a in hand_arxiv: add('normalizeArxiv', a)
for a in ['2403.18293v1', '2403.18293', 'cs/0501001v3', 'bad']: add('arxivBaseID', a)
for f in ['2403.18293v1.pdf', '2410.04144v1.pdf', '1312.6114.PDF', 'paper.pdf', 'cs0501001.pdf', '2403.18293v1 (1).pdf']: add('arxivIDFromFileName', f)
texts = [
  'See arXiv:2403.18293v2 and arxiv 1706.03762. Also https://arxiv.org/abs/2301.08243v3, arXiv: hep-th/9901001 and ARXIV:cs.AI/0101001v1.',
  'DOI 10.1073/pnas.1611835114. Cited 10.1109/CVPR.2017.330, and again 10.1073/PNAS.1611835114; PMID: 12345678 pmid 99',
  'No identifiers here at all, just 10.5 and 2020.',
  'Ｄｏｉ ١٠.١٢٣٤/abc and 10.١٢٣٤/xyz',
]
for t in texts:
  for fn in ['scan', 'dois', 'arxivIDs', 'pubmedID']: add(fn, t)
names = ['Smith, John', 'Smith, John, Jr.', 'John Smith', 'Jean-Paul van der Berg', 'Plato', '  ', 'Smith,', 'Kim, ', 'Yann LeCun']
for n in names: add('parseName', n)
for t in ['c. 2019', 'Proceedings 1999–2001', 'no year 12345', '３０２０ 2025', '1499 1500', '']: add('firstYear', t)
fold = ['Auto-Encoding Variational Bayes', 'Élan vital: Über café', 'ﬁne-tuning “quotes”', '  A  B  ', 'Straße ǅ İstanbul', '$\\pi_0$: flow', '한국어 제목 — 논문']
for f in fold:
  add('foldedTitle', f); add('collapsingWhitespace', f)
pairs = [('Auto-Encoding Variational Bayes', 'Auto-encoding variational Bayes'), ('Neural Motifs', 'Neural Motifs: Scene Graph Parsing with Global Context'), ('abc', 'xyz'), ('', ''), ('a', 'a'), ('Scene-Graph ViT', 'Scene Graph Generation by Iterative Message Passing'), ('crate', 'trace'), ('MARTHA', 'MARHTA')]
for a, b in pairs: add('titleSimilarity', a, b); add('jaroWinkler', a, b)
hyph = ['infor-\nmation and state-of-the-art', 'A-\nB', 'end -\n  lower', 'x-\r\ny', 'trailing-', 'multi-\n\n\nline']
for h in hyph: add('repairingHyphenation', h)
titles = ['Untitled', 'Microsoft Word - paper.docx', 'main.tex', 'paper - final', 'A Real Title About Things', 'NoSpacesButLongEnough', 'short', 'camera-ready - v2 draft', 'Proceedings.pdf  version', '  Deep   Residual Learning for Image Recognition  ']
for t in titles: add('cleanEmbeddedTitle', t)
authors = ['Kim; Lee; Park', 'John Smith and Jane Doe', 'Smith, John', 'A, B, C', 'Solo Author', '', 'Doe, J.; Roe, R.']
for a in authors: add('splitAuthorField', a)
for k in ['a, b; c', '', 'single', ' x ,, y ']: add('keywordList', k)
lines = set()
for r in rows:
  s = r['signals']
  add('candidates', s); add('guess', s)
  add('firstMeaningfulLine', s['firstPageLines'])
  if r['headers']: add('authorsFollowingTitle', r['headers'][0]['title'], s['firstPageLines'])
  add('scan', s['openingText']); add('dois', s['openingText']); add('arxivIDs', s['openingText'])
  add('repairingHyphenation', s['openingText'][:4000])
  add('looksLikeAbstract', s['openingText'][:3000])
  if 'firstPage' in r: add('largestFontText', r['firstPage'])
  for line in s['firstPageLines'][:30]: lines.add(line)
  add('referencePageIndices', s['pageCount'])
  add('venueStamp', '\n'.join(s['firstPageLines']))
for line in sorted(lines):
  for fn in ['isStamp', 'isLikelyAuthorOrAffiliationLine', 'looksLikeBoilerplate', 'endsMidPhrase', 'splitAuthorLine']: add(fn, line)
for n in [0, 1, 40, 41, 100, 686]: add('referencePageIndices', n)
stamps = [
  'Published as a conference paper at ICLR 2024', 'Under review as a conference paper at ICLR 2024',
  'Under review as a conference paper at ICLR 2025\nPublished as a conference paper at ICLR 2024',
  '37th Conference on Neural Information Processing Systems (NeurIPS 2023).',
  '38th Conference on Neural Information Processing Systems (NeurIPS 2024) Track on Datasets and Benchmarks.',
  'Submitted to 37th Conference on Neural Information Processing Systems (NeurIPS 2023). Do not distribute.',
  '37th Conference on Neural Information Processing Systems (NeurIPS 2023) Workshop on Foo.',
  '34th Conference on Neural Information Processing Systems (NeurIPS 2020), Vancouver, Canada.',
  'Preprint. Under review.', '31st Conference on Neural Information Processing Systems (NIPS 2017), Long Beach, CA, USA.',
  'Proceedings of the 40 th International Conference on Machine Learning, Honolulu, Hawaii, USA. PMLR 202, 2023. Copyright 2023 by the author(s).',
  'Preliminary work. Under review by the International Conference on Machine Learning (ICML).',
  'Proceedings of the 26th International Conference on Artificial Intelligence and Statistics (AISTATS) 2023, Valencia, Spain. PMLR: Volume 206.',
  '7th Conference on Robot Learning (CoRL 2023), Atlanta, USA.',
  'This CVPR paper is the Open Access version, provided by the Computer Vision Foundation.',
  'This ICCV 2023 paper is the Open Access version, provided by the Computer Vision Foundation.',
  'This CVPR workshop paper is the Open Access version, provided by the Computer Vision Foundation.',
  'The Thirty-Eighth AAAI Conference on Artificial Intelligence (AAAI-24)',
  'Proceedings of the Thirty-Second International Joint Conference on Artificial Intelligence (IJCAI-23)',
  'Findings of the Association for Computational Linguistics: EMNLP 2023, pages 1-15',
  'Proceedings of the 2023 Conference on Empirical Methods in Natural Language Processing, pages 1-15',
  'Proceedings of the 2024 Conference of the North American Chapter of the Association for Computational Linguistics',
  'Proceedings of the 61st Annual Meeting of the Association for Computational Linguistics (Volume 1: Long Papers), pages 1-15 July 9-14, 2023',
  'Published in Transactions on Machine Learning Research (11/2023)',
  'Journal of Machine Learning Research 24 (2023) 1-41 Submitted 1/22; Published 7/23',
  '', 'Nothing here at all',
]
for t in stamps: add('venueStamp', t)
tex = ['$\\pi_0$: A Vision-Language-Action Flow Model', 'Caf{\\\'e} na{\\"\\i}ve', '{\\AA}ngstr{\\"o}m', 'Deep {GAN} models --- and \\textit{more}', '\\cite{foo} and \\{braces\\}', '$\\alpha$-divergence of $\\Omega$', 'Costs $5 and $6', '``quoted\'\' text', '{\\c C}a va', '\\v{z} and \\H o and \\u{a}', '50\\% \\& more \\textdegree{}', 'x_1^2 in $x_1^2$']
for t in tex: add('unescape', t); add('clean', t)
json.dump(cases, open(sys.argv[3], 'w'), ensure_ascii=False)

