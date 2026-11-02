import Testing
@testable import InkEngine

/// The numbers Portable's `src/test/marks.ts` holds `highlightInk` and
/// `highlightBand` to — one palette on both desktops.
@Suite("A highlight's ink and band")
struct HighlightToneTests {
    private func round(_ c: HighlightTone.RGB) -> [Double] {
        [c.red, c.green, c.blue].map { (Double($0) * 1000).rounded() / 1000 }
    }

    @Test("the five inks, light and dark, and the band most of the way to white")
    func tones() {
        #expect(round(HighlightTone.ink(MarkupColor.yellow.rgb)) == [0.78, 0.5, 0.02])
        #expect(round(HighlightTone.ink(MarkupColor.pink.rgb)) == [0.84, 0.18, 0.33])
        #expect(round(HighlightTone.inkOnDark(MarkupColor.pink.rgb)) == [1, 0.5, 0.62])
        #expect(round(HighlightTone.inkOnDark(MarkupColor.yellow.rgb)) == [0.98, 0.76, 0.28])
        // Another reader's colour goes by the nearest of the five.
        #expect(round(HighlightTone.ink(HighlightTone.RGB(red: 0.4, green: 0.7, blue: 1))) == [0.12, 0.44, 0.85])
        #expect(round(HighlightTone.band(MarkupColor.pink.rgb)) == [0.998, 0.912, 0.932])
        #expect(round(HighlightTone.band(MarkupColor.pink.rgb, hovered: true)) == [0.999, 0.947, 0.959])
    }
}
