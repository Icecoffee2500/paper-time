/**
 * The window before there is a library, and when the one chosen is not there.
 *
 * The first is the Mac's `LibrarySetupView`: what a library is here — a
 * folder of ordinary files — the folders this machine already syncs as one
 * press each, the libraries opened before, Choose Folder…, and the sentence
 * that says deleting the app leaves the papers. It takes the whole window: a
 * heading in the list column between an empty sidebar and an empty reader
 * was a first screen made of the parts of a window that had nothing in them.
 *
 * The second is `LibraryUnavailableView`: the folder by name, Try Again, and
 * a way to choose another — a disk not plugged in is a wait, not an error.
 */
import { clear, el, on } from '../dom.js'
import { iconNode } from '../icons.js'
import { L } from '../../shared/lang.js'
import { providerIcon, providerName, providerOf, type CloudProvider } from '../../shared/cloudProvider.js'

export interface SetupActions {
  choose: () => void
  open: (root: string) => void
  /** Try the folder that was not there again. */
  retry: () => void
  suggestions: () => Promise<{ suggested: { path: string; provider: string }[]; recent: string[] }>
}

function basename(target: string): string {
  const parts = target.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] ?? target
}

export function buildSetup(actions: SetupActions): { node: HTMLElement; showSetup: () => void; showUnavailable: (root: string, message: string) => void } {
  const node = el('div', { class: 'setup-screen' })

  const folderButton = (target: string, caption: string, label = basename(target)) => {
    const glyph = iconNode(providerIcon(providerOf(target) as CloudProvider))
    const button = el('button', { class: 'setup-folder', title: target }, [
      el('span', { class: 'setup-folder-icon' }, glyph ? [glyph] : []),
      el('span', { class: 'setup-folder-lines' }, [
        el('span', { class: 'setup-folder-name', text: label }),
        el('span', { class: 'setup-folder-caption', text: caption }),
      ]),
    ])
    on(button, 'click', () => actions.open(target))
    return button
  }

  function showSetup() {
    clear(node)
    const glyph = iconNode('book.pages')
    const suggestions = el('div', { class: 'setup-suggestions' })
    const choose = el('button', { class: 'filled-button setup-choose', text: L('폴더 고르기…', 'Choose Folder…') })
    on(choose, 'click', actions.choose)
    node.append(el('div', { class: 'setup-card' }, [
      el('span', { class: 'setup-hero' }, glyph ? [glyph] : []),
      el('h1', { text: L('라이브러리 폴더 고르기', 'Choose a Library Folder') }),
      el('p', {
        class: 'setup-lede',
        text: L(
          'Paper Time은 논문을 그냥 파일로 둬요. OneDrive든 Google Drive든 폴더를 하나 고르면 돼요. 다른 기기에서 같은 폴더를 고르면 거기서도 똑같이 보여요.',
          'Paper Time keeps papers as ordinary files. Choose a folder in OneDrive, Google Drive, or anywhere else. Point another device at the same folder and the library follows.',
        ),
      }),
      suggestions,
      choose,
      el('p', { class: 'setup-foot', text: L('논문은 그 폴더에 그대로 있어요. 앱을 지워도 논문은 남아요.', 'Papers stay in that folder. Deleting the app leaves them there.') }),
    ]))
    void actions.suggestions().then(({ suggested, recent }) => {
      clear(suggestions)
      if (suggested.length > 0) {
        suggestions.append(el('div', { class: 'setup-heading', text: L('권하는 폴더', 'Suggested') }))
        for (const one of suggested) {
          // The folders' own names are a machine's: «com~apple~CloudDocs»,
          // «GoogleDrive-name@example.org». Said as a person says them.
          const name = basename(one.path)
          const account = /^[A-Za-z]+-(.+)$/.exec(name)?.[1]
          const label = name === 'com~apple~CloudDocs' ? 'iCloud Drive' : account ? providerName(one.provider as CloudProvider) : name
          suggestions.append(folderButton(one.path, account ?? providerName(one.provider as CloudProvider), label))
        }
      }
      if (recent.length > 0) {
        suggestions.append(el('div', { class: 'setup-heading', text: L('전에 연 라이브러리', 'Opened Before') }))
        for (const one of recent) suggestions.append(folderButton(one, one))
      }
    }).catch(() => undefined)
  }

  function showUnavailable(root: string, message: string) {
    clear(node)
    const glyph = iconNode('internaldrive')
    const again = el('button', { class: 'filled-button', text: L('다시 시도', 'Try Again') })
    const other = el('button', { class: 'plain-button', text: L('다른 폴더 고르기…', 'Choose a Different Folder…') })
    on(again, 'click', actions.retry)
    on(other, 'click', actions.choose)
    node.append(el('div', { class: 'setup-card' }, [
      el('span', { class: 'setup-hero muted' }, glyph ? [glyph] : []),
      el('h1', { text: L('라이브러리 폴더를 열 수 없어요', 'Library Folder Unavailable') }),
      el('p', { class: 'setup-lede', text: message }),
      el('p', { class: 'setup-path', text: root }),
      el('div', { class: 'setup-actions' }, [again, other]),
    ]))
  }

  return { node, showSetup, showUnavailable }
}
