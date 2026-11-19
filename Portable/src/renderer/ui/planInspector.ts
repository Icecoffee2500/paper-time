/**
 * The inspector's two plan sections, under the paper's title: when it is to
 * be read and in which plan, and what is kept beside it — its own address,
 * the slides, the code, the video. Paste an address and it is told what it
 * is; drop a file and it is copied beside the PDF.
 */
import { el, on } from '../dom.js'
import { iconNode } from '../icons.js'
import { call, droppedPaths } from '../bridge.js'
import { changed, plansOf, setShelf, store, type Paper } from '../state.js'
import { L } from '../../shared/lang.js'
import { materialAddress, materialKindOfAddress } from '../../shared/readingPlan.js'
import { dateLong, detectionLine, kindName, kindTone, progress, type Status } from '../../shared/planBoard.js'
import { showMenuAt } from './menu.js'
import { layoutPanes } from '../layout.js'
import { addMaterial, addMaterialFiles, addSupplementFiles, detachSupplement, openMaterial, openSupplement, removeMaterial, renameMaterial } from '../plans.js'
import { openDatePop } from './planPopovers.js'
import { KIND_ICON, materialsOf } from './planBoard.js'

function sectionNode(title: string, ...nodes: Node[]): HTMLElement {
  return el('div', { class: 'insp-section' }, [el('div', { class: 'insp-section-title', text: title }), ...nodes])
}

function kv(label: string, value: Node): HTMLElement {
  return el('div', { class: 'pi-kv' }, [el('span', { class: 'pi-key', text: label }), el('div', { class: 'pi-value' }, [value])])
}

export function planSections(entry: Paper): HTMLElement[] {
  const status = entry.state.readingStatus as Status

  // When, and in which plan.
  const label = dateLong(entry.schedule, status, store.today)
  const chip = el('button', { class: `pb-date ${label.tone}`, text: label.text, title: L('읽을 날 정하기', 'Set the Day to Read') })
  on(chip, 'click', () => openDatePop(chip, entry.id))
  const plans = plansOf(entry.id)
  const planList = el('div', { class: 'pi-plans' })
  if (plans.length === 0) planList.append(el('span', { class: 'pb-dim', text: L('없음', 'None') }))
  for (const one of plans) {
    const section = one.plan.sections.find((s) => s.id === one.plan.entries.find((e) => e.paper === entry.id)?.section)
    const link = el('button', { class: 'pi-plan', text: section ? `${one.plan.name} · ${section.name}` : one.plan.name })
    on(link, 'click', () => {
      setShelf({ kind: 'plan', id: one.plan.id })
      layoutPanes()
      changed('shelf')
    })
    planList.append(link)
  }
  const made = progress(entry.meta.file.pageCount, entry.state.lastPageIndex, status)
  const bar = el('div', { class: 'pb-prog' }, [
    el('span', { class: made.done ? 'pb-bar done' : 'pb-bar' }, [el('i', { style: `width:${Math.round(made.fraction * 100)}%` })]),
    made.text,
  ])
  const planSection = sectionNode(L('계획', 'Plan'),
    kv(L('읽을 날', 'Read On'), chip),
    kv(L('계획', 'Plan'), planList),
    kv(L('진행', 'Progress'), bar),
  )

  // What is kept beside it.
  const list = el('div', { class: 'pi-mats' })
  for (const one of materialsOf(entry)) {
    const tile = el('span', { class: 'pi-tile', 'data-tone': kindTone(one.kind) })
    const icon = iconNode(KIND_ICON[one.kind])
    if (icon) tile.append(icon)
    const row = el('div', { class: 'pi-mat', role: 'button', tabindex: '0', title: one.url ?? one.title }, [
      tile,
      el('div', { class: 'pi-mat-text' }, [el('div', { class: 'pi-mat-title', text: one.title }), el('div', { class: 'pi-mat-detail', text: one.detail })]),
    ])
    const supplement = one.supplement
    const open = () => {
      if (supplement) void openSupplement(supplement)
      else if (one.link) void openMaterial(entry.id, one.link)
      else if (one.url) void call('shell:openExternal', { url: one.url })
    }
    on(row, 'click', open)
    on(row, 'keydown', (event: KeyboardEvent) => {
      if (event.key === 'Enter') open()
    })
    if (supplement) {
      // Taken off by hand, it is a paper of its own again — and stays so.
      const cross = el('button', { class: 'pi-x', 'aria-label': L('자료 빼기', 'Remove Material'), title: L('빼기', 'Remove') })
      const x = iconNode('xmark')
      if (x) cross.append(x)
      on(cross, 'click', (event: MouseEvent) => {
        event.stopPropagation()
        void detachSupplement(supplement)
      })
      row.append(cross)
      on(row, 'contextmenu', (event: MouseEvent) => {
        event.preventDefault()
        showMenuAt({ x: event.clientX, y: event.clientY }, [
          { label: L('열기', 'Open'), icon: 'link', action: open },
          { label: L('폴더에서 보기', 'Show in Folder'), icon: 'folder', action: () => void call('paper:reveal', { id: supplement }) },
          { separator: true },
          { label: L('빼기', 'Remove'), icon: 'xmark.circle', danger: true, action: () => void detachSupplement(supplement) },
        ])
      })
    }
    if (one.link) {
      const link = one.link
      const cross = el('button', { class: 'pi-x', 'aria-label': L('자료 빼기', 'Remove'), title: L('빼기', 'Remove') })
      const x = iconNode('xmark')
      if (x) cross.append(x)
      on(cross, 'click', (event: MouseEvent) => {
        event.stopPropagation()
        void removeMaterial(entry.id, link)
      })
      row.append(cross)
      on(row, 'contextmenu', (event: MouseEvent) => {
        event.preventDefault()
        showMenuAt({ x: event.clientX, y: event.clientY }, [
          { label: L('열기', 'Open'), icon: 'link', action: open },
          { label: L('이름 바꾸기…', 'Rename…'), icon: 'square.and.pencil', action: () => void renameMaterial(entry.id, link, one.title) },
          { separator: true },
          { label: L('빼기', 'Remove'), icon: 'xmark.circle', danger: true, action: () => void removeMaterial(entry.id, link) },
        ])
      })
    }
    list.append(row)
  }
  if (!list.firstChild) list.append(el('p', { class: 'pi-none', text: L('아직 붙인 자료가 없어요.', 'Nothing kept beside this paper yet.') }))

  const field = el('input', {
    class: 'pi-link-input',
    type: 'text',
    placeholder: L('주소를 붙여넣어요', 'Paste a link'),
    autocomplete: 'off',
    spellcheck: 'false',
  }) as HTMLInputElement
  const detect = el('div', { class: 'pi-detect' })
  const say = () => {
    const typed = field.value.trim()
    detect.textContent = ''
    if (!typed) return
    const address = materialAddress(typed)
    if (!address) {
      detect.textContent = L('주소가 아니에요', "That isn't a web address")
      return
    }
    const kind = materialKindOfAddress(address)
    const chipNode = el('span', { class: 'pb-kchip', 'data-tone': kindTone(kind), title: kindName(kind) })
    const icon = iconNode(KIND_ICON[kind])
    if (icon) chipNode.append(icon)
    detect.append(chipNode, el('span', { text: detectionLine(kind) }))
  }
  on(field, 'input', say)
  on(field, 'keydown', (event: KeyboardEvent) => {
    if (event.key !== 'Enter' || !field.value.trim()) return
    event.preventDefault()
    const typed = field.value
    // Out of the field first: the inspector is not redrawn under a field being typed in.
    field.blur()
    void addMaterial(entry.id, typed).then((added) => {
      if (!added) {
        field.value = typed
        field.focus()
      }
    })
  })
  const linkField = el('label', { class: 'pi-linkfield' }, [iconNode('link') ?? '', field])
  const footer = el('p', {
    class: 'pi-foot',
    text: L('파일을 여기로 끌어다 놓으면 PDF 옆에 복사해서 붙여요. PDF는 보충 자료가 돼요.',
      'Drop files here to copy them beside the PDF. A PDF becomes a supplement.'),
  })
  const materials = sectionNode(L('자료', 'Materials'), list, linkField, detect, footer)
  materials.classList.add('pi-materials')

  // Files dropped here are copied in beside the PDF — not taken in as papers.
  let over = 0
  on(materials, 'dragenter', (event: DragEvent) => {
    if (!event.dataTransfer?.types.includes('Files')) return
    over += 1
    materials.classList.add('over')
  })
  on(materials, 'dragleave', () => {
    over = Math.max(0, over - 1)
    if (over === 0) materials.classList.remove('over')
  })
  on(materials, 'dragover', (event: DragEvent) => {
    if (!event.dataTransfer?.types.includes('Files')) return
    event.preventDefault()
    event.stopPropagation()
    event.dataTransfer.dropEffect = 'copy'
  })
  on(materials, 'drop', (event: DragEvent) => {
    over = 0
    materials.classList.remove('over')
    if (!event.dataTransfer?.types.includes('Files')) return
    event.preventDefault()
    event.stopPropagation()
    // A PDF is a supplement: into the library, under this paper — not into
    // the list beside it. Anything else is copied in beside the PDF.
    const paths = droppedPaths(event.dataTransfer.files)
    const pdfs = paths.filter((one) => /\.pdf$/i.test(one))
    const rest = paths.filter((one) => !/\.pdf$/i.test(one))
    if (pdfs.length > 0) void addSupplementFiles(entry.id, pdfs)
    if (rest.length > 0) void addMaterialFiles(entry.id, rest)
  })

  return [planSection, materials]
}
