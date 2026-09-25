/**
 * The model that ships, named once — `SemanticModel.swift`.
 *
 * The identifier is the Mac's, on purpose: the vector cache carries it, and
 * a cache the Mac wrote must open here and the other way round. The two
 * runtimes (Core ML in fp16, ONNX Runtime in fp32 from fp16-stored weights)
 * agree with sentence-transformers to a cosine of 0.9999 and beyond, and with
 * each other likewise, so their vectors are the same space. A conversion that
 * changes the numbers must change this string on both sides, or old caches
 * would be mixed with new vectors.
 */
export const MODEL_ID = 'all-MiniLM-L6-v2@1110a243/coreml-fp16/1'
export const DIMENSION = 384
/** `max_seq_length`: longer texts are cut to this many ids, `[CLS]` and `[SEP]` included. */
export const MAX_TOKENS = 256

/** The files beside the worker, as `build.mjs` lays them out. */
export const MODEL_FILE = 'all-MiniLM-L6-v2-fp16.onnx'
export const VOCAB_FILE = 'vocab.txt'
export const LICENCE_FILE = 'LICENSE.txt'
