/**
 * What the palette offers before anything is typed — the Mac's
 * `SearchSuggestions.groups`: the papers you are part way through, with how
 * little is left; the ones read a week or more ago that have notes, before
 * they fade; the ones added this week and not yet opened. Three or four
 * rows, never a wall.
 *
 * The Mac's «Because you read …» group — unread neighbours of the last paper
 * read, by the words they share — needs its `Resonance` index, which this
 * build does not have yet; it is left out rather than faked.
 */
import { L } from './lang.js'

export interface SuggestedPaper {
  id: string
  title: string
  authors: string
  pageCount: number
  lastPageIndex: number
  lastOpenedAt: Date | null
  readingStatus: 'unread' | 'reading' | 'read'
  addedAt: Date
  parentID?: string
}

export interface Suggestion {
  id: string
  title: string
  subtitle: string
  icon: 'book.pages' | 'arrow.uturn.backward' | 'star'
  reason: string
  /** How far through, for Continue's bar. */
  progress?: number
}

export interface SuggestionGroup {
  title: string
  rows: Suggestion[]
}

const DAY = 86_400_000

/** «오늘», «3일 전», «2주 전» — `ago(_:)`. */
export function ago(date: Date, now: Date): string {
  const days = Math.floor((now.getTime() - date.getTime()) / DAY)
  if (days <= 0) return L('오늘', 'today')
  if (days === 1) return L('어제', 'yesterday')
  if (days < 14) return L(`${days}일 전`, `${days} days ago`)
  if (days < 60) return L(`${Math.floor(days / 7)}주 전`, `${Math.floor(days / 7)} weeks ago`)
  return L(`${Math.floor(days / 30)}달 전`, `${Math.floor(days / 30)} months ago`)
}

export function suggestionGroups(all: SuggestedPaper[], notesFor: (id: string) => number, now = new Date()): SuggestionGroup[] {
  const papers = all.filter((paper) => !paper.parentID)
  const taken = new Set<string>()
  const groups: SuggestionGroup[] = []
  const row = (paper: SuggestedPaper, reason: string, icon: Suggestion['icon'], progress?: number): Suggestion => {
    taken.add(paper.id)
    return { id: paper.id, title: paper.title, subtitle: paper.authors, icon, reason, ...(progress !== undefined ? { progress } : {}) }
  }

  // Continue: opened, not finished, most recent first.
  const unfinished = papers
    .filter((paper) => paper.lastOpenedAt && paper.pageCount > 1
      && paper.lastPageIndex > 0 && paper.lastPageIndex < paper.pageCount - 1 && paper.readingStatus !== 'read')
    .sort((a, b) => (b.lastOpenedAt?.getTime() ?? 0) - (a.lastOpenedAt?.getTime() ?? 0))
    .slice(0, 3)
  if (unfinished.length > 0) {
    groups.push({
      title: L('이어서 읽기', 'Continue'),
      rows: unfinished.map((paper) => {
        const left = paper.pageCount - 1 - paper.lastPageIndex
        const progress = (paper.lastPageIndex + 1) / paper.pageCount
        const percent = Math.floor(progress * 100)
        const when = ago(paper.lastOpenedAt ?? now, now)
        return row(paper, L(`${percent}% · ${left}쪽 남음 · ${when}`, `${percent}% · ${left === 1 ? '1 page' : `${left} pages`} left · ${when}`), 'book.pages', progress)
      }),
    })
  }

  // Revisit: read a week or more ago, with notes — before it fades.
  const revisit = papers
    .filter((paper) => {
      if (!paper.lastOpenedAt || taken.has(paper.id)) return false
      const days = (now.getTime() - paper.lastOpenedAt.getTime()) / DAY
      return days >= 7 && days <= 90 && notesFor(paper.id) > 0
    })
    .sort((a, b) => notesFor(b.id) - notesFor(a.id))
    .slice(0, 2)
  if (revisit.length > 0) {
    groups.push({
      title: L('다시 보기', 'Revisit'),
      rows: revisit.map((paper) => {
        const count = notesFor(paper.id)
        const when = ago(paper.lastOpenedAt ?? now, now)
        return row(paper, L(`${when} 읽음 · 노트 ${count}개 — 지금 한 번 보면 남아요`, `read ${when} · ${count === 1 ? '1 note' : `${count} notes`} — a look now keeps it`), 'arrow.uturn.backward')
      }),
    })
  }

  // New this week, unread.
  const fresh = papers
    .filter((paper) => now.getTime() - paper.addedAt.getTime() < 7 * DAY && !paper.lastOpenedAt && !taken.has(paper.id))
    .sort((a, b) => b.addedAt.getTime() - a.addedAt.getTime())
    .slice(0, 2)
  if (fresh.length > 0) {
    groups.push({
      title: L('이번 주 새 논문', 'New this week'),
      rows: fresh.map((paper) => row(paper, L(`${ago(paper.addedAt, now)} 더함`, `added ${ago(paper.addedAt, now)}`), 'star')),
    })
  }
  return groups
}
