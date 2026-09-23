import Foundation

/// Minimal, dependency-free PNG encoder (RGBA8) with a real DEFLATE compressor (LZ77 with
/// hash chains + fixed Huffman codes). Foundation has no image codecs on Linux, and
/// render_view must produce PNGs headlessly.
public enum PNG {
    public static func encode(rgba: [UInt8], width: Int, height: Int) -> Data {
        precondition(rgba.count == width * height * 4)
        // Filter each scanline with "Up" (2) — rendered CAD images are dominated by flat
        // regions and vertical coherence, which then compress to long zero runs.
        var raw = [UInt8]()
        raw.reserveCapacity((width * 4 + 1) * height)
        let stride = width * 4
        for y in 0..<height {
            raw.append(y == 0 ? 0 : 2)
            let row = y * stride
            if y == 0 {
                raw.append(contentsOf: rgba[row..<(row + stride)])
            } else {
                for i in 0..<stride { raw.append(rgba[row + i] &- rgba[row - stride + i]) }
            }
        }
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBE(UInt32(width))
        ihdr.appendBE(UInt32(height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])  // 8-bit, RGBA, deflate, filter 0, no interlace
        chunk("IHDR", ihdr, into: &out)
        chunk("IDAT", Data(Zlib.compress(raw)), into: &out)
        chunk("IEND", Data(), into: &out)
        return out
    }

    static func chunk(_ type: String, _ body: Data, into out: inout Data) {
        out.appendBE(UInt32(body.count))
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(body)
        out.appendBE(CRC32.checksum(typeBytes + [UInt8](body)))
    }
}

extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

public enum Zlib {
    public static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let end = min(i + 5552, bytes.count)
            while i < end {
                a += UInt32(bytes[i])
                b += a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return (b << 16) | a
    }

    /// zlib stream (RFC 1950) wrapping a single fixed-Huffman DEFLATE block (RFC 1951).
    public static func compress(_ input: [UInt8]) -> [UInt8] {
        var w = BitWriter()
        w.bytes = [0x78, 0x01]  // CMF/FLG: deflate, 32K window, fastest; (0x7801 % 31 == 0)
        w.write(1, 1)  // BFINAL
        w.write(1, 2)  // BTYPE = 01 fixed Huffman
        let n = input.count
        let windowSize = 32768, maxChain = 48, minMatch = 3, maxMatch = 258
        var head = [Int](repeating: -1, count: 1 << 15)
        var prev = [Int](repeating: -1, count: windowSize)
        func hash(_ i: Int) -> Int {
            (Int(input[i]) << 10 ^ Int(input[i + 1]) << 5 ^ Int(input[i + 2])) & 0x7FFF
        }
        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prev[i & (windowSize - 1)] = head[h]
            head[h] = i
        }
        var i = 0
        while i < n {
            var bestLen = 0, bestDist = 0
            if i + minMatch <= n {
                var cand = head[hash(i)]
                var chain = 0
                let limit = min(maxMatch, n - i)
                while cand >= 0, i - cand <= windowSize, chain < maxChain {
                    if input[cand + bestLen] == input[i + bestLen] || bestLen == 0 {
                        var l = 0
                        while l < limit && input[cand + l] == input[i + l] { l += 1 }
                        if l > bestLen {
                            bestLen = l
                            bestDist = i - cand
                            if l == limit { break }
                        }
                    }
                    cand = prev[cand & (windowSize - 1)]
                    chain += 1
                }
            }
            if bestLen >= minMatch {
                w.writeLength(bestLen)
                w.writeDistance(bestDist)
                for k in 0..<bestLen { insert(i + k) }
                i += bestLen
            } else {
                w.writeLiteral(Int(input[i]))
                insert(i)
                i += 1
            }
        }
        w.writeLiteral(256)  // end of block
        w.flush()
        let a = adler32(input)
        w.bytes.append(contentsOf: [UInt8(a >> 24), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)])
        return w.bytes
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        var acc: UInt32 = 0
        var count: UInt32 = 0

        /// Write `n` bits of `value`, LSB first.
        mutating func write(_ value: Int, _ n: Int) {
            acc |= UInt32(value) << count
            count += UInt32(n)
            while count >= 8 {
                bytes.append(UInt8(acc & 0xFF))
                acc >>= 8
                count -= 8
            }
        }

        /// Huffman codes are written MSB first.
        mutating func writeCode(_ code: Int, _ n: Int) {
            var rev = 0
            for b in 0..<n where (code >> b) & 1 != 0 { rev |= 1 << (n - 1 - b) }
            write(rev, n)
        }

        mutating func writeLiteral(_ lit: Int) {
            switch lit {
            case 0...143: writeCode(0x30 + lit, 8)
            case 144...255: writeCode(0x190 + lit - 144, 9)
            case 256...279: writeCode(lit - 256, 7)
            default: writeCode(0xC0 + lit - 280, 8)
            }
        }

        static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

        mutating func writeLength(_ len: Int) {
            var idx = Self.lengthBase.count - 1
            while Self.lengthBase[idx] > len { idx -= 1 }
            // 258 has its own code (285) with no extra bits.
            if len == 258 { idx = 28 }
            writeLiteral(257 + idx)
            if Self.lengthExtra[idx] > 0 { write(len - Self.lengthBase[idx], Self.lengthExtra[idx]) }
        }

        mutating func writeDistance(_ dist: Int) {
            var idx = Self.distBase.count - 1
            while Self.distBase[idx] > dist { idx -= 1 }
            writeCode(idx, 5)
            if Self.distExtra[idx] > 0 { write(dist - Self.distBase[idx], Self.distExtra[idx]) }
        }

        mutating func flush() {
            if count > 0 {
                bytes.append(UInt8(acc & 0xFF))
                acc = 0
                count = 0
            }
        }
    }
}
