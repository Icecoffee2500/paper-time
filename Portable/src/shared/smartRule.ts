/**
 * Which papers a smart collection holds — the Mac's `SmartRuleEvaluator`
 * (`App/Model/LibraryModel.swift`), rule for rule.
 *
 * A smart collection has no members written down: its papers are whoever its
 * rule matches today. This build filtered every collection by the papers'
 * `collectionIDs`, so a smart collection made on the Mac was always empty
 * here — the same folder, two answers to what is in it.
 */
import type { CSLName, Collection, PaperMeta, PaperState, SmartCondition, SmartRule, Tag } from './model.js'

/** A name the way the Mac's `CSLName.displayName` writes it. */
export function displayName(name: CSLName): string {
  if (name.literal) return name.literal
  const tail = [name['non-dropping-particle'], name.family].filter((part): part is string => Boolean(part)).join(' ')
  const core = [name.given || undefined, tail || undefined].filter(Boolean).join(' ')
  return name.suffix ? `${core}, ${name.suffix}` : core
}

/** A number the way Swift's `Double(String)` reads one: all of it, or nothing. */
function number(text: string): number {
  return /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(text) ? Number(text) : 0
}

/** What a condition compares against, for one paper. */
function actual(condition: SmartCondition, meta: PaperMeta, state: PaperState, tags: Tag[]): string {
  switch (condition.field) {
    case 'title': return meta.displayTitle
    case 'author': return (meta.csl.author ?? []).map(displayName).join(' ')
    case 'year': return String(meta.year ?? 0)
    case 'venue': return meta.csl['container-title'] ?? ''
    case 'tag':
      return meta.tagIDs
        .map((id) => tags.find((tag) => tag.id === id)?.name)
        .filter((name): name is string => Boolean(name))
        .join(' ')
    case 'readingStatus': return state.readingStatus
    case 'confidence': return meta.confidence
    // `.iso8601.year().month().day()`, which is in UTC.
    case 'dateAdded': return meta.addedAt.toISOString().slice(0, 10)
  }
}

function holds(condition: SmartCondition, meta: PaperMeta, state: PaperState, tags: Tag[]): boolean {
  const value = actual(condition, meta, state, tags)
  switch (condition.comparison) {
    // `localizedCaseInsensitiveContains`, which finds nothing for nothing.
    case 'contains':
      return condition.value.length > 0 && value.toLocaleLowerCase().includes(condition.value.toLocaleLowerCase())
    case 'equals': return value.toLocaleLowerCase() === condition.value.toLocaleLowerCase()
    case 'notEquals': return value.toLocaleLowerCase() !== condition.value.toLocaleLowerCase()
    case 'greaterThan': return number(value) > number(condition.value)
    case 'lessThan': return number(value) < number(condition.value)
  }
}

/** Whether a paper answers a rule. A rule with no conditions takes everything. */
export function matchesRule(rule: SmartRule, meta: PaperMeta, state: PaperState, tags: Tag[]): boolean {
  const results = (rule.conditions ?? []).map((condition) => holds(condition, meta, state, tags))
  if (results.length === 0) return true
  return rule.matchAll === false ? results.some(Boolean) : results.every(Boolean)
}

/** Whether a paper is in a collection: its rule when it is smart, its
 *  membership when it is not. */
export function inCollection(collection: Collection, meta: PaperMeta, state: PaperState, tags: Tag[]): boolean {
  if (!collection.rule) return meta.collectionIDs.includes(collection.id)
  return matchesRule(collection.rule, meta, state, tags)
}
