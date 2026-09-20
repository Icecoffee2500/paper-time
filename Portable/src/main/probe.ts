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
import { app, type BrowserWindow } from 'electron'
import fsp from 'node:fs/promises'
import path from 'node:path'

export interface ProbeStep {
  /** Wait this many milliseconds before the step. */
  wait?: number
  /** Evaluate this in the page and record what it returns. */
  eval?: string
  /** Capture the window to this path. */
  shot?: string
  /**
   * Capture only this region, in window points.
   *
   * Cropping afterwards with `sips --cropOffset` does not reliably crop —
   * the Mac side of this project learned that the hard way — and Electron's
   * own capture takes a rectangle, so the crop happens where the pixels are.
   */
  rect?: { x: number; y: number; width: number; height: number }
  /** A pointer gesture over an element, in the element's own coordinates. */
  drag?: { selector: string; from: [number, number]; to: [number, number]; steps?: number }
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
    drag(selector, from, to, steps = 12) {
      const node = this.element(selector)
      // Capture is a no-op on a detached pointer id, and would otherwise
      // route the moves away from the element under test.
      node.setPointerCapture = () => {}
      node.releasePointerCapture = () => {}
      this.send(node, 'pointerdown', from[0], from[1])
      for (let i = 1; i <= steps; i += 1) {
        const t = i / steps
        this.send(node, 'pointermove', from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t)
      }
      this.send(node, 'pointerup', to[0], to[1])
      return true
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
          `window.__probe.drag(${JSON.stringify(step.drag.selector)}, ${JSON.stringify(step.drag.from)}, ${JSON.stringify(step.drag.to)}, ${step.drag.steps ?? 12})`))
      } else if (step.key) {
        results.push(await window.webContents.executeJavaScript(
          `window.__probe.key(${JSON.stringify(step.key.key)}, ${Boolean(step.key.shift)}, ${Boolean(step.key.meta)})`))
      } else if (step.shot) {
        const image = await window.webContents.capturePage(step.rect)
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
