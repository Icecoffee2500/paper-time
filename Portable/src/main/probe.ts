/**
 * Looking at the window without touching the machine.
 *
 * The Mac side of this project learned the hard way that driving an app with
 * synthesised system events sends keystrokes into whatever happens to be in
 * front — so nothing here is posted to the desktop. A probe runs JavaScript
 * inside the page and captures the window through Electron's own API: the
 * events are made and delivered in-process, the screenshot comes from the
 * compositor, and the pointer never moves.
 *
 * `--papertime-probe=<file.json>` runs a list of steps and writes what it saw
 * beside them; `--papertime-shot=<file.png>` captures the window and quits.
 */
import { BrowserWindow, app } from 'electron'
import { CHANNEL } from '../shared/api.js'
import fsp from 'node:fs/promises'
import path from 'node:path'

export interface ProbeStep {
  /** Wait this many milliseconds before the step. */
  wait?: number
  /** Evaluate this in the page and record what it returns. */
  eval?: string
  /** Send a menu command, the way a menu item or its key would. The window
   *  cannot be sent real menu keys, so this is how a command is exercised. */
  menu?: string
  /** Capture the window to this path. */
  shot?: string
  /** Which window to capture: 0 is the window the probe runs in; a paper
   *  opened in a window of its own is the next one. */
  window?: number
  /**
   * Capture only this region, in window points.
   *
   * Cropping afterwards with `sips --cropOffset` does not reliably crop —
   * the Mac side of this project learned that the hard way — and Electron's
   * own capture takes a rectangle, so the crop happens where the pixels are.
   */
  rect?: { x: number; y: number; width: number; height: number }
  /**
   * A pointer gesture over an element, in the element's own coordinates.
   *
   * `keys` are held on the moves (and the release), never on the press: that
   * is how a key is held in life, and it matters — Shift at the press means
   * "add this to the selection", so a drag that began that way would have let
   * go of what it carries. `hold` leaves the button down, so the picture that
   * follows has the drag still in hand: the only way to photograph what is
   * drawn only while it is.
   */
  drag?: {
    selector: string
    from: [number, number]
    to: [number, number]
    steps?: number
    keys?: { shift?: boolean; alt?: boolean; meta?: boolean; ctrl?: boolean }
    hold?: boolean
  }
  click?: { selector: string; at?: [number, number] }
  /** A key, delivered to the page rather than to the desktop. */
  key?: { key: string; shift?: boolean; meta?: boolean }
  note?: string
}

export function probeArgument(name: string): string | null {
  const prefix = `--papertime-${name}=`
  const found = process.argv.find((argument) => argument.startsWith(prefix))
  return found ? found.slice(prefix.length) : null
}

const GESTURE = `
(() => {
  window.__probe = {
    element(selector) {
      const node = document.querySelector(selector)
      if (!node) throw new Error('No element for ' + selector)
      return node
    },
    point(node, x, y) {
      const box = node.getBoundingClientRect()
      return { clientX: box.left + x, clientY: box.top + y }
    },
    send(node, type, x, y, extra = {}) {
      const at = this.point(node, x, y)
      node.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true,
        pointerId: 1, pointerType: 'mouse', isPrimary: true,
        button: type === 'pointermove' ? -1 : 0,
        buttons: type === 'pointerup' ? 0 : 1,
        pressure: type === 'pointerup' ? 0 : 0.5,
        ...at, ...extra,
      }))
    },
    drag(selector, from, to, steps = 12, keys = {}, hold = false) {
      const node = this.element(selector)
      // Capture is a no-op on a detached pointer id, and would otherwise
      // route the moves away from the element under test.
      node.setPointerCapture = () => {}
      node.releasePointerCapture = () => {}
      const held = {
        shiftKey: Boolean(keys.shift), altKey: Boolean(keys.alt),
        metaKey: Boolean(keys.meta), ctrlKey: Boolean(keys.ctrl),
      }
      this.send(node, 'pointerdown', from[0], from[1])
      for (let i = 1; i <= steps; i += 1) {
        const t = i / steps
        this.send(node, 'pointermove', from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t, held)
      }
      if (!hold) this.send(node, 'pointerup', to[0], to[1], held)
      return hold ? 'still down' : true
    },
    click(selector, at) {
      const node = this.element(selector)
      if (at) {
        node.setPointerCapture = () => {}
        node.releasePointerCapture = () => {}
        this.send(node, 'pointerdown', at[0], at[1])
        this.send(node, 'pointerup', at[0], at[1])
      }
      node.click?.()
      return true
    },
    key(key, shift, meta) {
      const event = new KeyboardEvent('keydown', {
        key, bubbles: true, cancelable: true,
        shiftKey: Boolean(shift), metaKey: Boolean(meta), ctrlKey: Boolean(meta),
      })
      window.dispatchEvent(event)
      return true
    },
  }
  return 'ready'
})()
`

export async function runProbe(window: BrowserWindow, file: string) {
  const steps = JSON.parse(await fsp.readFile(file, 'utf8')) as ProbeStep[]
  const results: unknown[] = []
  await window.webContents.executeJavaScript(GESTURE)
  for (const step of steps) {
    if (step.wait) await delay(step.wait)
    try {
      if (step.click) {
        results.push(await window.webContents.executeJavaScript(
          `window.__probe.click(${JSON.stringify(step.click.selector)}, ${JSON.stringify(step.click.at ?? null)})`))
      } else if (step.drag) {
        results.push(await window.webContents.executeJavaScript(
          `window.__probe.drag(${JSON.stringify(step.drag.selector)}, ${JSON.stringify(step.drag.from)}, ${JSON.stringify(step.drag.to)}, ${step.drag.steps ?? 12}, ${JSON.stringify(step.drag.keys ?? {})}, ${Boolean(step.drag.hold)})`))
      } else if (step.key) {
        results.push(await window.webContents.executeJavaScript(
          `window.__probe.key(${JSON.stringify(step.key.key)}, ${Boolean(step.key.shift)}, ${Boolean(step.key.meta)})`))
      } else if (step.menu) {
        window.webContents.send(CHANNEL.event, 'menu', step.menu)
        results.push(`menu: ${step.menu}`)
      } else if (step.shot) {
        const target = step.window ? BrowserWindow.getAllWindows().filter((w) => w !== window)[step.window - 1] ?? window : window
        const image = await target.webContents.capturePage(step.rect)
        await fsp.mkdir(path.dirname(step.shot), { recursive: true })
        await fsp.writeFile(step.shot, image.toPNG())
        results.push(`shot: ${step.shot}`)
      } else if (step.eval) {
        results.push(await window.webContents.executeJavaScript(step.eval))
      } else {
        results.push(step.note ?? null)
      }
    } catch (error) {
      results.push({ error: String(error) })
    }
  }
  process.stdout.write(`${JSON.stringify(results, null, 2)}\n`)
  app.quit()
}

export async function captureAndQuit(window: BrowserWindow, file: string, after = 2500) {
  await delay(after)
  const image = await window.webContents.capturePage()
  await fsp.mkdir(path.dirname(file), { recursive: true })
  await fsp.writeFile(file, image.toPNG())
  process.stdout.write(`shot: ${file}\n`)
  app.quit()
}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))
