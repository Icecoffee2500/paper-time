/**
 * What the page area says instead of staying blank.
 *
 * A reader that shows nothing teaches somebody that the app is broken. It
 * takes one sentence to say which thing happened, and the sentence is worth
 * more than the blank page was.
 */
import { el, on } from '../dom.js'
import { L } from '../../shared/lang.js'
import { handlerDisplayName, type ByteTrouble } from '../../shared/pdfLock.js'

export interface Notice {
  title: string
  body: string
  /** The fine line under it: what to grep for. */
  fine?: string
}

/**
 * What is wrong with the bytes, said in the words that fit it.
 *
 * These all arrive at pdf.js as the same six words, so the telling apart
 * happens before it is asked and the answer is handed here. The parser's
 * own sentence is kept in the fine line: it is the string that made this
 * diagnosable, and a report with nothing to grep for is a report nobody can
 * act on.
 */
export function troubleNotice(
  trouble: ByteTrouble, size: number, detail?: string, head?: string, line?: string | null,
): Notice {
  const megabytes = (size / 1_000_000).toFixed(1)
  const [title, body] = trouble === 'opaque' && line
    ? [
      L('PDF 자리에 글자가 들어 있어요', 'There is text where the PDF should be'),
      L('이 파일에는 PDF 대신 짧은 글자만 있어요. 원본이 다른 곳에 있다는 쪽지이거나, 회사 보안 '
        + '프로그램이 등록된 앱에만 원본을 주고 있는 거예요. 아래 첫 줄이 어느 쪽인지 말해 주니, '
        + '회사 IT에 그대로 보여주세요. 파일 탐색기에서 한 번 열어 본 뒤 «다시 열기»를 누르면 '
        + '원본이 따라오는 경우도 있어요.',
        'This file holds a short piece of text instead of a PDF. Either it is a note saying the '
        + 'real file lives somewhere else, or a security agent is giving the real file only to the '
        + 'readers your company registered. The first line below says which — show it to your IT '
        + 'desk as it stands. Opening the file once from your file manager and then pressing Try '
        + 'Again sometimes brings the real one across.'),
    ]
    : trouble === 'opaque'
    ? [
      L('이 파일을 이 앱에는 다르게 보여주고 있어요', 'Something is handing this app a different file'),
      L('파일 자리에 PDF가 아닌 것이 있어요. 같은 파일이 Acrobat에서는 열리고 여기서는 안 열린다면, '
        + '회사의 보안 프로그램이 등록된 앱에만 원본을 주고 있는 거예요. 그건 이 앱이 열 수 없어요.',
        'There is something other than a PDF where the file should be. If the same file opens in '
        + "Acrobat but not here, a security agent is giving the real file only to the readers your "
        + 'company registered — and this app cannot open what it is handed instead.'),
    ]
    : trouble === 'webpage'
    ? [
      L('이 파일은 PDF가 아니에요', 'This file is not a PDF'),
      L('PDF 자리에 웹 페이지가 들어 있어요. 회사 보안 프로그램이 원본 대신 안내문을 놓았을 수 있어요.',
        'There is a web page where the PDF should be. A security tool may have put a notice in its place.'),
    ]
    : trouble === 'empty'
      ? [
        L('이 논문은 아직 비어 있어요', 'This paper is still empty'),
        L('폴더에 이름만 있고 내용이 없어요. 클라우드에서 내려온 뒤에 다시 열어 주세요.',
          'The folder has the name but not the contents yet. Open it again once your cloud app has fetched it.'),
      ]
      : [
        L('이 논문을 아직 다 못 받았어요', 'This paper is still arriving'),
        trouble === 'placeholder'
          ? L('클라우드에서 아직 안 내려왔어요. 잠시 뒤에 다시 열어 주세요.',
              "It hasn't come down from the cloud yet. Open it again in a moment.")
          : L(`${megabytes} MB까지만 와 있어요. 잠시 뒤에 다시 열어 주세요.`,
              `Only ${megabytes} MB of it is here. Open it again in a moment.`),
      ]
  // The first bytes go in the fine line beside the parser's own words. They
  // cost nothing to send and they say which of these it is — which is the
  // difference between a day's hunting and a glance at a screenshot.
  // Bytes while it is bytes: a 249-byte stub reported as "0 KB" reads as a
  // rounding error rather than as the thing that is wrong with it.
  const measure = size < 1024
    ? `${size} B`
    : size < 1_000_000 ? `${Math.round(size / 1024)} KB` : `${megabytes} MB`
  const fine = [line ? `“${line}”` : null, head ? `${head} · ${measure}` : null, detail]
    .filter(Boolean).join('  ')
  return { title, body, fine: fine || undefined }
}

/** A file whose key is held by a rights service, not by the reader. */
export function lockedNotice(handler: string): Notice {
  // A container that named nobody is still a container: the sentence works
  // without the brand, and inventing one would be worse than leaving it out.
  const name = handlerDisplayName(handler) ?? L('회사 권한 서비스', 'a rights service')
  return {
    title: L('회사가 보호한 논문이에요', 'This paper is protected'),
    body: L(`${name}가 잠근 파일이라 Paper Time은 못 열어요. 파일이 깨진 건 아니에요 — 여는 열쇠를 `
      + '회사 권한 서버가 들고 있고, 그 서버에 물어볼 수 있는 앱은 Acrobat처럼 회사가 허락한 것뿐이에요.',
      `${name} locked this file, so Paper Time can't open it. The file is not damaged — the key `
      + "lives on your company's rights server, and only a reader your company allows, such as "
      + 'Acrobat, can ask for it.'),
  }
}

export function damagedNotice(detail: string): Notice {
  return {
    title: L('이 PDF를 열 수 없어요', "Paper Time can't open this PDF"),
    body: L('파일이 깨졌을 수 있어요. 다른 뷰어에서도 안 열리면 파일 쪽 문제예요.',
      'The file may be damaged. If another reader cannot open it either, the file is the problem.'),
    fine: detail,
  }
}

/** The notice as a block for the page area. */
export function noticeNode(notice: Notice, extra?: HTMLElement): HTMLElement {
  return el('div', { class: 'empty' }, [
    el('h2', { text: notice.title }),
    el('p', { text: notice.body }),
    ...(notice.fine ? [el('p', { class: 'fine', text: notice.fine })] : []),
    ...(extra ? [extra] : []),
  ])
}

/** One press to ask for the file again, rather than a paper to click away
 *  from — and one to go to the file itself, which is where the reader the
 *  company registered is reached from. */
export function troubleButtons(options: { reveal?: () => void; again?: () => void }): HTMLElement | undefined {
  const buttons: HTMLElement[] = []
  if (options.reveal) {
    const show = el('button', { class: 'plain-button', text: L('폴더에서 보기', 'Show in Folder') })
    on(show, 'click', () => options.reveal?.())
    buttons.push(show)
  }
  if (options.again) {
    const button = el('button', { class: 'filled-button', text: L('다시 열기', 'Try Again') })
    on(button, 'click', options.again)
    buttons.push(button)
  }
  return buttons.length > 0 ? el('div', { class: 'fb-row' }, buttons) : undefined
}

/**
 * The password, asked for in the page area itself.
 *
 * pdf.js keeps its promise pending until somebody answers, so with no one
 * asking, a locked paper sat on a blank page forever — no page, no error,
 * nothing to click. The answer goes straight back to pdf.js and is kept
 * nowhere.
 */
export function passwordPrompt(wrong: boolean, send: (password: string) => void): { notice: Notice; node: HTMLElement; focus: () => void } {
  const field = el('input', {
    class: 'fb-input',
    type: 'password',
    placeholder: L('암호', 'Password'),
  }) as HTMLInputElement
  const open = el('button', { class: 'filled-button', text: L('열기', 'Open') })
  const press = () => {
    if (field.value) send(field.value)
  }
  on(open, 'click', press)
  on(field, 'keydown', (event) => {
    if ((event as KeyboardEvent).key === 'Enter') press()
  })
  return {
    notice: {
      title: L('암호가 걸린 논문이에요', 'This paper is locked'),
      body: wrong
        ? L('암호가 맞지 않아요. 다시 넣어주세요.', "That password didn't work. Try again.")
        : L('암호를 넣으면 열어요. 어디에도 저장하지 않아요.',
            'Type the password and it opens. It is not stored anywhere.'),
    },
    node: el('div', { class: 'fb-row' }, [field, open]),
    focus: () => field.focus(),
  }
}

export const openingNotice = (): Notice => ({
  title: L('여는 중이에요', 'Opening'),
  body: L('암호를 확인하고 있어요.', 'Checking the password.'),
})
