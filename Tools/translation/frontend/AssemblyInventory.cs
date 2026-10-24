using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text;

// Reads ECMA-335 metadata from a bounded byte snapshot. Never loads an assembly,
// resolves a dependency on disk, invokes an attribute constructor, or interprets IL.
static class AssemblyInventory {
    const int FileLimit = 32 * 1024 * 1024;
    const int RowLimit = 100_000;
    const int ReferenceLimit = 20_000;
    const int AttributeBytes = 64 * 1024;
    static readonly UTF8Encoding StrictUTF8 = new(false, true);
    static int remainingText; // one snapshot per command; bounded cumulative decoded strings/blobs
    sealed record TypeIdentity(string Name, string? Assembly);
    sealed class Unsupported(string message) : Exception(message);
    sealed class BoundedOutput : MemoryStream {
        public override void Write(byte[] buffer, int offset, int count) { Check(count); base.Write(buffer, offset, count); }
        public override void Write(ReadOnlySpan<byte> buffer) { Check(buffer.Length); base.Write(buffer); }
        void Check(int count) { if (Length + count > 16 * 1024 * 1024) throw new Unsupported("Report exceeds 16 MiB"); }
    }
    static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    static readonly HashSet<string> Attributes = ["BepInEx.BepInPlugin", "BepInEx.BepInProcess", "BepInEx.BepInDependency", "BepInEx.BepInIncompatibility"];

    public static int Run(string[] args) {
        if (args.Length != 2 || !int.TryParse(args[1], out int limit) || limit < 1 || limit > FileLimit) {
            Console.Error.WriteLine("Usage: Translation --inventory-assembly path max-bytes (1..33554432)");
            return 2;
        }
        try {
            using var file = new FileStream(args[0], FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length > limit) throw new Unsupported("File exceeds byte limit");
            // Length is only an early check. The bounded read also handles growth.
            using var snapshot = new MemoryStream();
            byte[] buffer = new byte[64 * 1024];
            while (true) {
                int count = file.Read(buffer, 0, Math.Min(buffer.Length, limit + 1 - (int)snapshot.Length));
                if (count == 0) break;
                snapshot.Write(buffer, 0, count);
                if (snapshot.Length > limit) throw new Unsupported("File exceeds byte limit");
            }
            using var output = new BoundedOutput();
            JsonSerializer.Serialize(output, Read(snapshot.ToArray()), Json);
            Console.OpenStandardOutput().Write(output.GetBuffer(), 0, (int)output.Length);
            return 0;
        } catch (Exception e) when (e is IOException or UnauthorizedAccessException or Unsupported) {
            Console.WriteLine(JsonSerializer.Serialize(new { classification = "unreadable", entries = Array.Empty<object>(), diagnostics = new[] { e.Message } }, Json));
            return 0;
        }
    }

    static object Read(byte[] bytes) {
        remainingText = 4 * 1024 * 1024;
        string hash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        var diagnostics = new List<string>();
        var entries = new List<object>();
        var references = new List<object>();
        var typeReferences = new List<object>();
        var memberReferences = new List<object>();
        object? identity = null;
        string classification = "invalid-pe";
        try {
            using var stream = new MemoryStream(bytes, writable: false);
            using var pe = new PEReader(stream);
            if (!pe.HasMetadata) classification = "native-or-no-metadata";
            else {
                var reader = pe.GetMetadataReader(MetadataReaderOptions.Default, new MetadataStringDecoder(StrictUTF8));
                classification = reader.IsAssembly ? "managed-library" : "managed-netmodule";
                foreach (var table in new[] { TableIndex.TypeDef, TableIndex.CustomAttribute })
                    if (reader.GetTableRowCount(table) > RowLimit) throw new Unsupported($"{table} exceeds {RowLimit} rows");
                foreach (var table in new[] { TableIndex.AssemblyRef, TableIndex.TypeRef, TableIndex.MemberRef })
                    if (reader.GetTableRowCount(table) > ReferenceLimit) throw new Unsupported($"{table} exceeds {ReferenceLimit} rows");
                if (reader.IsAssembly) {
                    var definition = reader.GetAssemblyDefinition();
                    identity = new { name = Text(reader, definition.Name), version = definition.Version.ToString(), culture = Text(reader, definition.Culture), publicKey = Hex(reader, definition.PublicKey), flags = (int)definition.Flags };
                }
                foreach (var handle in reader.AssemblyReferences) {
                    var reference = reader.GetAssemblyReference(handle);
                    references.Add(new { token = Token(handle), name = Text(reader, reference.Name), version = reference.Version.ToString(), culture = Text(reader, reference.Culture), publicKeyOrToken = Hex(reader, reference.PublicKeyOrToken), flags = (int)reference.Flags });
                }
                foreach (var handle in reader.TypeReferences) {
                    var type = Type(reader, handle);
                    typeReferences.Add(new { token = Token(handle), type = type.Name, assembly = type.Assembly });
                }
                foreach (var handle in reader.MemberReferences) {
                    var member = reader.GetMemberReference(handle);
                    // A TypeSpec can contain generic signatures; retain its token
                    // rather than claiming a resolved API owner or reachable call.
                    var owner = member.Parent.Kind == HandleKind.TypeSpecification ? null : TypeOrNull(reader, member.Parent);
                    memberReferences.Add(new { token = Token(handle), name = Text(reader, member.Name), owner = owner?.Name, assembly = owner?.Assembly, parentKind = member.Parent.Kind.ToString(), parentToken = Token(member.Parent), signature = Hex(reader, member.Signature) });
                }
                foreach (var handle in reader.TypeDefinitions) ReadType(reader, handle, entries, diagnostics);
                if (entries.Count > 0) classification = "plugin-entries";
            }
        } catch (Exception e) when (e is BadImageFormatException or ArgumentException or InvalidOperationException or Unsupported or DecoderFallbackException) {
            classification = e is Unsupported ? "unsupported-metadata" : "invalid-metadata";
            diagnostics.Add(e.Message);
        }
        return new { sourceSha256 = hash, byteLength = bytes.Length, classification, assemblyIdentity = identity, assemblyReferences = references, typeReferences, memberReferences, entries, diagnostics };
    }

    static void ReadType(MetadataReader reader, TypeDefinitionHandle handle, List<object> entries, List<string> diagnostics) {
        var type = Type(reader, handle);
        var plugins = new List<object>();
        var processes = new List<string>();
        var dependencies = new List<object>();
        var incompatibilities = new List<string>();
        var issues = new List<string>();
        var attributes = reader.GetTypeDefinition(handle).GetCustomAttributes();
        if (attributes.Count > 256) throw new Unsupported("Type exceeds 256 custom attributes");
        foreach (var attributeHandle in attributes) {
            var attribute = reader.GetCustomAttribute(attributeHandle);
            try {
                var (owner, signature) = Constructor(reader, attribute.Constructor);
                if (!Attributes.Contains(owner.Name)) continue;
                if (owner.Assembly != "BepInEx") {
                    issues.Add($"Attribute {Token(attributeHandle)} {owner.Name} is from {owner.Assembly ?? "unknown scope"}, not BepInEx");
                    continue;
                }
                // Retain malformed/unsupported plugin declarations as candidates.
                object? pluginIdentity = null;
                string? error = null;
                try {
                    var parameters = Parameters(reader, signature);
                    if (reader.GetBlobReader(attribute.Value).Length > AttributeBytes) throw new Unsupported("Attribute exceeds 64 KiB");
                    var value = reader.GetBlobReader(attribute.Value);
                    if (value.ReadUInt16() != 1) throw new Unsupported("Invalid custom attribute prolog");
                    string String() {
                        if (value.ReadByte() == 0xff) throw new Unsupported("Null metadata string");
                        value.Offset--;
                        int length = value.ReadCompressedInteger();
                        if (length < 0 || length > value.RemainingBytes) throw new Unsupported("Invalid serialized string length");
                        return Budget(StrictUTF8.GetString(value.ReadBytes(length)));
                    }
                    switch (owner.Name) {
                        case "BepInEx.BepInPlugin":
                            Require(parameters, "string", "string", "string");
                            pluginIdentity = new { guid = String(), name = String(), version = String() };
                            break;
                        case "BepInEx.BepInProcess":
                            Require(parameters, "string");
                            processes.Add(String());
                            break;
                        case "BepInEx.BepInIncompatibility":
                            Require(parameters, "string");
                            incompatibilities.Add(String());
                            break;
                        case "BepInEx.BepInDependency":
                            if (parameters.SequenceEqual(new[] { "string", "string" })) dependencies.Add(new { guid = String(), minimumVersion = String(), flags = 1 });
                            else {
                                Require(parameters, "string", "dependency-flags");
                                string guid = String(); int flags = value.ReadInt32();
                                dependencies.Add(new { guid, flags });
                                if (flags is not (1 or 2)) throw new Unsupported($"Unsupported dependency flags {flags}");
                            }
                            break;
                    }
                    if (value.ReadUInt16() != 0) throw new Unsupported("Named attribute arguments are unsupported");
                    if (value.RemainingBytes != 0) throw new Unsupported("Trailing attribute bytes");
                } catch (Exception e) when (e is BadImageFormatException or ArgumentException or Unsupported or DecoderFallbackException) {
                    error = e.Message;
                    issues.Add($"Attribute {Token(attributeHandle)} {owner.Name}: {error}");
                }
                if (owner.Name == "BepInEx.BepInPlugin") plugins.Add(new { attributeToken = Token(attributeHandle), identity = pluginIdentity, diagnostic = error });
            } catch (Exception e) when (e is BadImageFormatException or ArgumentException or Unsupported or DecoderFallbackException) {
                issues.Add($"Attribute {Token(attributeHandle)}: {e.Message}");
            }
        }
        foreach (var plugin in plugins) entries.Add(new { type = type.Name, typeToken = Token(handle), declaration = plugin, processes, dependencies, incompatibilities, diagnostics = issues });
        if (plugins.Count == 0) diagnostics.AddRange(issues.Select(issue => $"Type {Token(handle)} {type.Name}: {issue}"));
    }

    static (TypeIdentity, BlobHandle) Constructor(MetadataReader reader, EntityHandle handle) {
        if (handle.Kind == HandleKind.MemberReference) {
            var member = reader.GetMemberReference((MemberReferenceHandle)handle);
            if (Text(reader, member.Name) != ".ctor") throw new Unsupported("Attribute member is not a constructor");
            return (Type(reader, member.Parent), member.Signature);
        }
        if (handle.Kind == HandleKind.MethodDefinition) {
            var method = reader.GetMethodDefinition((MethodDefinitionHandle)handle);
            if (Text(reader, method.Name) != ".ctor") throw new Unsupported("Attribute method is not a constructor");
            return (Type(reader, method.GetDeclaringType()), method.Signature);
        }
        throw new Unsupported("Unsupported attribute constructor kind");
    }

    static string[] Parameters(MetadataReader reader, BlobHandle signature) {
        var blob = reader.GetBlobReader(signature);
        if (blob.Length > 256 || blob.ReadByte() != 0x20) throw new Unsupported("Unsupported constructor signature");
        int count = blob.ReadCompressedInteger();
        if (count < 0 || count > 3 || blob.ReadByte() != 0x01) throw new Unsupported("Unsupported constructor parameters");
        var result = new string[count];
        for (int i = 0; i < count; i++) {
            byte kind = blob.ReadByte();
            if (kind == 0x0e) result[i] = "string";
            else if (kind == 0x11) {
                int coded = blob.ReadCompressedInteger();
                if (coded < 0) throw new Unsupported("Invalid enum handle");
                EntityHandle handle = (coded & 3) switch { 0 => MetadataTokens.TypeDefinitionHandle(coded >> 2), 1 => MetadataTokens.TypeReferenceHandle(coded >> 2), _ => throw new Unsupported("Unsupported enum scope") };
                var type = Type(reader, handle);
                if (type != new TypeIdentity("BepInEx.BepInDependency+DependencyFlags", "BepInEx")) throw new Unsupported("Unknown attribute enum");
                result[i] = "dependency-flags";
            } else throw new Unsupported($"Unsupported constructor parameter 0x{kind:x2}");
        }
        if (blob.RemainingBytes != 0) throw new Unsupported("Trailing constructor signature");
        return result;
    }
    static void Require(string[] actual, params string[] expected) {
        if (!actual.SequenceEqual(expected)) throw new Unsupported("Unsupported attribute constructor overload");
    }
    static TypeIdentity? TypeOrNull(MetadataReader reader, EntityHandle handle) => handle.Kind is HandleKind.TypeDefinition or HandleKind.TypeReference ? Type(reader, handle) : null;
    static TypeIdentity Type(MetadataReader reader, EntityHandle handle, int depth = 0) {
        if (depth >= 32) throw new Unsupported("Nested type depth exceeds 32");
        if (handle.Kind == HandleKind.TypeDefinition) {
            var type = reader.GetTypeDefinition((TypeDefinitionHandle)handle);
            string name = Text(reader, type.Name);
            if (!type.GetDeclaringType().IsNil) { var outer = Type(reader, type.GetDeclaringType(), depth + 1); return new(outer.Name + "+" + name, outer.Assembly); }
            return new(Qualify(Text(reader, type.Namespace), name), reader.IsAssembly ? Text(reader, reader.GetAssemblyDefinition().Name) : null);
        }
        if (handle.Kind == HandleKind.TypeReference) {
            var type = reader.GetTypeReference((TypeReferenceHandle)handle);
            string name = Text(reader, type.Name);
            if (type.ResolutionScope.Kind == HandleKind.TypeReference) { var outer = Type(reader, type.ResolutionScope, depth + 1); return new(outer.Name + "+" + name, outer.Assembly); }
            string? assembly = type.ResolutionScope.Kind == HandleKind.AssemblyReference ? Text(reader, reader.GetAssemblyReference((AssemblyReferenceHandle)type.ResolutionScope).Name) : null;
            return new(Qualify(Text(reader, type.Namespace), name), assembly);
        }
        throw new Unsupported("Unsupported type handle " + handle.Kind);
    }
    static string Qualify(string ns, string name) => ns.Length == 0 ? name : ns + "." + name;
    static int Token(EntityHandle handle) => MetadataTokens.GetToken(handle);
    static string Text(MetadataReader reader, StringHandle handle) { string value = reader.GetString(handle); if (value.Length > 8192) throw new Unsupported("Metadata string exceeds 8192 characters"); return Budget(value); }
    static string Budget(string value) { remainingText -= value.Length; if (remainingText < 0) throw new Unsupported("Decoded metadata exceeds 4 Mi characters"); return value; }
    static string Hex(MetadataReader reader, BlobHandle handle) { var blob = reader.GetBlobReader(handle); if (blob.Length > AttributeBytes) throw new Unsupported("Metadata blob exceeds 64 KiB"); return Budget(Convert.ToHexString(blob.ReadBytes(blob.Length)).ToLowerInvariant()); }
}
