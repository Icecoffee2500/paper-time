/**
 * The Windows and Linux half of the report sheet.
 *
 * Same contract as the Mac's: the app never speaks to a server on its own, and
 * when somebody presses 보내기 it sends only what the sheet listed for them.
 * The picture is the window's own page, captured by Chromium — nothing outside
 * this app, and no screen-recording permission to ask for.
 */
import { BrowserWindow, app, nativeImage, shell } from 'electron'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { L } from '../shared/lang.js'

const ENDPOINT =
  process.env.PAPERTIME_FEEDBACK_URL ??
  'https://paper-time-feedback.icecoffee2500.workers.dev/report'

export interface FeedbackContext {
  window?: string
  layout?: string
  panes?: string
  libraryCloud?: boolean
  paperCount?: number
  recent: string[]
}

export interface FeedbackReport {
  kind: 'bug' | 'wish'
  body: string
  name: string
  reply?: string | null
  context: FeedbackContext
  /** A data URL, already flattened with its marks by the window. */
  shot?: string | null
}

/** What the app can say about itself. Never about the papers. */
export function diagnostics() {
  return {
    version: app.getVersion(),
    build: '',
    platform: `${platformName()} ${os.release()}`,
    arch: process.arch,
    lang: L('ko', 'en'),
  }
}

function platformName(): string {
  switch (process.platform) {
    case 'win32':
      return 'Windows'
    case 'darwin':
      return 'macOS'
    default:
      return 'Linux'
  }
}

/**
 * The window's own page as a PNG data URL.
 *
 * Taken in the main process because `capturePage` lives on `webContents`, and
 * taken before the sheet is drawn so the sheet is not in its own picture.
 */
export async function capture(window: BrowserWindow | null): Promise<string | null> {
  if (!window || window.isDestroyed()) return null
  try {
    const image = await window.webContents.capturePage()
    if (image.isEmpty()) return null
    const size = image.getSize()
    // A 6K window is four megabytes of PNG and nobody needs that many pixels
    // to see where the arrow points.
    const shrunk =
      size.width > 2200 ? image.resize({ width: 2200, quality: 'good' }) : image
    return shrunk.toDataURL()
  } catch {
    return null
  }
}

export async function send(report: FeedbackReport): Promise<{ ok: boolean; url?: string; kept?: string; error?: string }> {
  const payload = { ...report, app: diagnostics() }
  try {
    const response = await fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(30_000),
    })
    if (response.status === 429) {
      return {
        ok: false,
        error: L(
          '잠깐 사이에 너무 많이 보냈어요. 조금 뒤에 다시 보내주세요.',
          "That's a lot of reports in a short time. Try again in a bit.",
        ),
      }
    }
    const answer = (await response.json()) as { ok?: boolean; url?: string }
    if (response.ok && answer.ok) return { ok: true, url: answer.url }
  } catch {
    // Offline, or the worker is down. Fall through and keep it.
  }
  const kept = keep(report)
  return kept
    ? { ok: false, kept }
    : {
        ok: false,
        error: L('보내지 못했어요. 인터넷 연결을 확인해 주세요.', "Couldn't send. Check the network connection."),
      }
}

/**
 * Nothing anybody wrote is lost to a bad network: it goes to the desktop as a
 * folder they can attach to an email themselves.
 */
function keep(report: FeedbackReport): string | null {
  try {
    const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '')
    const folder = path.join(app.getPath('desktop'), `Paper Time feedback ${stamp}`)
    fs.mkdirSync(folder, { recursive: true })
    const info = diagnostics()
    const lines = [
      report.body,
      '',
      `— ${report.name}`,
      report.reply ? report.reply : '',
      '',
      `version: ${info.version}`,
      `system: ${info.platform} · ${info.arch}`,
      `language: ${info.lang}`,
      report.context.window ? `window: ${report.context.window}` : '',
      report.context.paperCount !== undefined ? `papers: ${report.context.paperCount}` : '',
      report.context.recent.length ? `recent: ${report.context.recent.join(' → ')}` : '',
    ].filter((line) => line !== '')
    fs.writeFileSync(path.join(folder, 'message.txt'), lines.join('\n'), 'utf8')
    if (report.shot) {
      const image = nativeImage.createFromDataURL(report.shot)
      fs.writeFileSync(path.join(folder, 'screen.png'), image.toPNG())
    }
    void shell.openPath(folder)
    return folder
  } catch {
    return null
  }
}
