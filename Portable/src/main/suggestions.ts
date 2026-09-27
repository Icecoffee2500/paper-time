/**
 * Folders to offer on the first-run screen — the Mac's
 * `LibrarySetupView.findSuggestions`: the ones this machine already syncs, so
 * the common case is one press. Only folders that are there; nothing is
 * created, and nothing is opened until somebody presses one.
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { settings } from './settings.js'
import { providerOf } from '../shared/cloudProvider.js'
import { findPath } from '../shared/paths.js'

export function isFolder(target: string): boolean {
  try {
    return fs.statSync(target).isDirectory()
  } catch {
    return false
  }
}

function children(folder: string): string[] {
  try {
    return fs.readdirSync(folder, { withFileTypes: true }).filter((one) => one.isDirectory()).map((one) => path.join(folder, one.name))
  } catch {
    return []
  }
}

/** Every cloud folder this desktop keeps where its client puts it. */
export function suggestedFolders(home = os.homedir(), platform = process.platform): { path: string; provider: string }[] {
  const found: string[] = []
  if (platform === 'darwin') {
    found.push(path.join(home, 'Library/Mobile Documents/com~apple~CloudDocs'))
    found.push(...children(path.join(home, 'Library/CloudStorage')))
  } else {
    // In the home folder: OneDrive (and «OneDrive - Company»), Dropbox,
    // iCloudDrive, Google Drive's old folder, Box.
    for (const one of children(home)) {
      const name = path.basename(one).toLowerCase()
      if (/^onedrive( - .*)?$/.test(name) || ['dropbox', 'iclouddrive', 'google drive', 'googledrive', 'box'].includes(name)) found.push(one)
    }
    // Google Drive for desktop mounts a drive of its own on Windows, «My Drive» at its root.
    if (platform === 'win32') {
      for (const letter of 'DEFGHIJKLMNOPQRSTUVWXYZ') {
        const drive = `${letter}:\\My Drive`
        if (isFolder(drive)) found.push(drive)
      }
    }
  }
  const out: { path: string; provider: string }[] = []
  for (const one of found) {
    if (!isFolder(one)) continue
    const provider = providerOf(one)
    if (provider === 'local') continue
    if (!findPath(out.map((entry) => entry.path), one)) out.push({ path: one, provider })
  }
  return out
}

/** The libraries opened before, that are still there and not open now. */
export function recentLibraries(open: string[]): string[] {
  return (settings().recentLibraries ?? []).filter((one) => !findPath(open, one) && isFolder(one)).slice(0, 5)
}
