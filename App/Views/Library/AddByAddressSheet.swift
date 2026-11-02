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
                .onChange(of: text) { failure = nil }
            Text(L(
                "예: 2512.11732, https://arxiv.org/abs/2512.11732, 10.1145/3292500.3330701, 논문 PDF의 주소. DOI는 열린 사본이 있을 때만 받아져요.",
                "For example 2512.11732, https://arxiv.org/abs/2512.11732, 10.1145/3292500.3330701, or the address of a PDF. A DOI is fetched when an open copy exists."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(L("받는 중…", "Fetching…")).foregroundStyle(.secondary)
                } else if let failure {
                    Text(Self.whyNoPaper(failure)).foregroundStyle(.red)
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
        let outcome = await model.addPaper(byAddress: text, keepFile: !app.settings.keepsPDFsInMemory)
        busy = false
        switch outcome {
        case let .added(paper):
            close()
            model.selectedPaperID = paper.id
        case let .already(paper):
            close()
            model.selectedPaperID = paper.id
        case let .failed(why):
            failure = why
            fieldFocused = true
        }
    }

    static func whyNoPaper(_ why: PaperFetcher.Failure) -> String {
        switch why {
        case .notAnAddress:
            L("논문 주소가 아니에요. arXiv 번호나 주소, DOI, PDF 주소를 넣어주세요.", "That is not a paper address. Enter an arXiv number or address, a DOI, or the address of a PDF.")
        case .noPDF:
            L("이 주소에서 열린 PDF를 찾지 못했어요. 출판사 페이지만 있는 논문은 받을 수 없어요.", "Paper Time couldn't find an open PDF at this address. A paper that only has a publisher's page can't be fetched.")
        case .notFound:
            L("이 주소에는 아무것도 없어요.", "There is nothing at this address.")
        case .offline:
            L("인터넷에 닿지 않아요.", "Paper Time can't reach the internet.")
        case .tooLarge:
            L("파일이 너무 커요.", "The file is too large.")
        case .failed:
            L("받지 못했어요. 잠시 뒤에 다시 해보세요.", "Paper Time couldn't fetch it. Try again in a moment.")
        }
    }
}
