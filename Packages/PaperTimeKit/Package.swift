// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaperTimeKit",
    defaultLocalization: "en",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "PaperCore", targets: ["PaperCore"]),
        .library(name: "LibraryStore", targets: ["LibraryStore"]),
        .library(name: "Bibliography", targets: ["Bibliography"]),
        .library(name: "MetadataPipeline", targets: ["MetadataPipeline"]),
        .library(name: "InkEngine", targets: ["InkEngine"]),
        .library(name: "PDFReader", targets: ["PDFReader"]),
        .library(name: "PDFUpdate", targets: ["PDFUpdate"]),
        .library(name: "Importers", targets: ["Importers"]),
        .library(name: "Semantic", targets: ["Semantic"]),
    ],
    targets: [
        .executableTarget(
            name: "papertime-seed",
            dependencies: ["PaperCore", "LibraryStore", "MetadataPipeline", "Bibliography"],
            path: "Sources/Tools/papertime-seed"
        ),
        // What the incremental writer does to real papers, from outside the
        // app: `swift run -c release papertime-pdfcheck protocol <copy.pdf> <dir>`.
        .executableTarget(
            name: "papertime-pdfcheck",
            dependencies: ["InkEngine", "PDFReader", "PDFUpdate"],
            path: "Sources/Tools/papertime-pdfcheck"
        ),
        .executableTarget(
            name: "papertime-eval",
            dependencies: ["PaperCore", "MetadataPipeline", "Bibliography"],
            path: "Sources/Tools/papertime-eval"
        ),
        // The Latex Suite snippet file is shared with the Portable build, which
        // imports the same JSON; its licence travels with it.
        .target(name: "PaperCore", resources: [.process("Resources")]),
        .target(name: "LibraryStore", dependencies: ["PaperCore"]),
        .target(name: "Bibliography", dependencies: ["PaperCore"]),
        .target(name: "MetadataPipeline", dependencies: ["PaperCore", "Bibliography"]),
        .target(name: "InkEngine", dependencies: ["PaperCore"]),
        // Writes marks into a PDF as an incremental update, never by
        // re-serialising the paper. Foundation, zlib, CryptoKit and PDFKit
        // only, so it can be read and tested on its own.
        .target(name: "PDFUpdate"),
        .target(name: "PDFReader", dependencies: ["PaperCore", "InkEngine", "LibraryStore", "PDFUpdate"]),
        .target(name: "Importers", dependencies: ["PaperCore", "Bibliography", "LibraryStore"]),
        // Search by meaning. The model is committed compiled (.mlmodelc) and
        // copied as it is: `swift test` cannot compile a Core ML model, and a
        // model compiled on the reader's machine costs seconds on first use.
        .target(
            name: "Semantic",
            resources: [
                .copy("Resources/MiniLM-L6-v2.mlmodelc"),
                .copy("Resources/vocab.txt"),
                .copy("Resources/MiniLM-L6-v2-LICENSE.txt"),
            ]
        ),

        .testTarget(name: "PaperCoreTests", dependencies: ["PaperCore"], resources: [.copy("Fixtures")]),
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
        .testTarget(name: "PDFUpdateTests", dependencies: ["PDFUpdate"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SemanticTests", dependencies: ["Semantic"], resources: [.copy("Fixtures")]),
    ]
)
