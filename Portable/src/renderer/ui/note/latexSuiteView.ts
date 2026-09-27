/**
 * Latex Suite in the note editor — the adapter between CodeMirror and the
 * engine in `shared/latexSuite.ts`.
 *
 * The plugin itself is a CodeMirror extension, so this is the adapter that
 * needs the least: the engine is asked when a character is typed
 * (`inputHandler`) and for Tab, Shift-Tab, Enter, Shift-Enter and Backspace
 * (a keymap ahead of the editor's own), and its edit goes in as the plugin's
 * does — each undo step its own history event, so one Undo brings back `@a`
 * from `\alpha`. Mirrored placeholders are the editor's own multiple
 * selections; the placeholders themselves live in a state field, mapped
 * through every change, and drawn as the plugin draws them. Nothing runs
 * while an input method composes: Korean is typed through a composition.
 */
import { EditorSelection, EditorState, Prec, StateEffect, StateField, Transaction, type Extension, type Range } from '@codemirror/state'
import { Decoration, EditorView, WidgetType, keymap, type DecorationSet } from '@codemirror/view'
import { isolateHistory } from '@codemirror/commands'
import { LatexEngine, Tabstops, type LatexChange, type LatexEdit, type LatexInput, type TextRange } from '../../../shared/latexSuite.js'
import { latexShortcutsEnabled } from '../latexSuiteInput.js'

let sharedEngine: LatexEngine | null = null
const engine = () => (sharedEngine ??= new LatexEngine())

const setTabstops = StateEffect.define<Tabstops>()

const rangesOf = (state: EditorState): TextRange[] => state.selection.ranges.map((range) => ({ from: range.from, to: range.to }))

class EmptySlot extends WidgetType {
  override eq() { return true }
  toDOM() {
    const span = document.createElement('span')
    span.className = 'ls-slot-empty'
    return span
  }
}

function slotDecorations(tabstops: Tabstops): DecorationSet {
  const ranges: Range<Decoration>[] = []
  // The group the caret starts in is not drawn, as in the plugin.
  tabstops.groups.forEach((group, k) => {
    if (k === 0) return
    for (const range of group.ranges) {
      if (range.to > range.from) ranges.push(Decoration.mark({ class: 'ls-slot' }).range(range.from, range.to))
      else ranges.push(Decoration.widget({ widget: new EmptySlot(), side: 1 }).range(range.from))
    }
  })
  return Decoration.set(ranges, true)
}

const tabstopField = StateField.define<Tabstops>({
  create: () => Tabstops.none,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setTabstops)) return effect.value
    if (tr.isUserEvent('undo') || tr.isUserEvent('redo')) return Tabstops.none
    if (!value.isActive) return value
    if (tr.docChanged) {
      const changes: LatexChange[] = []
      tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => changes.push({ from: fromA, to: toA, text: inserted.toString() }))
      return value.afterEdit(changes, rangesOf(tr.state))
    }
    if (tr.selection) return value.selecting(rangesOf(tr.state))
    return value
  },
  provide: (field) => EditorView.decorations.from(field, slotDecorations),
})

function apply(view: EditorView, edit: LatexEdit) {
  for (const step of edit.undoSteps) {
    view.dispatch({
      changes: step.map((change) => ({ from: change.from, to: change.to, insert: change.text })),
      annotations: [isolateHistory.of('full'), Transaction.userEvent.of('input.latex')],
    })
  }
  const selection = edit.selection.length > 0
    ? EditorSelection.create(edit.selection.map((range) => EditorSelection.range(range.from, range.to)))
    : view.state.selection
  view.dispatch({ selection, effects: setTabstops.of(edit.tabstops), scrollIntoView: true })
}

function ask(view: EditorView, input: LatexInput): boolean {
  if (!latexShortcutsEnabled() || view.composing) return false
  const state = view.state
  const edit = engine().handle(input, state.doc.toString(), rangesOf(state), state.field(tabstopField))
  if (!edit) return false
  apply(view, edit)
  return true
}

export function latexSuiteView(): Extension {
  return [
    // Latex Suite's mirrored placeholders are several selections at once.
    EditorState.allowMultipleSelections.of(true),
    tabstopField,
    Prec.high(keymap.of([
      { key: 'Tab', run: (view) => ask(view, 'tab'), shift: (view) => ask(view, 'shiftTab') },
      { key: 'Enter', run: (view) => ask(view, 'enter'), shift: (view) => ask(view, 'shiftEnter') },
      { key: 'Backspace', run: (view) => ask(view, 'backspace') },
    ])),
    EditorView.inputHandler.of((view, _from, _to, text) => text.length === 1 && ask(view, { text })),
  ]
}
