// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StudyAI",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Actualizaciones automáticas desde las releases de GitHub.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ],
    targets: [
        // Lógica pura y testeable sin hardware ni permisos.
        .target(name: "StudyAICore"),
        .executableTarget(name: "StudyAI", dependencies: ["StudyAICore", .product(name: "Sparkle", package: "Sparkle")]),
        // Servidor MCP (stdio) para que ChatGPT o Claude lean las clases desde este Mac.
        .executableTarget(name: "EstudIAMCP", dependencies: ["StudyAICore"]),
        .testTarget(name: "StudyAICoreTests", dependencies: ["StudyAICore"]),
    ],
    swiftLanguageModes: [.v5]
)
