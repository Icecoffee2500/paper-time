/**
 * The window's panes, once they are built.
 *
 * `index.ts` builds each pane with the actions it offers and puts it here;
 * the modules those actions live in reach a pane through this rather than
 * through `index.ts`, which would make every one of them import the window
 * it is part of. Nothing reads these before `index.ts` has filled them in —
 * they are read inside actions, which run later.
 */
import { soloPaperID } from './bridge.js'
import type { buildToolbar } from './ui/toolbar.js'
import type { buildSidebar } from './ui/sidebar.js'
import type { buildPaperList } from './ui/paperList.js'
import type { buildInspector } from './ui/inspector.js'
import type { buildSlipBox } from './ui/slipBox.js'
import type { buildSketchRack } from './ui/sketchToolbar.js'
import type { buildSetup } from './ui/setup.js'
import type { buildPlanBoard } from './ui/planBoard.js'
import type { buildProjects } from './ui/projects.js'

export interface Shell {
  toolbar: ReturnType<typeof buildToolbar>
  sidebar: ReturnType<typeof buildSidebar>
  paperList: ReturnType<typeof buildPaperList>
  inspector: ReturnType<typeof buildInspector>
  slipBox: ReturnType<typeof buildSlipBox>
  rack: ReturnType<typeof buildSketchRack>
  /** The first-run screen, and the one for a library that is not there. */
  setup: ReturnType<typeof buildSetup>
  /** A shelf's table, a plan's calendar, «This Week» — where the list and the page were. */
  board: ReturnType<typeof buildPlanBoard>
  /** The projects: their list in the list's column, a project's page in the page area (1.1). */
  projects: ReturnType<typeof buildProjects>
  /** The list's pane: the papers, or on a slip-box shelf the slip-box (1.1: one of the row's panes). */
  listSlot: HTMLElement
  /** The row the panes stand in. */
  panes: HTMLElement
}

export const shell = {} as Shell

/** This window shows one paper on its own: no library columns. */
export const solo = soloPaperID !== null
