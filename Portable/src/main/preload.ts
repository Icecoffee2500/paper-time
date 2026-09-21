/**
 * The only door between the window and the files.
 *
 * Context isolation stays on and Node stays out of the renderer: the window
 * runs a PDF a stranger wrote and text a stranger typed, and giving that page
 * `require` would be handing it the user's home directory. Everything it needs
 * goes through one named channel with a fixed list of requests.
 */
import { contextBridge, ipcRenderer } from 'electron'
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
})
