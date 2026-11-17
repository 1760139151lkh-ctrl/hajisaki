import SwiftUI
import UIKit

/// One native viewport owns reuse, self-sizing and the reading position.
/// Rich blocks keep their existing SwiftUI/TextKit/WebKit implementations.
@MainActor
struct ConversationList<Content: View>: UIViewRepresentable {
    let rows: [ConversationRow]
    @Binding var followsLatest: Bool
    let layoutRevision: Int
    let palette: TheaterPalette
    let content: (ConversationRow) -> Content

    init(rows: [ConversationRow], followsLatest: Binding<Bool>, layoutRevision: Int,
         palette: TheaterPalette, @ViewBuilder content: @escaping (ConversationRow) -> Content) {
        self.rows = rows
        _followsLatest = followsLatest
        self.layoutRevision = layoutRevision
        self.palette = palette
        self.content = content
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ConversationTableView {
        let table = ConversationTableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 100
        table.selfSizingInvalidation = .enabledIncludingConstraints
        table.sectionHeaderTopPadding = 0
        table.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)
        table.contentInsetAdjustmentBehavior = .never
        table.insetsContentViewsToSafeArea = false
        table.cellLayoutMarginsFollowReadableWidth = false
        table.keyboardDismissMode = .interactive
        table.alwaysBounceVertical = true
        table.allowsSelection = false
        table.register(ConversationHostingCell.self, forCellReuseIdentifier: "MessageBlock")
        context.coordinator.attach(table)
        return table
    }

    func updateUIView(_ table: ConversationTableView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ table: ConversationTableView, coordinator: Coordinator) {
        table.didLayout = nil
        table.didChangeWidth = nil
        table.delegate = nil
        table.dataSource = nil
        coordinator.dataSource = nil
        coordinator.table = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDelegate {
        var parent: ConversationList
        weak var table: ConversationTableView?
        var dataSource: UITableViewDiffableDataSource<Int, String>?
        private var rowsByID: [String: ConversationRow] = [:]
        private var currentIDs: [String] = []
        private var applying = false
        private var updatePending = false
        private var layoutPending = false
        private var adjusting = false
        private var remeasurePending = false
        private var remeasuring = false
        private var needsBottomTarget = true
        private var previouslyFollowing = true
        private var readingAnchor: (id: String, offset: CGFloat)?

        init(_ parent: ConversationList) { self.parent = parent }

        func attach(_ table: ConversationTableView) {
            self.table = table
            table.delegate = self
            table.didLayout = { [weak self] in self?.settlePosition() }
            table.didChangeWidth = { [weak self] in self?.remeasurePending = true; self?.requestLayout() }
            dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) { [weak self] table, path, identifier in
                guard let self, let row = self.rowsByID[identifier] else { return nil }
                let cell = table.dequeueReusableCell(withIdentifier: "MessageBlock", for: path)
                self.configure(cell, row: row)
                return cell
            }
        }

        func update(_ parent: ConversationList) {
            if self.parent.layoutRevision != parent.layoutRevision { remeasurePending = true }
            if previouslyFollowing && !parent.followsLatest { captureReadingAnchor() }
            if !previouslyFollowing && parent.followsLatest {
                readingAnchor = nil
                needsBottomTarget = true
            }
            previouslyFollowing = parent.followsLatest
            self.parent = parent
            // A pending snapshot can still ask for an older block before its
            // replacement is installed. Retain that source until completion.
            for row in parent.rows { rowsByID[row.id] = row }
            render()
        }

        private func render() {
            guard let dataSource else { return }
            if applying { updatePending = true; return }
            let identifiers = parent.rows.map(\.id)
            if identifiers != currentIDs {
                currentIDs = identifiers
                if parent.followsLatest { needsBottomTarget = true }
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(identifiers)
                applying = true
                dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                    guard let self else { return }
                    self.applying = false
                    self.remeasurePending = true
                    self.pruneRows()
                    self.refreshVisibleCells()
                    self.requestLayout()
                    if self.updatePending { self.updatePending = false; self.render() }
                }
            } else {
                pruneRows()
                refreshVisibleCells()
                requestLayout()
            }
        }

        private func pruneRows() {
            let needed = Set(currentIDs).union(parent.rows.map(\.id))
            rowsByID = rowsByID.filter { needed.contains($0.key) }
        }

        private func configure(_ cell: UITableViewCell, row: ConversationRow) {
            guard let cell = cell as? ConversationHostingCell else { return }
            cell.backgroundColor = .clear
            cell.backgroundConfiguration = .clear()
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = row.id
            if cell.rowID == row.id, let model = cell.rowModel as? ConversationCellModel<Content> {
                model.content = parent.content(row)
                model.palette = parent.palette
            } else {
                let model = ConversationCellModel(content: parent.content(row), palette: parent.palette)
                cell.rowID = row.id
                cell.rowModel = model
                cell.contentConfiguration = UIHostingConfiguration {
                    ConversationCellContent(model: model).id(row.id)
                }.margins(.all, 0).minSize(width: 0, height: 0)
            }
        }

        private func refreshVisibleCells() {
            guard let table, let dataSource else { return }
            for path in table.indexPathsForVisibleRows ?? [] {
                guard let identifier = dataSource.itemIdentifier(for: path),
                      let row = rowsByID[identifier], let cell = table.cellForRow(at: path) else { continue }
                configure(cell, row: row)
            }
        }

        private func requestLayout() {
            guard !layoutPending else { return }
            layoutPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layoutPending = false
                if let table = self.table, self.remeasurePending, !self.applying,
                   table.window != nil, !table.isTracking, !table.isDragging, !table.isDecelerating {
                    self.remeasurePending = false
                    self.remeasuring = true
                    UIView.performWithoutAnimation { table.beginUpdates(); table.endUpdates() }
                    self.remeasuring = false
                }
                self.table?.setNeedsLayout()
                self.table?.layoutIfNeeded()
                self.settlePosition()
            }
        }

        fileprivate func settlePosition() {
            guard let table, table.window != nil, table.bounds.height > 1,
                  !applying, !remeasuring, !adjusting, !table.isTracking, !table.isDragging, !table.isDecelerating else { return }
            adjusting = true
            defer { adjusting = false }
            if parent.followsLatest {
                if needsBottomTarget, !currentIDs.isEmpty {
                    needsBottomTarget = false
                    table.scrollToRow(at: IndexPath(row: currentIDs.count - 1, section: 0), at: .bottom, animated: false)
                }
                let bottom = max(-table.adjustedContentInset.top,
                    table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
                setOffset(CGPoint(x: 0, y: bottom), in: table)
            } else if let readingAnchor, let path = dataSource?.indexPath(for: readingAnchor.id) {
                if table.indexPathsForVisibleRows?.contains(path) != true {
                    table.scrollToRow(at: path, at: .top, animated: false)
                }
                let rect = table.rectForRow(at: path)
                let offset = min(readingAnchor.offset, max(0, rect.height - 1))
                let desired = rect.minY + offset
                let bottom = max(-table.adjustedContentInset.top,
                    table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
                setOffset(CGPoint(x: 0, y: min(bottom, max(-table.adjustedContentInset.top, desired))), in: table)
            }
        }

        private func setOffset(_ target: CGPoint, in table: UITableView) {
            guard abs(table.contentOffset.x - target.x) > 0.5 || abs(table.contentOffset.y - target.y) > 0.5 else { return }
            table.setContentOffset(target, animated: false)
        }

        private func captureReadingAnchor() {
            guard let table, let dataSource else { return }
            let top = table.contentOffset.y + table.adjustedContentInset.top
            let paths = (table.indexPathsForVisibleRows ?? []).sorted().filter {
                let rect = table.rectForRow(at: $0)
                return rect.height > 1 && rect.maxY > top && rect.minY < table.contentOffset.y + table.bounds.height
            }
            guard let path = paths.first(where: { table.rectForRow(at: $0).minY >= top - 1 }) ?? paths.first,
                  let identifier = dataSource.itemIdentifier(for: path) else { return }
            readingAnchor = (identifier, table.contentOffset.y - table.rectForRow(at: path).minY)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            captureReadingAnchor()
            parent.followsLatest = false
            previouslyFollowing = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !adjusting && !remeasuring && table?.isPerformingLayout != true && !parent.followsLatest &&
                (scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || readingAnchor == nil) {
                captureReadingAnchor()
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            captureReadingAnchor()
            if !decelerate { requestLayout() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            captureReadingAnchor()
            requestLayout()
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            readingAnchor = nil
            parent.followsLatest = false
            previouslyFollowing = false
            return true
        }
    }
}

@MainActor
private final class ConversationCellModel<Content: View>: ObservableObject {
    @Published var content: Content
    @Published var palette: TheaterPalette
    init(content: Content, palette: TheaterPalette) {
        self.content = content
        self.palette = palette
    }
}

private struct ConversationCellContent<Content: View>: View {
    @ObservedObject var model: ConversationCellModel<Content>
    var body: some View { model.content.environment(\.theaterPalette, model.palette) }
}

private final class ConversationHostingCell: UITableViewCell {
    var rowID: String?
    var rowModel: AnyObject?
    override func prepareForReuse() {
        super.prepareForReuse()
        rowID = nil
        rowModel = nil
        contentConfiguration = nil
    }
}

final class ConversationTableView: UITableView {
    private(set) var isPerformingLayout = false
    var didLayout: (() -> Void)?
    var didChangeWidth: (() -> Void)?
    private var measuredWidth: CGFloat = 0
    override func layoutSubviews() {
        isPerformingLayout = true
        super.layoutSubviews()
        let widthChanged = abs(measuredWidth - bounds.width) > 0.5
        measuredWidth = bounds.width
        isPerformingLayout = false
        if widthChanged { didChangeWidth?() }
        didLayout?()
    }
}
