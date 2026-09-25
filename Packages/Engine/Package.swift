// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ikkoku-inspect", targets: ["IkkokuInspect"]),
        .library(name: "Engine",
                 targets: ["Renderer", "GPU", "CoreMath", "ShaderTypes",
                           "Assets", "Scene", "Character", "Studio", "Gameplay"]),
    ],
    targets: [
        .executableTarget(name: "IkkokuInspect", dependencies: ["Assets", "CoreMath", "Studio", "Character", "Scene", "Gameplay"]),
        .target(name: "ShaderTypes"),
        .target(name: "CoreMath", dependencies: ["ShaderTypes"]),
        .target(name: "GPU", dependencies: ["CoreMath", "ShaderTypes"]),
        .target(name: "Assets", dependencies: ["CoreMath", "ShaderTypes"]),
        .target(name: "Scene", dependencies: ["CoreMath", "ShaderTypes", "Assets"]),
        .target(name: "Character", dependencies: ["CoreMath", "ShaderTypes", "Assets", "Scene", "GPU", "Renderer"]),
        .target(name: "Renderer", dependencies: ["GPU", "CoreMath", "ShaderTypes", "Assets", "Scene"]),
        .target(name: "Studio", dependencies: ["CoreMath", "ShaderTypes", "Assets", "Scene", "Character", "Renderer", "Gameplay"]),
        .target(name: "Gameplay"),
        .testTarget(name: "CoreMathTests", dependencies: ["CoreMath", "ShaderTypes"]),
        .testTarget(name: "EngineTests", dependencies: ["Assets", "Scene", "Character", "Studio", "CoreMath", "ShaderTypes", "Gameplay"]),
    ]
)
