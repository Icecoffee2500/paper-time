/** The slip-box's projects (`main/projects.ts`). */
import type { ProjectFiles } from '../projects.js'
import type { Context, Handlers } from './context.js'

export function projectHandlers(ctx: Context, projects: ProjectFiles): Partial<Handlers> {
  const { windows } = ctx

  return {
    'projects:load': () => projects.load(),

    'projects:create': async ({ name }, sender) => {
      if (typeof name !== 'string' || !name.trim()) return { error: 'A project needs a name.' }
      const made = await projects.create(name)
      if (!('error' in made)) windows.sendExcept(sender, 'projects:changed')
      return made
    },

    'projects:edit': async ({ id, edit }, sender) => {
      if (typeof id !== 'string') return { error: 'No such project.' }
      const done = await projects.edit(id, edit)
      if (!('error' in done)) windows.sendExcept(sender, 'projects:changed')
      return done
    },

    'projects:delete': async ({ id }, sender) => {
      if (typeof id !== 'string') return false
      const gone = await projects.remove(id)
      if (gone) windows.sendExcept(sender, 'projects:changed')
      return gone
    },
  }
}
