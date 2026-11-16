#if os(macOS)
import SwiftUI
import WebKit

/// The reading plans, shown the way the page shows them: the working window
/// out of `Website/plans-demo.js`, in About.
///
/// A web view rather than a SwiftUI demonstration, on purpose and once: this
/// is the window that was drawn to decide what the feature would be, and the
/// person who decided asked for that window here as it is. It is the same
/// file the page and the Portable build's About load (`project.yml` puts it in
/// the bundle straight from `Website/`), so the three cannot drift. It needs
/// nothing from the network — the page, its sheet and its script are one
/// string handed to the web view — and it draws at 900 points and is shown
/// smaller in a narrower pane, so the sidebar, the plan and the inspector all
/// stay in it.
struct PlansDemoSection: View {
    @State private var height: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)
            Text(L("읽기 계획", "Reading Plans"))
                .font(.headline)
            Text(L(
                "한 계열의 논문을 모아 차례와 날짜를 정하고, 발표 자료와 코드를 논문 옆에 붙여 둬요. 아래 창을 직접 누르고 끌어 봐도 돼요.",
                "Gather a line of papers, give them an order and days to read them, and keep the slides and the code beside each one. The window below works — click it, drag in it."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            PlansDemoWebView(height: $height)
                .frame(height: height)
                .padding(.top, 4)
        }
    }
}

/// The web view, as tall as the demonstration says it is.
struct PlansDemoWebView: NSViewRepresentable {
    @Binding var height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> PlansDemo.Receiver {
        PlansDemo.Receiver { value in height = value }
    }

    func makeNSView(context: Context) -> WKWebView {
        let theme = colorScheme == .dark ? "dark" : "light"
        context.coordinator.theme = theme
        context.coordinator.korean = Language.prefersKorean
        return PlansDemo.makeWebView(theme: theme, receiver: context.coordinator)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let receiver = context.coordinator
        receiver.onHeight = { value in height = value }
        // The language: the page is a string in one language, so a new one
        // is a new page.
        if receiver.korean != Language.prefersKorean {
            receiver.korean = Language.prefersKorean
            view.loadHTMLString(PlansDemo.page(theme: receiver.theme), baseURL: nil)
        }
        // The appearance, followed in place — a reload would lose whatever
        // somebody had moved on the calendar.
        let theme = colorScheme == .dark ? "dark" : "light"
        if receiver.theme != theme {
            receiver.theme = theme
            view.evaluateJavaScript("window.__plansDemo && window.__plansDemo.setTheme('\(theme)')")
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: PlansDemo.Receiver) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: PlansDemo.channel)
    }
}

@MainActor
enum PlansDemo {
    /// The name the page posts its height under.
    static let channel = "plansDemo"
    /// The width the window is drawn at; a narrower view shows it smaller.
    static let designWidth = 900

    /// The demonstration's own sheet and script, out of the bundle.
    static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    /// Whether the bundle has the demonstration at all.
    static var isBundled: Bool {
        Bundle.main.url(forResource: "plans-demo", withExtension: "js") != nil
    }

    /// The page, whole: one string, so the web view loads nothing. In the
    /// app's language unless a probe asks for the other one.
    static func page(theme: String, lang asked: String? = nil) -> String {
        let lang = asked ?? (Language.prefersKorean ? "ko" : "en")
        let css = resource("plans-demo", "css")
        let js = resource("plans-demo", "js")
        return """
        <!doctype html>
        <html lang="\(lang)">
        <head>
        <meta charset="utf-8">
        <style id="ptp-css">\(css)</style>
        <style>html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }</style>
        </head>
        <body>
        <div id="demo"></div>
        <script>\(js)</script>
        <script>
        window.__plansDemo = window.PlansDemo && PlansDemo.mount(document.getElementById('demo'), {
          lang: '\(lang)', theme: '\(theme)', fit: \(designWidth),
          parts: ['tour', 'window', 'fine', 'howto'],
          onHeight: function (h) { window.webkit.messageHandlers.\(channel).postMessage(h); }
        });
        </script>
        </body>
        </html>
        """
    }

    /// A web view with the page in it, telling `receiver` how tall it is.
    static func makeWebView(theme: String, lang: String? = nil, receiver: Receiver) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(receiver, name: channel)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 640), configuration: configuration)
        view.navigationDelegate = receiver
        // Over the pane's own panel, not on a white page of its own.
        if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            view.setValue(false, forKey: "drawsBackground")
        }
        view.allowsMagnification = false
        view.loadHTMLString(page(theme: theme, lang: lang), baseURL: nil)
        return view
    }

    /// Hears the height and keeps the web view on its one page.
    @MainActor
    final class Receiver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onHeight: (CGFloat) -> Void
        var theme = "light"
        var korean = true
        private(set) var lastHeight: CGFloat = 0

        init(onHeight: @escaping (CGFloat) -> Void) {
            self.onHeight = onHeight
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == PlansDemo.channel, let number = message.body as? NSNumber else { return }
            let value = CGFloat(truncating: number)
            guard value > 0, value != lastHeight else { return }
            lastHeight = value
            onHeight(value)
        }

        /// Nothing in the demonstration goes anywhere: the page it was loaded
        /// with is the only one it shows.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .other ? .allow : .cancel
        }
    }
}

/// The demonstration drawn without a hand on the keyboard.
///
/// `--papertime-plans-demo=<png in the container>` loads it in a web view in
/// a window of the probe's own, on no display (`WindowProbe.ownWindow`), at
/// the width About gives it, and writes what the page reports — whether the
/// script came out of the bundle and ran, how much smaller it is drawn, its
/// height, theme and language — then the picture. `…-step=<0–5>` presses that
/// step of the tour first, `…-theme=dark` draws it dark, `…-lang=en|ko` sets
/// the demo's language (not the app's), `…-quit=1` quits.
/// No event is posted to the system, and Settings — whose off-screen probe
/// loops on this macOS — is not opened.
@MainActor
enum PlansDemoProbe {
    private static var keep: [AnyObject] = []

    static func runIfAsked() {
        guard let path = Boot.setting("PAPERTIME_PLANS_DEMO") else { return }
        func say(_ text: String) { FileHandle.standardError.write(Data(("plans demo: " + text + "\n").utf8)) }
        guard Boot.isSet("PAPERTIME_LIBRARY") else { return say("refused — not the test library") }
        Task { @MainActor in
            say("bundled \(PlansDemo.isBundled), js \(PlansDemo.resource("plans-demo", "js").count) chars, css \(PlansDemo.resource("plans-demo", "css").count) chars")
            let width: CGFloat = 760
            let window = WindowProbe.ownWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 1400), styleMask: [.borderless]
            )
            guard !WindowProbe.isOnAScreen(window) else { return say("refused — its window would be on a display") }
            let theme = Boot.setting("PAPERTIME_PLANS_DEMO_THEME") == "dark" ? "dark" : "light"
            if theme == "dark" { window.appearance = NSAppearance(named: .darkAqua) }
            var heights: [CGFloat] = []
            let receiver = PlansDemo.Receiver { heights.append($0) }
            // The demo's own language only — the app's is the person's
            // setting, and a probe writes no settings.
            let lang = Boot.setting("PAPERTIME_PLANS_DEMO_LANG").flatMap { $0 == "en" || $0 == "ko" ? $0 : nil }
            let view = PlansDemo.makeWebView(theme: theme, lang: lang, receiver: receiver)
            keep = [window, receiver, view]
            view.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
            window.contentView = view
            window.orderFront(nil)
            if WindowProbe.isOnAScreen(window) {
                window.orderOut(nil)
                return say("the window landed on a display at \(window.frame) — put away")
            }
            try? await Task.sleep(for: .seconds(2))
            if let step = Boot.setting("PAPERTIME_PLANS_DEMO_STEP").flatMap(Int.init) {
                // Something to hand back: a script that answers nothing is one
                // the async call has been known to trip over.
                _ = try? await view.evaluateJavaScript("(window.__plansDemo && window.__plansDemo.step(\(step)), 'ok')")
                try? await Task.sleep(for: .seconds(1.4))
            }
            let report = """
            (() => {
              const box = document.getElementById('demo').firstElementChild;
              const app = box && box.shadowRoot && box.shadowRoot.querySelector('.ptp');
              const pop = app && app.querySelector('#ptp-pop');
              return JSON.stringify({
                script: typeof PlansDemo, mounted: !!app, transform: app ? app.style.transform : null,
                frameHeight: box ? box.style.height : null, theme: app ? app.dataset.theme : null, lang: app ? app.lang : null,
                rows: app ? app.querySelectorAll('.row').length : 0, popOpen: pop ? !pop.hidden : false,
                width: innerWidth
              });
            })()
            """
            let answer = (try? await view.evaluateJavaScript(report)) as? String ?? "no answer"
            say("page \(answer); heights \(heights.map { Int($0) })")
            if let last = heights.last {
                view.frame.size.height = last
                window.setContentSize(NSSize(width: width, height: last))
                try? await Task.sleep(for: .seconds(0.8))
            }
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            if let image = try? await view.takeSnapshot(configuration: configuration),
               let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                say("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
            } else {
                say("no snapshot")
            }
            // The page as the web process lays it out, whatever the window
            // server made of a window on no display.
            if let pdf = try? await view.pdf(configuration: WKPDFConfiguration()) {
                let pdfPath = (path as NSString).deletingPathExtension + ".pdf"
                try? pdf.write(to: URL(fileURLWithPath: pdfPath))
                say("wrote \(pdfPath)")
            }
            window.orderOut(nil)
            if Boot.isSet("PAPERTIME_PLANS_DEMO_QUIT") { NSApp.terminate(nil) }
        }
    }
}
#endif
