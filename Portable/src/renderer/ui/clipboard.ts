/**
 * Putting words on the clipboard, and knowing whether it worked.
 *
 * The page's own clipboard is refused in places — some Linux desktops under
 * Wayland turn it away when the window is not the one in front — and a toast
 * saying «Copied» over a clipboard that holds nothing is worse than no toast.
 * So the page is tried first and the main process, which always may, second.
 */
import { call } from '../bridge.js'

export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    try {
      await call('clipboard:write', { text })
      return true
    } catch {
      return false
    }
  }
}
