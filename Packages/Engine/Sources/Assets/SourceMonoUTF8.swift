import Foundation

/// The game's UTF-8 string decode, for the native readers of its strings.
/// The game keeps a leading EF BB BF as the character U+FEFF. Foundation's
/// `String(data:encoding: .utf8)` and `String(bytes:encoding: .utf8)` drop
/// it as a byte-order mark, so a native read of such a string had one
/// character less than the game's, and a rewrite lost three bytes (#418).
///
/// Sources:
/// - Unity-Technologies/mono, branch unity-5.6:
///   - `mcs/class/corlib/System.Text/UTF8Encoding.cs`: `GetString`,
///     `GetChars` and `InternalGetChars` decode EF BB BF like any
///     three-byte sequence. The preamble is used only by `GetPreamble`, on
///     the encode side.
///   - `mcs/class/corlib/System.IO/BinaryReader.cs`: `ReadString` reads the
///     seven-bit length, then `decoder.GetChars` with no BOM skip.
/// - The game's Assembly-CSharp-firstpass, by type: MessagePack's
///   `FixString`, `Str8String`, `Str16String` and `Str32String` decoders
///   call `StringEncoding.UTF8.GetString`, which is
///   `new UTF8Encoding(false)`.
///
/// Bytes that are not valid UTF-8 still return nil; the callers refuse
/// them. (The game repairs them instead: #423.)
public enum SourceMonoUTF8 {
    public static func string<Bytes: Collection>(_ bytes: Bytes) -> String? where Bytes.Element == UInt8 {
        if let result = bytes.withContiguousStorageIfAvailable(decode) { return result }
        return Array(bytes).withUnsafeBufferPointer(decode)
    }

    /// The .NET string readers' `Data`, read through its buffer.
    public static func string(_ data: Data) -> String? {
        data.withUnsafeBytes { decode($0.bindMemory(to: UInt8.self)) }
    }

    private static func decode(_ bytes: UnsafeBufferPointer<UInt8>) -> String? {
        // String(decoding:as:) keeps a leading U+FEFF and repairs invalid input
        // with U+FFFD. A repair changes the byte count, or (for example, when a
        // truncated four-byte sequence becomes one U+FFFD) the bytes.
        var result = String(decoding: bytes, as: UTF8.self)
        guard result.utf8.count == bytes.count,
              result.withUTF8({ $0.isEmpty || memcmp($0.baseAddress!, bytes.baseAddress!, $0.count) == 0 }) else { return nil }
        return result
    }
}
