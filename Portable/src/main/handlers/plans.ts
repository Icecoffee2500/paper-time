/** The reading plans: the plans, the days, and what is kept beside a paper (`main/plans.ts`). */
import { addLinks, editLink, openLink, setDays, type PlanFiles } from '../plans.js'
import type { Context, Handlers } from './context.js'

export function planHandlers(ctx: Context, plans: PlanFiles): Partial<Handlers> {
  const { libraries, windows } = ctx
  const owner = (id: string) => libraries.ownerOf(id)

  return {
    'plans:load': () => plans.load(),

    'plans:create': async ({ name, root, papers }, sender) => {
      if (typeof name !== 'string' || !name.trim()) return { error: 'A plan needs a name.' }
      const ids = Array.isArray(papers) ? papers.filter((one): one is string => typeof one === 'string') : []
      const made = await plans.create(name, typeof root === 'string' ? root : undefined, ids)
      windows.sendExcept(sender, 'plans:changed')
      return made
    },

    'plans:edit': async ({ id, edit }, sender) => {
      if (typeof id !== 'string') return { error: 'No such plan.' }
      const done = await plans.edit(id, edit)
      if (!('error' in done)) windows.sendExcept(sender, 'plans:changed')
      return done
    },

    'plans:delete': async ({ id }, sender) => {
      if (typeof id !== 'string') return false
      const gone = await plans.remove(id)
      if (gone) windows.sendExcept(sender, 'plans:changed')
      return gone
    },

    'schedule:set': async ({ changes }, sender) => {
      const written = await setDays(owner, Array.isArray(changes) ? changes : [])
      for (const { id } of written) windows.sendExcept(sender, 'paper:changed', { id, layers: ['plan'] })
      return written
    },

    'links:add': async ({ id, url, files }, sender) => {
      const library = typeof id === 'string' ? await owner(id) : null
      if (!library) return { error: 'missing' }
      const result = await addLinks(library, id, {
        url: typeof url === 'string' ? url : undefined,
        files: Array.isArray(files) ? files : undefined,
      })
      if (!('error' in result)) windows.sendExcept(sender, 'paper:changed', { id, layers: ['links'] })
      return result
    },

    'links:edit': async ({ id, linkID, title, remove }, sender) => {
      const library = typeof id === 'string' ? await owner(id) : null
      if (!library || typeof linkID !== 'string') return []
      const links = await editLink(library, id, linkID, { title: typeof title === 'string' ? title : null, remove: remove === true })
      windows.sendExcept(sender, 'paper:changed', { id, layers: ['links'] })
      return links
    },

    'links:open': async ({ id, linkID }) => {
      const library = typeof id === 'string' ? await owner(id) : null
      if (!library || typeof linkID !== 'string') return false
      return openLink(library, id, linkID)
    },
  }
}
