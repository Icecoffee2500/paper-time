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

/**
 * The rows the sheet lists under «What gets sent», from the context that is
 * sent — one list for both, so they cannot drift apart.
 */
export function diagnosticRows(context: FeedbackContext): [string, string][] {
  const about = diagnostics()
  const rows: [string, string][] = [
    [L('버전', 'Version'), about.build ? `${about.version} (${about.build})` : about.version],
    [L('운영체제', 'System'), `${about.platform} · ${about.arch}`],
    [L('앱 언어', 'Language'), about.lang],
  ]
  if (context.window) rows.push([L('창 크기', 'Window'), context.window])
  if (context.layout) rows.push([L('쪽 배치', 'Page layout'), context.layout])
  if (context.panes) rows.push([L('열어 둔 칸', 'Panes open'), context.panes])
  if (context.paperCount !== undefined) rows.push([L('논문 수', 'Papers'), String(context.paperCount)])
  if (context.libraryCloud !== undefined) rows.push([L('클라우드 폴더', 'Cloud folder'), context.libraryCloud ? L('예', 'yes') : L('아니오', 'no')])
  if (context.recent.length > 0) rows.push([L('최근에 한 일', 'Last few actions'), context.recent.join(' → ')])
  return rows
}

/** The last few commands, by name only (`Feedback.Trail`): what somebody
 *  did just before something went wrong, never what it was done to. */
const trail: string[] = []

export function noteAction(name: string) {
  trail.push(name)
  if (trail.length > 8) trail.splice(0, trail.length - 8)
}

export function recentActions(): string[] {
  return trail.slice(-5)
}

/**
 * Whether the last run ended without quitting — a file written at launch and
 * taken away on a clean exit. Not in a probe run, which must write nothing of
 * the person's.
 */
let crashedBefore = false

function runningMarker(): string {
  return path.join(app.getPath('userData'), 'running')
}

export function markRunning(probeRun: boolean) {
  if (probeRun) return
  try {
    crashedBefore = fs.existsSync(runningMarker())
    fs.writeFileSync(runningMarker(), String(process.pid))
  } catch {
    // A folder that cannot be written only loses the note.
  }
}

export function markCleanExit(probeRun: boolean) {
  if (probeRun) return
  try {
    fs.rmSync(runningMarker(), { force: true })
  } catch {
    // Nothing to do.
  }
}

export function lastRunCrashed(): boolean {
  return crashedBefore
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
