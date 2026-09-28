/**
 * Whether there is a newer Paper Time, and — on Windows — installing it:
 * the Mac's `UpdateCenter`, with electron-updater where the Mac has Sparkle.
 *
 * Looks a few seconds after launch and then once a day, at the page's
 * `releases.json`. What it finds at launch is a sheet; what it finds later,
 * with a paper open, is a line at the bottom of the window. On Windows the
 * installer comes down in the background and Install Now runs it; Later
 * leaves it to run when the app quits. On Linux both buttons open the
 * download page — an AppImage and a tar.gz are replaced differently, and
 * the app cannot tell which one it is (the choice was the reader's: notice
 * only, the same for both).
 *
 * A probe looks nowhere unless given a feed (`--papertime-update-feed=`),
 * and never installs.
 */
import { app, net, shell } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { FEED_URL, NO_UPDATE, offerFrom, type UpdateState } from '../shared/updates.js'
import { probe } from './probeMode.js'
import { settings, update } from './settings.js'

/** What installs an update: electron-updater on Windows. */
interface Installer {
  prepare(version: string): void
  install(): void
  cancel(): void
}

export class Updates {
  private state: UpdateState = { ...NO_UPDATE }
  private installer: Installer | null = null
  private timer: NodeJS.Timeout | null = null
  private skippedInMemory: string | null = null

  constructor(
    private readonly send: (state: UpdateState) => void,
    private readonly log: (line: string) => void,
  ) {}

  get current(): UpdateState {
    return { ...this.state, current: this.version }
  }

  private get feed(): string | null {
    const given = probe.argument('update-feed')
    if (given) return given
    return probe.isRun ? null : FEED_URL
  }

  private get version(): string {
    return probe.argument('update-as') || app.getVersion()
  }

  private get skipped(): string | null {
    return probe.isRun ? this.skippedInMemory : settings().skippedUpdateVersion
  }

  private change(patch: Partial<UpdateState>, event: string) {
    this.state = { ...this.state, ...patch, current: this.version }
    this.send(this.state)
    if (probe.argument('update-log') === '1') {
      const { offer, stage, showsSheet, showsBar, lastCheckFailed, installs } = this.state
      this.log(`update: offer ${offer?.version ?? 'none'} steps ${offer?.steps.map((one) => one.version).join(',') || '-'} stage ${stage} sheet ${showsSheet} bar ${showsBar} failed ${lastCheckFailed} installs ${installs} download ${offer?.download ?? '-'} after ${event}`)
    }
  }

  /** Once the window is up. */
  start() {
    if (this.timer) return
    setTimeout(() => void this.check({ atLaunch: probe.argument('update-bar') !== '1' }), probe.isRun ? 800 : 4000)
    // Once an hour it asks whether a day has gone by; a day-long timer would
    // drift across sleep.
    this.timer = setInterval(() => {
      const last = this.state.lastCheck
      if (last && Date.now() - last > 86_000_000) void this.check({ atLaunch: false })
    }, 3_600_000)
    this.timer.unref?.()
    sweepCache(this.log)
  }

  /** `userInitiated`: Settings' «Check Now» — runs even when checking is off, and shows a skipped version. */
  async check({ atLaunch, userInitiated = false }: { atLaunch: boolean; userInitiated?: boolean }) {
    const feed = this.feed
    if ((!userInitiated && settings().checkForUpdates === false) || !feed || this.state.checking) return
    this.change({ checking: true }, 'start')
    let offer
    try {
      offer = offerFrom(await read(feed), this.version, process.platform)
    } catch (error) {
      this.change({ checking: false, lastCheckFailed: true }, `check (${String((error as Error)?.message ?? error)})`)
      return
    }
    const base = { checking: false, lastCheckFailed: false, lastCheck: Date.now() }
    if (!offer) {
      if (this.state.offer) this.installer?.cancel()
      this.change({ ...base, offer: null, showsSheet: false, showsBar: false }, 'check')
      return
    }
    if (!userInitiated && offer.version === this.skipped) {
      this.change(base, 'check (skipped)')
      return
    }
    const isNew = offer.version !== this.state.offer?.version
    const next: Partial<UpdateState> = { ...base, offer }
    if (isNew) {
      if (!this.installer) this.installer = makeInstaller(this)
      Object.assign(next, { stage: this.installer ? 'preparing' : 'manual', progress: null, wantsInstall: false, installs: this.installer != null })
    }
    if (userInitiated || atLaunch) Object.assign(next, { showsSheet: true, showsBar: false })
    else if (isNew) next.showsBar = true
    this.change(next, 'check')
    if (isNew) this.installer?.prepare(offer.version)
  }

  // MARK: What the notice's buttons do

  act(action: 'install' | 'later' | 'skip' | 'hideBar' | 'showChanges' | 'closeSheet') {
    const { offer, stage } = this.state
    switch (action) {
      case 'showChanges':
        return this.change({ showsSheet: true }, action)
      case 'closeSheet':
        return this.change({ showsSheet: false }, action)
      case 'hideBar':
        return this.change({ showsBar: false }, action)
      case 'later':
        return this.change({ showsSheet: false, showsBar: false, wantsInstall: false }, action)
      case 'skip':
        if (!offer) return
        if (probe.isRun) this.skippedInMemory = offer.version
        else update({ skippedUpdateVersion: offer.version })
        this.installer?.cancel()
        return this.change({ offer: null, showsSheet: false, showsBar: false }, action)
      case 'install':
        if (!offer) return
        if (stage === 'manual') {
          void shell.openExternal(offer.download)
          return this.change({ showsSheet: false, showsBar: false }, action)
        }
        if (stage === 'ready') {
          this.change({ stage: 'installing' }, action)
          return this.installer?.install()
        }
        if (stage !== 'installing') this.change({ wantsInstall: true }, action)
    }
  }

  // MARK: What the installer reports

  progress(fraction: number | null) {
    if (this.state.stage !== 'manual') this.change({ stage: 'downloading', progress: fraction }, 'progress')
  }

  ready() {
    if (this.state.wantsInstall) {
      this.change({ stage: 'installing' }, 'ready')
      this.installer?.install()
    } else {
      this.change({ stage: 'ready', progress: 1 }, 'ready')
    }
  }

  failed(reason: string) {
    this.change({ stage: 'manual', wantsInstall: false }, `failed (${reason})`)
  }
}

/** The feed, from the page or — for a probe — a file. */
async function read(feed: string): Promise<unknown> {
  if (!/^https?:\/\//.test(feed)) return JSON.parse(await fs.promises.readFile(feed, 'utf8'))
  const response = await net.fetch(feed, {
    cache: 'no-store',
    headers: { 'User-Agent': `Paper Time/${app.getVersion()} (${process.platform})` },
    credentials: 'omit',
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

/**
 * electron-updater, on an installed Windows copy only. The release's own
 * `latest.yml` says which file and its SHA-512; the installer runs silently
 * (`/S`) and starts the app again. Nothing is downloaded differentially —
 * that would need the 250 MB installer copy the installer script clears
 * away (assets/installer.nsh).
 */
function makeInstaller(center: Updates): Installer | null {
  if (process.platform !== 'win32' || !app.isPackaged || probe.isRun) return null
  // Required here rather than imported at the top, so Linux and a probe
  // never load it.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { NsisUpdater } = require('electron-updater') as typeof import('electron-updater')
  let updater: InstanceType<typeof NsisUpdater> | null = null
  return {
    prepare(version) {
      updater = new NsisUpdater({
        provider: 'generic',
        url: `https://github.com/Icecoffee2500/paper-time/releases/download/${version}/`,
      })
      updater.autoDownload = true
      updater.autoInstallOnAppQuit = true
      updater.disableDifferentialDownload = true
      updater.allowDowngrade = false
      updater.logger = null
      updater.on('download-progress', (info) => center.progress(info.total ? info.transferred / info.total : null))
      updater.on('update-downloaded', () => center.ready())
      updater.on('error', (error) => center.failed(String(error?.message ?? error)))
      updater.on('update-not-available', () => center.failed('not in latest.yml'))
      center.progress(null)
      updater.checkForUpdates().catch((error) => center.failed(String(error?.message ?? error)))
    },
    install() {
      // Silent, and the app comes back when it is done.
      updater?.quitAndInstall(true, true)
    },
    cancel() {
      if (updater) updater.autoInstallOnAppQuit = false
      updater = null
    },
  }
}

/**
 * What electron-updater leaves behind once it has done its job: the
 * installer it ran, 130 MB in %LOCALAPPDATA%\paper-time-updater\pending.
 * Taken away when this copy is at least that version.
 */
function sweepCache(log: (line: string) => void) {
  if (process.platform !== 'win32' || probe.isRun) return
  const pending = path.join(process.env.LOCALAPPDATA ?? '', 'paper-time-updater', 'pending')
  fs.promises.rm(pending, { recursive: true, force: true }).catch((error) => log(`updates - could not clear ${pending}: ${error}`))
}
