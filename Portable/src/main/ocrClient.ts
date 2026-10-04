/**
 * The main process's handle on the formula OCR worker (`ocrWorker.ts`).
 *
 * Starts `ocr.js` as a utility process the first time a formula needs
 * reading off a picture — never at launch — and turns its messages into
 * promises. Unlike the semantic worker it is kept for the app's life: the
 * model takes a second or two to load, and a person who lassoed one
 * scanned formula will lasso the next one in a minute.
 *
 * Where the model is: in a packaged app, `resources/ocr/` (electron-builder's
 * `extraResources` copies the Mac's `App/Resources/MathOCR` there — one copy
 * in the repository, shared with the Mac); in development, that folder
 * itself, beside `Portable/`. The runtime's WebAssembly and glue are the
 * ones `build.mjs` lays beside the semantic worker — one runtime, two
 * workers.
 */
import { app, utilityProcess, type UtilityProcess } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import type { OCRReading, OCRReply, OCRRequest, OCRStats } from './ocrWorker.js'

export class OCRClient {
  private child: UtilityProcess | null = null
  private token = 0
  private waiting = new Map<number, { resolve: (reply: OCRReply) => void; reject: (error: Error) => void }>()
  private untagged: Array<{ type: OCRReply['type']; resolve: (reply: OCRReply) => void; reject: (error: Error) => void }> = []

  constructor(private readonly log: (line: string) => void = () => undefined) {}

  /** Whether the model files are where this build expects them. */
  static isAvailable(): boolean {
    const directory = OCRClient.modelDirectory()
    return ['encoder_model.onnx', 'decoder_model.onnx', 'tokenizer.json'].every((file) => fs.existsSync(path.join(directory, file)))
  }

  /** `process.resourcesPath/ocr` once packaged; the Mac's folder in development. */
  static modelDirectory(): string {
    return app.isPackaged
      ? path.join(process.resourcesPath, 'ocr')
      : path.join(app.getAppPath(), '..', 'App', 'Resources', 'MathOCR')
  }

  private process(): UtilityProcess {
    if (this.child) return this.child
    // From the copy the packager leaves outside the archive (`asarUnpack`):
    // the runtime loads its WebAssembly from a file, and a file inside the
    // archive is not one it can load.
    const script = unpacked(path.join(__dirname, 'ocr.js'))
    const child = utilityProcess.fork(script, [], { serviceName: 'Paper Time Formula OCR' })
    child.postMessage({
      type: 'configure',
      modelDirectory: OCRClient.modelDirectory(),
      runtimeDirectory: unpacked(path.join(__dirname, 'semantic')),
    } satisfies OCRRequest)
    child.on('message', (reply: OCRReply) => this.receive(reply))
    child.on('exit', (code) => {
      if (this.child === child) this.child = null
      this.log(`ocr: worker ended (${code})`)
      const gone = new Error('the formula OCR worker ended')
      for (const { reject } of this.waiting.values()) reject(gone)
      this.waiting.clear()
      for (const { reject } of this.untagged.splice(0)) reject(gone)
    })
    this.child = child
    return child
  }

  private receive(reply: OCRReply) {
    if ('token' in reply && reply.token !== undefined) {
      const asked = this.waiting.get(reply.token)
      if (!asked) return
      this.waiting.delete(reply.token)
      if (reply.type === 'error') asked.reject(new Error(reply.message))
      else asked.resolve(reply)
      return
    }
    const at = this.untagged.findIndex((u) => u.type === reply.type || reply.type === 'error')
    if (at < 0) return
    const [asked] = this.untagged.splice(at, 1)
    if (reply.type === 'error') asked.reject(new Error(reply.message))
    else asked.resolve(reply)
  }

  /**
   * The formula in a picture — the model's normalised 3×384×384 tensor, as
   * `shared/formulaOCRInput.ts` makes it. Null when nothing was read.
   */
  read(pixels: Float32Array): Promise<OCRReading | null> {
    const token = ++this.token
    return new Promise((resolve, reject) => {
      this.waiting.set(token, {
        resolve: (reply) => resolve(reply.type === 'read' ? reply.reading : null),
        reject,
      })
      this.process().postMessage({ type: 'read', token, pixels } satisfies OCRRequest)
    })
  }

  async stats(): Promise<OCRStats | null> {
    if (!this.child) return null
    return new Promise((resolve, reject) => {
      this.untagged.push({ type: 'stats', resolve: (reply) => resolve(reply.type === 'stats' ? reply.stats : null), reject })
      this.process().postMessage({ type: 'stats' } satisfies OCRRequest)
    })
  }

  /** Ends the worker, with the app. */
  end(): void {
    this.child?.kill()
    this.child = null
  }
}

function unpacked(file: string): string {
  const outside = file.replace(/app\.asar(?=[\\/])/, 'app.asar.unpacked')
  return outside !== file && fs.existsSync(outside) ? outside : file
}
