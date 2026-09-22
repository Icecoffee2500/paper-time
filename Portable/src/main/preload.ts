/**
 * The only door between the window and the files.
 *
 * Context isolation stays on and Node stays out of the renderer: the window
 * runs a PDF a stranger wrote and text a stranger typed, and giving that page
 * `require` would be handing it the user's home directory. Everything it needs
 * goes through one named channel with a fixed list of requests.
 */
import { contextBridge, ipcRenderer, webUtils } from 'electron'
import { CHANNEL } from '../shared/api.js'

/**
 * `--papertime-chrome=win32` makes the window draw the chrome of another
 * desktop. Only the window's own buttons and the traffic-light gutter differ
 * between platforms, and being able to see the Windows arrangement without a
 * Windows machine is the difference between having checked it and having
 * assumed it.
 */
const override = process.argv
  .find((argument) => argument.startsWith('--papertime-chrome='))
  ?.slice('--papertime-chrome='.length)

/**
 * Which language the interface speaks, decided by the main process from the
 * desktop's locale and the reader's override. Handed over rather than worked
 * out again here, so the window cannot disagree with its own menu bar.
 */
const language = process.argv
  .find((argument) => argument.startsWith('--papertime-lang='))
  ?.slice('--papertime-lang='.length)

/**
 * A window for one paper: `--papertime-paper=<id>` names it, and the window
 * shows that paper's reader and nothing else. `--papertime-split=1` puts the
 * first two papers side by side, for a probe.
 */
const soloPaper = process.argv
  .find((argument) => argument.startsWith('--papertime-paper='))
  ?.slice('--papertime-paper='.length)
const wantsSplit = process.argv.includes('--papertime-split=1')

contextBridge.exposeInMainWorld('papertime', {
  paper: soloPaper ?? null,
  flags: { split: wantsSplit },
  invoke: (name: string, args?: unknown) => ipcRenderer.invoke(CHANNEL.invoke, name, args),
  on: (handler: (event: string, payload: unknown) => void) => {
    const listener = (_: unknown, event: string, payload: unknown) => handler(event, payload)
    ipcRenderer.on(CHANNEL.event, listener)
    return () => ipcRenderer.removeListener(CHANNEL.event, listener)
  },
  platform: override ?? process.platform,
  korean: language === 'ko',
  /**
   * Where a dropped file is on disk.
   *
   * Electron used to hang a `path` on every `File` a drop handed the page,
   * and that property was removed in Electron 32 — it read as a silent
   * change, because the code that used it kept compiling and kept running
   * and simply found `undefined` in every file. Dragging a paper onto the
   * window did nothing at all, and said nothing either. `webUtils` answers
   * the same question from the preload, where the page cannot reach the
   * filesystem itself; a file that has no path on disk answers with ''.
   */
  pathForFile: (file: File) => {
    try { return webUtils.getPathForFile(file) } catch { return '' }
  },
})
