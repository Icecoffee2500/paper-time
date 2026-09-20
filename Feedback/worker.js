/**
 * The one server Paper Time has.
 *
 * The app never talks to it on its own — no telemetry, no check-in, no
 * "anonymous usage statistics". It talks only when somebody presses 보내기,
 * and it sends only what that person was shown before they pressed it.
 *
 * What it does: turns one report into one GitHub issue, so the roadmap on the
 * landing page can be read straight from the issues. A check mark there is not
 * something anybody remembers to tick — it is the issue being closed. The same
 * argument the app makes about marks living in the PDF: keep the state in the
 * one place that cannot drift, and read it.
 *
 * Secrets (wrangler secret put …):
 *   GITHUB_TOKEN   a fine-grained PAT on this repo alone, with
 *                  Issues: read+write and Contents: read+write
 *   READ_TOKEN     a long random string; whoever holds it can read the
 *                  reply-to addresses back out
 * Bindings:
 *   REPLIES        a KV namespace
 *
 * Reply addresses never enter the issue. A public issue is public, and
 * somebody who typed their address to hear back did not agree to publish it.
 * It goes in KV under the issue number and comes back out through an
 * authenticated route that only the maintainer can call.
 */

const REPO = 'Icecoffee2500/paper-time'
const ASSET_BRANCH = 'feedback-assets'
/** Reports per address per hour. High enough never to meet an honest reader. */
const LIMIT = 6
const MAX_BODY = 8000
const MAX_SHOT = 4 * 1024 * 1024

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
}

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  })

function api(env, path, init = {}) {
  return fetch(`https://api.github.com/repos/${REPO}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'paper-time-feedback',
      'Content-Type': 'application/json',
      ...init.headers,
    },
  })
}

/** One line, short enough to read in a list. */
function titleOf(body) {
  const first = body.trim().split(/\r?\n/).find((line) => line.trim()) || 'Feedback'
  const clean = first.trim().replace(/\s+/g, ' ')
  return clean.length > 80 ? `${clean.slice(0, 79)}…` : clean
}

/**
 * The screenshot goes on a branch of its own rather than into the issue: the
 * issues API has no attachment endpoint, and a file in the repository is a URL
 * that keeps working without anybody's session.
 */
async function uploadShot(env, dataURL) {
  const match = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(dataURL || '')
  if (!match) return null
  if (match[1].length > MAX_SHOT) return null
  const path = `shots/${crypto.randomUUID()}.png`
  const response = await api(env, `/contents/${path}`, {
    method: 'PUT',
    body: JSON.stringify({
      message: `feedback screenshot ${path}`,
      content: match[1],
      branch: ASSET_BRANCH,
    }),
  })
  if (!response.ok) return null
  const created = await response.json()
  return created.content?.download_url ?? null
}

function diagnosticsBlock(payload) {
  const app = payload.app || {}
  const context = payload.context || {}
  const rows = [
    ['version', app.version],
    ['build', app.build],
    ['platform', app.platform],
    ['architecture', app.arch],
    ['interface language', app.lang],
    ['window', context.window],
    ['page layout', context.layout],
    ['panes', context.panes],
    ['library in a cloud folder', context.libraryCloud === undefined ? undefined : String(context.libraryCloud)],
    ['papers in the library', context.paperCount === undefined ? undefined : String(context.paperCount)],
  ].filter(([, value]) => value !== undefined && value !== null && value !== '')

  const recent = Array.isArray(context.recent) ? context.recent.filter(Boolean) : []
  const lines = rows.map(([key, value]) => `| ${key} | ${value} |`).join('\n')
  const table = rows.length ? `| | |\n|---|---|\n${lines}\n` : ''
  const trail = recent.length ? `\nLast few actions:\n${recent.map((r) => `- ${r}`).join('\n')}\n` : ''
  return `\n<details><summary>What the app sent with this</summary>\n\n${table}${trail}\n</details>\n`
}

async function report(request, env) {
  let payload
  try {
    payload = await request.json()
  } catch {
    return json({ error: 'not json' }, 400)
  }

  const body = String(payload.body || '').slice(0, MAX_BODY).trim()
  if (body.length < 3) return json({ error: 'empty' }, 400)

  // Rate limit before anything is written anywhere.
  const who = request.headers.get('CF-Connecting-IP') || 'unknown'
  const key = `rate:${who}`
  const seen = Number((await env.REPLIES.get(key)) || 0)
  if (seen >= LIMIT) return json({ error: 'too many' }, 429)
  await env.REPLIES.put(key, String(seen + 1), { expirationTtl: 3600 })

  const kind = payload.kind === 'wish' ? 'wish' : 'bug'
  const name = String(payload.name || '').trim().slice(0, 60)
  const shot = await uploadShot(env, payload.shot)

  const parts = [body, '']
  if (shot) parts.push(`![screenshot](${shot})`, '')
  if (payload.crash) {
    parts.push('<details><summary>Crash report</summary>\n', '```',
      String(payload.crash).slice(0, 6000), '```', '\n</details>', '')
  }
  parts.push(diagnosticsBlock(payload))
  // Read by the landing page to credit the reporter. A comment so it shows in
  // the source but not in the rendered issue.
  parts.push(`\n<!-- credit: ${name || 'anonymous'} -->`)
  parts.push(`<!-- sent from the app -->`)

  const created = await api(env, '/issues', {
    method: 'POST',
    body: JSON.stringify({
      title: titleOf(body),
      body: parts.join('\n'),
      labels: ['feedback', kind === 'bug' ? 'bug' : 'wish'],
    }),
  })
  if (!created.ok) return json({ error: 'github', status: created.status }, 502)
  const issue = await created.json()

  const reply = String(payload.reply || '').trim().slice(0, 200)
  if (reply) {
    // Never in the issue. Ninety days is long enough to answer somebody and
    // short enough not to be a database of addresses.
    await env.REPLIES.put(`reply:${issue.number}`, JSON.stringify({ reply, name }), {
      expirationTtl: 60 * 60 * 24 * 90,
    })
  }

  return json({ ok: true, number: issue.number, url: issue.html_url })
}

/** For the maintainer, to answer somebody. Not for anyone else. */
async function replyFor(request, env, number) {
  if (request.headers.get('X-Read-Token') !== env.READ_TOKEN) {
    return json({ error: 'no' }, 403)
  }
  const stored = await env.REPLIES.get(`reply:${number}`)
  return json(stored ? JSON.parse(stored) : { reply: null })
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS })
    if (url.pathname === '/report' && request.method === 'POST') return report(request, env)
    const found = /^\/reply\/(\d+)$/.exec(url.pathname)
    if (found && request.method === 'GET') return replyFor(request, env, found[1])
    return json({ error: 'not found' }, 404)
  },
}
