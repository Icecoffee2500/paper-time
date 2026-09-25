import CommonCrypto
import CryptoKit
import Foundation

/// The standard security handler (ISO 32000-1 §7.6.3, ISO 32000-2 §7.6.4),
/// enough to write an incremental update into an encrypted file: derive the
/// file key from a user password (usually the empty one — a paper that opens
/// without asking but carries permissions), and encrypt the strings and
/// streams of new objects with it. Also decrypts, so the reader can look into
/// object streams and compare strings.
///
/// Anything else — another handler (certificate, rights management), crypt
/// filters other than V2/AESV2/AESV3, a password nobody gave us — is not
/// handled and the writer refuses.
public struct StandardSecurity: Sendable {
    public enum Method: String, Sendable { case identity, rc4, aesv2, aesv3 }

    public let revision: Int
    public let fileKey: [UInt8]
    public let streamMethod: Method
    public let stringMethod: Method
    public let encryptMetadata: Bool
    /// The /P permission bits, as the file states them.
    public let permissions: Int32

    /// Bit 6 of /P (ISO 32000-1, Table 22): "add or modify text annotations".
    public var allowsAnnotations: Bool { permissions & (1 << 5) != 0 }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case handler(String)
        case unsupported(String)
        case wrongPassword

        public var description: String {
            switch self {
            case let .handler(h): "security handler \(h)"
            case let .unsupported(s): "unsupported encryption: \(s)"
            case .wrongPassword: "the user password is not empty (or not the one given)"
            }
        }
    }

    static let padding: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ]

    public init(encrypt d: PDFDict, id0: [UInt8], password: [UInt8] = []) throws {
        guard d["Filter"]?.name == "Standard" else { throw Failure.handler(d["Filter"]?.name ?? "none") }
        let v = d["V"]?.int ?? 0
        let r = d["R"]?.int ?? 0
        revision = r
        encryptMetadata = { if case let .bool(b)? = d["EncryptMetadata"] { return b }; return true }()
        let o = d["O"]?.stringBytes ?? []
        let u = d["U"]?.stringBytes ?? []
        let p = Int32(truncatingIfNeeded: d["P"]?.int ?? 0)
        permissions = p

        // Which cipher: V 1–2 are RC4 throughout; V 4–5 name crypt filters.
        func method(_ filterName: String?) throws -> Method {
            guard v >= 4 else { return .rc4 }
            guard let filterName, filterName != "Identity" else { return .identity }
            guard let cf = d["CF"]?.dict?[filterName]?.dict else { throw Failure.unsupported("crypt filter \(filterName)") }
            switch cf["CFM"]?.name {
            case "V2"?: return .rc4
            case "AESV2"?: return .aesv2
            case "AESV3"?: return .aesv3
            case "None"?, nil: return .identity
            case let other?: throw Failure.unsupported("CFM \(other)")
            }
        }
        guard [1, 2, 4, 5].contains(v) else { throw Failure.unsupported("V \(v)") }
        streamMethod = try method(d["StmF"]?.name)
        stringMethod = try method(d["StrF"]?.name)

        if r <= 4 {
            // Algorithm 2: the key from the padded password, O, P, the first
            // ID and (R4, metadata left clear) four 0xFF.
            let n = r == 2 ? 5 : max(5, min(16, (d["Length"]?.int ?? 40) / 8))
            var input = Array((password + StandardSecurity.padding).prefix(32))
            input += o.prefix(32)
            input += withUnsafeBytes(of: p.littleEndian, Array.init)
            input += id0
            if r >= 4, !encryptMetadata { input += [0xFF, 0xFF, 0xFF, 0xFF] }
            var key = Array(Insecure.MD5.hash(data: input))
            if r >= 3 {
                for _ in 0..<50 { key = Array(Insecure.MD5.hash(data: key.prefix(n))) }
            }
            key = Array(key.prefix(n))
            // Algorithms 4 and 5: the key is right if it reproduces U.
            let check: [UInt8]
            if r == 2 {
                check = StandardSecurity.rc4(key, StandardSecurity.padding)
                guard check == Array(u.prefix(32)) else { throw Failure.wrongPassword }
            } else {
                var x = StandardSecurity.rc4(key, Array(Insecure.MD5.hash(data: StandardSecurity.padding + id0)))
                for i in 1...19 { x = StandardSecurity.rc4(key.map { $0 ^ UInt8(i) }, x) }
                guard x.prefix(16) == u.prefix(16) else { throw Failure.wrongPassword }
            }
            fileKey = key
        } else if r == 6 || r == 5 {
            // Algorithm 2.A: validate against U's validation salt, then unwrap
            // UE with a key made from its key salt.
            guard u.count >= 48, let ue = d["UE"]?.stringBytes, ue.count >= 32 else { throw Failure.unsupported("R\(r) without U/UE") }
            let pw = Array(password.prefix(127))
            let hash: ([UInt8], [UInt8]) -> [UInt8] = { salt, extra in
                r == 5 ? Array(SHA256.hash(data: pw + salt + extra)) : StandardSecurity.hash2B(pw, salt: salt, extra: extra)
            }
            guard hash(Array(u[32..<40]), []) == Array(u[0..<32]) else { throw Failure.wrongPassword }
            let intermediate = hash(Array(u[40..<48]), [])
            guard let key = StandardSecurity.aes(decrypt: true, key: intermediate, iv: [UInt8](repeating: 0, count: 16), Array(ue.prefix(32)), padding: false) else {
                throw Failure.unsupported("UE")
            }
            fileKey = key
        } else {
            throw Failure.unsupported("R \(r)")
        }
    }

    /// Algorithm 2.B (ISO 32000-2): SHA-256, then rounds of AES-128-CBC and
    /// SHA-256/384/512 until the last byte says stop.
    static func hash2B(_ password: [UInt8], salt: [UInt8], extra: [UInt8]) -> [UInt8] {
        var k = Array(SHA256.hash(data: password + salt + extra))
        var round = 0
        while true {
            let k1base = password + k + extra
            var k1: [UInt8] = []
            k1.reserveCapacity(k1base.count * 64)
            for _ in 0..<64 { k1 += k1base }
            guard let e = aes(decrypt: false, key: Array(k[0..<16]), iv: Array(k[16..<32]), k1, padding: false) else { return k }
            let mod = e.prefix(16).reduce(0) { ($0 + Int($1)) } % 3
            switch mod {
            case 0: k = Array(SHA256.hash(data: e))
            case 1: k = Array(SHA384.hash(data: e))
            default: k = Array(SHA512.hash(data: e))
            }
            round += 1
            if round >= 64, let last = e.last, Int(last) <= round - 32 { break }
        }
        return Array(k.prefix(32))
    }

    // MARK: Ciphers

    static func rc4(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var s = [UInt8](0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }
        var out = [UInt8](repeating: 0, count: data.count)
        var i = 0
        j = 0
        for n in 0..<data.count {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            out[n] = data[n] ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }
        return out
    }

    static func aes(decrypt: Bool, key: [UInt8], iv: [UInt8], _ data: [UInt8], padding: Bool) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + 32)
        var moved = 0
        let status = CCCrypt(
            CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(padding ? kCCOptionPKCS7Padding : 0),
            key, key.count, iv, data, data.count, &out, out.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(moved))
    }

    // MARK: Objects

    func objectKey(_ ref: PDFRef, aes: Bool) -> [UInt8] {
        var input = fileKey
        input += [UInt8(ref.num & 0xFF), UInt8((ref.num >> 8) & 0xFF), UInt8((ref.num >> 16) & 0xFF)]
        input += [UInt8(ref.gen & 0xFF), UInt8((ref.gen >> 8) & 0xFF)]
        if aes { input += Array("sAlT".utf8) }
        return Array(Insecure.MD5.hash(data: input).prefix(min(fileKey.count + 5, 16)))
    }

    func encrypt(_ data: [UInt8], _ ref: PDFRef, method: Method) -> [UInt8] {
        switch method {
        case .identity: return data
        case .rc4: return StandardSecurity.rc4(objectKey(ref, aes: false), data)
        case .aesv2, .aesv3:
            let key = method == .aesv3 ? fileKey : objectKey(ref, aes: true)
            var iv = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, &iv)
            return iv + (StandardSecurity.aes(decrypt: false, key: key, iv: iv, data, padding: true) ?? [])
        }
    }

    func decrypt(_ data: [UInt8], _ ref: PDFRef, method: Method) -> [UInt8] {
        switch method {
        case .identity: return data
        case .rc4: return StandardSecurity.rc4(objectKey(ref, aes: false), data)
        case .aesv2, .aesv3:
            guard data.count >= 32 else { return [] }
            let key = method == .aesv3 ? fileKey : objectKey(ref, aes: true)
            return StandardSecurity.aes(decrypt: true, key: key, iv: Array(data[0..<16]), Array(data[16...]), padding: true) ?? []
        }
    }

    /// An object as it goes into the file under `ref`: every string and the
    /// stream's data encrypted. Streams whose data is already in the clear
    /// by rule — the cross-reference stream, metadata left clear — are not
    /// passed here.
    public func encrypting(_ o: PDFObj, as ref: PDFRef) -> PDFObj {
        switch o {
        case let .string(b, _): return .string(encrypt(b, ref, method: stringMethod), hex: true)
        case let .array(a): return .array(a.map { encrypting($0, as: ref) })
        case let .dict(d): return .dict(PDFDict(d.pairs.map { ($0.key, encrypting($0.value, as: ref)) }))
        case let .stream(d, data):
            let dict = PDFDict(d.pairs.map { ($0.key, encrypting($0.value, as: ref)) })
            if d["Type"]?.name == "Metadata", !encryptMetadata { return .stream(dict, data) }
            return .stream(dict, encrypt(data, ref, method: streamMethod))
        default: return o
        }
    }

    public func decrypting(_ o: PDFObj, as ref: PDFRef) -> PDFObj {
        switch o {
        case let .string(b, hex): return .string(decrypt(b, ref, method: stringMethod), hex: hex)
        case let .array(a): return .array(a.map { decrypting($0, as: ref) })
        case let .dict(d): return .dict(PDFDict(d.pairs.map { ($0.key, decrypting($0.value, as: ref)) }))
        case let .stream(d, data):
            let dict = PDFDict(d.pairs.map { ($0.key, decrypting($0.value, as: ref)) })
            if d["Type"]?.name == "XRef" { return .stream(dict, data) }
            if d["Type"]?.name == "Metadata", !encryptMetadata { return .stream(dict, data) }
            return .stream(dict, decrypt(data, ref, method: streamMethod))
        default: return o
        }
    }
}
