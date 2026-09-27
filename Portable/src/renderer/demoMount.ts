export {}
/**
 * After the website's demos load: the one asked for, in its slot, woken as
 * the manual wakes it (`docs.js`), and its height told to the window so the
 * frame is as tall as the demonstration.
 */
const params = new URLSearchParams(location.search)
const demoName = params.get('demo') ?? ''
const slot = document.getElementById('demo')
const demos = (window as unknown as { PaperTime?: { demos?: Record<string, () => HTMLElement & { activate?: () => void }> } }).PaperTime?.demos
const make = demos?.[demoName]
if (slot && typeof make === 'function') {
  const demo = make()
  slot.replaceChildren(demo)
  demo.activate?.()
}
const report = () => parent.postMessage({ paperTimeDemo: demoName, height: document.documentElement.scrollHeight }, '*')
new ResizeObserver(report).observe(document.body)
report()
