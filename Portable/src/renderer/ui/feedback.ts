/**
 * The report sheet, the same one the Mac has.
 *
 * Three things make it not a form:
 *   1. the screenshot is already taken when it opens — the hard part of a bug
 *      report is explaining where you were, and the app knows that already;
 *   2. you draw on it with the app's own pen, the arrow and box from the
 *      reader, because an app about marking up a page should let you mark up
 *      the bug;
 *   3. the row it becomes on the public list is shown before the send, not
 *      after. Nobody writes into a void; showing the void has an exit is most
 *      of the work.
 *
 * It registers its own shortcut rather than being wired from the shell, so the
 * one keystroke works from anywhere in the window with nothing else to know.
 */
import { SketchColor, SketchElement, SketchStyle, point } from '../../shared/sketch.js'
import { drawElements } from '../../shared/sketchRender.js'
import { L } from '../../shared/lang.js'
import { call, isCommand } from '../bridge.js'
import { el, on } from '../dom.js'

type Kind = 'bug' | 'wish'
type Tool = 'arrow' | 'box' | 'hide'

interface Draft {
  kind: Kind
  message: string
  name: string
  reply: string
  includesShot: boolean
  marks: SketchElement[]
  shot: HTMLImageElement | null
  shotURL: string | null
}

/** Kept between openings: closing the sheet must not throw away the words. */
const draft: Draft = {
  kind: 'bug',
  message: '',
  name: localStorage.getItem('feedback.name') ?? '',
  reply: localStorage.getItem('feedback.reply') ?? '',
  includesShot: true,
  marks: [],
  shot: null,
  shotURL: null,
}

let open = false

function styleFor(tool: Tool, width: number): SketchStyle {
  const style = new SketchStyle()
  style.width = width
  style.endHead = 'none'
  switch (tool) {
    case 'arrow':
      style.stroke = SketchColor.red
      style.endHead = 'triangle'
      break
    case 'box':
      style.stroke = SketchColor.red
      style.fill = null
      break
    case 'hide':
      // Opaque, not a blur: a blur can sometimes be undone, and anybody
      // covering something here means it.
      style.stroke = new SketchColor(0.1, 0.1, 0.12)
      style.fill = new SketchColor(0.1, 0.1, 0.12)
      break
  }
  return style
}

function element(tool: Tool, from: { x: number; y: number }, to: { x: number; y: number }, width: number) {
  return new SketchElement({
    kind: tool === 'arrow' ? 'arrow' : 'rectangle',
    points: [point(from.x, from.y), point(to.x, to.y)],
    style: styleFor(tool, width),
  })
}

export async function showFeedback() {
  if (open) return
  open = true

  // Taken before the sheet is built, so the sheet is not in its own picture.
  if (!draft.shotURL) {
    draft.shotURL = await call<string | null>('feedback:capture')
    if (draft.shotURL) {
      const image = new Image()
      image.src = draft.shotURL
      await image.decode().catch(() => {})
      draft.shot = image
    }
  }

  const backdrop = el('div', { class: 'sheet-backdrop' })
  const sheet = el('div', { class: 'fb-sheet', role: 'dialog', 'aria-modal': 'true' })
  backdrop.append(sheet)
  document.body.append(backdrop)

  const close = () => {
    backdrop.remove()
    open = false
  }

  // ── what kind ────────────────────────────────────────────────────────────
  const kinds = el('div', { class: 'fb-kinds' })
  const kindButtons: Record<Kind, HTMLButtonElement> = {
    bug: el('button', { type: 'button', text: L('문제가 있어요', "Something's wrong") }),
    wish: el('button', { type: 'button', text: L('이랬으면 좋겠어요', 'I wish it did this') }),
  }
  const markKinds = () => {
    for (const key of ['bug', 'wish'] as Kind[]) {
      kindButtons[key].classList.toggle('on', draft.kind === key)
    }
  }
  for (const key of ['bug', 'wish'] as Kind[]) {
    on(kindButtons[key], 'click', () => {
      draft.kind = key
      markKinds()
      body.placeholder = placeholder()
    })
    kinds.append(kindButtons[key])
  }
  markKinds()

  // ── the picture, already taken ───────────────────────────────────────────
  let tool: Tool = 'arrow'
  const canvas = el('canvas', { class: 'fb-canvas' })
  const ctx = canvas.getContext('2d')
  let drawing: SketchElement | null = null

  const paint = () => {
    if (!ctx || !draft.shot) return
    const image = draft.shot
    const box = canvas.getBoundingClientRect()
    const ratio = window.devicePixelRatio || 1
    canvas.width = Math.round(box.width * ratio)
    canvas.height = Math.round(box.height * ratio)
    const scale = Math.min(box.width / image.width, box.height / image.height)
    const drawn = { width: image.width * scale, height: image.height * scale }
    const origin = { x: (box.width - drawn.width) / 2, y: (box.height - drawn.height) / 2 }
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
    ctx.clearRect(0, 0, box.width, box.height)
    ctx.save()
    ctx.translate(origin.x, origin.y)
    ctx.scale(scale, scale)
    ctx.drawImage(image, 0, 0)
    const all = drawing ? [...draft.marks, drawing] : draft.marks
    drawElements(all, ctx)
    ctx.restore()
    canvas.dataset.scale = String(scale)
    canvas.dataset.ox = String(origin.x)
    canvas.dataset.oy = String(origin.y)
  }

  /** A point in the canvas, in the picture's own pixels, clamped to it. */
  const toImage = (event: PointerEvent) => {
    const box = canvas.getBoundingClientRect()
    const scale = Number(canvas.dataset.scale) || 1
    const ox = Number(canvas.dataset.ox) || 0
    const oy = Number(canvas.dataset.oy) || 0
    const image = draft.shot
    return {
      x: Math.max(0, Math.min((event.clientX - box.left - ox) / scale, image?.width ?? 0)),
      y: Math.max(0, Math.min((event.clientY - box.top - oy) / scale, image?.height ?? 0)),
    }
  }

  let from: { x: number; y: number } | null = null
  on(canvas, 'pointerdown', (event: PointerEvent) => {
    if (!draft.shot) return
    canvas.setPointerCapture(event.pointerId)
    from = toImage(event)
  })
  on(canvas, 'pointermove', (event: PointerEvent) => {
    if (!from || !draft.shot) return
    const width = Math.max(2, draft.shot.width / 420)
    drawing = element(tool, from, toImage(event), width)
    paint()
  })
  on(canvas, 'pointerup', () => {
    if (drawing) draft.marks.push(drawing)
    drawing = null
    from = null
    paint()
    markTools()
  })

  const toolButtons: { tool: Tool; label: string; glyph: string }[] = [
    { tool: 'arrow', label: L('화살표', 'Arrow'), glyph: '↖' },
    { tool: 'box', label: L('네모', 'Box'), glyph: '▢' },
    { tool: 'hide', label: L('가리기', 'Hide'), glyph: '▮' },
  ]
  const tools = el('div', { class: 'fb-tools' })
  const toolNodes = toolButtons.map(({ tool: which, label, glyph }) => {
    const button = el('button', { type: 'button', title: label, text: glyph })
    on(button, 'click', () => {
      tool = which
      markTools()
    })
    return { which, button }
  })
  const undo = el('button', { type: 'button', title: L('되돌리기', 'Undo'), text: '↺' })
  on(undo, 'click', () => {
    draft.marks.pop()
    paint()
    markTools()
  })
  const markTools = () => {
    for (const { which, button } of toolNodes) button.classList.toggle('on', which === tool)
    undo.disabled = draft.marks.length === 0
  }
  tools.append(...toolNodes.map((t) => t.button), undo)
  markTools()

  const drop = el('button', {
    type: 'button',
    class: 'fb-drop',
    title: L('화면 빼고 보내기', 'Send without the screenshot'),
    text: '✕',
  })

  const shotRow = el('div', { class: 'fb-row' }, [
    el('span', { class: 'fb-label', text: L('화면은 이미 찍어뒀어요', 'The screenshot is already here') }),
    el('span', { class: 'fb-spacer' }),
    tools,
    drop,
  ])
  const shotHint = el('p', {
    class: 'fb-hint',
    text: L(
      '위에 바로 그려도 돼요. 남에게 보이면 안 되는 곳은 가려주세요.',
      "Draw on it. Use Hide to cover anything that shouldn't leave your machine.",
    ),
  })
  const shotBox = el('div', { class: 'fb-shot' }, [canvas])
  on(drop, 'click', () => {
    draft.includesShot = !draft.includesShot
    shotBox.hidden = !draft.includesShot
    tools.hidden = !draft.includesShot
    shotHint.textContent = draft.includesShot
      ? L('위에 바로 그려도 돼요. 남에게 보이면 안 되는 곳은 가려주세요.',
          "Draw on it. Use Hide to cover anything that shouldn't leave your machine.")
      : L('화면 없이 보내요.', 'Sending without a screenshot.')
  })

  // ── the message ──────────────────────────────────────────────────────────
  const placeholder = () =>
    draft.kind === 'bug'
      ? L('한 줄이면 충분해요.', 'One line is enough.')
      : L('어떤 게 있으면 좋을까요?', 'What would you like it to do?')
  const body = el('textarea', { class: 'fb-body', placeholder: placeholder() }) as HTMLTextAreaElement
  body.value = draft.message

  // ── who ──────────────────────────────────────────────────────────────────
  const name = el('input', { class: 'fb-input', placeholder: L('익명', 'anonymous') }) as HTMLInputElement
  name.value = draft.name
  const reply = el('input', {
    class: 'fb-input',
    placeholder: L('메일 (안 적어도 돼요)', 'Email, optional'),
  }) as HTMLInputElement
  reply.value = draft.reply

  // ── the row it becomes ───────────────────────────────────────────────────
  const previewTitle = el('span', { class: 'fb-pv-title' })
  const previewWho = el('span', { class: 'fb-pv-who' })
  const preview = el('div', { class: 'fb-preview' }, [
    el('span', { class: 'fb-pv-mark', text: '○' }),
    previewTitle,
    el('span', { class: 'fb-spacer' }),
    el('span', { class: 'fb-pv-state', text: L('기다리는 중', 'open') }),
    previewWho,
  ])

  const refresh = () => {
    draft.message = body.value
    draft.name = name.value
    draft.reply = reply.value
    const first = draft.message.split('\n').find((line) => line.trim())?.trim() ?? ''
    previewTitle.textContent = first
      ? first.length > 60
        ? `${first.slice(0, 59)}…`
        : first
      : L('여기 쓴 첫 줄이 제목이 돼요', 'Your first line becomes the title')
    previewTitle.classList.toggle('dim', !first)
    previewWho.textContent = `— ${draft.name.trim() || L('익명', 'anonymous')}`
    sendButton.disabled = draft.message.trim().length < 3
  }
  on(body, 'input', refresh)
  on(name, 'input', refresh)
  on(reply, 'input', refresh)

  // ── footer ───────────────────────────────────────────────────────────────
  const status = el('span', { class: 'fb-status' })
  const cancel = el('button', { type: 'button', class: 'btn', text: L('취소', 'Cancel') })
  const sendButton = el('button', {
    type: 'button',
    class: 'btn btn-primary',
    text: L('보내기', 'Send'),
  }) as HTMLButtonElement
  on(cancel, 'click', close)
  on(sendButton, 'click', async () => {
    sendButton.disabled = true
    status.textContent = L('보내는 중…', 'Sending…')
    localStorage.setItem('feedback.name', draft.name)
    localStorage.setItem('feedback.reply', draft.reply)
    const answer = await call<{ ok: boolean; url?: string; kept?: string; error?: string }>('feedback:send', {
      kind: draft.kind,
      body: draft.message.trim(),
      name: draft.name.trim() || L('익명', 'anonymous'),
      reply: draft.reply.trim() || null,
      shot: draft.includesShot ? flatten() : null,
    })
    if (answer.ok) {
      status.textContent = L('고마워요. 목록에 올렸어요.', "Thanks. It's on the list.")
      draft.message = ''
      draft.marks = []
      draft.shot = null
      draft.shotURL = null
      sendButton.remove()
      cancel.textContent = L('닫기', 'Close')
    } else if (answer.kept) {
      status.textContent = L(
        '지금은 못 보냈어요. 바탕화면에 저장해뒀어요.',
        "Couldn't send just now. Saved it to the desktop instead.",
      )
      sendButton.remove()
      cancel.textContent = L('닫기', 'Close')
    } else {
      status.textContent = answer.error ?? L('보내지 못했어요.', "Couldn't send.")
      sendButton.disabled = false
    }
  })

  /** The picture with the marks burned in — exactly what the sheet showed. */
  const flatten = (): string | null => {
    const image = draft.shot
    if (!image) return null
    const out = document.createElement('canvas')
    out.width = image.width
    out.height = image.height
    const context = out.getContext('2d')
    if (!context) return null
    context.drawImage(image, 0, 0)
    drawElements(draft.marks, context)
    return out.toDataURL('image/png')
  }

  sheet.append(
    el('h2', { class: 'fb-title', text: L('어떤 일이 있었나요?', 'What happened?') }),
    kinds,
    el('div', { class: 'fb-scroll' }, [
      shotRow,
      shotBox,
      shotHint,
      body,
      el('div', { class: 'fb-who' }, [
        el('span', { class: 'fb-label', text: L('이름', 'Name') }),
        name,
        el('span', { class: 'fb-label', text: L('답장', 'Reply') }),
        reply,
      ]),
      el('p', {
        class: 'fb-hint',
        text: L(
          '적은 이름으로 기록에 올라가요. 메일은 답장할 때만 쓰고, 공개 목록에는 올라가지 않아요.',
          'The name goes on the list. The address is used only to write back, and never appears there.',
        ),
      }),
      el('p', { class: 'fb-hint', text: L('보내면 이렇게 올라가요', 'This is the row it becomes') }),
      preview,
    ]),
    el('div', { class: 'fb-foot' }, [status, el('span', { class: 'fb-spacer' }), cancel, sendButton]),
  )

  if (!draft.shot) {
    shotBox.hidden = true
    tools.hidden = true
    shotHint.textContent = L('화면을 찍지 못했어요.', "Couldn't take a screenshot.")
  }

  refresh()
  requestAnimationFrame(paint)
  body.focus()

  on(backdrop, 'click', (event: MouseEvent) => {
    if (event.target === backdrop) close()
  })
  on(backdrop, 'keydown', (event: KeyboardEvent) => {
    if (event.key === 'Escape') close()
  })
}

/**
 * ⌥⌘/ on a Mac, Ctrl+Alt+/ elsewhere — next to the ? on every layout, and
 * taken by nothing else. Registered here so the shell needs to know nothing.
 */
on(document, 'keydown', (event: KeyboardEvent) => {
  if (event.key === '/' && event.altKey && isCommand(event)) {
    event.preventDefault()
    void showFeedback()
  }
})
