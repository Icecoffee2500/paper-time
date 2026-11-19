/* What 1.0 set aside — the Portable half of `App/Model/Legacy.swift`.
   The code stays and the files stay compatible; the places that make these
   things are hidden until 2.0. One flag per feature, all off. Only the
   features this build has are listed. */
export const LEGACY = {
  /** What the empty search palette offers (continue, revisit, new this week). */
  emptySearchSuggestions: false,
  /** The slip-box's maps and drafts from a note's menu — «Put on Map», «Add to Draft» (the Mac's `slipBoxStructures`).
   *  The files still open; the ways of making them wait for 2.0. */
  slipBoxStructures: false,
  /** Settings → Library → «Notes Without a Paper»: choosing their folder. The notes stay; the control waits for 2.0. */
  looseNotesFolder: false,
  /** The list beside the page as it was before 1.1 (`ui/paperList.ts`), and
   *  the List | Table switch that chose between it and the table — the Mac's
   *  `Legacy.paperList`. The user tried both on 2026-11-16 and kept the
   *  table; the list stays in the code so it comes back with this one line.
   *  Search results still use it (their passages are rows a table has no
   *  columns for), and so does a library with no papers yet (its setup). */
  paperList: false,
} as const
