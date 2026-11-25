import SwiftUI

// Runs a copy or move in the background: progress, Cancel, and the question asked when a name already exists.
@MainActor
final class TransferCenter: ObservableObject {
    struct Prompt: Identifiable {
        let id = UUID()
        let name: String
        let place: String
        let more: Bool
    }
    struct Report {
        // Items handled (done or skipped) before the transfer ended; the rest weren't finished.
        var finished = 0
        var done = 0
        var skipped = 0
        var cancelled = false
        var stopped = false
        var failure: String?
    }
    @Published private(set) var running = false
    @Published private(set) var title = ""
    @Published private(set) var detail = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var prompt: Prompt? { didSet { asking = prompt != nil } }
    // Drives the question. Closing it without a choice stops; a tapped choice clears the prompt first,
    // so the check below finds nothing left to answer.
    @Published var asking = false {
        didSet {
            guard !asking, let id = prompt?.id else { return }
            Task { [weak self] in
                if let self, self.prompt?.id == id { self.choose(.stop, forAll: false) }
            }
        }
    }
    private var answer: CheckedContinuation<ConflictChoice, Never>?
    private var always: ConflictChoice?
    private var meter = TransferMeter()

    private var items: [Entry] = []
    private var position = 0
    private var total: Int64?
    private var verb = ""

    // homes gives the folder of items found by a search inside subfolders; other items come from origin.
    func start(_ items: [Entry], from origin: Location, homes: [String: Location] = [:], to destination: Location, move: Bool,
               finished: @escaping @MainActor (Report) -> Void) {
        guard !running, !items.isEmpty else { return }
        running = true
        always = nil
        meter = TransferMeter()
        self.items = items
        position = 0
        total = nil
        verb = move ? "Moving" : "Copying"
        title = "\(verb)…"
        detail = ""
        fraction = nil
        let meter = self.meter
        Task {
            var report = Report()
            total = await Self.planned(items, from: origin, homes: homes)
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.showProgress()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            for (index, item) in items.enumerated() {
                position = index
                showProgress()
                let more = index < items.count - 1
                let place = destination.title
                let hooks = TransferHooks(meter: meter, resolve: { [weak self] name in
                    await self?.ask(name, place: place, more: more) ?? .stop
                })
                do {
                    if try await Transfer.run(item, from: homes[item.id] ?? origin, to: destination, move: move, hooks: hooks) { report.done += 1 }
                    else { report.skipped += 1 }
                    report.finished = index + 1
                } catch is TransferStopped {
                    report.stopped = true
                    break
                } catch {
                    if meter.isCancelled || error is CancellationError { report.cancelled = true }
                    else { report.failure = error.localizedDescription }
                    break
                }
                if meter.isCancelled {
                    report.cancelled = true
                    break
                }
            }
            ticker.cancel()
            prompt = nil
            running = false
            finished(report)
        }
    }

    private static func planned(_ items: [Entry], from origin: Location, homes: [String: Location]) async -> Int64? {
        guard !homes.isEmpty else { return await Transfer.plannedBytes(items, from: origin) }
        var total: Int64 = 0
        for item in items {
            guard let bytes = await Transfer.plannedBytes([item], from: homes[item.id] ?? origin) else { return nil }
            total += bytes
        }
        return total
    }

    func cancel() {
        meter.cancel()
        choose(.stop, forAll: false)
    }

    func choose(_ choice: ConflictChoice, forAll: Bool) {
        if forAll { always = choice }
        prompt = nil
        let waiting = answer
        answer = nil
        waiting?.resume(returning: choice)
    }

    private func ask(_ name: String, place: String, more: Bool) async -> ConflictChoice {
        if let always { return always }
        if meter.isCancelled { return .stop }
        return await withCheckedContinuation { continuation in
            answer = continuation
            prompt = Prompt(name: name, place: place, more: more)
        }
    }

    private func showProgress() {
        guard running, !items.isEmpty else { return }
        let name = items[min(position, items.count - 1)].name
        title = items.count == 1 ? "\(verb) \(name)" : "\(verb) \(position + 1) of \(items.count) · \(name)"
        let bytes = meter.bytes
        let size = { (value: Int64) in ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
        if let total, total > 0 {
            let part = min(Double(bytes) / Double(total), 1)
            fraction = part
            detail = "\(size(min(bytes, total))) of \(size(total)) · \(Int(part * 100))%"
        } else {
            fraction = items.count > 1 ? Double(position) / Double(items.count) : nil
            detail = bytes > 0 ? size(bytes) : ""
        }
    }
}

// The bar under the panes while a transfer runs.
struct TransferBar: View {
    @ObservedObject var center: TransferCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(center.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel", role: .destructive) { center.cancel() }.accessibilityIdentifier("transfer-cancel")
            }
            if let fraction = center.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            if !center.detail.isEmpty { Text(center.detail).foregroundStyle(.secondary) }
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer-bar")
    }
}

// Asks once per name that already exists; the "all" choices answer the rest of the transfer.
struct ConflictQuestion: ViewModifier {
    @ObservedObject var center: TransferCenter
    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Name already exists",
            isPresented: $center.asking,
            titleVisibility: .visible, presenting: center.prompt
        ) { prompt in
            Button("Replace") { center.choose(.replace, forAll: false) }
            Button("Keep both") { center.choose(.keepBoth, forAll: false) }
            Button("Skip") { center.choose(.skip, forAll: false) }
            if prompt.more {
                Button("Replace all") { center.choose(.replace, forAll: true) }
                Button("Keep both for all") { center.choose(.keepBoth, forAll: true) }
                Button("Skip all") { center.choose(.skip, forAll: true) }
            }
            Button("Stop", role: .cancel) { center.choose(.stop, forAll: false) }
        } message: { prompt in
            Text("“\(prompt.name)” already exists in \(prompt.place). Replace overwrites it; Keep both adds a number to the new copy.")
        }
    }
}

extension View {
    func conflictQuestion(_ center: TransferCenter) -> some View { modifier(ConflictQuestion(center: center)) }
}
