/**
 * The page's tint and the pictures night keeps as printed.
 *
 * The rule for which rendering a tint gets is the Mac's
 * (`ReaderConfiguration.rendering`), and the colours are its colours, so the
 * first half asks the same questions of `shared/pageTint.ts`. The second half
 * walks operator lists — made up, and then a real one: a PDF built here with
 * a picture in every shape pdf.js paints one in, read by the same pdf.js the
 * window uses, so what the walker is fed is what the reader will feed it.
 */
import assert from 'node:assert/strict'
import path from 'node:path'
import { PDFDocument, PDFName, type PDFRef } from 'pdf-lib'
import * as pdfjs from 'pdfjs-dist/legacy/build/pdf.mjs'
import {
  DEFAULT_TINT_COLOR,
  NIGHT_GROUND,
  PAGE_TINTS,
  SEPIA_GROUND,
  groundFor,
  hexOf,
  luminance,
  pageTintFrom,
  parseHex,
  renderingFor,
  tintColorFrom,
  tintLabel,
} from '../shared/pageTint.js'
import {
  concat,
  imageRects,
  isInkOnWhite,
  pixelRect,
  tones,
  unitSquare,
  type OperatorList,
  type PageRect,
} from '../shared/pageImages.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

/** Close enough for a rectangle worked out through two matrices. */
function near(actual: PageRect, expected: [number, number, number, number], what: string) {
  const got = [actual.x, actual.y, actual.width, actual.height]
  for (let i = 0; i < 4; i += 1) {
    assert.ok(Math.abs(got[i] - expected[i]) < 0.01, `${what}: ${JSON.stringify(got)} is not ${JSON.stringify(expected)}`)
  }
}

// pdf.js's own numbers, so a test and the window read the same list.
const OPS = pdfjs.OPS as unknown as Record<string, number>

function list(steps: [string, unknown?][]): OperatorList {
  return { fnArray: steps.map(([name]) => OPS[name]), argsArray: steps.map(([, args]) => args ?? null) }
}

export async function pageTintSuite(test: Test, suite: (name: string) => void) {
  suite('The page tint — the Mac\'s model')

  await test('the five tints, in the order both builds offer them', () => {
    assert.deepEqual([...PAGE_TINTS], ['none', 'sepia', 'dim', 'glass', 'custom'])
    for (const tint of PAGE_TINTS) assert.ok(tintLabel(tint).length > 0)
  })

  await test('the old names are read as the new ones', () => {
    assert.equal(pageTintFrom('night'), 'dim')
    assert.equal(pageTintFrom('grey'), 'none')
    assert.equal(pageTintFrom('sepia'), 'sepia')
    assert.equal(pageTintFrom('glass'), 'glass')
    assert.equal(pageTintFrom('custom'), 'custom')
    assert.equal(pageTintFrom('dim'), 'dim')
    assert.equal(pageTintFrom(undefined), 'none')
    assert.equal(pageTintFrom('lavender'), 'none')
    assert.equal(pageTintFrom(3), 'none')
  })

  await test('the grounds are the Mac\'s colours, written the way it writes them', () => {
    // `TintColor.sepia` and `TintColor.night`, through `hex`.
    assert.equal(hexOf(0.96, 0.93, 0.86), SEPIA_GROUND)
    assert.equal(hexOf(0.149, 0.153, 0.169), NIGHT_GROUND)
    assert.equal(DEFAULT_TINT_COLOR, '#26272b')
  })

  await test('a stored colour is a colour or the default', () => {
    assert.deepEqual(parseHex('#ff8000'), [1, 128 / 255, 0])
    assert.deepEqual(parseHex('FF8000'), [1, 128 / 255, 0])
    assert.equal(parseHex('#ff80'), null)
    assert.equal(parseHex('#gg0000'), null)
    assert.equal(tintColorFrom('#ABCDEF'), '#abcdef')
    assert.equal(tintColorFrom(' 123456 '), '#123456')
    assert.equal(tintColorFrom('red'), DEFAULT_TINT_COLOR)
    assert.equal(tintColorFrom(null), DEFAULT_TINT_COLOR)
  })

  await test('luminance is WCAG\'s, over linear sRGB', () => {
    assert.equal(luminance('#000000'), 0)
    assert.ok(Math.abs(luminance('#ffffff') - 1) < 1e-12)
    assert.ok(Math.abs(luminance('#26272b') - 0.0204) < 0.0005)
    assert.ok(luminance(SEPIA_GROUND) > 0.8)
  })

  await test('each tint draws the way its ground decides', () => {
    for (const dark of [false, true]) {
      assert.equal(renderingFor('none', DEFAULT_TINT_COLOR, dark), 'plain')
      assert.equal(renderingFor('sepia', DEFAULT_TINT_COLOR, dark), 'multiply')
      assert.equal(renderingFor('dim', '#ffffff', dark), 'night')
    }
    // The panel behind Glass is light or dark with the appearance.
    assert.equal(renderingFor('glass', DEFAULT_TINT_COLOR, false), 'multiply')
    assert.equal(renderingFor('glass', DEFAULT_TINT_COLOR, true), 'night')
  })

  await test('a custom ground multiplies when it is light and goes to night when it is dark', () => {
    assert.equal(renderingFor('custom', '#26272b', false), 'night')
    assert.equal(renderingFor('custom', '#f4ecd8', true), 'multiply')
    // The line falls between these two greys: 188 is just light enough.
    assert.ok(luminance('#bcbcbc') >= 0.5 && luminance('#bbbbbb') < 0.5)
    assert.equal(renderingFor('custom', '#bcbcbc', false), 'multiply')
    assert.equal(renderingFor('custom', '#bbbbbb', false), 'night')
    // Whatever it is, the appearance does not change it.
    assert.equal(renderingFor('custom', '#bbbbbb', true), 'night')
    // A colour that is not one is the default, and the default is dark.
    assert.equal(renderingFor('custom', 'nonsense', false), 'night')
  })

  await test('the ground is the tint\'s colour, or the panel\'s own for none and Glass', () => {
    assert.equal(groundFor('none', '#123456'), null)
    assert.equal(groundFor('glass', '#123456'), null)
    assert.equal(groundFor('sepia', '#123456'), SEPIA_GROUND)
    assert.equal(groundFor('dim', '#123456'), NIGHT_GROUND)
    assert.equal(groundFor('custom', '#ABCDEF'), '#abcdef')
    assert.equal(groundFor('custom', 'nonsense'), DEFAULT_TINT_COLOR)
  })

  suite('The pictures night keeps as printed')

  await test('matrices compose the way the canvas composes them', () => {
    const scale: [number, number, number, number, number, number] = [2, 0, 0, 3, 0, 0]
    const move: [number, number, number, number, number, number] = [1, 0, 0, 1, 10, 20]
    // Moved in the scaled space: the move is scaled too.
    assert.deepEqual(concat(scale, move), [2, 0, 0, 3, 20, 60])
    near(unitSquare([0, 1, -1, 0, 500, 300]), [499, 300, 1, 1], 'a quarter turn')
  })

  await test('an image is the unit square of the matrix in force', () => {
    const rects = imageRects(list([
      ['save'], ['transform', [200, 0, 0, 100, 50, 600]], ['paintImageXObject', ['img_1', 4, 4]], ['restore'],
      ['save'], ['transform', [0, 1, -1, 0, 500, 300]], ['transform', [120, 0, 0, 60, 0, 0]],
      ['paintInlineImageXObject', [{}]], ['restore'],
    ]), OPS)
    assert.equal(rects.length, 2)
    near(rects[0], [50, 600, 200, 100], 'placed')
    near(rects[1], [440, 300, 60, 120], 'turned')
  })

  await test('a form is drawn with its own matrix after ours, and forgets it after', () => {
    const rects = imageRects(list([
      ['transform', [1, 0, 0, 1, 10, 0]],
      ['paintFormXObjectBegin', [[0.5, 0, 0, 0.5, 300, 100], [0, 0, 1000, 1000]]],
      ['transform', [100, 0, 0, 100, 0, 0]],
      ['paintImageXObject', ['img_1', 4, 4]],
      ['paintFormXObjectEnd'],
      ['transform', [100, 0, 0, 100, 0, 0]],
      ['paintImageXObject', ['img_1', 4, 4]],
    ]), OPS)
    near(rects[0], [310, 100, 50, 50], 'inside the form')
    near(rects[1], [10, 0, 100, 100], 'after it')
  })

  await test('a transparency group saves and restores without a matrix of its own', () => {
    const rects = imageRects(list([
      ['beginGroup', [{ matrix: [9, 0, 0, 9, 9, 9], bbox: [0, 0, 1, 1] }]],
      ['paintFormXObjectBegin', [[2, 0, 0, 2, 0, 0], null]],
      ['transform', [50, 0, 0, 50, 0, 0]],
      ['paintImageXObject', ['img_1', 4, 4]],
      ['paintFormXObjectEnd'],
      ['endGroup', [{}]],
      ['transform', [50, 0, 0, 50, 0, 0]],
      ['paintImageXObject', ['img_1', 4, 4]],
    ]), OPS)
    near(rects[0], [0, 0, 100, 100], 'in the group')
    near(rects[1], [0, 0, 50, 50], 'after it')
  })

  await test('an annotation\'s appearance starts from the page, whatever came before', () => {
    const rects = imageRects(list([
      ['save'], ['transform', [3, 0, 0, 3, 0, 0]],
      ['beginAnnotation', ['1R', [400, 100, 500, 150], [1, 0, 0, 1, 400, 100], [1, 0, 0, 1, 0, 0], false]],
      ['transform', [100, 0, 0, 50, 0, 0]],
      ['paintImageXObject', ['img_1', 4, 4]],
      ['endAnnotation'],
    ]), OPS)
    near(rects[0], [400, 100, 100, 50], 'the stamp')
  })

  await test('one image at many places, and many small ones in one call, are each a rectangle', () => {
    const rects = imageRects(list([
      ['transform', [2, 0, 0, 2, 0, 0]],
      ['paintImageXObjectRepeat', ['img_1', 50, 30, new Float32Array([0, 0, 100, 0])]],
      ['paintInlineImageXObjectGroup', [{}, [{ transform: [60, 0, 0, 40, 10, 200], x: 0, y: 0, w: 1, h: 1 }]]],
    ]), OPS)
    assert.equal(rects.length, 3)
    near(rects[0], [0, 0, 100, 60], 'first repeat')
    near(rects[1], [200, 0, 100, 60], 'second repeat')
    near(rects[2], [20, 400, 120, 80], 'the inline group')
  })

  await test('stencil masks, hairlines and pictures off the page are not kept; small photographs are', () => {
    const rects = imageRects(list([
      ['save'], ['transform', [200, 0, 0, 100, 50, 450]], ['paintImageMaskXObject', [{}]], ['restore'],
      ['save'], ['transform', [200, 0, 0, 100, 50, 450]], ['paintSolidColorImageMask'], ['restore'],
      // A rule drawn as an image, either way round: 12 points is not a picture.
      ['save'], ['transform', [12, 0, 0, 300, 0, 0]], ['paintImageXObject', ['img_1', 4, 4]], ['restore'],
      ['save'], ['transform', [300, 0, 0, 12, 0, 0]], ['paintImageXObject', ['img_1', 4, 4]], ['restore'],
      ['save'], ['transform', [100, 0, 0, 50, 700, 700]], ['paintImageXObject', ['img_1', 4, 4]], ['restore'],
      ['save'], ['transform', [100, 0, 0, 50, 560, 20]], ['paintImageXObject', ['img_1', 4, 4]], ['restore'],
      // One frame of a grid of video frames: small, and a photograph.
      ['save'], ['transform', [20, 0, 0, 14, 300, 300]], ['paintImageXObject', ['img_1', 4, 4]], ['restore'],
    ]), OPS, { bounds: { x: 0, y: 0, width: 612, height: 792 } })
    assert.equal(rects.length, 2)
    // Half off the page: kept, and cut to it.
    near(rects[0], [560, 20, 52, 50], 'cut to the page')
    near(rects[1], [300, 300, 20, 14], 'a small frame')
  })

  await test('a restore with nothing saved changes nothing, and a name pdf.js lacks is never matched', () => {
    const rects = imageRects(list([
      ['transform', [100, 0, 0, 100, 0, 0]], ['restore'], ['restore'],
      ['paintImageXObject', ['img_1', 4, 4]],
    ]), { ...OPS, paintJpegXObject: undefined } as never)
    near(rects[0], [0, 0, 100, 100], 'unchanged')
    // A made-up operator list with no numbers at all walks to nothing.
    assert.deepEqual(imageRects({ fnArray: [1, 2, 3], argsArray: [null, null, null] }, {}), [])
  })

  await test('a picture in page space lands on the canvas through the viewport', () => {
    // pdf.js's viewport for a 612 × 792 page at 1.5: y turned over.
    const viewport = [1.5, 0, 0, -1.5, 0, 1188]
    const canvas = { width: 1836, height: 2376 }
    // (50, 600)–(250, 700) is x 75–375 and y 138–288 in the viewport, and
    // twice that in the canvas's pixels.
    assert.deepEqual(pixelRect({ x: 50, y: 600, width: 200, height: 100 }, viewport, 2, canvas), {
      x: 150, y: 276, width: 600, height: 300,
    })
    // Turned a quarter, as a rotated page's viewport is.
    const turned = pixelRect({ x: 0, y: 0, width: 100, height: 50 }, [0, 1, 1, 0, 0, 0], 1, { width: 1000, height: 1000 })
    assert.deepEqual(turned, { x: 0, y: 0, width: 50, height: 100 })
    assert.equal(pixelRect({ x: 700, y: 0, width: 50, height: 50 }, [1, 0, 0, 1, 0, 0], 1, { width: 612, height: 792 }), null)
  })

  await test('ink on white goes to night with the page; a picture does not', () => {
    const pixels = (count: number, colour: (i: number) => [number, number, number]) => {
      const out = new Uint8ClampedArray(count * 4)
      for (let i = 0; i < count; i += 1) {
        const [r, g, b] = colour(i)
        out.set([r, g, b, 255], i * 4)
      }
      return out
    }
    // A scanned page: paper, and a tenth of it type.
    assert.equal(isInkOnWhite(pixels(1000, (i) => (i % 10 === 0 ? [20, 20, 20] : [250, 250, 250]))), true)
    // With the grey edges a scanner leaves round the letters (the corpus's
    // textbook, at its greyest: 78% paper, 12% tone).
    assert.equal(isInkOnWhite(pixels(100, (i) => (i < 10 ? [30, 30, 30] : i < 22 ? [150, 150, 150] : [252, 252, 252]))), true)
    // A yellowed page is still paper.
    assert.equal(isInkOnWhite(pixels(1000, (i) => (i % 8 === 0 ? [40, 35, 30] : [245, 238, 215]))), true)
    // A photograph: tone everywhere.
    assert.equal(isInkOnWhite(pixels(1000, (i) => [(i * 37) % 256, (i * 91) % 256, (i * 53) % 256])), false)
    // A black-and-white photograph: greys, mostly not paper.
    assert.equal(isInkOnWhite(pixels(1000, (i) => [i % 200, i % 200, i % 200])), false)
    // A light grey photograph — the robot in v-jepa 2's Figure 1: a third
    // paper and the rest light tones, no colour. Still a photograph.
    assert.equal(isInkOnWhite(pixels(100, (i) => (i < 32 ? [236, 236, 236] : i < 78 ? [208, 208, 208] : [175, 175, 175]))), false)
    // A diagram of coloured boxes on white: paper, but a tenth of it colour.
    assert.equal(isInkOnWhite(pixels(1000, (i) => (i % 10 === 0 ? [230, 60, 50] : [255, 255, 255]))), false)
    assert.deepEqual(tones(pixels(4, (i) => [[255, 255, 255], [128, 128, 128], [0, 0, 0], [255, 0, 0]][i] as [number, number, number])), {
      paper: 0.25, tone: 0.25, coloured: 0.25, seen: 4,
    })
    // Clear pixels are not looked at, and nothing at all is a picture.
    const clear = pixels(100, () => [255, 255, 255])
    for (let i = 3; i < clear.length; i += 4) clear[i] = 0
    assert.equal(tones(clear).seen, 0)
    assert.equal(isInkOnWhite(clear), false)
  })

  await test('pdf.js\'s own operator list, for a PDF with a picture in every shape it paints one', async () => {
    const bytes = await pictureFixture()
    const modules = path.join(__dirname, '../../node_modules/pdfjs-dist')
    const document = await pdfjs.getDocument({
      data: bytes,
      cMapUrl: `${modules}/cmaps/`,
      cMapPacked: true,
      standardFontDataUrl: `${modules}/standard_fonts/`,
      isEvalSupported: false,
      verbosity: 0,
    }).promise
    try {
      const page = await document.getPage(1)
      const [x0, y0, x1, y1] = page.view as number[]
      // As the reader asks it: the annotations the page is drawn with.
      const found = imageRects(await page.getOperatorList({ annotationMode: 1 }), OPS, {
        bounds: { x: x0, y: y0, width: x1 - x0, height: y1 - y0 },
      })
      const expected: [number, number, number, number][] = [
        [50, 600, 200, 100], // placed
        [300, 100, 50, 50], // inside a form with a matrix of its own
        [440, 300, 60, 120], // turned a quarter
        [300, 650, 100, 50], // inline
        [560, 20, 52, 50], // half off the page, cut to it
        [400, 160, 100, 50], // a stamp's appearance
      ]
      assert.equal(found.length, expected.length, JSON.stringify(found))
      expected.forEach((rect, i) => near(found[i], rect, `picture ${i}`))
      page.cleanup()
    } finally {
      await document.destroy()
    }
  })
}

/**
 * One page, and a picture in each of the shapes the reader has to find: an
 * image placed with `cm`, one inside a form with its own matrix, one turned a
 * quarter, an inline one, one half off the page, and one in a stamp's
 * appearance — beside what must not be found: a stencil mask, a picture no
 * bigger than a rule (10 points square), and one wholly off the page.
 */
async function pictureFixture(): Promise<Uint8Array> {
  const doc = await PDFDocument.create()
  const page = doc.addPage([612, 792])
  const context = doc.context
  const grey = (width: number, height: number) => context.register(context.stream(new Uint8Array(width * height).fill(128), {
    Type: 'XObject', Subtype: 'Image', Width: width, Height: height, ColorSpace: 'DeviceGray', BitsPerComponent: 8,
  }))
  const photo = grey(4, 4)
  const small = grey(2, 2)
  const mask = context.register(context.stream(new Uint8Array([0x0f, 0xf0, 0x0f, 0xf0]), {
    Type: 'XObject', Subtype: 'Image', Width: 8, Height: 4, ImageMask: true, BitsPerComponent: 1,
  }))
  const form = context.register(context.stream('q 100 0 0 100 0 0 cm /P Do Q', {
    Type: 'XObject', Subtype: 'Form', BBox: [0, 0, 1000, 1000], Matrix: [0.5, 0, 0, 0.5, 300, 100],
    Resources: { XObject: { P: photo } },
  }))
  const xobjects: [string, PDFRef][] = [['P', photo], ['S', small], ['M', mask], ['F', form]]
  for (const [name, ref] of xobjects) page.node.setXObject(PDFName.of(name), ref)
  const content = [
    'q 200 0 0 100 50 600 cm /P Do Q',
    'q 200 0 0 100 50 450 cm /M Do Q',
    'q 10 0 0 10 400 700 cm /S Do Q',
    'q /F Do Q',
    'q 0 1 -1 0 500 300 cm 120 0 0 60 0 0 cm /P Do Q',
    `q 100 0 0 50 300 650 cm BI /W 2 /H 2 /CS /G /BPC 8 ID ${'\x80\x40\x40\x80'} EI Q`,
    'q 100 0 0 50 700 700 cm /P Do Q',
    'q 100 0 0 50 560 20 cm /P Do Q',
  ].join('\n')
  page.node.set(PDFName.of('Contents'), context.register(context.stream(Buffer.from(content, 'latin1'))))
  // A stamp whose appearance is the photograph, filling its box.
  const appearance = context.register(context.stream('q 100 0 0 50 0 0 cm /P Do Q', {
    Type: 'XObject', Subtype: 'Form', BBox: [0, 0, 100, 50], Resources: { XObject: { P: photo } },
  }))
  const stamp = context.register(context.obj({
    Type: 'Annot', Subtype: 'Stamp', Rect: [400, 160, 500, 210], F: 4, AP: { N: appearance },
  }))
  page.node.set(PDFName.of('Annots'), context.obj([stamp]))
  return doc.save({ useObjectStreams: false })
}
