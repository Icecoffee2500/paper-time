/**
 * The reading plan's rules — the Mac's `ReadingPlan.swift`, rule for rule.
 *
 *   .papertime/plans/<plan>.json          a plan: name, sections, order
 *   .papertime/papers/<paper>/plan.json   the day a paper is to be read
 *   .papertime/papers/<paper>/links.json  what is kept beside a paper
 *
 * The day belongs to the paper, not to a plan. Days are `YYYY-MM-DD` strings
 * and counted with the civil calendar's own arithmetic, so the two builds
 * agree to the day without asking a time zone. A week starts on Monday.
 * `reading-plans.json` (`Scripts/reading-plan-fixture.swift`) is the Mac's
 * answer to every rule here; `src/test/readingPlan.ts` holds this file to it.
 */
import { isoTimestamp, makeUUID } from './coding.js'

// MARK: - A day

/** `YYYY-MM-DD`, exactly, and a day that exists. */
export function isDay(text: unknown): text is string {
  if (typeof text !== 'string' || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(text)) return false
  const [y, m, d] = text.split('-').map(Number)
  return validDay(y, m, d)
}

function validDay(year: number, month: number, day: number): boolean {
  return year >= 1 && year <= 9999 && month >= 1 && month <= 12 && day >= 1 && day <= monthLength(month, year)
}

export function monthLength(month: number, year: number): number {
  if (month === 2) return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0 ? 29 : 28
  return month === 4 || month === 6 || month === 9 || month === 11 ? 30 : 31
}

function makeDay(year: number, month: number, day: number): string | null {
  return validDay(year, month, day) ? dayText(year, month, day) : null
}

function dayText(year: number, month: number, day: number): string {
  return `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`
}

/** Days since 1970-01-01. */
export function dayOrdinal(text: string): number {
  const [year, month, day] = text.split('-').map(Number)
  const y = month <= 2 ? year - 1 : year
  const era = Math.trunc((y >= 0 ? y : y - 399) / 400)
  const yoe = y - era * 400
  const doy = Math.trunc((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5) + day - 1
  const doe = yoe * 365 + Math.trunc(yoe / 4) - Math.trunc(yoe / 100) + doy
  return era * 146097 + doe - 719468
}

/** The day `ordinal` days after 1970-01-01. */
export function dayFromOrdinal(ordinal: number): string {
  const z = ordinal + 719468
  const era = Math.trunc((z >= 0 ? z : z - 146096) / 146097)
  const doe = z - era * 146097
  const yoe = Math.trunc((doe - Math.trunc(doe / 1460) + Math.trunc(doe / 36524) - Math.trunc(doe / 146096)) / 365)
  const doy = doe - (365 * yoe + Math.trunc(yoe / 4) - Math.trunc(yoe / 100))
  const mp = Math.trunc((5 * doy + 2) / 153)
  const day = doy - Math.trunc((153 * mp + 2) / 5) + 1
  const month = mp < 10 ? mp + 3 : mp - 9
  return dayText(yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
}

export const addDays = (day: string, n: number): string => dayFromOrdinal(dayOrdinal(day) + n)
/** 0 is Monday, 6 is Sunday. */
export const weekdayOf = (day: string): number => (((dayOrdinal(day) + 3) % 7) + 7) % 7
export const mondayOf = (day: string): string => addDays(day, -weekdayOf(day))
export const daysBetween = (later: string, earlier: string): number => dayOrdinal(later) - dayOrdinal(earlier)
export const dayParts = (day: string): [number, number, number] => day.split('-').map(Number) as [number, number, number]

/** Today where the reader is. */
export function todayDay(now: Date = new Date()): string {
  return dayText(now.getFullYear(), now.getMonth() + 1, now.getDate())
}

// MARK: - Reading a day someone typed

const SPACES = new Set([' ', '\t', '\n', '\r', '　', ' '])

/** Spaces of every kind made one space and the ends trimmed, case kept. */
export function normalizedKeepingCase(raw: string): string {
  let out = ''
  let pending = false
  for (const character of raw) {
    if (SPACES.has(character)) {
      pending = out.length > 0
      continue
    }
    if (pending) {
      out += ' '
      pending = false
    }
    out += character
  }
  return out
}

const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december']
const WEEKDAYS = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday']
const KOREAN_WEEKDAYS = '월화수목금토일'
const WEEK_UNITS = new Set(['주', 'w', 'wk', 'wks', 'week', 'weeks'])

function monthNumber(word: string): number | null {
  if (word.length < 3) return null
  const index = MONTHS.findIndex((name) => name.startsWith(word))
  return index < 0 ? null : index + 1
}

function weekdayNumber(word: string): number | null {
  if (word.length < 3) return null
  const index = WEEKDAYS.findIndex((name) => name.startsWith(word))
  return index < 0 ? null : index
}

type Which = 'upcoming' | 'thisWeek' | 'nextWeek'

function onWeekday(weekday: number, which: Which, today: string): string {
  if (which === 'upcoming') return addDays(today, (weekday - weekdayOf(today) + 7) % 7)
  if (which === 'thisWeek') return addDays(mondayOf(today), weekday)
  return addDays(mondayOf(today), 7 + weekday)
}

/** This year's day, unless that is more than two months behind — then next year's. */
function upcoming(month: number, day: number, today: string): string | null {
  const [year] = dayParts(today)
  const now = makeDay(year, month, day)
  if (!now) return makeDay(year + 1, month, day)
  if (dayOrdinal(now) < dayOrdinal(today) - 60) return makeDay(year + 1, month, day)
  return now
}

/**
 * What a person types into a date field — «금요일», «다음 주 수», «12/3»,
 * «+1주», «tomorrow», «next fri», «Dec 3» — read against `today`. Anything it
 * cannot read is null.
 */
export function readDay(raw: string, today: string): string | null {
  const text = normalizedKeepingCase(raw).toLowerCase()
  if (!text) return null
  switch (text) {
    case '오늘': case 'today': return today
    case '내일': case 'tomorrow': return addDays(today, 1)
    case '모레': return addDays(today, 2)
    case '다음 주': case '다음주': case '담주': case 'next week': return addDays(mondayOf(today), 7)
    case '주말': case '이번 주말': case '이번주말': case 'weekend': case 'this weekend':
      return addDays(today, (5 - weekdayOf(today) + 7) % 7)
  }
  let m: RegExpMatchArray | null
  if ((m = text.match(/^\+ ?([0-9]{1,3}) ?(일|d|day|days|주|w|wk|wks|week|weeks)?$/))
    || (m = text.match(/^([0-9]{1,3}) ?(일|주) ?(?:뒤|후)$/))
    || (m = text.match(/^in ([0-9]{1,3}) ?(d|day|days|w|wk|wks|week|weeks)$/))) {
    return addDays(today, Number(m[1]) * (WEEK_UNITS.has(m[2] ?? '') ? 7 : 1))
  }
  if ((m = text.match(/^([0-9]{4}) ?[-./] ?([0-9]{1,2}) ?[-./] ?([0-9]{1,2})\.?$/))
    || (m = text.match(/^([0-9]{4})년 ?([0-9]{1,2})월 ?([0-9]{1,2})일?$/))) {
    return makeDay(Number(m[1]), Number(m[2]), Number(m[3]))
  }
  if ((m = text.match(/^([0-9]{1,2}) ?[-./] ?([0-9]{1,2})\.?$/)) || (m = text.match(/^([0-9]{1,2})월 ?([0-9]{1,2})일?$/))) {
    return upcoming(Number(m[1]), Number(m[2]), today)
  }
  if ((m = text.match(/^([a-z]{3,9})\.? ([0-9]{1,2})(?:st|nd|rd|th)?$/))) {
    const month = monthNumber(m[1])
    if (month !== null) return upcoming(month, Number(m[2]), today)
  }
  if ((m = text.match(/^([0-9]{1,2})(?:st|nd|rd|th)? ([a-z]{3,9})\.?$/))) {
    const month = monthNumber(m[2])
    if (month !== null) return upcoming(month, Number(m[1]), today)
  }
  if ((m = text.match(/^([0-9]{1,2})일$/))) {
    const day = Number(m[1])
    const [year, month, now] = dayParts(today)
    if (day >= now) {
      const here = makeDay(year, month, day)
      if (here) return here
    }
    return month === 12 ? makeDay(year + 1, 1, day) : makeDay(year, month + 1, day)
  }
  if ((m = text.match(/^(이번 ?주 ?|다음 ?주 ?|담주 ?)?([월화수목금토일])(?:요일)?$/))) {
    const prefix = (m[1] ?? '').replace(/ /g, '')
    const which: Which = prefix === '' ? 'upcoming' : prefix === '이번주' ? 'thisWeek' : 'nextWeek'
    return onWeekday(KOREAN_WEEKDAYS.indexOf(m[2]), which, today)
  }
  if ((m = text.match(/^(this |next )?([a-z]{3,9})$/))) {
    const weekday = weekdayNumber(m[2])
    if (weekday !== null) {
      const which: Which = m[1] === 'this ' ? 'thisWeek' : m[1] === 'next ' ? 'nextWeek' : 'upcoming'
      return onWeekday(weekday, which, today)
    }
  }
  return null
}

// MARK: - Spreading a plan over the weeks

/** The days `count` papers are read on: from `start`, on the chosen weekdays (0 is Monday), `perDay` a day. */
export function spreadDays(count: number, weekdays: Iterable<number>, perDay: number, start: string): string[] {
  const chosen = new Set([...weekdays].filter((day) => day >= 0 && day <= 6))
  if (count <= 0 || perDay <= 0 || chosen.size === 0) return []
  const out: string[] = []
  let day = start
  while (out.length < count) {
    if (chosen.has(weekdayOf(day))) {
      for (let i = 0; i < perDay && out.length < count; i += 1) out.push(day)
    }
    day = addDays(day, 1)
  }
  return out
}

// MARK: - The plan

export interface PlanSection {
  id: string
  name: string
  [key: string]: unknown
}

export interface PlanEntry {
  paper: string
  section?: string
  [key: string]: unknown
}

/** `plans/<id>.json`. Unknown keys a later build wrote are carried. */
export interface ReadingPlan {
  id: string
  name: string
  sections: PlanSection[]
  entries: PlanEntry[]
  createdAt: string
  [key: string]: unknown
}

export interface PlanGroup {
  section: PlanSection | null
  papers: string[]
}

export function newPlan(name: string, now: Date = new Date()): ReadingPlan {
  return { id: makeUUID(), name, sections: [], entries: [], createdAt: isoTimestamp(now) }
}

/** A plan read from a file, or null when it is not one. */
export function readPlan(value: unknown): ReadingPlan | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Record<string, unknown>
  if (typeof raw.id !== 'string' || typeof raw.name !== 'string' || typeof raw.createdAt !== 'string') return null
  if (!Array.isArray(raw.sections) || !Array.isArray(raw.entries)) return null
  const sections = raw.sections.filter((s): s is PlanSection =>
    !!s && typeof s === 'object' && typeof (s as PlanSection).id === 'string' && typeof (s as PlanSection).name === 'string')
  const entries = raw.entries.filter((e): e is PlanEntry =>
    !!e && typeof e === 'object' && typeof (e as PlanEntry).paper === 'string'
      && ((e as PlanEntry).section === undefined || typeof (e as PlanEntry).section === 'string'))
  return { ...raw, sections, entries } as ReadingPlan
}

export function copyPlan(plan: ReadingPlan): ReadingPlan {
  return { ...plan, sections: plan.sections.map((s) => ({ ...s })), entries: plan.entries.map((e) => ({ ...e })) }
}

export const planContains = (plan: ReadingPlan, paper: string): boolean => plan.entries.some((e) => e.paper === paper)

export function sectionOf(plan: ReadingPlan, paper: string): PlanSection | null {
  const id = plan.entries.find((e) => e.paper === paper)?.section
  return id === undefined ? null : plan.sections.find((s) => s.id === id) ?? null
}

/** Papers in no section first (the only group when there are no sections), then every section, empty ones too. */
export function planGroups(plan: ReadingPlan): PlanGroup[] {
  const known = new Set(plan.sections.map((s) => s.id))
  const loose = plan.entries.filter((e) => e.section === undefined || !known.has(e.section)).map((e) => e.paper)
  const out: PlanGroup[] = []
  if (loose.length || plan.sections.length === 0) out.push({ section: null, papers: loose })
  for (const section of plan.sections) {
    out.push({ section, papers: plan.entries.filter((e) => e.section === section.id).map((e) => e.paper) })
  }
  return out
}

export const planOrder = (plan: ReadingPlan): string[] => planGroups(plan).flatMap((g) => g.papers)

function once(papers: string[]): string[] {
  const seen = new Set<string>()
  return papers.filter((p) => (seen.has(p) ? false : (seen.add(p), true)))
}

function knownSection(plan: ReadingPlan, section: string | null | undefined): string | undefined {
  return section && plan.sections.some((s) => s.id === section) ? section : undefined
}

/** Appends the papers the plan does not have yet, into `section`. */
export function addToPlan(plan: ReadingPlan, papers: string[], section: string | null = null): void {
  const target = knownSection(plan, section)
  const have = new Set(plan.entries.map((e) => e.paper))
  for (const paper of papers) {
    if (have.has(paper)) continue
    plan.entries.push(target === undefined ? { paper } : { paper, section: target })
    have.add(paper)
  }
}

export function removeFromPlan(plan: ReadingPlan, papers: Iterable<string>): void {
  const gone = new Set(papers)
  plan.entries = plan.entries.filter((e) => !gone.has(e.paper))
}

/** Moves the papers to just before `target`, into its section. Nothing moves when the target is one of them. */
export function moveBefore(plan: ReadingPlan, papers: string[], target: string): void {
  if (papers.includes(target)) return
  const anchor = plan.entries.find((e) => e.paper === target)
  if (!anchor) {
    moveToEnd(plan, papers, null)
    return
  }
  const present = new Set(plan.entries.map((e) => e.paper))
  const taken = once(papers).filter((p) => present.has(p))
  const moving = new Set(taken)
  const kept = new Map(plan.entries.filter((e) => moving.has(e.paper)).map((e) => [e.paper, e]))
  plan.entries = plan.entries.filter((e) => !moving.has(e.paper))
  const index = plan.entries.findIndex((e) => e.paper === target)
  const inserted = taken.map((paper) => withSection(kept.get(paper)!, anchor.section))
  plan.entries.splice(index < 0 ? plan.entries.length : index, 0, ...inserted)
}

/** Moves the papers to the end of `section` (null: out of every section). */
export function moveToEnd(plan: ReadingPlan, papers: string[], section: string | null): void {
  const target = knownSection(plan, section)
  const present = new Set(plan.entries.map((e) => e.paper))
  const taken = once(papers).filter((p) => present.has(p))
  const moving = new Set(taken)
  const kept = new Map(plan.entries.filter((e) => moving.has(e.paper)).map((e) => [e.paper, e]))
  plan.entries = plan.entries.filter((e) => !moving.has(e.paper))
  plan.entries.push(...taken.map((paper) => withSection(kept.get(paper)!, target)))
}

function withSection(entry: PlanEntry, section: string | undefined): PlanEntry {
  const out: PlanEntry = { ...entry }
  if (section === undefined) delete out.section
  else out.section = section
  return out
}

export function addSection(plan: ReadingPlan, name: string, id: string = makeUUID()): string {
  plan.sections.push({ id, name })
  return id
}

export function renameSection(plan: ReadingPlan, id: string, name: string): void {
  const section = plan.sections.find((s) => s.id === id)
  if (section) section.name = name
}

/** The section goes; its papers stay, in order, in no section. */
export function removeSection(plan: ReadingPlan, id: string): void {
  plan.sections = plan.sections.filter((s) => s.id !== id)
  plan.entries = plan.entries.map((e) => (e.section === id ? withSection(e, undefined) : e))
}

export function moveSection(plan: ReadingPlan, id: string, offset: number): void {
  const from = plan.sections.findIndex((s) => s.id === id)
  if (from < 0) return
  const to = Math.max(0, Math.min(plan.sections.length - 1, from + offset))
  if (to === from) return
  const [section] = plan.sections.splice(from, 1)
  plan.sections.splice(to, 0, section)
}

// MARK: - The day a paper is read

/** `papers/<id>/plan.json`. No file is no day. */
export interface PaperSchedule {
  date: string
  [key: string]: unknown
}

export function readSchedule(value: unknown): PaperSchedule | null {
  if (!value || typeof value !== 'object') return null
  return isDay((value as PaperSchedule).date) ? (value as PaperSchedule) : null
}

// MARK: - Materials

export type MaterialKind = 'paper' | 'slides' | 'code' | 'notebook' | 'video' | 'data' | 'post' | 'file'
export const MATERIAL_KINDS: MaterialKind[] = ['paper', 'slides', 'code', 'notebook', 'video', 'data', 'post', 'file']

/** One thing kept beside a paper: an address, or a file in the library folder (relative, `/` between parts). */
export interface PaperLink {
  id: string
  kind: MaterialKind
  url?: string
  file?: string
  title?: string
  addedAt: string
  [key: string]: unknown
}

/** `papers/<id>/links.json`. */
export interface PaperLinks {
  links: PaperLink[]
  [key: string]: unknown
}

export function readLinks(value: unknown): PaperLinks | null {
  if (!value || typeof value !== 'object' || !Array.isArray((value as PaperLinks).links)) return null
  const links = (value as PaperLinks).links
    .filter((l): l is PaperLink => !!l && typeof l === 'object' && typeof l.id === 'string' && typeof l.addedAt === 'string')
    .map((l) => ({ ...l, kind: (MATERIAL_KINDS as string[]).includes(l.kind) ? l.kind : 'file' }) as PaperLink)
  return { ...(value as PaperLinks), links }
}

export function linkTitle(link: PaperLink): string {
  if (link.title) return link.title
  if (link.url) return materialTitle(link.url)
  if (link.file) return link.file.split('/').pop() ?? link.file
  return ''
}

function afterScheme(address: string): string {
  const at = address.indexOf('://')
  return at < 0 ? address : address.slice(at + 3)
}

function hostPart(rest: string): string {
  let host = ''
  for (const c of rest) {
    if (c === '/' || c === '?' || c === '#') break
    host += c
  }
  return host
}

/** The address to keep, with `https://` put in front when it was left off; null for anything that is not one. */
export function materialAddress(raw: string): string | null {
  let text = normalizedKeepingCase(raw)
  if (text.startsWith('<') && text.endsWith('>')) text = text.slice(1, -1)
  if (!text || text.includes(' ')) return null
  const lower = text.toLowerCase()
  let rest: string
  if (lower.startsWith('https://')) rest = text.slice(8)
  else if (lower.startsWith('http://')) rest = text.slice(7)
  else if (lower.includes('://')) return null
  else {
    rest = text
    text = 'https://' + text
  }
  let host = hostPart(rest).toLowerCase()
  const colon = host.indexOf(':')
  if (colon >= 0) {
    const port = host.slice(colon + 1)
    if (!port || !/^[0-9]+$/.test(port)) return null
    host = host.slice(0, colon)
  }
  if (!host.includes('.') || !/^[a-z0-9.-]+$/.test(host)) return null
  if (host.startsWith('.') || host.endsWith('.') || host.startsWith('-') || host.includes('..')) return null
  return text
}

/** The host, without `www.` and without a port. */
export function materialHost(address: string): string {
  let host = hostPart(afterScheme(address)).toLowerCase()
  const colon = host.indexOf(':')
  if (colon >= 0) host = host.slice(0, colon)
  return host.startsWith('www.') ? host.slice(4) : host
}

function decode(part: string): string {
  try {
    return decodeURIComponent(part)
  } catch {
    return part
  }
}

function pathParts(address: string): string[] {
  const rest = afterScheme(address)
  const slash = rest.indexOf('/')
  if (slash < 0) return []
  let path = ''
  for (const c of rest.slice(slash)) {
    if (c === '?' || c === '#') break
    path += c
  }
  return path.split('/').filter((p) => p.length > 0).map(decode)
}

const hasQuery = (address: string): boolean => afterScheme(address).includes('?')

export function materialKindOfAddress(address: string): MaterialKind {
  const host = materialHost(address)
  const parts = pathParts(address)
  const first = (parts[0] ?? '').toLowerCase()
  const last = (parts[parts.length - 1] ?? '').toLowerCase()
  const ends = (extensions: string[]) => extensions.some((ext) => last.endsWith('.' + ext))
  if (ends(['ipynb'])) return 'notebook'
  if (host === 'colab.research.google.com' || host === 'nbviewer.org' || (host === 'kaggle.com' && first === 'code')) return 'notebook'
  if (['github.com', 'gitlab.com', 'bitbucket.org', 'codeberg.org'].includes(host)) return 'code'
  if (host === 'huggingface.co') return first === 'datasets' ? 'data' : 'code'
  if (host === 'kaggle.com' && first === 'datasets') return 'data'
  if (['youtube.com', 'm.youtube.com', 'youtu.be', 'vimeo.com', 'bilibili.com'].includes(host)) return 'video'
  if (host === 'docs.google.com' && first === 'presentation') return 'slides'
  if (['slideshare.net', 'speakerdeck.com', 'slides.com'].includes(host)) return 'slides'
  if (ends(['ppt', 'pptx', 'key', 'odp'])) return 'slides'
  if (['arxiv.org', 'openreview.net', 'doi.org', 'dx.doi.org', 'aclanthology.org', 'proceedings.neurips.cc',
    'proceedings.mlr.press', 'semanticscholar.org', 'dl.acm.org', 'ieeexplore.ieee.org', 'link.springer.com'].includes(host)
    || ends(['pdf'])) return 'paper'
  if (ends(['mp4', 'mov', 'm4v', 'webm', 'mkv'])) return 'video'
  if (ends(['csv', 'tsv', 'json', 'jsonl', 'parquet'])) return 'data'
  return 'post'
}

/** `NSString.pathExtension`: after the last dot of the last component, unless the name starts with it. */
function pathExtension(name: string): string {
  const base = name.split('/').pop() ?? name
  const dot = base.lastIndexOf('.')
  return dot <= 0 ? '' : base.slice(dot + 1)
}

export function materialKindOfFile(name: string): MaterialKind {
  switch (pathExtension(name).toLowerCase()) {
    case 'ppt': case 'pptx': case 'key': case 'odp': return 'slides'
    case 'ipynb': return 'notebook'
    case 'mp4': case 'mov': case 'm4v': case 'webm': case 'mkv': case 'avi': return 'video'
    case 'csv': case 'tsv': case 'json': case 'jsonl': case 'parquet': case 'h5': case 'hdf5': case 'npz': case 'npy': case 'xlsx': case 'xls': return 'data'
    case 'py': case 'r': case 'jl': case 'm': case 'c': case 'cc': case 'cpp': case 'h': case 'hpp': case 'js': case 'ts': case 'rs': case 'go': case 'java': case 'sh': case 'swift': return 'code'
    case 'md': case 'txt': case 'html': case 'htm': return 'post'
    default: return 'file'
  }
}

function hasFileExtension(part: string): boolean {
  const dot = part.lastIndexOf('.')
  if (dot <= 0) return false
  return /^[A-Za-z0-9]{1,5}$/.test(part.slice(dot + 1))
}

/** A short name for an address: `owner/repo`, `arXiv:2106.06860`, the file's name, or the host. */
export function materialTitle(address: string): string {
  const host = materialHost(address)
  const parts = pathParts(address)
  if (['github.com', 'gitlab.com', 'bitbucket.org', 'codeberg.org'].includes(host) && parts.length >= 2) {
    let repo = parts[1]
    if (repo.toLowerCase().endsWith('.git')) repo = repo.slice(0, -4)
    return parts[0] + '/' + repo
  }
  if (host === 'huggingface.co') {
    const rest = ['datasets', 'spaces', 'models'].includes(parts[0] ?? '') ? parts.slice(1) : parts
    if (rest.length >= 2) return rest[0] + '/' + rest[1]
  }
  if (host === 'arxiv.org' && parts.length >= 2 && ['abs', 'pdf', 'html'].includes(parts[0])) {
    let id = parts.slice(1).join('/')
    if (id.toLowerCase().endsWith('.pdf')) id = id.slice(0, -4)
    return 'arXiv:' + id
  }
  if ((host === 'doi.org' || host === 'dx.doi.org') && parts.length) return parts.join('/')
  const last = parts[parts.length - 1]
  if (last !== undefined && hasFileExtension(last)) return last
  return parts.length === 0 && !hasQuery(address) ? host : host + '/…'
}

/** The paper's own address, from its identifiers. */
export function paperAddressOf(arxiv?: string | null, doi?: string | null): string | null {
  if (arxiv) return 'https://arxiv.org/abs/' + arxiv
  if (doi) return 'https://doi.org/' + doi
  return null
}
