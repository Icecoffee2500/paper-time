#if os(macOS) && canImport(OnnxRuntimeBindings)
import AppKit
import InkEngine
import PDFKit
import PDFReader
import PencilKit

/// Reading a lassoed rectangle that holds no glyphs to read — a scanned
/// page, handwritten notes, a formula pasted in as a picture.
///
/// Handwriting goes to the vision-language model when one is on this Mac
/// (`HandwritingModels`): it reads the words and the mathematics both.
/// Without one, the formula OCR reads what it can, which is printed
/// formulas; the first time that happens the toast says where the
/// handwriting model is.
enum PictureReading {
    enum Engine: Sendable { case handwriting, formula }

    struct Result: Sendable {
        /// What Ultracopy copies: words, `$…$`, `$$…$$` lines.
        var text: String
        var engine: Engine
        var seconds: Double
    }

    /// What is on the page that drawing the page does not draw: the ink and
    /// the shapes Paper Time keeps beside the file, which the reader lays
    /// over the page (`InkOverlayView`, `SketchOverlayView`) — the PDF's own
    /// copies of them are hidden under those. A formula written in the
    /// margin with the pen, on the iPad or here, is the handwriting most
    /// worth reading.
    struct Overlay {
        var ink: PKDrawing
        var sketch: [SketchElement]
    }

    /// The page's ink and shapes as the session has them.
    @MainActor
    static func overlay(of session: DocumentSession, page index: Int) -> Overlay {
        Overlay(ink: session.drawing(forPage: index), sketch: session.sketch(forPage: index))
    }

    /// Said once a run: there is a better reader for handwriting.
    @MainActor private static var offered = false

    @MainActor
    static func read(page: PDFPage, rect: CGRect, overlay: Overlay? = nil,
                     partial: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let picture = try picture(of: page, rect: rect, overlay: overlay)
        guard !FormulaOCR.isBlank(picture) else { throw FormulaOCR.Failure.nothingRead }
        if HandwritingReader.canRun, let directory = HandwritingModels.shared.readyDirectory {
            let reading = try await HandwritingReader.shared.read(picture, from: directory, partial: partial)
            return Result(text: reading.text, engine: .handwriting, seconds: reading.seconds)
        }
        let read = try await FormulaOCR.read(picture: picture)
        return Result(text: read.latex, engine: .formula, seconds: read.seconds)
    }

    /// The rectangle drawn three times its size, with room round it — a
    /// stroke pressed against the edge of the picture is read as half a
    /// letter — and the ink and shapes over the page.
    @MainActor
    static func picture(of page: PDFPage, rect: CGRect, overlay: Overlay?) throws -> CGImage {
        let padded = rect.insetBy(dx: -6, dy: -5)
        let scale: CGFloat = 3
        return try FormulaOCR.picture(of: page, rect: padded, scale: scale) { context in
            guard let overlay else { return }
            let toDisplay = page.transform(for: .cropBox)
            let drawn = padded.applying(toDisplay)
            if !overlay.ink.strokes.isEmpty {
                // PencilKit's space is the page as displayed, from the top.
                let height = PageGeometry(page: page).displaySize.height
                let region = CGRect(x: drawn.minX, y: height - drawn.maxY, width: drawn.width, height: drawn.height)
                // In the light: a black stroke is drawn white in the dark,
                // and the reader wants ink on paper.
                var image: NSImage?
                (NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                    image = overlay.ink.image(from: region, scale: scale)
                }
                if let strokes = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    context.draw(strokes, in: drawn)
                }
            }
            if !overlay.sketch.isEmpty {
                context.concatenate(toDisplay)
                SketchRenderer.draw(overlay.sketch, in: context, options: .init(rasterScale: scale))
            }
        }
    }

    /// The toast after a reading.
    @MainActor
    static func toast(after result: Result, copied: Bool) -> String {
        switch result.engine {
        case .handwriting:
            return copied
                ? L("손글씨를 읽어 복사했어요. 틀린 데가 있는지 봐주세요.", "Read the handwriting and copied it — check it over.")
                : L("손글씨를 읽었어요. 틀린 데가 있는지 봐주세요.", "Read the handwriting — check it over.")
        case .formula:
            let said = copied
                ? L("그림에서 읽어 복사했어요. 틀린 데가 있는지 봐주세요.", "Read off the picture and copied — check it over.")
                : L("그림에서 수식을 읽었어요. 틀린 데가 있는지 봐주세요.", "Read the formula off the picture — check it over.")
            guard HandwritingReader.canRun, !offered else { return said }
            offered = true
            return said + " " + L("손글씨는 설정 → 읽기에서 손글씨 모델을 받으면 더 잘 읽어요.",
                                  "For handwriting, get the handwriting model in Settings → Reading.")
        }
    }
}
#endif
