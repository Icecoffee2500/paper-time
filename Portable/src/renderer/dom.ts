/** Small helpers, so the views read as what they build. */

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attributes: Record<string, string | number | boolean | null | undefined> = {},
  children: (Node | string)[] = [],
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag)
  for (const [key, value] of Object.entries(attributes)) {
    if (value === null || value === undefined || value === false) continue
    if (key === 'html') {
      node.innerHTML = String(value)
      continue
    }
    if (key === 'text') {
      node.textContent = String(value)
      continue
    }
    node.setAttribute(key, String(value))
  }
  for (const child of children) {
    node.append(child)
  }
  return node
}

export function clear(node: Element) {
  while (node.firstChild) node.removeChild(node.firstChild)
}

export function on<K extends keyof HTMLElementEventMap>(
  node: EventTarget,
  event: K | string,
  handler: (event: never) => void,
  options?: AddEventListenerOptions,
) {
  node.addEventListener(event, handler as EventListener, options)
}

/** Positions a pop-up under a control, nudged back inside the window. */
export function place(menu: HTMLElement, anchor: Element, align: 'left' | 'right' = 'left') {
  const box = anchor.getBoundingClientRect()
  document.body.append(menu)
  const size = menu.getBoundingClientRect()
  let left = align === 'left' ? box.left : box.right - size.width
  left = Math.max(8, Math.min(left, window.innerWidth - size.width - 8))
  let top = box.bottom + 5
  if (top + size.height > window.innerHeight - 8) top = Math.max(8, box.top - size.height - 5)
  menu.style.left = `${left}px`
  menu.style.top = `${top}px`
}
