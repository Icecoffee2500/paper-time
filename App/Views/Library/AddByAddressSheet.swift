import LibraryStore
import PaperCore
import SwiftUI

/// «Add Paper by Address…»: one field, and what came of it.
///
/// The sheet stays up while the paper is fetched and says what it is doing,
/// because a field that closes on Return and a notice that comes ten seconds
/// later is a press that did nothing. When the address gave no paper, the
/// reason stands under the field and the field keeps what was typed, so a
/// mistyped identifier is fixed rather than typed again. The Portable build
/// has the same sheet (`ui/addByAddress.ts`).
struct AddByAddressSheet: View {
    let model: LibraryModel
    /// Closing is done by putting the request back (`AttachSheet` says why).
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var busy = false
    @State private var failure: PaperFetcher.Failure?
    /// What the network said, shown with the failure: a reader whose
    /// company proxy turns the lookup away sees «OpenAlex HTTP 403», not
    /// «try again in a moment».
    @State private var detail: String?
    @FocusState private var fieldFocused: Bool

    private var address: PaperAddress? { PaperAddress.read(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("주소로 논문 더하기", "Add Paper by Address"))
                .font(.title2.weight(.semibold))
            TextField(L("arXiv 번호나 주소, DOI, PDF 주소", "arXiv number or address, DOI, or PDF address"), text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .disabled(busy)
                .onSubmit { Task { await add() } }
                .onChange(of: text) { failure = nil; detail = nil }
            Text(L(
                "예: 2512.11732, https://arxiv.org/abs/2512.11732, 10.1145/3292500.3330701, 논문 PDF의 주소. DOI는 열린 사본이 있거나 이 네트워크가 구독 중일 때 받아져요.",
                "For example 2512.11732, https://arxiv.org/abs/2512.11732, 10.1145/3292500.3330701, or the address of a PDF. A DOI is fetched when an open copy exists or this network has a subscription."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(L("받는 중…", "Fetching…")).foregroundStyle(.secondary)
                } else if let failure {
                    Text(Self.whyNoPaper(failure, detail: detail)).foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if !text.isEmpty, address == nil {
                    Text(Self.whyNoPaper(.notAnAddress)).foregroundStyle(.red)
                }
            }
            .font(.footnote)
            .frame(minHeight: 18, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("취소", "Cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(L("더하기", "Add")) { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || address == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            fieldFocused = true
            // The clipboard's address, when it holds one: the usual way here
            // is to copy the address from a browser and come to Paper Time.
            #if os(macOS)
            if text.isEmpty, let held = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               held.count < 400, PaperAddress.read(held) != nil {
                text = held
            }
            #endif
        }
    }

    private func add() async {
        guard !busy, address != nil else { return }
        busy = true
        failure = nil
        detail = nil
        let outcome = await model.addPaper(byAddress: text, keepFile: !app.settings.keepsPDFsInMemory)
        busy = false
        switch outcome {
        case let .added(paper):
            close()
            model.selectedPaperID = paper.id
        case let .already(paper):
            close()
            model.selectedPaperID = paper.id
        case let .failed(why, said):
            failure = why
            detail = said
            fieldFocused = true
        }
    }

    /// Why there is no paper, in the app's words — with what the network
    /// said when that is the whole story (`failed`, `offline`). The Portable
    /// build's `whyNoPaper` says the same.
    static func whyNoPaper(_ why: PaperFetcher.Failure, detail: String? = nil) -> String {
        let said = detail.map { "(\($0.prefix(120)))" }
        switch why {
        case .notAnAddress:
            return L("논문 주소가 아니에요. arXiv 번호나 주소, DOI, PDF 주소를 넣어주세요.", "That is not a paper address. Enter an arXiv number or address, a DOI, or the address of a PDF.")
        case .noPDF:
            return L("열린 PDF가 없는 논문이에요. 브라우저에서 받은 PDF를 Paper Time에 끌어다 놓거나, 그 PDF의 주소를 넣어주세요.", "This paper has no open PDF. Drop the PDF from your browser onto Paper Time, or enter the PDF's address.")
        case .notFound:
            return L("이 주소에는 아무것도 없어요.", "There is nothing at this address.")
        case .offline:
            return [L("인터넷에 닿지 않아요.", "Paper Time can't reach the internet."), said].compactMap { $0 }.joined(separator: " ")
        case .tooLarge:
            return L("파일이 너무 커요.", "The file is too large.")
        case .failed:
            return [
                L("받지 못했어요.", "Paper Time couldn't fetch it."), said,
                L("네트워크가 막고 있다면 PDF 주소를 직접 넣어주세요.", "If the network is in the way, enter the PDF's address instead."),
            ].compactMap { $0 }.joined(separator: " ")
        }
    }
}
