/**
 * Something did not happen, said in the app's voice.
 *
 * The reason — an English message from the main process, a path — goes to
 * the console for whoever reads the log; the person gets a sentence about
 * what they asked for.
 */
import { on } from './dom.js'
import { toast } from './ui/toolbar.js'
import { L } from '../shared/lang.js'

const COULD_NOT = {
  addPDFs: () => L('PDF를 더하지 못했어요.', "Paper Time couldn't add those PDFs."),
  readPDF: () => L('이 논문의 PDF를 읽지 못했어요.', "Paper Time couldn't read this paper's PDF."),
  moveNotes: () => L('노트를 옮기지 못했어요.', "Paper Time couldn't move the notes."),
  finish: () => L('문제가 생겨서 하던 일을 마치지 못했어요.', "Paper Time couldn't finish that."),
}

export function couldNot(what: keyof typeof COULD_NOT, reason: unknown) {
  console.error(`${what} -`, reason)
  toast(COULD_NOT[what]())
}

/** A request nobody caught — the main process threw, a file went away — is
 *  said once rather than lost in the console with nothing on screen. */
export function installRejectionNotice() {
  on(window, 'unhandledrejection', (event: PromiseRejectionEvent) => couldNot('finish', event.reason))
}
