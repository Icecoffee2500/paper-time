/**
 * What is done to one paper: its reading status, its star, its kind, the
 * paper it hangs off, the shelves it is filed under, its name, the trash.
 *
 * Every write puts the record the main process wrote back into the store
 * (`patchPaper`) instead of reading the whole library again — a star used to
 * be a read of every record in every folder, and the watcher read them all
 * once more. The library is read again only when its shape changes: a file
 * renamed, a paper thrown away, a collection made.
 */
import { call } from '../bridge.js'
import {
  attachmentsOf,
  changed,
  closeOpenPaper,
  isOpenPaper,
  patchPaper,
  paper as findPaper,
  store,
  undock,
  type Paper,
  type Shelf,
} from '../state.js'
import { fileNameOf, reconcileReaders } from '../pageArea.js'
import { applySnapshot, reload } from '../library.js'
import { closeOthers, closePaper, dockPaper, keepPaper, openInWindow, showPaper } from './openPapers.js'
import { showMenu, toast, type MenuEntry } from '../ui/toolbar.js'
import { showAttachSheet } from '../ui/attachSheet.js'
import { couldNot } from '../notices.js'
import { L } from '../../shared/lang.js'
import { isCitable, isLookedUp, type DocumentKind } from '../../shared/documentKind.js'
import { entryFor } from '../../shared/bibtex.js'
import { DOCK_ZONES, type DockZone } from '../../shared/split.js'

type ReadingStatus = 'unread' | 'reading' | 'read'

/** Writes part of a paper's record and puts what was written in place. */
export async function editMeta(id: string, patch: Record<string, unknown>) {
  const meta = await call('paper:meta', { id, patch })
  if (!meta) return reload()
  patchPaper(id, { meta })
  changed('papers')
}

/** The same for the paper's reading state — status, star, rating, summary. */
export async function editState(id: string, patch: Record<string, unknown>) {
  const state = await call('paper:state', { id, patch })
  if (!state) return reload()
  patchPaper(id, { state })
  changed('papers')
}

export const setStatus = (id: string, readingStatus: ReadingStatus) => editState(id, { readingStatus })
export const setFavorite = (id: string, isFavorite: boolean) => editState(id, { isFavorite })

export async function toggleFavorite(id: string) {
  const entry = findPaper(id)
  if (entry) await setFavorite(id, !entry.state.isFavorite)
}

/** The answer to "a paper, a book, course material, or a document?", from the
 *  inspector or the row's menu. */
export async function setKind(id: string, kind: DocumentKind) {
  // Nothing but a paper has a registrar to disagree with, so nothing else
  // stays on the shelf of things to look at.
  const patch: Record<string, unknown> = { kind }
  if (!isLookedUp(kind)) patch.confidence = 'unparsed'
  // Nothing is cleared for course material or a document. A book clears the
  // journal's fields below because a book is exported and would print a
  // volume it never had; these two are not exported at all, so throwing away
  // what somebody typed would cost them something and buy nothing.
  if (kind === 'book') {
    // Called a book, it is written down as one — so the export says `@book`
    // and the citation prints a publisher rather than a journal. The
    // journal's own fields go, or a textbook prints as a volume and an issue
    // of a journal it was never in.
    const entry = findPaper(id)
    const csl = { ...(entry?.meta.csl ?? {}) } as Record<string, unknown>
    if (csl.type !== 'book' && csl.type !== 'chapter') csl.type = 'book'
    for (const key of ['container-title', 'container-title-short', 'volume', 'issue', 'page', 'ISSN']) {
      delete csl[key]
    }
    patch.csl = csl
  }
  await editMeta(id, patch)
}

/** The four kinds as menu rows, the paper's own ticked — the Mac's Kind picker. */
export function kindEntries(entry: Paper): MenuEntry[] {
  return ([
    ['paper', L('논문', 'Paper'), 'text.document'],
    ['book', L('책', 'Book'), 'book'],
    ['lecture', L('강의자료', 'Course Material'), 'lecture'],
    ['document', L('일반 문서', 'Document'), 'doc'],
  ] as const).map(([value, label, glyph]) => ({
    label,
    icon: glyph,
    checked: entry.meta.effectiveKind === value,
    action: () => { if (entry.meta.effectiveKind !== value || entry.meta.kindIsUnanswered) void setKind(entry.id, value) },
  }))
}

/** The three reading statuses as menu rows, the paper's own ticked. */
export function statusEntries(entry: Paper): MenuEntry[] {
  return ([
    ['unread', L('안 읽음', 'Unread'), 'circle'],
    ['reading', L('읽는 중', 'Reading'), 'circle.lefthalf.filled'],
    ['read', L('읽음', 'Read'), 'checkmark.circle'],
  ] as const).map(([value, label, glyph]) => ({
    label,
    icon: glyph,
    checked: entry.state.readingStatus === value,
    action: () => void setStatus(entry.id, value),
  }))
}

/**
 * Makes one paper another's supplement: it leaves every shelf and hangs off
 * that paper's row by its paperclip. Not onto itself, not onto a paper that
 * is itself a supplement, and not a paper that has supplements of its own —
 * the Mac's rules, one level deep.
 */
export async function attach(child: string, parent: string) {
  const entry = findPaper(child)
  const target = findPaper(parent)
  if (!entry || !target || child === parent) return
  if (target.meta.parentID || entry.meta.parentID === parent) return
  if (attachmentsOf(child).length > 0) {
    toast(L('보충 자료가 붙은 논문은 다른 논문에 붙일 수 없어요.', "A paper with supplements of its own can't become one."))
    return
  }
  await editMeta(child, { parentID: parent })
  // Off the shelves now; if it was the one showing, its paper comes forward
  // (`LibraryModel.attach`).
  if (store.selectedID === child) await showPaper(parent)
  toast(L(`“${target.meta.displayTitle}”에 붙였어요`, `Attached to “${target.meta.displayTitle}”`))
}

/** Takes a supplement off its paper: a paper of its own again. */
export const detach = (child: string) => editMeta(child, { parentID: null })

/** Every paper another could go under: standing on its own, and not itself. */
export function attachTargets(id: string): { id: string; title: string; fileName: string }[] {
  return store.papers
    .filter((entry) => entry.id !== id && !entry.meta.parentID)
    .map((entry) => ({ id: entry.id, title: entry.meta.displayTitle, fileName: fileNameOf(entry) }))
}

/**
 * A paper dropped on a sidebar row, filed under it — the Mac's `dropTarget`s:
 * a reading status, the favourites, a collection, a tag. Nothing else takes
 * a drop, and a paper already there is left as it is.
 */
export async function fileUnder(paperID: string, shelf: Shelf) {
  const entry = findPaper(paperID)
  if (!entry) return
  switch (shelf.kind) {
    case 'status':
      if (entry.state.readingStatus !== shelf.status) await setStatus(paperID, shelf.status)
      return
    case 'favorites':
      if (!entry.state.isFavorite) await setFavorite(paperID, true)
      return
    case 'collection': {
      const collection = store.collections.find((one) => one.id === shelf.id)
      if (!collection || collection.rule || entry.meta.collectionIDs.includes(shelf.id)) return
      await editMeta(paperID, { collectionIDs: [...entry.meta.collectionIDs, shelf.id] })
      toast(L(`“${collection.name}”에 넣었어요`, `Added to “${collection.name}”`))
      return
    }
    case 'tag': {
      const tag = store.tags.find((one) => one.id === shelf.id)
      if (!tag || entry.meta.tagIDs.includes(shelf.id)) return
      await editMeta(paperID, { tagIDs: [...entry.meta.tagIDs, shelf.id] })
      return
    }
  }
}

/** Why a name was refused, in the reader's own language. */
const RENAME_TROUBLE = (): Record<string, string> => ({
  empty: L('이름을 적어주세요.', 'Type a name.'),
  notAName: L('이름에 «/»나 «:» 같은 글자는 쓸 수 없어요.',
    'A name cannot contain / \\ : * ? " < > or |.'),
  taken: L('같은 이름의 파일이 이미 있어요.', 'A file with that name is already there.'),
  missing: L('파일이 있던 자리에 없어요.', 'Paper Time cannot find the file.'),
})

/** A new file name, or why not. The file moved, so the library is read again. */
export async function renamePaper(id: string, name: string): Promise<string | null> {
  const result = await call('paper:rename', { id, name })
  if ('error' in result) return RENAME_TROUBLE()[result.error] ?? null
  await reload()
  return null
}

export async function copyKey(id: string) {
  const entry = findPaper(id)
  if (!entry) return
  // The key the exported file gives it — its own, or the one the export
  // makes up — and never its title, which no \cite{} would find.
  await navigator.clipboard.writeText(entryFor(entry.meta).key)
  toast(L('인용 키를 복사했어요', 'Citation key copied'))
}

/** Into the library's own Trash folder, asked first — nothing is deleted. */
export async function trashPaper(id: string) {
  const entry = findPaper(id)
  if (!entry) return
  if (!confirm(L(
    `“${entry.meta.displayTitle}”\n\n라이브러리 휴지통에 넣을까요? 아무것도 지우지 않아요. PDF와 그 기록은 라이브러리 안 휴지통 폴더로 옮겨가요.`,
    `Move “${entry.meta.displayTitle}” to the library's Trash?\n\nThe PDF and its record move to the Trash folder inside the library. Nothing is deleted.`,
  ))) return
  const snapshot = await call('library:trash', { id })
  if ('error' in snapshot) return couldNot('finish', snapshot.error)
  undock(id)
  closeOpenPaper(id)
  applySnapshot(snapshot)
  reconcileReaders()
}

const ZONE_LABELS = (): Record<DockZone, string> => ({
  left: L('왼쪽에', 'Left Half'),
  right: L('오른쪽에', 'Right Half'),
  topLeft: L('왼쪽 위에', 'Top Left'),
  topRight: L('오른쪽 위에', 'Top Right'),
  bottomLeft: L('왼쪽 아래에', 'Bottom Left'),
  bottomRight: L('오른쪽 아래에', 'Bottom Right'),
})

const ZONE_ICONS: Record<DockZone, string> = {
  left: 'rectangle.lefthalf.inset.filled',
  right: 'rectangle.righthalf.inset.filled',
  topLeft: 'rectangle.inset.topleft.filled',
  topRight: 'rectangle.inset.topright.filled',
  bottomLeft: 'rectangle.inset.bottomleft.filled',
  bottomRight: 'rectangle.inset.bottomright.filled',
}

/** The Mac's status button: the kind first — a handful of wrongly answered
 *  imports is corrected down the list without the inspector — then the
 *  reading status, each with its answer ticked. */
export function statusMenu(id: string, anchor: Element) {
  const entry = findPaper(id)
  if (!entry) return
  showMenu(anchor, [
    { caption: L('종류', 'Kind') },
    ...kindEntries(entry),
    { separator: true },
    { caption: L('읽기 상태', 'Reading Status') },
    ...statusEntries(entry),
  ], 'right')
}

/** A row's paperclip: the supplements that hang off it. */
export function attachmentsMenu(id: string, anchor: Element) {
  const children = attachmentsOf(id)
  if (children.length === 0) return
  showMenu(anchor, [
    { caption: L('보충 자료', 'Supplementary Material') },
    ...children.map((child) => ({
      label: child.meta.displayTitle,
      icon: 'doc',
      children: [
        { label: L('열기', 'Open'), icon: 'text.page', action: () => void showPaper(child.id) },
        { label: L('논문에서 떼기', 'Detach from Paper'), icon: 'paperclip', action: () => void detach(child.id) },
      ],
    })),
  ], 'right')
}

/** A row's own menu, in the Mac's order. */
export function paperMenu(id: string, anchor: Element) {
  const entry = findPaper(id)
  if (!entry) return
  const labels = ZONE_LABELS()
  showMenu(anchor, [
    { label: L('열기', 'Open'), icon: 'text.page', action: () => void showPaper(id) },
    // Beside the paper already open: a half, or a quarter, of the page.
    {
      label: L('나란히 열기', 'Open Side by Side'),
      icon: 'rectangle.split.2x1',
      children: DOCK_ZONES.flatMap((zone, index) => [
        ...(index === 2 ? [{ separator: true }] : []),
        { label: labels[zone], icon: ZONE_ICONS[zone], action: () => dockPaper(id, zone) },
      ]),
    },
    ...(isOpenPaper(id)
      ? [
          { label: L('닫기', 'Close'), icon: 'xmark.circle', action: () => closePaper(id) },
          ...(store.openPaperIDs.length > 1
            ? [{ label: L('다른 논문 모두 닫기', 'Close Other Papers'), icon: 'xmark.circle.fill', action: () => closeOthers(id) }]
            : []),
        ]
      : [{ label: L('열어 두기', 'Keep Open'), icon: 'pin', action: () => keepPaper(id, true) }]),
    { label: L('새 창으로 열기', 'Open in New Window'), icon: 'macwindow.badge.plus', action: () => openInWindow(id) },
    { separator: true },
    // The same answer the inspector asks for, where a handful of rows can
    // be corrected one after another — which is what a wrongly answered
    // import feels like. The one it already is is left out: a menu offering
    // what has already happened is a menu item that does nothing.
    ...([
      ['paper', L('논문으로 바꾸기', 'Make It a Paper'), 'text.document'],
      ['book', L('책으로 바꾸기', 'Make It a Book'), 'book'],
      ['lecture', L('강의자료로 바꾸기', 'Make It Course Material'), 'lecture'],
      ['document', L('일반 문서로 바꾸기', 'Make It a Document'), 'note'],
    ] as const)
      .filter(([value]) => value !== entry.meta.effectiveKind)
      .map(([value, label, glyph]) => ({
        label, icon: glyph, action: () => void setKind(id, value),
      })),
    // A search for the one to go under, as on the Mac — greyed for a paper
    // that is a supplement already, has its own, or has nothing to go under.
    {
      label: L('다른 논문에 붙이기…', 'Attach To…'),
      icon: 'paperclip',
      disabled: Boolean(entry.meta.parentID) || attachmentsOf(id).length > 0 || attachTargets(id).length === 0,
      action: () => showAttachSheet({
        child: { id, title: entry.meta.displayTitle },
        candidates: attachTargets(id),
        attach: (parent) => void attach(id, parent),
      }),
    },
    { separator: true },
    { label: L('폴더에서 보기', 'Show in Folder'), icon: 'folder', action: () => void call('paper:reveal', { id }) },
    ...(isCitable(entry.meta.effectiveKind)
      ? [{ label: L('인용 키 복사', 'Copy Citation Key'), icon: 'doc.on.doc', action: () => void copyKey(id) }]
      : []),
    { separator: true },
    // The Mac's row menu has the reading status as a picker of its own.
    { label: L('읽기 상태', 'Reading Status'), icon: 'circle.lefthalf.filled', children: statusEntries(entry) },
    {
      label: entry.state.isFavorite
        ? L('즐겨찾기에서 빼기', 'Remove from Favorites')
        : L('즐겨찾기에 더하기', 'Add to Favorites'),
      icon: 'star',
      action: () => void setFavorite(id, !entry.state.isFavorite),
    },
    { separator: true },
    { label: L('휴지통에 넣기', 'Move to Trash'), icon: 'trash', action: () => void trashPaper(id) },
  ])
}
