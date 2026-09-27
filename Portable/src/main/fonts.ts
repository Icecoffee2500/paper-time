/**
 * The font families this machine has, as the desktop lists them — the Mac's
 * `NSFontManager.availableFontFamilies`, for the Tools tab's font menu.
 *
 * The window cannot ask: `queryLocalFonts` needs a permission Electron does
 * not grant, and measuring text against a fallback only finds the families
 * somebody thought to try. So the main process asks the desktop, once:
 * fontconfig on Linux, the .NET font collection on Windows (the registry's
 * list when PowerShell is not allowed). Nothing on a Mac, where this build
 * is not the one people use — the window's own list stands there.
 */
import { execFile } from 'node:child_process'

let answer: Promise<string[]> | null = null

function run(command: string, args: string[]): Promise<string> {
  return new Promise((resolve) => {
    execFile(command, args, { timeout: 8000, maxBuffer: 8 * 1024 * 1024, windowsHide: true }, (error, stdout) => {
      resolve(error ? '' : String(stdout))
    })
  })
}

/** «Arial Bold (TrueType)» → «Arial»: the registry names a face, not a family. */
export function familyFromRegistryName(name: string): string {
  return name
    .replace(/\s*\((TrueType|OpenType|All res|VGA res|[^)]*)\)\s*$/i, '')
    .split(' & ')[0]
    .replace(/\s+(Bold|Italic|Light|Semibold|SemiBold|Semilight|SemiLight|Black|Medium|Thin|ExtraLight|ExtraBold|Regular|Oblique|Condensed|Heavy)\b.*$/i, '')
    .trim()
}

/** fontconfig's `family` field: the names of one font, comma separated, the first its own. */
export function familiesFromFontconfig(output: string): string[] {
  return output.split('\n').map((line) => line.split(',')[0].replace(/\\-/g, '-').trim()).filter(Boolean)
}

async function ask(platform: NodeJS.Platform): Promise<string[]> {
  if (platform === 'linux') return familiesFromFontconfig(await run('fc-list', [':', 'family']))
  if (platform === 'win32') {
    const listed = await run('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      '[Console]::OutputEncoding=[Text.Encoding]::UTF8; Add-Type -AssemblyName System.Drawing; (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }',
    ])
    if (listed.trim()) return listed.split(/\r?\n/).map((one) => one.trim()).filter(Boolean)
    const names: string[] = []
    for (const hive of ['HKLM', 'HKCU']) {
      const out = await run('reg', ['query', `${hive}\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts`])
      for (const line of out.split(/\r?\n/)) {
        const match = /^\s{4}(.+?)\s{4}REG_SZ\s{4}/.exec(line)
        if (match) names.push(familyFromRegistryName(match[1]))
      }
    }
    return names
  }
  return []
}

export function fontFamilies(platform: NodeJS.Platform = process.platform): Promise<string[]> {
  answer ??= ask(platform).then((names) =>
    [...new Set(names.filter((name) => name && !name.startsWith('.') && !name.startsWith('@')))].sort((a, b) => a.localeCompare(b)))
  return answer
}
