/**
 * Builds a Windows .ico from the PNGs beside it.
 *
 * Every size is stored as a PNG inside the icon, which Windows has accepted
 * since Vista and which keeps the file a tenth the size of the old bitmap
 * form. Written here rather than pulled from a package: it is forty lines,
 * and an icon is not worth a dependency.
 */
import fs from 'node:fs'
import path from 'node:path'

const dir = path.join(import.meta.dirname, '..', 'assets', 'icons')
const sizes = [16, 24, 32, 48, 64, 128, 256]
const images = sizes.map((size) => ({ size, data: fs.readFileSync(path.join(dir, `icon-${size}.png`)) }))

const header = Buffer.alloc(6)
header.writeUInt16LE(0, 0)               // reserved
header.writeUInt16LE(1, 2)               // 1 = icon
header.writeUInt16LE(images.length, 4)

const directory = Buffer.alloc(16 * images.length)
let offset = header.length + directory.length
images.forEach((image, index) => {
  const at = index * 16
  // 256 is written as 0: the field is one byte.
  directory.writeUInt8(image.size >= 256 ? 0 : image.size, at)
  directory.writeUInt8(image.size >= 256 ? 0 : image.size, at + 1)
  directory.writeUInt8(0, at + 2)        // palette
  directory.writeUInt8(0, at + 3)        // reserved
  directory.writeUInt16LE(1, at + 4)     // colour planes
  directory.writeUInt16LE(32, at + 6)    // bits per pixel
  directory.writeUInt32LE(image.data.length, at + 8)
  directory.writeUInt32LE(offset, at + 12)
  offset += image.data.length
})

fs.writeFileSync(
  path.join(dir, 'icon.ico'),
  Buffer.concat([header, directory, ...images.map((image) => image.data)]),
)
console.log(`icon.ico: ${images.length} sizes, ${offset} bytes`)
