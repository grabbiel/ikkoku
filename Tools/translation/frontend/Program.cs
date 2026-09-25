using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

record Node(string Kind, string? Type = null, string? Name = null, object? Value = null, List<Node>? Children = null);
record Parameter(string Name, string Type);
record Method(string Name, string Symbol, bool Static, string ReturnType, List<Parameter> Parameters, Node Body, string? Lifecycle);
record Field(string Name, string Type, Node Initializer, bool Serialized);
record Issue(string Code, string Message, int Line, int Column, string Syntax);
sealed class Unsupported(SyntaxNode node, string reason) : Exception(reason) { public SyntaxNode Node = node; }

class Lowerer(SemanticModel model, INamedTypeSymbol owner, HashSet<IMethodSymbol> selected, bool component) {
    public readonly List<object> Substitutions = [];
    static readonly Dictionary<string, string> Types = new() {
        ["void"] = "Void", ["float"] = "Float", ["double"] = "Double", ["bool"] = "Bool", ["int"] = "Int32", ["string"] = "String",
        ["UnityEngine.Vector3"] = "Vector3", ["UnityEngine.GameObject"] = "Object", ["UnityEngine.Transform"] = "Transform", ["UnityEngine.Space"] = "Space"
    };
    string SourceType(ITypeSymbol? symbol) => symbol?.ToDisplayString() ?? "<unresolved>";
    public string Type(ITypeSymbol? symbol, SyntaxNode site) => Types.TryGetValue(SourceType(symbol), out var result) ? result : throw new Unsupported(site, "Unsupported type: " + SourceType(symbol));
    ISymbol Symbol(SyntaxNode n) => model.GetSymbolInfo(n).Symbol ?? throw new Unsupported(n, "Symbol did not resolve uniquely");
    Node Ref(string n, string t) => new("ref", t, n);
    void Mark(SyntaxNode node, ISymbol symbol, string operation) {
        var pos = node.GetLocation().GetLineSpan().StartLinePosition;
        Substitutions.Add(new { symbol = symbol.ToDisplayString(), operation, line = pos.Line + 1, column = pos.Character + 1 });
    }
    Node Api(SyntaxNode node, ISymbol symbol, string operation, string type, params Node[] args) {
        Mark(node, symbol, operation);
        return new("api", type, operation, Children: [..args]);
    }
    public Node Expression(ExpressionSyntax expression) {
        Node result = Raw(expression);
        var info = model.GetTypeInfo(expression);
        if (info.Type is not null && info.ConvertedType is not null && !SymbolEqualityComparer.Default.Equals(info.Type, info.ConvertedType)) {
            string from = Type(info.Type, expression), to = Type(info.ConvertedType, expression);
            if (new[] { "Float", "Double", "Int32" }.Contains(from) && new[] { "Float", "Double" }.Contains(to))
                result = new("convert", to, Children: [result]);
            else throw new Unsupported(expression, $"Unsupported implicit conversion: {from} -> {to}");
        }
        return result;
    }
    Node Raw(ExpressionSyntax expression) {
        string type = Type(model.GetTypeInfo(expression).Type, expression);
        switch (expression) {
            case LiteralExpressionSyntax literal:
                if (literal.Token.Value is null) throw new Unsupported(expression, "Null/object fake-null semantics are not implemented");
                return new("literal", type, Value: literal.Token.Value);
            case ParenthesizedExpressionSyntax paren: return Expression(paren.Expression);
            case IdentifierNameSyntax id:
                var symbol = Symbol(id);
                if (symbol is IParameterSymbol or ILocalSymbol) return Ref(symbol.Name, type);
                if (symbol is IFieldSymbol field && SymbolEqualityComparer.Default.Equals(field.ContainingType, owner)) {
                    if (field.HasConstantValue && field.ConstantValue is not null) return new("literal", type, Value: field.ConstantValue);
                    if (field.IsStatic) throw new Unsupported(id, "Static component fields are not supported");
                    return new("field", type, field.Name);
                }
                if (symbol is IPropertySymbol inherited && inherited.ContainingType.ToDisplayString() == "UnityEngine.MonoBehaviour" && component)
                    return Api(id, inherited, inherited.Name, type);
                throw new Unsupported(id, "Unsupported value symbol: " + symbol.ToDisplayString());
            case MemberAccessExpressionSyntax member:
                var memberSymbol = Symbol(member);
                string parent = memberSymbol.ContainingType?.ToDisplayString() ?? "";
                if (memberSymbol is IFieldSymbol constant && constant.HasConstantValue && constant.ConstantValue is not null && SymbolEqualityComparer.Default.Equals(constant.ContainingType, owner))
                    return new("literal", type, Value: constant.ConstantValue);
                if (parent == "UnityEngine.Time" && component && memberSymbol.Name is "deltaTime" or "fixedDeltaTime")
                    return Api(member, memberSymbol, memberSymbol.Name, type);
                if (parent == "UnityEngine.Vector3" && memberSymbol.Name is "zero" or "one")
                    return Api(member, memberSymbol, "vector." + memberSymbol.Name, type);
                if (parent == "UnityEngine.Space" && memberSymbol.Name is "World" or "Self")
                    return new("space", type, memberSymbol.Name);
                if (parent == "UnityEngine.Vector3" && memberSymbol.Name is "x" or "y" or "z")
                    return new("member", type, memberSymbol.Name, Children: [Expression(member.Expression)]);
                if ((parent == "UnityEngine.Transform" && memberSymbol.Name is "position" or "localPosition" or "localScale") ||
                    (parent == "UnityEngine.GameObject" && memberSymbol.Name == "transform"))
                    return Api(member, memberSymbol, memberSymbol.Name, type, Expression(member.Expression));
                if (member.Expression is ThisExpressionSyntax && memberSymbol is IFieldSymbol own && SymbolEqualityComparer.Default.Equals(own.ContainingType, owner))
                    return new("field", type, own.Name);
                throw new Unsupported(member, "Unsupported member: " + memberSymbol.ToDisplayString());
            case ObjectCreationExpressionSyntax created:
                if (type != "Vector3" || created.Initializer is not null || created.ArgumentList?.Arguments.Count != 3)
                    throw new Unsupported(created, "Only the three-float Vector3 constructor is supported");
                return Api(created, Symbol(created), "vector.init", type, [..created.ArgumentList.Arguments.Select(Argument)]);
            case InvocationExpressionSyntax call:
                if (Symbol(call) is not IMethodSymbol method) throw new Unsupported(call, "Not a method call");
                var arguments = call.ArgumentList.Arguments.Select(Argument).ToList();
                string containing = method.ContainingType.ToDisplayString();
                if (containing == "UnityEngine.Mathf" && method.Name is "Clamp01" or "Lerp" or "Sqrt")
                    return Api(call, method, "math." + method.Name, type, [..arguments]);
                if (component && containing == "UnityEngine.Object" && method.Name is "Instantiate" or "Destroy")
                    return Api(call, method, "world." + method.Name, type, [..arguments]);
                if (component && containing == "UnityEngine.Transform" && method.Name == "Translate" && call.Expression is MemberAccessExpressionSyntax translate) {
                    if (arguments.Count == 1) arguments.Add(new("space", "Space", "Self"));
                    return Api(call, method, "translate", type, [Expression(translate.Expression), ..arguments]);
                }
                if (component && containing == "UnityEngine.GameObject" && method.Name == "SetActive" && call.Expression is MemberAccessExpressionSyntax active)
                    return Api(call, method, "setActive", type, [Expression(active.Expression), ..arguments]);
                if (SymbolEqualityComparer.Default.Equals(method.ContainingType, owner) && selected.Contains(method)) {
                    if (call.Expression is MemberAccessExpressionSyntax access && !method.IsStatic && access.Expression is not ThisExpressionSyntax)
                        throw new Unsupported(call, "Calls on a different component instance are unsupported");
                    return new("call", type, method.Name, method.IsStatic, arguments);
                }
                throw new Unsupported(call, "Unsupported call: " + method.ToDisplayString());
            case BinaryExpressionSyntax binary:
                if (!new[] { "+", "-", "*", "/", "<", ">", "<=", ">=", "==", "!=", "&&", "||" }.Contains(binary.OperatorToken.Text))
                    throw new Unsupported(binary, "Unsupported binary operator");
                if (type is "Int32" or "String" || model.GetTypeInfo(binary.Left).Type?.ToDisplayString() is "string" or "UnityEngine.GameObject" or "UnityEngine.Vector3") {
                    if (type != "Vector3") throw new Unsupported(binary, "Integer overflow, string concatenation and Unity object/vector equality need explicit adapters");
                }
                return new("binary", type, binary.OperatorToken.Text, Children: [Expression(binary.Left), Expression(binary.Right)]);
            case PrefixUnaryExpressionSyntax unary when unary.OperatorToken.Text is "-" or "!" or "+":
                if (type == "Int32") throw new Unsupported(unary, "Integer arithmetic is outside the supported subset");
                return new("unary", type, unary.OperatorToken.Text, Children: [Expression(unary.Operand)]);
            case ConditionalExpressionSyntax conditional:
                return new("conditional", type, Children: [Expression(conditional.Condition), Expression(conditional.WhenTrue), Expression(conditional.WhenFalse)]);
            case CastExpressionSyntax cast:
                var operand = Expression(cast.Expression);
                if (type is not ("Float" or "Double") || operand.Type is not ("Float" or "Double" or "Int32")) throw new Unsupported(cast, "Unsupported explicit conversion");
                return new("convert", type, Children: [operand]);
            default: throw new Unsupported(expression, "Unsupported expression: " + expression.Kind());
        }
    }
    Node Argument(ArgumentSyntax argument) {
        if (argument.NameColon is not null || argument.RefKindKeyword.RawKind != 0) throw new Unsupported(argument, "Named/ref/out arguments are unsupported");
        return Expression(argument.Expression);
    }
    Node Assignment(AssignmentExpressionSyntax assignment) {
        if (!new[] { "=", "+=", "-=", "*=", "/=" }.Contains(assignment.OperatorToken.Text)) throw new Unsupported(assignment, "Unsupported assignment operator");
        var left = Expression(assignment.Left);
        if (left.Kind is not ("ref" or "field" or "member" or "api")) throw new Unsupported(assignment.Left, "Unsupported assignment destination");
        if (left.Kind == "api" && left.Name is not ("position" or "localPosition" or "localScale")) throw new Unsupported(assignment.Left, "Read-only translated API");
        if (assignment.OperatorToken.Text != "=" && left.Type is not ("Float" or "Double" or "Vector3")) throw new Unsupported(assignment, "Compound integer assignment is not implemented");
        return new("assign", Name: assignment.OperatorToken.Text, Children: [left, Expression(assignment.Right)]);
    }
    public Node Statement(StatementSyntax statement) {
        switch (statement) {
            case BlockSyntax block: return new("block", Children: [..block.Statements.Select(Statement)]);
            case ExpressionStatementSyntax { Expression: AssignmentExpressionSyntax assignment }: return Assignment(assignment);
            case ExpressionStatementSyntax { Expression: InvocationExpressionSyntax invocation }: return new("expression", Children: [Expression(invocation)]);
            case LocalDeclarationStatementSyntax declaration:
                if (declaration.UsingKeyword.RawKind != 0 || declaration.AwaitKeyword.RawKind != 0 || declaration.Modifiers.Count != 0) throw new Unsupported(declaration, "Unsupported local modifier");
                return new("declarations", Children: [..declaration.Declaration.Variables.Select(variable => {
                    var symbol = model.GetDeclaredSymbol(variable) as ILocalSymbol;
                    var t = Type(symbol?.Type, variable);
                    if (variable.Initializer is null) throw new Unsupported(variable, "Locals require explicit initialization");
                    return new Node("local", t, variable.Identifier.ValueText, Children: [Expression(variable.Initializer.Value)]);
                })]);
            case IfStatementSyntax condition: return new("if", Children: [Expression(condition.Condition), Statement(condition.Statement), condition.Else is null ? new("empty") : Statement(condition.Else.Statement)]);
            case ReturnStatementSyntax returned: return new("return", Children: returned.Expression is null ? [] : [Expression(returned.Expression)]);
            case EmptyStatementSyntax: return new("empty");
            default: throw new Unsupported(statement, "Unsupported statement: " + statement.Kind());
        }
    }
}

class Program {
    static int Main(string[] args) {
        if (args.Length < 4) { Console.Error.WriteLine("Usage: Translation source.cs qualified.type component|methods method1,method2"); return 2; }
        string sourcePath = Path.GetFullPath(args[0]);
        byte[] bytes = File.ReadAllBytes(sourcePath);
        if (bytes.Length > 8 * 1024 * 1024) throw new InvalidDataException("Source exceeds 8 MiB");
        string source = new UTF8Encoding(false, true).GetString(bytes);
        var tree = CSharpSyntaxTree.ParseText(source, path: sourcePath);
        using var stream = typeof(Program).Assembly.GetManifestResourceStream("Translation.UnitySurface.txt")!;
        string surface = new StreamReader(stream).ReadToEnd();
        var stub = CSharpSyntaxTree.ParseText(surface, path: "<UnitySurface>");
        var refs = ((string)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES")!).Split(Path.PathSeparator).Select(p => MetadataReference.CreateFromFile(p));
        var compilation = CSharpCompilation.Create("SourceAnalysis", [tree, stub], refs, new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary));
        var model = compilation.GetSemanticModel(tree);
        var issues = new List<Issue>();
        void Issue(SyntaxNode node, string message, string code = "UNSUPPORTED") {
            var p = node.GetLocation().GetLineSpan().StartLinePosition;
            issues.Add(new(code, message, p.Line + 1, p.Character + 1, node.Kind().ToString()));
        }
        foreach (var diagnostic in compilation.GetDiagnostics().Where(d => d.Severity == DiagnosticSeverity.Error)) {
            var p = diagnostic.Location.GetLineSpan().StartLinePosition;
            issues.Add(new(diagnostic.Id, diagnostic.GetMessage(), p.Line + 1, p.Character + 1, "SemanticDiagnostic"));
        }
        foreach (var ns in tree.GetRoot().DescendantNodes().OfType<BaseNamespaceDeclarationSyntax>().Where(n => n.Name.ToString().StartsWith("UnityEngine", StringComparison.Ordinal)))
            Issue(ns, "Input cannot redefine the trusted Unity semantic surface");
        var declaration = tree.GetRoot().DescendantNodes().OfType<ClassDeclarationSyntax>().Where(d => model.GetDeclaredSymbol(d)?.ToDisplayString() == args[1]).ToArray();
        List<Method> methods = []; List<Field> fields = []; List<object> substitutions = [];
        object? plugin = null;
        string[] lifecycles = ["Awake", "OnEnable", "Start", "Update", "FixedUpdate", "LateUpdate", "OnDisable", "OnDestroy"];
        bool component = args[2] == "component";
        if (args[2] is not ("component" or "methods")) issues.Add(new("MODE", "Expected component or methods", 0, 0, "Input"));
        string swiftName = "";
        if (declaration.Length != 1) issues.Add(new("TYPE", "Type must resolve to exactly one declaration (partial classes are unsupported)", 0, 0, "Input"));
        else {
            var cls = declaration[0];
            var owner = model.GetDeclaredSymbol(cls)!;
            swiftName = "Translated_" + owner.Name + "_" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(args[1])))[..8].ToLowerInvariant();
            if (cls.TypeParameterList is not null) Issue(cls, "Generic classes require a dedicated adapter");
            if (component && owner.BaseType?.ToDisplayString() is not ("UnityEngine.MonoBehaviour" or "BepInEx.BaseUnityPlugin")) Issue(cls, "Component must inherit UnityEngine.MonoBehaviour or BepInEx.BaseUnityPlugin directly");
            var attributes = owner.GetAttributes();
            var identities = attributes.Where(a => a.AttributeClass?.ToDisplayString() == "BepInEx.BepInPlugin").ToArray();
            List<string> processes = [], incompatibilities = []; List<object> dependencies = [];
            foreach (var attribute in attributes) {
                string kind = attribute.AttributeClass?.ToDisplayString() ?? "";
                var values = attribute.ConstructorArguments;
                if (!component || attribute.NamedArguments.Length != 0 || !new[] { "BepInEx.BepInPlugin", "BepInEx.BepInProcess", "BepInEx.BepInDependency", "BepInEx.BepInIncompatibility" }.Contains(kind)) { Issue(cls, "Attribute requires a dedicated adapter: " + kind); continue; }
                if (values.Length == 0 || values[0].Value is not string identity || string.IsNullOrEmpty(identity)) { Issue(cls, "Empty plugin metadata identity"); continue; }
                if (kind == "BepInEx.BepInProcess") processes.Add(identity);
                if (kind == "BepInEx.BepInIncompatibility") incompatibilities.Add(identity);
                if (kind == "BepInEx.BepInDependency") {
                    string? version = values.Length > 1 ? values[1].Value as string : null;
                    int flags = values.Length > 1 && values[1].Value is int number ? number : 1;
                    if (flags is not (1 or 2)) Issue(cls, "Unknown BepInDependency flags");
                    dependencies.Add(new { guid = identity, minimumVersion = version, required = flags == 1 });
                }
            }
            if (identities.Length == 1) {
                var values = identities[0].ConstructorArguments;
                if (values.Length == 3 && values.All(v => v.Value is string s && !string.IsNullOrEmpty(s)))
                    plugin = new { guid = (string)values[0].Value!, name = (string)values[1].Value!, version = (string)values[2].Value!, processes, dependencies, incompatibilities };
                else Issue(cls, "Invalid BepInPlugin metadata");
            } else if (identities.Length > 1 || owner.BaseType?.ToDisplayString() == "BepInEx.BaseUnityPlugin") Issue(cls, "A BepInEx plugin requires exactly one BepInPlugin identity");
            if (!component && !owner.IsStatic) Issue(cls, "Method selection currently requires a static class");
            var requested = args[3].Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
            if (!component && requested.Count == 0) Issue(cls, "Select at least one utility method");
            var declarations = cls.Members.OfType<MethodDeclarationSyntax>().Where(m => component || requested.Contains(m.Identifier.ValueText)).ToList();
            foreach (var wanted in requested.Where(w => !declarations.Any(d => d.Identifier.ValueText == w))) Issue(cls, "Requested method was not found: " + wanted);
            foreach (var group in declarations.GroupBy(d => d.Identifier.ValueText).Where(g => g.Count() != 1)) Issue(group.First(), "Overloaded selected methods require signature selection");
            HashSet<IMethodSymbol> selected = new(SymbolEqualityComparer.Default);
            foreach (var m in declarations) selected.Add(model.GetDeclaredSymbol(m)!);
            var lower = new Lowerer(model, owner, selected, component);
            if (component) foreach (var member in cls.Members) {
                if (member is MethodDeclarationSyntax) continue;
                if (member is not FieldDeclarationSyntax field) { Issue(member, "Unsupported component member: " + member.Kind()); continue; }
                try {
                    if (field.Modifiers.Any(SyntaxKind.ConstKeyword)) {
                        if (field.AttributeLists.Count > 0) throw new Unsupported(field, "Attributed constants require an adapter");
                        continue; // Roslyn resolves immutable constants at each use.
                    }
                    if (field.Modifiers.Any(SyntaxKind.StaticKeyword) || field.Modifiers.Any(SyntaxKind.ReadOnlyKeyword)) throw new Unsupported(field, "Static/readonly fields require an adapter");
                    foreach (var variable in field.Declaration.Variables) {
                        if (new[] { "context", "gameObject", "transform", "sourceIdentityJSON", "sourceAwake", "sourceStart", "sourceUpdate", "sourceFixedUpdate", "sourceOnEnable", "sourceLateUpdate", "sourceOnDisable", "sourceOnDestroy" }.Contains(variable.Identifier.ValueText)) throw new Unsupported(variable, "Field collides with the native bridge surface");
                        var fieldSymbol = (IFieldSymbol)model.GetDeclaredSymbol(variable)!;
                        var fieldAttributes = fieldSymbol.GetAttributes().Select(a => a.AttributeClass?.ToDisplayString()).ToArray();
                        if (fieldAttributes.Any(a => a is not ("UnityEngine.SerializeField" or "System.NonSerializedAttribute"))) throw new Unsupported(field, "Unknown field attribute requires an adapter");
                        var serialized = !fieldAttributes.Contains("System.NonSerializedAttribute") && (fieldSymbol.DeclaredAccessibility == Accessibility.Public || fieldAttributes.Contains("UnityEngine.SerializeField"));
                        var t = lower.Type(fieldSymbol.Type, variable);
                        if (t is "Object" or "Transform") throw new Unsupported(variable, "Object fields require an explicit serialized-reference adapter");
                        var initial = variable.Initializer is not null ? lower.Expression(variable.Initializer.Value) : t switch {
                            "Float" or "Double" or "Int32" => new Node("literal", t, Value: 0), "Bool" => new Node("literal", t, Value: false),
                            "Vector3" => new Node("api", t, "vector.zero"), _ => throw new Unsupported(variable, "Field needs an explicit initializer")
                        };
                        fields.Add(new(variable.Identifier.ValueText, t, initial, serialized));
                    }
                } catch (Unsupported error) { Issue(error.Node, error.Message); }
            }
            foreach (var syntax in declarations) {
                try {
                    var symbol = model.GetDeclaredSymbol(syntax)!;
                    if (component && new[] { "context", "gameObject", "transform", "sourceIdentityJSON", "sourceAwake", "sourceStart", "sourceUpdate", "sourceFixedUpdate", "sourceOnEnable", "sourceLateUpdate", "sourceOnDisable", "sourceOnDestroy" }.Contains(symbol.Name)) throw new Unsupported(syntax, "Method collides with the native bridge surface");
                    if (symbol.IsGenericMethod || syntax.AttributeLists.Count > 0 || syntax.Modifiers.Any(SyntaxKind.AsyncKeyword) || symbol.IsAbstract || symbol.IsVirtual || symbol.IsOverride || symbol.IsExtern)
                        throw new Unsupported(syntax, "Generic, attributed, async, virtual and extern methods are unsupported");
                    if (component && symbol.IsStatic) throw new Unsupported(syntax, "Static component methods are outside the supported subset");
                    if (!component && !symbol.IsStatic) throw new Unsupported(syntax, "Selected utility methods must be static");
                    if (symbol.Parameters.Any(p => p.RefKind != RefKind.None || p.HasExplicitDefaultValue || p.IsParams)) throw new Unsupported(syntax, "ref/out/default/params parameters are unsupported");
                    string? lifecycle = null;
                    if (component && lifecycles.Contains(symbol.Name)) {
                        if (symbol.IsStatic || !symbol.ReturnsVoid || symbol.Parameters.Length != 0) throw new Unsupported(syntax, "Lifecycle callbacks must be instance void methods without parameters");
                        lifecycle = symbol.Name;
                    }
                    if (component && lifecycle is null && (symbol.Name.StartsWith("On", StringComparison.Ordinal) || symbol.Name == "Reset")) throw new Unsupported(syntax, "Lifecycle callback has no host adapter: " + symbol.Name);
                    Node body = syntax.Body is not null ? lower.Statement(syntax.Body) : syntax.ExpressionBody is not null ? new("block", Children: [new("return", Children: [lower.Expression(syntax.ExpressionBody.Expression)])]) : throw new Unsupported(syntax, "Method has no body");
                    methods.Add(new(symbol.Name, symbol.GetDocumentationCommentId() ?? symbol.ToDisplayString(), symbol.IsStatic, lower.Type(symbol.ReturnType, syntax), [..symbol.Parameters.Select(p => new Parameter(p.Name, lower.Type(p.Type, syntax)))], body, lifecycle));
                } catch (Unsupported error) { Issue(error.Node, error.Message); }
            }
            substitutions = lower.Substitutions;
        }
        var output = new { schemaVersion = 1, status = issues.Count == 0 ? "ready" : "rejected", source = new { path = sourcePath, sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() },
            semanticSurfaceSHA256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(surface))).ToLowerInvariant(), parser = typeof(CSharpSyntaxTree).Assembly.GetName().Version?.ToString(),
            type = args[1], swiftName, mode = args[2], plugin, fields, methods, substitutions, diagnostics = issues };
        Console.WriteLine(JsonSerializer.Serialize(output, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true }));
        return issues.Count == 0 ? 0 : 2;
    }
}
