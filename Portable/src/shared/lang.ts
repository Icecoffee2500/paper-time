/**
 * The interface in two languages, written side by side in the source.
 *
 * The same arrangement as the Mac's `L(ko, en)`: the two versions live next to
 * each other so they have to be edited together, rather than in a catalogue
 * where one quietly rots. Korean is written first, always.
 *
 * Which one is shown is decided once, in the main process, from the desktop's
 * own locale and the reader's override, and handed to the window as a launch
 * argument — so the first paint is already in the right language and there is
 * no flash of the wrong one.
 */

let korean = false

/** Set once at startup, on both sides. */
export function setKorean(value: boolean): void {
  korean = value
}

export function prefersKorean(): boolean {
  return korean
}

/** One string, both languages. Korean first. */
export function L(ko: string, en: string): string {
  return korean ? ko : en
}

export type LanguageChoice = 'system' | 'ko' | 'en'

/** What the desktop asks for: Korean when its locale is Korean. */
export function systemPrefersKorean(locale: string): boolean {
  return locale.toLowerCase().startsWith('ko')
}

export function resolveKorean(choice: LanguageChoice, locale: string): boolean {
  switch (choice) {
    case 'ko':
      return true
    case 'en':
      return false
    default:
      return systemPrefersKorean(locale)
  }
}
