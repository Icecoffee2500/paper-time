/**
 * `VenueStamp` (MetadataPipeline): where a paper was published, read off its
 * own first page.
 *
 * A camera-ready paper says where it appeared, in words its venue's style
 * file prints and nothing else does: «Published as a conference paper at
 * ICLR 2024», «37th Conference on Neural Information Processing Systems
 * (NeurIPS 2023)», «Proceedings of the 40th International Conference on
 * Machine Learning … PMLR 202, 2023». Those venues have no DOI, so no
 * registrar can say it — and the arXiv copy a reader downloads very often
 * still carries the line. The phrasings are the final ones only: «Under
 * review as a conference paper at ICLR», «Submitted to 37th Conference…»,
 * «Preprint. Under review.» and the workshops say nothing here.
 *
 * The patterns are the Mac's, read the way ICU reads them: `\d` is any
 * decimal digit (`\p{Nd}`), `\s` is Unicode white space, and a year is an
 * `Int(String)` — ASCII digits only.
 */

import type { CSLItem } from '../model.js'
import { collapsingWhitespace, swiftInt } from './text.js'

export interface VenueStamp {
  /** The venue as a table names it: «ICLR». */
  short: string
  /** The venue as a citation names it. */
  containerTitle: string
  type: string
  year?: number
  /** The proceedings series, for PMLR venues. */
  collectionTitle?: string
  volume?: string
}

/** The stamp on a page's text, if it carries one. */
export function findVenueStamp(text: string): VenueStamp | undefined {
  const page = collapsingWhitespace(text)
  if (!page) return undefined
  for (const rule of RULES) {
    const found = rule(page)
    if (found) return found
  }
  return undefined
}

/** The record a preprint becomes once its venue is known. */
export function appliedStamp(stamp: VenueStamp, item: CSLItem): CSLItem {
  const made: CSLItem = { ...item }
  made.type = stamp.type
  made['container-title'] = stamp.containerTitle
  delete made['container-title-short']
  if (stamp.collectionTitle !== undefined) made['collection-title'] = stamp.collectionTitle
  if (stamp.volume !== undefined) made.volume = stamp.volume
  if (stamp.year !== undefined) made.issued = { 'date-parts': [[stamp.year]] }
  if (typeof made.publisher === 'string' && made.publisher.toLowerCase().includes('arxiv')) delete made.publisher
  // arXiv's DOI names the preprint, not the paper at the venue.
  if (typeof made.DOI === 'string' && made.DOI.toLowerCase().startsWith('10.48550/arxiv.')) delete made.DOI
  return made
}

// MARK: - The phrasings

type Rule = (page: string) => VenueStamp | undefined

/** `\d` and `\s` as ICU reads them. */
function pattern(source: string): RegExp {
  return new RegExp(source.replaceAll('\\d', '\\p{Nd}').replaceAll('\\s', '\\p{White_Space}'), 'iu')
}

/** The first match, as its groups — a group that did not take part is ''. */
function first(source: string, text: string): string[] | undefined {
  const match = pattern(source).exec(text)
  if (!match) return undefined
  return Array.from(match, (group) => group ?? '')
}

/** `localizedCaseInsensitiveContains`, for the ASCII phrases it is asked about. */
const containsIgnoringCase = (text: string, phrase: string) => text.toLowerCase().includes(phrase.toLowerCase())

function stamp(short: string, containerTitle: string, type: string, year: number | undefined,
  collectionTitle?: string, volume?: string): VenueStamp {
  const out: VenueStamp = { short, containerTitle, type }
  if (year !== undefined) out.year = year
  if (collectionTitle !== undefined) out.collectionTitle = collectionTitle
  if (volume !== undefined) out.volume = volume
  return out
}

const PMLR = 'Proceedings of Machine Learning Research'

const RULES: Rule[] = [
  (page) => {
    const match = first('Published as a conference paper at ICLR (\\d{4})', page)
    if (!match || containsIgnoringCase(page, 'Under review as a conference paper')) return undefined
    return stamp('ICLR', 'International Conference on Learning Representations', 'paper-conference', swiftInt(match[1]))
  },
  (page) => {
    const match = first('(Submitted to )?\\d+\\s?(?:st|nd|rd|th) Conference on Neural Information Processing Systems \\((?:NeurIPS|NIPS) (\\d{4})\\)( Workshop)?', page)
    if (!match || match[1] !== '' || match[3] !== '') return undefined
    return stamp('NeurIPS', 'Advances in Neural Information Processing Systems', 'paper-conference', swiftInt(match[2]))
  },
  (page) => {
    const match = first('Proceedings of the \\d+\\s?(?:st|nd|rd|th) International Conference on Machine Learning,.{0,80}?PMLR (\\d+), (\\d{4})', page)
    if (!match) return undefined
    return stamp('ICML', 'International Conference on Machine Learning', 'paper-conference', swiftInt(match[2]), PMLR, match[1])
  },
  (page) => {
    const match = first('Proceedings of the \\d+\\s?(?:st|nd|rd|th) International Conference on Artificial Intelligence and Statistics \\(AISTATS\\) (\\d{4}).{0,80}?PMLR:? Volume (\\d+)', page)
    if (!match) return undefined
    return stamp('AISTATS', 'International Conference on Artificial Intelligence and Statistics', 'paper-conference', swiftInt(match[1]), PMLR, match[2])
  },
  (page) => {
    const match = first('\\d+\\s?(?:st|nd|rd|th) Conference on Robot Learning \\(CoRL (\\d{4})\\)', page)
    if (!match) return undefined
    return stamp('CoRL', 'Conference on Robot Learning', 'paper-conference', swiftInt(match[1]), PMLR)
  },
  (page) => {
    const match = first('This (CVPR|ICCV|WACV)( \\d{4})? (?:paper|workshop paper) is the Open Access version, provided by the Computer Vision Foundation', page)
    if (!match) return undefined
    const venue = match[1]
    const year = swiftInt(match[2].replace(/^[\t    -​  　]+|[\t    -​  　]+$/g, ''))
    if (containsIgnoringCase(page, `This ${venue}${match[2]} workshop paper`)) return undefined
    const name = venue === 'CVPR' ? 'Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)'
      : venue === 'ICCV' ? 'Proceedings of the IEEE/CVF International Conference on Computer Vision (ICCV)'
        : 'Proceedings of the IEEE/CVF Winter Conference on Applications of Computer Vision (WACV)'
    return stamp(venue, name, 'paper-conference', year)
  },
  (page) => {
    const match = first('AAAI Conference on Artificial Intelligence \\(AAAI-(\\d{2})\\)', page)
    const two = match ? swiftInt(match[1]) : undefined
    if (!match || two === undefined) return undefined
    return stamp('AAAI', 'Proceedings of the AAAI Conference on Artificial Intelligence', 'paper-conference', 2000 + two)
  },
  (page) => {
    const match = first('\\(IJCAI-(\\d{2})\\)', page)
    const two = match ? swiftInt(match[1]) : undefined
    if (!match || !containsIgnoringCase(page, 'International Joint Conference on Artificial Intelligence') || two === undefined) return undefined
    return stamp('IJCAI', 'Proceedings of the International Joint Conference on Artificial Intelligence', 'paper-conference', 2000 + two)
  },
  (page) => {
    const match = first('Findings of the Association for Computational Linguistics: (ACL|EMNLP|NAACL|EACL|AACL)[- ]?(?:IJCNLP )?(\\d{4})', page)
    if (!match) return undefined
    return stamp(`Findings of ${match[1]}`, `Findings of the Association for Computational Linguistics: ${match[1]} ${match[2]}`,
      'paper-conference', swiftInt(match[2]))
  },
  (page) => {
    const match = first('Proceedings of the (\\d{4}) Conference on Empirical Methods in Natural Language Processing', page)
    if (!match) return undefined
    return stamp('EMNLP', `Proceedings of the ${match[1]} Conference on Empirical Methods in Natural Language Processing`,
      'paper-conference', swiftInt(match[1]))
  },
  (page) => {
    const match = first('Proceedings of the (\\d{4}) Conference of the North American Chapter of the Association for Computational Linguistics', page)
    if (!match) return undefined
    return stamp('NAACL', `Proceedings of the ${match[1]} Conference of the North American Chapter of the Association for Computational Linguistics`,
      'paper-conference', swiftInt(match[1]))
  },
  (page) => {
    const match = first('Proceedings of the \\d+\\s?(?:st|nd|rd|th) Annual Meeting of the Association for Computational Linguistics(?: \\(Volume \\d+: [A-Za-z ]+\\))?,? pages .{0,60}?(\\d{4})', page)
    if (!match) return undefined
    return stamp('ACL', 'Proceedings of the Annual Meeting of the Association for Computational Linguistics', 'paper-conference', swiftInt(match[1]))
  },
  (page) => {
    const match = first('Published in Transactions on Machine Learning Research \\(\\d{1,2}/(\\d{4})\\)', page)
    if (!match) return undefined
    return stamp('TMLR', 'Transactions on Machine Learning Research', 'article-journal', swiftInt(match[1]))
  },
  (page) => {
    const match = first('Journal of Machine Learning Research (\\d+) \\((\\d{4})\\) \\d+-\\d+ Submitted .{0,40}?Published', page)
    if (!match) return undefined
    return stamp('JMLR', 'Journal of Machine Learning Research', 'article-journal', swiftInt(match[2]), undefined, match[1])
  },
]
