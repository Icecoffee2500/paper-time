/* What 1.0 set aside — the Portable half of `App/Model/Legacy.swift`.
   The code stays and the files stay compatible; the places that make these
   things are hidden until 2.0. One flag per feature, all off. Only the
   features this build has are listed. */
export const LEGACY = {
  /** What the empty search palette offers (continue, revisit, new this week). */
  emptySearchSuggestions: false,
  /** Settings → Library → «Notes Without a Paper»: choosing their folder. The notes stay; the control waits for 2.0. */
  looseNotesFolder: false,
} as const
