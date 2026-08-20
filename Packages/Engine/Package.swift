// swift-tools-version: 6.0
//
//  Package.swift
//  IkkokuCreator
//
//  Created by rumpology on 8/18/26.
//

import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Engine", targets: ["Renderer", "GPU", "CoreMath", "ShaderTypes"]),
    ],
    targets: [
        .target(name: "ShaderTypes"),
        .target(name: "CoreMath", dependencies: ["ShaderTypes"]),
        .target(name: "GPU", dependencies: ["CoreMath", "ShaderTypes"]),
        .target(name: "Renderer", dependencies: ["GPU", "CoreMath", "ShaderTypes"]),
        .testTarget(name: "CoreMathTests", dependencies: ["CoreMath", "ShaderTypes"]),
    ]
)
