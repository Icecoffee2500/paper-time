// The Mac's update signature, without Sparkle's own tools.
//
// Sparkle checks every update against an Ed25519 key whose public half is in
// the app (SUPublicEDKey) and whose private half signs the disk image at
// release time. CryptoKit's Curve25519.Signing is Ed25519, so the two halves
// can be made and used here, and the key never has to pass through a binary
// downloaded from somewhere else.
//
//   swift Scripts/sparkle-sign.swift make            < nothing >   → seed, then public key
//   swift Scripts/sparkle-sign.swift public          < seed        → public key
//   swift Scripts/sparkle-sign.swift sign <file>     < seed        → signature
//
// The seed is the private key's 32 bytes in base64, read from standard input
// so it never sits in an argument list. Scripts/sparkle-key.sh keeps it in
// the login keychain and is what calls this.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func seed() -> Curve25519.Signing.PrivateKey {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), raw.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("no key on standard input") }
    return key
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "make":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(seed().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = arguments.dropFirst().first else { fail("sign <file>") }
    let key = seed()
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let signature = try key.signature(for: data)
    // Checked here, so a signature that would not verify never leaves.
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("the signature does not verify") }
    print(signature.base64EncodedString())
default:
    fail("usage: sparkle-sign.swift make | public | sign <file>")
}
