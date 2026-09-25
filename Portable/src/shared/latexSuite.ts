/**
 * The text engine of Latex Suite (Obsidian, by artisticat1), with its default
 * snippets and settings, for the note editors of this build.
 *
 * This is the TypeScript half of `PaperCore/LatexSuite` on the Mac, and the two
 * are one engine written twice: the same snippet file (the Mac bundles it, the
 * renderer bundle carries it here), the same public shape, the same fixtures
 * recorded from the plugin itself. Latex Suite is why people take math notes
 * at the speed they write — `@a` becomes `\alpha`, `x/` becomes `\frac{x}{}`
 * with the caret in the denominator, Tab walks through placeholders and out of
 * the equation — and what makes it feel right is a thousand small decisions
 * about which snippet wins and where the caret lands. A person who moves
 * between a Mac and a Windows machine must not have to learn two of them.
 *
 * It is pure: text in, edit out — no editor, no DOM. `ui/latexSuiteInput.ts`
 * adapts a textarea to it.
 *
 * **When to call it.** Before the editor acts on a key, exactly like Latex
 * Suite's `keydown` handler: the typed character is *not* yet in `text`. Null
 * means the key is not Latex Suite's: let the editor do what it normally does,
 * then move the tabstops with `Tabstops.afterEdit`. An edit means: do not
 * insert the key; apply the edit instead. Call it only for plain keystrokes —
 * not while an input method is composing, not with Command or Control held
 * (Option-made characters are fine) — because Latex Suite does not run then
 * either.
 *
 * **Units.** Every offset is a UTF-16 code unit, which is what a JavaScript
 * string index already is and what the Mac's NSRange counts. A range is
 * `{ from, to }` (the Mac's `NSRange(location: from, length: to - from)`).
 *
 * **The selection.** Ranges in any order; they are sorted and merged, and the
 * first one after that is the main one — the caret whose place decides the
 * mode for all of them. A range's end stands for the caret.
 *
 * **Tabstops.** Keep the `tabstops` an edit returns and pass them back with the
 * next key. Whenever the text or selection changes any other way, run them
 * through `afterEdit` (or `selecting` for a selection change alone): that is
 * how a placeholder grows as it is typed into, and how leaving every
 * placeholder ends the snippet. Undo drops them (`Tabstops.none`).
 */
import { ChangeSet, normalizedSelection, type PublicChange } from './latexSuite/changes.js'
import { Run } from './latexSuite/run.js'
import { defaultSettings, type LatexSettings } from './latexSuite/settings.js'
import { Library } from './latexSuite/snippets.js'
import { TabstopState } from './latexSuite/tabstops.js'
import type { Span } from './latexSuite/text.js'

export { defaultSettings, type LatexSettings }

/** One keystroke, and what Latex Suite may do with it. */
export type LatexInput =
  /** The characters one keypress produces. Only a single UTF-16 code unit counts. */
  | { text: string }
  /** Tab-triggered snippets, then the next tabstop, then the matrix shortcuts, then out of the equation. */
  | 'tab'
  /** The previous tabstop. */
  | 'shiftTab'
  /** A new matrix row, inside a matrix environment. */
  | 'enter'
  /** Out of the matrix row or environment. */
  | 'shiftEnter'
  /** Both dollars of an empty `$$` at once. */
  | 'backspace'

/** A range of UTF-16 offsets, `from` included and `to` not. */
export interface TextRange {
  from: number
  to: number
}

/** One replacement: `from..<to` (UTF-16) of the document it applies to becomes `text`. */
export type LatexChange = PublicChange

export interface TabstopGroup {
  /** In document order; a range may be empty (a caret position). */
  ranges: TextRange[]
  /** 0, 1 or 2, cycling per expansion: Latex Suite's placeholder colour. Styling only. */
  color: number
}

/**
 * Whatever an editor hands over, as a range this engine can use: NaN and
 * negative offsets become 0, and an end before the start leaves the range
 * empty at the start — never a trap, never a range the other way round.
 */
function sane(r: TextRange): Span {
  const from = Number.isFinite(r.from) ? Math.max(0, Math.floor(r.from)) : 0
  const to = Number.isFinite(r.to) ? Math.max(from, Math.floor(r.to)) : from
  return { from, to }
}

/**
 * The placeholders of the snippets being filled in.
 *
 * A snippet's tabstops form **groups** visited in order; `$0` is the *first*
 * stop (not the last, as in VS Code). Ranges of one group mirror each other
 * and are selected together. `index` is the group the caret is in. Reaching
 * the last group — or leaving every group — ends the snippet, and then there
 * are no groups at all. A snippet expanded inside a group replaces that group
 * with its own groups, so Tab continues with the outer snippet afterwards.
 */
export class Tabstops {
  constructor(readonly groups: TabstopGroup[], readonly index: number, readonly nextColor = 0) {}

  static readonly none = new Tabstops([], 0, 0)

  get isActive(): boolean {
    return this.groups.length > 0
  }

  get current(): TabstopGroup | null {
    return this.groups[this.index] ?? null
  }

  /** @internal */
  static fromState(state: TabstopState): Tabstops {
    return new Tabstops(
      state.groups.map((ranges, k) => ({ ranges: ranges.map((r) => ({ from: r.from, to: r.to })), color: state.colors[k] ?? 0 })),
      state.index,
      state.nextColor,
    )
  }

  /** @internal */
  toState(): TabstopState {
    return new TabstopState(this.groups.map((g) => g.ranges.map(sane)), this.groups.map((g) => g.color), this.index, this.nextColor)
  }

  /**
   * Every range moved through an edit — the editor's own typing inside a
   * placeholder, or anything else. Ranges grow at both ends (text typed at a
   * placeholder's edge becomes part of it); an empty tabstop inside text that
   * was replaced disappears. `changes` are simultaneous and refer to the
   * document before them.
   */
  mapped(changes: LatexChange[]): Tabstops {
    const state = this.toState()
    state.map(new ChangeSet(changes.map((c) => {
      const r = sane(c)
      return { from: r.from, to: r.to, insert: c.text }
    })))
    return Tabstops.fromState(state)
  }

  /**
   * What Latex Suite does whenever the selection is set: the current group
   * becomes the first one containing the whole selection, and if that is the
   * last group, or none, the snippet is over.
   */
  selecting(selection: TextRange[]): Tabstops {
    const state = this.toState()
    state.select(selection.map(sane))
    return Tabstops.fromState(state)
  }

  /** Both, for an edit the editor made itself: `changes` against the old document, then `selection` in the new one. */
  afterEdit(changes: LatexChange[], selection: TextRange[]): Tabstops {
    return this.mapped(changes).selecting(selection)
  }
}

/** What to do instead of the editor's own handling of the key. */
export interface LatexEdit {
  /** The whole edit, all against the document passed in: sorted, not overlapping. Apply them together (right to left). */
  changes: LatexChange[]
  /**
   * The same edit as Latex Suite's undo history records it: apply each step's
   * changes (against the document the previous step left) as its own undo
   * group. When a snippet expands on a typed key, the key itself is the first
   * step — one Undo then brings back the trigger as typed (`@a`), a second
   * removes the key.
   */
  undoSteps: LatexChange[][]
  /** The selection afterwards, in document order; several ranges are mirrored placeholders selected together. */
  selection: TextRange[]
  tabstops: Tabstops
}

/** The credit, licence and version the bundled data carries, for an About screen. */
export const LatexSuite = {
  /** The credit line the licence asks for. */
  get credit(): string {
    return Library.shared.header.credit
  },
  /** Latex Suite's MIT licence, verbatim. */
  get licence(): string {
    return Library.shared.header.licenceText
  },
  /** The Latex Suite release the defaults and behaviour come from. */
  get version(): string {
    return Library.shared.header.version
  },
  /** How many default snippets the bundled file holds (199 for 1.13.1). */
  get snippetCount(): number {
    return Library.shared.snippets.length
  },
}

/** Reacts to keystrokes. Holds no document state: pass the text, the selection and the tabstops every time. */
export class LatexEngine {
  readonly settings: LatexSettings
  private readonly library: Library

  constructor(settings: LatexSettings = defaultSettings()) {
    this.settings = settings
    this.library = Library.shared
  }

  /**
   * Latex Suite's answer to `input` typed into `text` with `selection` (one
   * range is the usual caret or selection) and the active `tabstops`. Null
   * means the key is not Latex Suite's: let the editor handle it.
   */
  handle(input: LatexInput, text: string, selection: TextRange[], tabstops: Tabstops = Tabstops.none): LatexEdit | null {
    const count = text.length
    const ranges = normalizedSelection(selection.map((r) => {
      const s = sane(r)
      return { from: Math.min(s.from, count), to: Math.min(s.to, count) }
    }))
    if (ranges.length === 0) return null
    // Placeholders kept from an older text may reach past this one; an editor
    // must never be handed a range outside its text.
    const state = tabstops.toState()
    state.clamp(count)
    const run = new Run(text, ranges, state, this.settings, this.library)
    if (!run.handle(input)) return null
    const edit = run.edit()
    return {
      changes: edit.changes,
      undoSteps: edit.undoSteps,
      selection: edit.selection.map((r) => ({ from: r.from, to: r.to })),
      tabstops: Tabstops.fromState(edit.tabstops),
    }
  }
}
