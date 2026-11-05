/**
 * What a reader typed into «Add Paper by Address…», read for what it names —
 * the Mac's `PaperAddress` (PaperCore), held to the same fixture
 * (`Tests/PaperCoreTests/Fixtures/paper-addresses.json`).
 *
 * Three things come through that field: an arXiv paper (its identifier, or
 * any of the addresses arxiv.org gives one), a DOI (bare, with a `doi:`
 * prefix, as a doi.org address, or buried in a publisher's or Scopus's
 * address as a path or a `doi=` query), and a plain web address that may be
 * a PDF. A DOI is found before a plain address is kept, because a
 * publisher's page is a page and the DOI on it is what finds the PDF.
 */

export type PaperAddress =
  | { kind: 'arxiv'; id: string }
  | { kind: 'doi'; doi: string }
  | { kind: 'web'; url: string }

const NEW_STYLE = /(\d{4}\.\d{4,5})(?:v\d+)?(?!\d)/
const OLD_STYLE = /([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?\/\d{7})(?:v\d+)?(?!\d)/
// `<` and `>` are in a SICI DOI; `?` and `#` end a URL's path.
const DOI = /10\.\d{4,9}\/[^\s"?#]+/

/** Reads a typed line. Null when nothing in it names a paper. */
export function readPaperAddress(text: string): PaperAddress | null {
  let line = text.trim()
  if (line.startsWith('<') && line.endsWith('>')) line = line.slice(1, -1)
  // «DOI: 10.…» as a reference list writes it: the label and its space come
  // off. Otherwise an address has no spaces in it, and a sentence pasted by
  // mistake is not read for the DOI it may hold.
  line = line.replace(/^(doi|arxiv)\s*:\s+/i, '')
  if (line.length === 0 || /\s/.test(line)) return null

  const arxiv = arxivIdentifier(line)
  if (arxiv) return { kind: 'arxiv', id: arxiv }
  const doi = doiIn(line)
  if (doi) {
    // arXiv's own DOIs name the paper on arXiv.
    const onArxiv = arxivIdentifier(doi)
    return onArxiv ? { kind: 'arxiv', id: onArxiv } : { kind: 'doi', doi }
  }
  const url = webAddress(line)
  return url ? { kind: 'web', url } : null
}

/** The address as it is kept and shown: `arXiv:…`, `doi:…`, or the URL. */
export function addressText(address: PaperAddress): string {
  switch (address.kind) {
    case 'arxiv': return `arXiv:${address.id}`
    case 'doi': return `doi:${address.doi}`
    case 'web': return address.url
  }
}

/** Where the PDF is, when the address itself says so. */
export function addressPDF(address: PaperAddress): string | null {
  switch (address.kind) {
    case 'arxiv': return `https://arxiv.org/pdf/${address.id}`
    case 'doi': return null
    case 'web': return address.url
  }
}

/** Where to ask which open-access copy a DOI has: OpenAlex, which folds in
 *  Unpaywall's locations and needs no key. */
export function addressLookup(address: PaperAddress): string | null {
  if (address.kind !== 'doi') return null
  // Swift's `urlPathAllowed` less `?` and `#`: what a path may hold stays
  // as it is, and the rest is percent-encoded.
  const escaped = address.doi.replace(/[^A-Za-z0-9\-._~!$&'()*+,;=:@/]/g, (ch) =>
    Array.from(new TextEncoder().encode(ch)).map((byte) => `%${byte.toString(16).toUpperCase().padStart(2, '0')}`).join(''))
  return `https://api.openalex.org/works/https://doi.org/${escaped}?select=id,open_access,best_oa_location,primary_location,locations`
}

/** The name the PDF takes in the library. */
export function addressFileName(address: PaperAddress): string {
  switch (address.kind) {
    case 'arxiv': return `${address.id.split('/').join('_')}.pdf`
    case 'doi': return `${sanitised(address.doi)}.pdf`
    case 'web': {
      const url = new URL(address.url)
      let last = decodeURIComponent(lastPathComponent(url.pathname))
      if (last.toLowerCase().endsWith('.pdf')) last = last.slice(0, -4)
      // `…/pdf?id=abc`: the page is named by its query, not its path.
      if (['pdf', 'download', 'view', 'file', 'fulltext', 'content'].includes(last.toLowerCase())) {
        const items = [...url.searchParams.entries()]
        const value = items.length > 0 ? items[items.length - 1][1] : ''
        if (value) last = value
      }
      const name = sanitised(last)
      return name.length === 0 || last === '/' ? 'paper.pdf' : `${name}.pdf`
    }
  }
}

/** The identifier the record starts with, so the lookup asks the registrar
 *  directly rather than reading the first page for it. */
export function addressIdentifiers(address: PaperAddress): { arxiv?: string; doi?: string } {
  switch (address.kind) {
    case 'arxiv': return { arxiv: address.id }
    case 'doi': return { doi: address.doi }
    case 'web': return {}
  }
}

/** The PDF addresses OpenAlex's answer offers, best first: the location it
 *  calls best, then every other with a `pdf_url`, then `oa_url` when it is
 *  an address at all. Empty when the answer has none. */
export function openAccessPDFs(openAlexJSON: string): string[] {
  let object: unknown
  try {
    object = JSON.parse(openAlexJSON)
  } catch {
    return []
  }
  if (!object || typeof object !== 'object' || Array.isArray(object)) return []
  const found: string[] = []
  const take = (value: unknown) => {
    if (typeof value !== 'string') return
    let url: URL
    try {
      url = new URL(value)
    } catch {
      return
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return
    if (!found.includes(value)) found.push(value)
  }
  const record = object as Record<string, unknown>
  const field = (holder: unknown, name: string) =>
    holder && typeof holder === 'object' ? (holder as Record<string, unknown>)[name] : undefined
  take(field(record.best_oa_location, 'pdf_url'))
  take(field(record.primary_location, 'pdf_url'))
  if (Array.isArray(record.locations)) for (const location of record.locations) take(field(location, 'pdf_url'))
  take(field(record.open_access, 'oa_url'))
  return found
}

/**
 * Where a publisher keeps the PDF of a DOI, guessed from the prefix — tried
 * after every open copy, for the reader whose network has a subscription (a
 * university's, a research company's) and for the publisher that lets the
 * file through anyway. ACM, Springer, Wiley, Nature, ACS, Science, PNAS,
 * Taylor & Francis, SIAM and bioRxiv name the file by the DOI; Elsevier and
 * IEEE by an identifier of their own that OpenAlex's landing page carries.
 * Empty for a prefix not known here. The guesses are cheap to be wrong
 * about: a 403 is the same answer as none. The Mac's `publisherPDFs`.
 */
export function publisherPDFs(doi: string, openAlexJSON: string): string[] {
  const lower = doi.toLowerCase()
  const slash = lower.indexOf('/')
  if (slash < 0) return []
  const prefix = lower.slice(0, slash)
  const suffix = lower.slice(slash + 1)
  if (suffix.length === 0) return []
  const guesses: string[] = []
  switch (prefix) {
    case '10.1145': case '10.5555': guesses.push(`https://dl.acm.org/doi/pdf/${lower}`); break
    case '10.1007': guesses.push(`https://link.springer.com/content/pdf/${lower}.pdf`); break
    case '10.1002': guesses.push(`https://onlinelibrary.wiley.com/doi/pdfdirect/${lower}`); break
    case '10.1038': guesses.push(`https://www.nature.com/articles/${suffix}.pdf`); break
    case '10.1021': guesses.push(`https://pubs.acs.org/doi/pdf/${lower}`); break
    case '10.1126': guesses.push(`https://www.science.org/doi/pdf/${lower}`); break
    case '10.1073': guesses.push(`https://www.pnas.org/doi/pdf/${lower}`); break
    case '10.1080': guesses.push(`https://www.tandfonline.com/doi/pdf/${lower}`); break
    case '10.1137': guesses.push(`https://epubs.siam.org/doi/pdf/${lower}`); break
    case '10.1101': guesses.push(`https://www.biorxiv.org/content/${lower}.full.pdf`); break
    case '10.1016':
      // ScienceDirect names the file by its PII, which OpenAlex's landing
      // page (`…/science/article/pii/S0893608021000010`) carries.
      for (const page of landingPages(openAlexJSON)) {
        const match = /\/pii\/([A-Za-z0-9]{17})/.exec(page)
        if (match) guesses.push(`https://www.sciencedirect.com/science/article/pii/${match[1]}/pdfft?isDTMRedir=true&download=true`)
      }
      break
    case '10.1109':
      // IEEE Xplore names the file by its article number (`…/document/9879595`).
      for (const page of landingPages(openAlexJSON)) {
        const match = /ieeexplore\.ieee\.org\/document\/(\d+)/.exec(page)
        if (match) guesses.push(`https://ieeexplore.ieee.org/stampPDF/getPDF.jsp?tp=&arnumber=${match[1]}`)
      }
      break
    default: break
  }
  const found: string[] = []
  for (const guess of guesses) {
    let url: URL
    try {
      url = new URL(guess)
    } catch {
      continue
    }
    // Foundation's `URL(string:)` writes the address as it was given; so
    // does this, since `URL.href` would re-encode what Swift leaves alone.
    void url
    if (!found.includes(guess)) found.push(guess)
  }
  return found
}

/** The landing pages OpenAlex's answer names, the primary one first. */
function landingPages(openAlexJSON: string): string[] {
  let object: unknown
  try {
    object = JSON.parse(openAlexJSON)
  } catch {
    return []
  }
  if (!object || typeof object !== 'object' || Array.isArray(object)) return []
  const record = object as Record<string, unknown>
  const pages: string[] = []
  const take = (holder: unknown) => {
    const value = holder && typeof holder === 'object' ? (holder as Record<string, unknown>).landing_page_url : undefined
    if (typeof value === 'string' && value.length > 0 && !pages.includes(value)) pages.push(value)
  }
  take(record.primary_location)
  take(record.best_oa_location)
  if (Array.isArray(record.locations)) for (const location of record.locations) take(location)
  return pages
}

function arxivIdentifier(line: string): string | null {
  const lower = line.toLowerCase()
  if (lower.startsWith('arxiv:') || lower.startsWith('arxiv.') || lower.startsWith('10.48550/arxiv.')) {
    return identifierInArxivPath(line.slice(lower.startsWith('10.48550/arxiv.') ? 15 : 6))
  }
  const url = parseURL(line)
  if (url) {
    const host = url.hostname.toLowerCase()
    if (host === 'arxiv.org' || host.endsWith('.arxiv.org')) {
      // /abs/ID, /pdf/ID, /pdf/ID.pdf, /pdfvN, /html/ID: the path's tail.
      let path = url.pathname
      for (const prefix of ['/abs/', '/pdf/', '/html/', '/format/']) if (path.startsWith(prefix)) path = path.slice(prefix.length)
      if (path.toLowerCase().endsWith('.pdf')) path = path.slice(0, -4)
      return identifierInArxivPath(path)
    }
  }
  // A bare identifier, and nothing else on the line.
  const whole = /^(\d{4}\.\d{4,5})(?:v\d+)?$/.exec(line) ?? /^([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?\/\d{7})(?:v\d+)?$/.exec(line)
  return whole ? whole[1] : null
}

function identifierInArxivPath(path: string): string | null {
  const trimmed = path.replace(/^\/+|\/+$/g, '')
  const found = NEW_STYLE.exec(trimmed) ?? OLD_STYLE.exec(trimmed)
  return found ? found[1] : null
}

function doiIn(line: string): string | null {
  const candidates: string[] = []
  if (line.toLowerCase().startsWith('doi:')) candidates.push(line.slice(4))
  const url = parseURL(line)
  if (url) {
    const host = url.hostname.toLowerCase()
    if (host === 'doi.org' || host === 'dx.doi.org' || host.endsWith('.doi.org')) {
      candidates.push(decodeSafely(url.pathname.slice(1)))
    }
    // Scopus and the like: `…?eid=…&doi=10.…`.
    for (const [name, value] of url.searchParams.entries()) if (name.toLowerCase() === 'doi') candidates.push(value)
    candidates.push(decodeSafely(url.pathname))
  }
  candidates.push(decodeSafely(line))
  for (const candidate of candidates) {
    const found = DOI.exec(candidate)
    if (found) return clean(found[0])
  }
  return null
}

/** A DOI as a registrar would take it: lower-cased, without the punctuation
 *  a sentence or a URL hangs on its end. */
function clean(doi: string): string {
  let value = doi
  while (value.length > 0 && '.,;:)]}\'"'.includes(value[value.length - 1])) value = value.slice(0, -1)
  // `…/abstract` and `…/pdf` are the page's, not the DOI's — only on the
  // known publisher suffixes, since a DOI may hold any characters.
  for (const tail of ['/abstract', '/full', '/pdf', '/epdf', '/summary', '/meta']) {
    if (value.toLowerCase().endsWith(tail)) value = value.slice(0, -tail.length)
  }
  return value.toLowerCase()
}

function webAddress(line: string): string | null {
  const url = parseURL(line)
  if (url && (url.protocol === 'http:' || url.protocol === 'https:') && url.hostname) return line
  if (url) return null
  // `example.org/paper.pdf`: a host with a dot and no scheme.
  if (line.includes('://')) return null
  const dot = line.indexOf('.')
  if (dot <= 0) return null
  const made = parseURL(`https://${line}`)
  if (!made || !made.hostname.includes('.')) return null
  const tail = made.hostname.split('.').pop() ?? ''
  if (tail.length < 2 || !/^[A-Za-z]+$/.test(tail)) return null
  return `https://${line}`
}

function parseURL(text: string): URL | null {
  // Foundation's `URL(string:)` takes only what has a scheme and parses.
  if (!/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(text)) return null
  try {
    return new URL(text)
  } catch {
    return null
  }
}

function decodeSafely(text: string): string {
  try {
    return decodeURIComponent(text)
  } catch {
    return text
  }
}

function lastPathComponent(pathname: string): string {
  if (pathname === '' || pathname === '/') return '/'
  const parts = pathname.replace(/\/+$/, '').split('/')
  return parts[parts.length - 1] || '/'
}

function sanitised(text: string): string {
  // What no desktop takes in a name: the Mac's two, and Windows's rest.
  let name = ''
  for (const ch of text) {
    const code = ch.codePointAt(0) ?? 0
    name += '/:\\<>"|?*%'.includes(ch) || code < 32 ? '_' : ch
  }
  return [...name].slice(0, 120).join('')
}
