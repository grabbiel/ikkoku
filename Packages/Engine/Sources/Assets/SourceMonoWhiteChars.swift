/// `String.WhiteChars` in the game's Mono corlib: the separators that
/// `string.Split()` with no arguments uses. In the same source, `string.Trim()`
/// (`FindNotWhiteSpace`) tests the same set. It is not `char.IsWhiteSpace`.
///
/// Source: Unity-Technologies/mono, branch unity-5.6,
/// `mcs/class/corlib/System/String.cs`, built with its NET_2_0 and NET_2_1
/// blocks. The game's mscorlib.dll holds this 27-entry table in source order:
/// U+0009–U+000D, U+0085, U+1680, U+2028, U+2029, U+0020, U+00A0,
/// U+2000–U+200B, U+3000, U+FEFF, U+202F and U+205F. U+180E and U+001C–U+001F
/// are not in it.
public enum SourceMonoWhiteChars {
    public static let scalars: Set<UInt32> = Set([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x1680, 0x2028, 0x2029, 0x20, 0xA0,
                                                  0x3000, 0xFEFF, 0x202F, 0x205F] + Array(0x2000...0x200B))
}
