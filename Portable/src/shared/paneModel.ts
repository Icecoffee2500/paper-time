/**
 * Which columns the window shows, and focus mode — the Mac's rules
 * (`AppModel.toggleSidebar/PaperList/Reader/Inspector`, `setFocusMode`), pure
 * so they are tested (`src/test/focus.ts`) rather than clicked.
 *
 * Focus is a state of its own, not four flags overwritten: it remembers the
 * list and the inspector it hid, and what is saved is the window focus
 * would give back — the window used to save the focused panes themselves,
 * and a restart stranded it with every column shut and no way back.
 */
export interface Panes {
  sidebar: boolean
  paperList: boolean
  reader: boolean
  inspector: boolean
}

export type Pane = keyof Panes

export interface PaneState {
  panes: Panes
  focus: { on: boolean; before: { paperList: boolean; inspector: boolean } }
}

export const unfocused = (panes: Panes): PaneState => ({
  panes: { ...panes },
  focus: { on: false, before: { paperList: panes.paperList, inspector: panes.inspector } },
})

/** The paper and nothing else: the list and the inspector remembered. */
export function enterFocus(state: PaneState): PaneState {
  if (state.focus.on) return state
  return {
    panes: { sidebar: false, paperList: false, reader: true, inspector: false },
    focus: { on: true, before: { paperList: state.panes.paperList, inspector: state.panes.inspector } },
  }
}

/** Back: the sidebar, and the list and inspector as they were. */
export function leaveFocus(state: PaneState): PaneState {
  if (!state.focus.on) return state
  return {
    panes: { ...state.panes, sidebar: true, paperList: state.focus.before.paperList, inspector: state.focus.before.inspector },
    focus: { ...state.focus, on: false },
  }
}

/**
 * One column on or off. Something is always left to look at: closing the
 * list with nothing else showing opens the paper, closing the paper with
 * nothing else showing opens the list — and asking for the paper in focus
 * mode, which is the paper and nothing else, leaves focus mode.
 */
export function togglePaneState(state: PaneState, pane: Pane): PaneState {
  if (pane === 'reader' && state.focus.on) return leaveFocus(state)
  const panes = { ...state.panes, [pane]: !state.panes[pane] }
  if (pane === 'paperList' && !panes.paperList && !panes.reader && !panes.sidebar) panes.reader = true
  if (pane === 'reader' && !panes.reader && !panes.paperList && !panes.sidebar) panes.paperList = true
  if (pane === 'sidebar' && !panes.sidebar && !panes.paperList && !panes.reader) panes.reader = true
  return { ...state, panes }
}

/** A column shown for someone — the pen bringing the Tools tab, a note
 *  opening — in or out of focus. */
export function showPane(state: PaneState, pane: Pane): PaneState {
  if (state.panes[pane]) return state
  return { ...state, panes: { ...state.panes, [pane]: true } }
}

/** What is written to the settings: the window as it is out of focus. */
export function restingPanes(state: PaneState): Panes {
  return state.focus.on ? leaveFocus(state).panes : state.panes
}
