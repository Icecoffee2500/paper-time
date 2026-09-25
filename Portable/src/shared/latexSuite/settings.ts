/**
 * The settings Latex Suite has, at its defaults, plus the two the host editor
 * owns — `LatexSuite.Settings` on the Mac.
 */
import { Library } from './snippets.js'

export interface LatexSettings {
  snippetsEnabled: boolean
  removeSnippetWhitespace: boolean
  autoDeleteDollar: boolean
  autofractionEnabled: boolean
  autofractionSymbol: string
  autofractionBreakingChars: string
  /** Pairs of `[open, close]` inside which `/` makes no fraction. */
  autofractionExcludedEnvironments: string[][]
  matrixShortcutsEnabled: boolean
  matrixShortcutsEnvironments: string[]
  matrixShortcutsMacros: string[]
  taboutEnabled: boolean
  taboutExitEquationOnlyOnEOL: boolean
  taboutClosingSymbols: string[]
  autoEnlargeBrackets: boolean
  autoEnlargeBracketsSpace: boolean
  autoEnlargeBracketsTriggers: string[]
  wordDelimiters: string
  forceMathLanguages: string[]
  /** The editor's tab width in columns, for the indentation snippets keep. */
  tabSize: number
  /** The editor's indentation unit: spaces, or a tab. */
  indentUnit: string
}

/** Latex Suite's defaults (from the bundled file), with the tab width and indentation the fixtures were made with. */
export function defaultSettings(): LatexSettings {
  const s = Library.shared.settings
  return {
    snippetsEnabled: s.snippetsEnabled,
    removeSnippetWhitespace: s.removeSnippetWhitespace,
    autoDeleteDollar: s['autoDelete$'],
    autofractionEnabled: s.autofractionEnabled,
    autofractionSymbol: s.autofractionSymbol,
    autofractionBreakingChars: s.autofractionBreakingChars,
    autofractionExcludedEnvironments: s.autofractionExcludedEnvs.map((pair) => [...pair]),
    matrixShortcutsEnabled: s.matrixShortcutsEnabled,
    matrixShortcutsEnvironments: [...s.matrixShortcutsEnvNames],
    matrixShortcutsMacros: [...s.matrixShortcutsMacroNames],
    taboutEnabled: s.taboutEnabled,
    taboutExitEquationOnlyOnEOL: s.taboutExitEquationOnlyOnEOL,
    taboutClosingSymbols: [...s.taboutClosingSymbols],
    autoEnlargeBrackets: s.autoEnlargeBrackets,
    autoEnlargeBracketsSpace: s.autoEnlargeBracketsSpace,
    autoEnlargeBracketsTriggers: [...s.autoEnlargeBracketsTriggers],
    wordDelimiters: s.wordDelimiters,
    forceMathLanguages: [...s.forceMathLanguages],
    tabSize: 4,
    indentUnit: '  ',
  }
}
