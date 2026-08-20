//
//  Package.swift
//  IkkokuCreator
//
//  Created by rumpology on 8/18/26.
//

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Engine", targets: ["GPU", "CoreMath", "ShaderTypes"]),
    ],
    targets: [
        .target(name: "ShaderTypes"),
        .target(name: "CoreMath", dependencies: ["ShaderTypes"]),
        .target(name: "GPU", dependencies: ["CoreMath", "ShaderTypes"]),
        .testTarget(name: "CoreMathTests", dependencies: ["CoreMath"]),
    ]
)
