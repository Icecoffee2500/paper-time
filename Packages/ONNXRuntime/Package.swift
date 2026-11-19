// swift-tools-version:5.9
//
// ONNX Runtime for the formula lasso's OCR (App/Model/FormulaOCR.swift).
//
// The Objective-C bindings come from Microsoft's Swift package,
// github.com/microsoft/onnxruntime-swift-package-manager — tag 1.24.2,
// commit b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2, MIT (LICENSE beside this
// file). That repository was gone from GitHub by 2026-11-18 («Repository not
// found»), and a fresh checkout stopped before it built anything, so the
// bindings live here now: `objectivec/` as it was, less the tests, the docs
// and the training API, which the app does not use.
//
// The runtime itself is not here: it is Microsoft's prebuilt static
// framework, fetched by SwiftPM from download.onnxruntime.ai and checked
// against the checksum below — the same file the package fetched. Should
// that address go too, point `ORT_POD_LOCAL_PATH` at a copy of the zip (or
// of the xcframework inside it) and the build uses that instead.

import PackageDescription
import class Foundation.ProcessInfo

let package = Package(
    name: "ONNXRuntime",
    platforms: [.iOS(.v15), .macOS(.v14)],
    products: [
        .library(name: "onnxruntime", type: .static, targets: ["OnnxRuntimeBindings"]),
    ],
    targets: [
        .target(
            name: "OnnxRuntimeBindings",
            dependencies: ["onnxruntime"],
            path: "objectivec",
            cxxSettings: [.define("SPM_BUILD")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

if let local = ProcessInfo.processInfo.environment["ORT_POD_LOCAL_PATH"] {
    package.targets.append(.binaryTarget(name: "onnxruntime", path: local))
} else {
    package.targets.append(.binaryTarget(
        name: "onnxruntime",
        url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip",
        checksum: "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
    ))
}
