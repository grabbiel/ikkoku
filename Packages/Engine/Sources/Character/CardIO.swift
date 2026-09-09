import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// PNG cards: a thumbnail PNG with the JSON payload in an `iTXt` chunk, like Koikatsu's character/scene cards.
public enum CardIO {
    public static let cardKeyword = "ikkoku:card"
    public static let sceneKeyword = "ikkoku:scene"

    public enum CardError: Error { case notPNG, noPayload, encodeFailed }

    public static func encode<T: Encodable>(_ value: T, keyword: String, thumbnail: CGImage?) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = try enc.encode(value)
        let png = try thumbnailPNG(thumbnail)
        return try insertChunk(into: png, keyword: keyword, payload: json)
    }

    public static func decode<T: Decodable>(_ type: T.Type, keyword: String, from data: Data) throws -> T {
        guard let payload = extractChunk(from: data, keyword: keyword) else { throw CardError.noPayload }
        return try JSONDecoder().decode(type, from: payload)
    }

    public static func thumbnail(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: PNG plumbing

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func thumbnailPNG(_ image: CGImage?) throws -> Data {
        let img: CGImage
        if let image { img = image } else {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: 252, height: 352, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = { ctx.setFillColor(CGColor(red: 0.93, green: 0.90, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 252, height: 352)); return ctx.makeImage() }() else { throw CardError.encodeFailed }
            img = cg
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw CardError.encodeFailed }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw CardError.encodeFailed }
        return out as Data
    }

    static func insertChunk(into png: Data, keyword: String, payload: Data) throws -> Data {
        guard png.count > 8, Array(png.prefix(8)) == signature else { throw CardError.notPNG }
        // iTXt: keyword\0 compression flag(0) compression method(0) language tag\0 translated keyword\0 text
        var body = Data()
        body.append(contentsOf: Array(keyword.utf8)); body.append(0)
        body.append(0); body.append(0)
        body.append(0); body.append(0)
        body.append(payload)
        var out = Data()
        out.append(png.prefix(8))
        var offset = 8
        var inserted = false
        while offset + 8 <= png.count {
            let length = Int(png.readBE32(at: offset))
            let typeRange = (offset + 4)..<(offset + 8)
            let type = String(decoding: png[typeRange], as: UTF8.self)
            let chunkEnd = offset + 12 + length
            guard chunkEnd <= png.count else { throw CardError.notPNG }
            if type == "IEND" && !inserted {
                out.append(makeChunk(type: "iTXt", body: body))
                inserted = true
            }
            if type == "iTXt", extractKeyword(png[(offset + 8)..<(offset + 8 + length)]) == keyword { offset = chunkEnd; continue }
            out.append(png[offset..<chunkEnd])
            offset = chunkEnd
        }
        if !inserted { out.append(makeChunk(type: "iTXt", body: body)); out.append(makeChunk(type: "IEND", body: Data())) }
        return out
    }

    static func extractChunk(from png: Data, keyword: String) -> Data? {
        guard png.count > 8, Array(png.prefix(8)) == signature else { return nil }
        var offset = 8
        while offset + 8 <= png.count {
            let length = Int(png.readBE32(at: offset))
            let type = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let chunkEnd = offset + 12 + length
            guard chunkEnd <= png.count else { return nil }
            if type == "iTXt" || type == "tEXt" {
                let body = png[(offset + 8)..<(offset + 8 + length)]
                if extractKeyword(body) == keyword {
                    let bytes = Array(body)
                    guard let nul = bytes.firstIndex(of: 0) else { return nil }
                    if type == "tEXt" { return Data(bytes[(nul + 1)...]) }
                    // iTXt: skip flag, method, language\0, translated\0
                    var i = nul + 1 + 2
                    guard i < bytes.count, let l = bytes[i...].firstIndex(of: 0) else { return nil }
                    i = l + 1
                    guard i <= bytes.count, let t = bytes[i...].firstIndex(of: 0) else { return nil }
                    i = t + 1
                    return Data(bytes[i...])
                }
            }
            offset = chunkEnd
        }
        return nil
    }

    private static func extractKeyword(_ body: Data) -> String {
        let bytes = Array(body)
        guard let nul = bytes.firstIndex(of: 0) else { return "" }
        return String(decoding: bytes[..<nul], as: UTF8.self)
    }

    private static func makeChunk(type: String, body: Data) -> Data {
        var d = Data()
        d.appendBE32(UInt32(body.count))
        var crcData = Data(type.utf8)
        crcData.append(body)
        d.append(crcData)
        d.appendBE32(crc32(crcData))
        return d
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    func readBE32(at offset: Int) -> UInt32 {
        let b = self
        let i = b.startIndex + offset
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    mutating func appendBE32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
