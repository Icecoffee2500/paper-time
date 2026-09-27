/**
 * The windows: the library's, and one for each paper torn off into its own.
 *
 * Both are the same page with the same chrome; a paper's window is told
 * which paper it is for and shows that paper's reader and nothing else.
 * Everything platform-specific about the frame lives here and in `menu.ts`.
 */
import { BrowserWindow, nativeTheme, screen, shell } from 'electron'
import path from 'node:path'
import { CHANNEL, type WindowState } from '../shared/api.js'
import { settings, update } from './settings.js'
import { probe } from './probeMode.js'

export interface WindowShape {
  width: number
  height: number
  x?: number
  y?: number
}

/** `--ground` in style.css, light and dark. */
export const GROUND = { light: '#e9eaec', dark: '#202024' }

export interface WindowsOptions {
  /** See `--papertime-chrome` in `preload.ts`. */
  chromeOverride: string | null
  korean: () => boolean
  /** `--papertime-split=1`: the first two papers side by side, for a probe. */
  split: boolean
}

export class Windows {
  main: BrowserWindow | null = null
  readonly papers = new Set<BrowserWindow>()

  constructor(private readonly options: WindowsOptions) {}

  /** The window in front, or the main one. */
  get focused(): BrowserWindow | null {
    return BrowserWindow.getFocusedWindow() ?? this.main
  }

  /** What every window should hear: the library changed, the theme changed. */
  send(event: string, payload?: unknown) {
    for (const target of BrowserWindow.getAllWindows()) {
      if (!target.isDestroyed()) target.webContents.send(CHANNEL.event, event, payload)
    }
  }

  /** Every window but one — the one that made the change and already has the answer. */
  sendExcept(except: BrowserWindow | null, event: string, payload?: unknown) {
    for (const target of BrowserWindow.getAllWindows()) {
      if (target !== except && !target.isDestroyed()) target.webContents.send(CHANNEL.event, event, payload)
    }
  }

  /** A menu command goes to the window it was meant for — the one in front. */
  sendToFocused(event: string, payload?: unknown) {
    this.sendTo(this.focused, event, payload)
  }

  sendTo(target: BrowserWindow | null, event: string, payload?: unknown) {
    if (target && !target.isDestroyed()) target.webContents.send(CHANNEL.event, event, payload)
  }

  createMain(): BrowserWindow {
    const saved = settings().window
    const made = this.make(onAScreen(saved), this.options.split ? ['--papertime-split=1'] : [])
    this.main = made
    // A probe keeps its own window where nobody is, and so neither fills the
    // screen nor writes that place into the settings of whoever uses this copy.
    if (saved.maximized && !probe.isRun) made.maximize()
    const remember = () => {
      if (made.isDestroyed() || probe.isRun) return
      // The frame a maximised window had before, not the whole screen.
      const kept = made.isMaximized()
        ? { ...settings().window, maximized: true }
        : { ...made.getBounds(), maximized: false }
      update({ window: kept }, { soon: true })
    }
    made.on('resize', remember)
    made.on('move', remember)
    made.on('closed', () => {
      if (this.main === made) this.main = null
    })
    return made
  }

  /**
   * A window of its own for one paper, the way a browser tab torn off becomes
   * a window. Put with its top-left corner near the point when there is one —
   * where a drag ended — and beside the main window otherwise.
   */
  createPaper(id: string, at?: { x: number; y: number }): BrowserWindow {
    const shape: WindowShape = { width: 900, height: 760 }
    if (at) {
      shape.x = Math.round(at.x - 40)
      shape.y = Math.round(at.y - 20)
    } else if (this.main && !this.main.isDestroyed()) {
      const bounds = this.main.getBounds()
      shape.x = bounds.x + 60
      shape.y = bounds.y + 60
    }
    const made = this.make(shape, [`--papertime-paper=${id}`])
    this.papers.add(made)
    made.on('closed', () => this.papers.delete(made))
    return made
  }

  state(target: BrowserWindow | null = this.main): WindowState {
    const live = target && !target.isDestroyed() ? target : null
    return {
      maximized: live?.isMaximized() ?? false,
      fullScreen: live?.isFullScreen() ?? false,
      focused: live?.isFocused() ?? true,
    }
  }

  /** Every window of ours, in screen points. */
  allBounds() {
    return BrowserWindow.getAllWindows()
      .filter((target) => !target.isDestroyed() && target.isVisible())
      .map((target) => target.getBounds())
  }

  private make(shape: WindowShape, extraArguments: string[]): BrowserWindow {
    const isMac = process.platform === 'darwin'
    const made = new BrowserWindow({
      width: shape.width,
      height: shape.height,
      x: shape.x,
      y: shape.y,
      minWidth: 720,
      minHeight: 480,
      show: false,
      title: 'Paper Time',
      // The toolbar is the app's, not the system's, so the frame goes. On a
      // Mac the traffic lights stay where a Mac user reaches for them; on
      // Windows and Linux the window's own buttons are drawn in the toolbar's
      // right end, where those desktops put them. Everything between the two
      // ends is the same pixel for pixel.
      frame: false,
      titleBarStyle: isMac ? 'hiddenInset' : 'hidden',
      trafficLightPosition: isMac ? { x: 14, y: 16 } : undefined,
      // The page's own ground, from the appearance the reader chose, so the
      // window does not flash another colour first.
      backgroundColor: launchGround(),
      webPreferences: {
        preload: path.join(__dirname, 'preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: false,
        spellcheck: true,
        // A probe's window sits outside every display, where Chromium counts
        // it as hidden and slows its timers and frames to a crawl — which
        // would make every timing a probe takes a timing of the throttle.
        backgroundThrottling: !probe.isRun,
        // The renderer gets its own argv; the app's is not passed down, so the
        // flags the window needs are handed over explicitly.
        additionalArguments: [
          ...(this.options.chromeOverride ? [`--papertime-chrome=${this.options.chromeOverride}`] : []),
          `--papertime-lang=${this.options.korean() ? 'ko' : 'en'}`,
          ...(probe.isRun ? ['--papertime-probe-run=1'] : []),
          ...extraArguments,
        ],
      },
    })

    made.loadFile(path.join(__dirname, '../renderer/index.html'))
    made.once('ready-to-show', () => {
      if (!probe.isRun) return made.show()
      // Outside every display, shown without activating anything.
      const { width, height } = made.getBounds()
      made.setBounds({ ...offscreen(width), width, height })
      made.showInactive()
    })
    for (const event of ['maximize', 'unmaximize', 'enter-full-screen', 'leave-full-screen', 'focus', 'blur']) {
      made.on(event as 'maximize', () => this.sendTo(made, 'window:state', this.state(made)))
    }

    // A page in the reader must never navigate the app away from itself, and
    // a link in a paper belongs in the user's browser, not inside this window.
    made.webContents.setWindowOpenHandler(({ url }) => {
      if (/^https?:/.test(url)) shell.openExternal(url)
      return { action: 'deny' }
    })
    made.webContents.on('will-navigate', (event, url) => {
      if (!url.startsWith('file://')) event.preventDefault()
    })
    return made
  }
}

export function launchGround(): string {
  const appearance = settings().appearance
  const dark = appearance === 'dark' || (appearance === 'system' && nativeTheme.shouldUseDarkColors)
  return dark ? GROUND.dark : GROUND.light
}

/**
 * The saved place, when a display still shows it. A window saved on a
 * monitor that has since been unplugged opened off every screen, with no
 * way to drag it back; its size is kept and the desktop picks the place.
 */
export function onAScreen(saved: WindowShape, displays = screen.getAllDisplays().map((one) => one.workArea)): WindowShape {
  const width = Number.isFinite(saved.width) ? Math.max(720, Math.round(saved.width)) : 1440
  const height = Number.isFinite(saved.height) ? Math.max(480, Math.round(saved.height)) : 900
  const shape: WindowShape = { width, height }
  if (!Number.isFinite(saved.x) || !Number.isFinite(saved.y)) return shape
  const x = Math.round(saved.x!)
  const y = Math.round(saved.y!)
  // Enough of the title bar to take hold of: 120 × 40 points on some display.
  const area = displays.find((one) =>
    x + width - 120 >= one.x && x + 120 <= one.x + one.width &&
    y + 40 >= one.y && y <= one.y + one.height - 40)
  if (!area) return shape
  return { x, y, width: Math.min(width, area.width), height: Math.min(height, area.height) }
}

/**
 * A place no display covers: right of the rightmost one, level with the
 * highest. The union of every display rather than the primary one, because a
 * second monitor to the left or above has real pixels at negative coordinates.
 * The window draws and can be captured there like anywhere else; nobody sees it.
 */
export function offscreen(width: number): { x: number; y: number } {
  const displays = screen.getAllDisplays().map((one) => one.bounds)
  const right = Math.max(...displays.map((one) => one.x + one.width))
  const top = Math.min(...displays.map((one) => one.y))
  return { x: right + Math.max(width, 400), y: top }
}
