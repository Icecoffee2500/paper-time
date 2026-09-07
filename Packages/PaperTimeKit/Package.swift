// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaperTimeKit",
    defaultLocalization: "en",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PaperCore", targets: ["PaperCore"]),
        .library(name: "LibraryStore", targets: ["LibraryStore"]),
        .library(name: "Bibliography", targets: ["Bibliography"]),
        .library(name: "MetadataPipeline", targets: ["MetadataPipeline"]),
        .library(name: "InkEngine", targets: ["InkEngine"]),
        .library(name: "PDFReader", targets: ["PDFReader"]),
        .library(name: "Importers", targets: ["Importers"]),
    ],
    targets: [
        .executableTarget(
            name: "papertime-seed",
            dependencies: ["PaperCore", "LibraryStore", "MetadataPipeline", "Bibliography"],
            path: "Sources/Tools/papertime-seed"
        ),
        .executableTarget(
            name: "papertime-eval",
            dependencies: ["PaperCore", "MetadataPipeline", "Bibliography"],
            path: "Sources/Tools/papertime-eval"
        ),
        .target(name: "PaperCore"),
        .target(name: "LibraryStore", dependencies: ["PaperCore"]),
        .target(name: "Bibliography", dependencies: ["PaperCore"]),
        .target(name: "MetadataPipeline", dependencies: ["PaperCore", "Bibliography"]),
        .target(name: "InkEngine", dependencies: ["PaperCore"]),
        .target(name: "PDFReader", dependencies: ["PaperCore", "InkEngine", "LibraryStore"]),
        .target(name: "Importers", dependencies: ["PaperCore", "Bibliography", "LibraryStore"]),

        .testTarget(name: "PaperCoreTests", dependencies: ["PaperCore"]),
        .testTarget(name: "LibraryStoreTests", dependencies: ["LibraryStore"]),
        .testTarget(name: "BibliographyTests", dependencies: ["Bibliography"]),
        .testTarget(
            name: "MetadataPipelineTests",
            dependencies: ["MetadataPipeline"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ImportersTests", dependencies: ["Importers"]),
        .testTarget(name: "InkEngineTests", dependencies: ["InkEngine"]),
        .testTarget(name: "PDFReaderTests", dependencies: ["PDFReader"]),
    ]
)
