/**
 * Which service a library folder is synced by, guessed from where it is.
 *
 * Paper Time speaks to no provider's SDK — the library is a plain folder and
 * whichever service already syncs it does the work. This exists so a row can
 * say where a folder lives: a cloud folder that is slow to answer is waiting,
 * and a folder on this machine that is slow to answer is broken, and the icon
 * is the difference between those two.
 *
 * The Mac's copy is `CloudProvider.swift`. Every desktop puts these folders
 * somewhere else; the answers are the same.
 */
export type CloudProvider =
  | 'iCloudDrive'
  | 'googleDrive'
  | 'dropbox'
  | 'oneDrive'
  | 'box'
  | 'local'

export function providerOf(root: string): CloudProvider {
  // One shape for three desktops: forward slashes, lower case, so a rule is
  // written once instead of three times.
  const path = root.replace(/\\/g, '/').toLowerCase()
  if (path.includes('/mobile documents/com~apple~clouddocs')
    || /(^|\/)iclouddrive(\/|$)/.test(path)) {
    return 'iCloudDrive'
  }
  // Three shapes for one service: the Mac's File Provider folder, the old
  // "Google Drive" folder both desktops used, and the drive Windows mounts —
  // which has no "Google" anywhere in it, only "My Drive" at its root.
  if (path.includes('/cloudstorage/googledrive-')
    || /(^|\/)google[ -]?drive(\/|$)/.test(path)
    || /^[a-z]:\/(my drive|shared drives)(\/|$)/.test(path)) {
    return 'googleDrive'
  }
  if (/(^|\/)dropbox(\/|$)/.test(path)) return 'dropbox'
  // "OneDrive - Acme" is what a work account is called.
  if (/(^|\/)onedrive( -[^/]*)?(\/|$)/.test(path)) return 'oneDrive'
  if (/(^|\/)box(\/|$)/.test(path)) return 'box'
  return 'local'
}

/** The icon a folder's row wears: this machine, or a cloud. */
export function providerIcon(provider: CloudProvider): string {
  if (provider === 'iCloudDrive') return 'icloud'
  if (provider === 'local') return 'internaldrive'
  return 'cloud'
}

export function providerName(provider: CloudProvider): string {
  switch (provider) {
    case 'iCloudDrive': return 'iCloud Drive'
    case 'googleDrive': return 'Google Drive'
    case 'dropbox': return 'Dropbox'
    case 'oneDrive': return 'OneDrive'
    case 'box': return 'Box'
    case 'local': return 'This Device'
  }
}
