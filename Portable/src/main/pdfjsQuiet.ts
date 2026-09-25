/**
 * Stand-ins for the three drawing classes pdf.js looks for when it finds
 * itself in plain Node.
 *
 * It wants them to render, and says "rendering may be broken" for each one
 * it cannot find — three lines on every start, in every test run. Reading a
 * page's text draws nothing, so an empty class is the honest answer: if
 * anything ever did try to draw with one, it would fail loudly rather than
 * draw wrong.
 */
const scope = globalThis as unknown as Record<string, unknown>
for (const name of ['DOMMatrix', 'ImageData', 'Path2D']) {
  if (typeof scope[name] === 'undefined') scope[name] = class {}
}

export {}
