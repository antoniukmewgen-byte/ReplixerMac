import Foundation

/// Minimal ASN.1 DER TLV (tag-length-value) reader — just enough to unwrap
/// a PKCS#8 `PrivateKeyInfo` down to the PKCS#1 `RSAPrivateKey` DER bytes
/// nested inside its `privateKey OCTET STRING` field. Not a general-purpose
/// ASN.1 parser (no indefinite-length encoding, no tags beyond the ones
/// PKCS#8/PKCS#1 actually use here) — scoped tightly to this one job rather
/// than pulling in a third-party ASN.1 library for a single extraction.
enum DERReader {
    /// Given the DER bytes of a PKCS#8 `PrivateKeyInfo` SEQUENCE (the
    /// `-----BEGIN PRIVATE KEY-----` PEM body Google's service-account JSON
    /// ships), returns the inner PKCS#1 `RSAPrivateKey` DER bytes — the
    /// contents of the structure's third element, the
    /// `privateKey OCTET STRING`, which is itself already a complete
    /// PKCS#1-encoded RSA private key. Returns nil if the input doesn't
    /// look like the expected PKCS#8-wrapped-RSA structure.
    static func pkcs1RSAKey(fromPKCS8 der: Data) -> Data? {
        var outerReader = Cursor(data: der)
        guard let outer = outerReader.readTLV(), outer.tag == 0x30 else { return nil } // SEQUENCE

        var inner = Cursor(data: outer.value)
        guard let version = inner.readTLV(), version.tag == 0x02 else { return nil } // INTEGER
        guard let algorithm = inner.readTLV(), algorithm.tag == 0x30 else { return nil } // SEQUENCE
        _ = algorithm
        guard let privateKey = inner.readTLV(), privateKey.tag == 0x04 else { return nil } // OCTET STRING

        return privateKey.value
    }

    private struct TLV {
        let tag: UInt8
        let value: Data
    }

    /// Walks a DER buffer one TLV at a time. Always operates on freshly
    /// `subdata`-sliced `Data` (guaranteed zero-based indices), so plain
    /// `Int` offsets are safe here.
    private struct Cursor {
        let data: Data
        var offset: Int = 0

        init(data: Data) {
            self.data = data
        }

        mutating func readTLV() -> TLV? {
            guard offset < data.count else { return nil }
            let tag = data[offset]
            offset += 1
            guard let length = readLength() else { return nil }
            guard offset + length <= data.count else { return nil }
            let value = data.subdata(in: offset..<(offset + length))
            offset += length
            return TLV(tag: tag, value: value)
        }

        private mutating func readLength() -> Int? {
            guard offset < data.count else { return nil }
            let first = data[offset]
            offset += 1
            if first & 0x80 == 0 {
                // Short form: length is the low 7 bits directly.
                return Int(first)
            }
            // Long form: low 7 bits give the number of subsequent
            // length-bytes, interpreted big-endian.
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, offset + byteCount <= data.count else { return nil }
            var length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(data[offset])
                offset += 1
            }
            return length
        }
    }
}
