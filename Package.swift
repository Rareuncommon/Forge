// swift-tools-version:6.1
// Forge — parametric CAD. See SPEC.md, docs/adr/.
//
// OCCT location is resolved from FORGE_OCCT_PREFIX (an install prefix containing
// include/opencascade and lib/). Defaults:
//   macOS: Vendor/occt/darwin-arm64   (built by scripts/build-occt.sh)
//   Linux: /usr                       (Ubuntu libocct-*-dev packages, used by CI)
// The toolkit naming changed in OCCT 7.8 (TKSTEP -> TKDESTEP, ...); the layout is
// detected from the libraries present, or forced with FORGE_OCCT_LAYOUT=legacy|de.

import Foundation
import PackageDescription

let env = ProcessInfo.processInfo.environment
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

#if os(macOS)
let defaultOCCTPrefix = "\(packageRoot)/Vendor/occt/darwin-arm64"
#else
let defaultOCCTPrefix = "/usr"
#endif
let occtPrefix = env["FORGE_OCCT_PREFIX"] ?? defaultOCCTPrefix
let occtInclude = "\(occtPrefix)/include/opencascade"

let occtLibDirs: [String] = {
    var dirs = ["\(occtPrefix)/lib"]
    #if os(Linux)
    dirs.append("\(occtPrefix)/lib/x86_64-linux-gnu")
    dirs.append("\(occtPrefix)/lib/aarch64-linux-gnu")
    #endif
    return dirs.filter { FileManager.default.fileExists(atPath: $0) }
}()

/// "de" = OCCT >= 7.8 DataExchange toolkits (TKDESTEP, TKDESTL, TKDEIGES); "legacy" = TKSTEP etc.
let occtLayout: String = {
    if let forced = env["FORGE_OCCT_LAYOUT"] { return forced }
    for dir in occtLibDirs {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        if files.contains(where: { $0.hasPrefix("libTKDESTEP") }) { return "de" }
    }
    return "legacy"
}()

let occtCoreLibs = [
    "TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKBRep", "TKGeomAlgo",
    "TKTopAlgo", "TKPrim", "TKBO", "TKBool", "TKShHealing", "TKMesh", "TKFillet",
    "TKOffset", "TKFeat", "TKXSBase",
]
let occtDataExchangeLibs = occtLayout == "de"
    ? ["TKDE", "TKDESTEP", "TKDESTL", "TKDEIGES"]
    : ["TKSTEP", "TKSTEPBase", "TKSTEPAttr", "TKSTEP209", "TKSTL", "TKIGES"]

let occtLinkerFlags: [String] = occtLibDirs.flatMap { ["-L\($0)", "-Xlinker", "-rpath", "-Xlinker", $0] }

let strictSwift: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

var targets: [Target] = [
    // C++20 bridge over OCCT exposing a plain C ABI (docs/adr/0001-kernel-wrapping.md).
    .target(
        name: "CForgeKernel",
        path: "Sources/CForgeKernel",
        cxxSettings: [
            .unsafeFlags(["-I\(occtInclude)", "-Wno-deprecated-declarations", "-Wno-deprecated-enum-enum-conversion"]),
        ],
        linkerSettings: (occtCoreLibs + occtDataExchangeLibs).map { .linkedLibrary($0) }
            + [.unsafeFlags(occtLinkerFlags)]
    ),
    .target(name: "ForgeCore", swiftSettings: strictSwift),
    .target(name: "ForgeKernel", dependencies: ["CForgeKernel", "ForgeCore"], swiftSettings: strictSwift),
    .target(name: "ForgeCommands", dependencies: ["ForgeCore", "ForgeKernel", "ForgeRender"], swiftSettings: strictSwift),
    .target(name: "ForgeRender", dependencies: ["ForgeCore", "ForgeKernel"], swiftSettings: strictSwift),
    .target(name: "ForgeMCP", dependencies: ["ForgeCore", "ForgeCommands", "ForgeRender"], swiftSettings: strictSwift),
    .executableTarget(
        name: "forge-cli",
        dependencies: ["ForgeCore", "ForgeKernel", "ForgeCommands", "ForgeMCP", "ForgeRender"],
        swiftSettings: strictSwift
    ),

    .testTarget(name: "ForgeCoreTests", dependencies: ["ForgeCore"]),
    .testTarget(name: "ForgeKernelTests", dependencies: ["ForgeKernel"]),
    .testTarget(name: "ForgeCommandsTests", dependencies: ["ForgeCommands"]),
    .testTarget(name: "ForgeRenderTests", dependencies: ["ForgeRender", "ForgeKernel"]),
    .testTarget(name: "ForgeMCPTests", dependencies: ["ForgeMCP", "ForgeCommands"]),
    .testTarget(
        name: "GoldenModelTests",
        dependencies: ["ForgeCommands"],
        resources: [.copy("Models")]
    ),
]

var products: [Product] = [
    .executable(name: "forge-cli", targets: ["forge-cli"]),
    .library(name: "ForgeEngine", targets: ["ForgeCore", "ForgeKernel", "ForgeCommands", "ForgeRender", "ForgeMCP"]),
]

#if os(macOS)
// The GUI shell only exists on macOS (Metal + SwiftUI). Everything else is headless and
// builds on Linux for CI (docs/adr/0007-build-and-ci.md).
targets.append(
    .executableTarget(
        name: "ForgeApp",
        dependencies: ["ForgeCore", "ForgeKernel", "ForgeCommands", "ForgeRender"],
        swiftSettings: strictSwift
    )
)
products.append(.executable(name: "ForgeApp", targets: ["ForgeApp"]))
#endif

let package = Package(
    name: "Forge",
    platforms: [.macOS("27.0")],
    products: products,
    targets: targets,
    cxxLanguageStandard: .cxx20
)
