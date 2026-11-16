export {}
/**
 * After the website's demos load: the one asked for, in its slot, woken as
 * the manual wakes it (`docs.js`), and its height told to the window so the
 * frame is as tall as the demonstration.
 *
 * `readingPlan` is the reading-plans window (`Website/plans-demo.js`), the
 * same one the page and the Mac's About show: drawn at 900 points and shown
 * smaller when the frame is narrower, so the sidebar, the plan and the
 * inspector all stay in it.
 */
const params = new URLSearchParams(location.search)
const demoName = params.get('demo') ?? ''
const slot = document.getElementById('demo')
type Made = HTMLElement & { activate?: () => void }
const page = window as unknown as {
  PaperTime?: { demos?: Record<string, () => Made> }
  PlansDemo?: { mount: (host: HTMLElement, options: Record<string, unknown>) => unknown }
}
const tell = (height: number) => parent.postMessage({ paperTimeDemo: demoName, height }, '*')
if (slot && demoName === 'readingPlan' && page.PlansDemo) {
  // Its own window and its own cards: no manual-style card around it. And it
  // says how tall it is itself — the document's height is at least the
  // frame's, so asking the document would only ever tell the frame its own size.
  slot.removeAttribute('class')
  // The frame is made as tall as the demo, so a scroll bar of its own would
  // only take width away from the fit for a moment and then vanish.
  document.documentElement.style.overflow = 'hidden'
  const theme = params.get('theme')
  page.PlansDemo.mount(slot, {
    lang: params.get('lang') === 'en' ? 'en' : 'ko',
    theme: theme === 'dark' || theme === 'light' ? theme : undefined,
    fit: 900,
    parts: ['tour', 'window', 'fine', 'howto'],
    onHeight: tell,
  })
} else {
  const make = page.PaperTime?.demos?.[demoName]
  if (slot && typeof make === 'function') {
    const demo = make()
    slot.replaceChildren(demo)
    demo.activate?.()
  }
  const report = () => tell(document.documentElement.scrollHeight)
  new ResizeObserver(report).observe(document.body)
  report()
}
