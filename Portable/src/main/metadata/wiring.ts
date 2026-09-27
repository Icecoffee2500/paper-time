/**
 * Where the lookups go out, for this run.
 *
 * One `NetworkService` for the whole app — the registrars' pace is per
 * machine, not per paper — made again only when the contact address changes.
 * A probe never reaches the registrars unless it is told to:
 * `--papertime-lookup-replay=<responses.json[.gz]>` answers from recorded
 * responses (the Mac's, from `Scripts/metadata-fixtures.sh`) without waiting
 * out the pace, and `--papertime-lookup=1` asks the real ones. Without either,
 * a probe guesses at kinds and looks nothing up.
 */
import fs from 'node:fs'
import zlib from 'node:zlib'
import type { Network } from '../../shared/metadata/resolver.js'
import { NetworkFailure } from '../../shared/metadata/resolver.js'
import { NetworkService, fetchSend, realClock, type Reply } from './network.js'

let service: { email: string | undefined; network: NetworkService } | null = null

export function lookupNetwork(options: { isProbe: boolean; replay: string | null; allowed: boolean; email: string | undefined }): Network | null {
  if (options.isProbe && options.replay) {
    if (service?.email === `replay:${options.replay}`) return service.network
    const raw = fs.readFileSync(options.replay)
    const responses = JSON.parse((options.replay.endsWith('.gz') ? zlib.gunzipSync(raw) : raw).toString('utf8')) as Record<string, Reply>
    const network = new NetworkService(async (url) => {
      const reply = responses[url]
      if (!reply || reply.status === 0) throw new NetworkFailure('offline')
      return reply
    }, options.email, { now: () => 0, sleep: async () => {} })
    service = { email: `replay:${options.replay}`, network }
    return network
  }
  if (options.isProbe && !options.allowed) return null
  if (!service || service.email !== options.email) service = { email: options.email, network: new NetworkService(fetchSend, options.email, realClock) }
  return service.network
}
