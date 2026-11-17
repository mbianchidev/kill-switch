import SwiftUI
import TableQueryCore

struct TableSearchControls<Row>: View {
    @Binding var search: String
    let fields: [TableField<Row>]
    var prompt = "Search text or field > value"
    var resetAdditional: (() -> Void)?
    @State private var showFilter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                TextField(prompt, text: $search)
                    .textFieldStyle(.roundedBorder)
                    .help("Search identifying text, or compare other fields using field > value. AND separates clauses. Filters update as you type.")
                Button { showFilter = true } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                    .disabled(fields.isEmpty)
                    .popover(isPresented: $showFilter) {
                        TableFilterEditor(fields: fields, search: $search) { showFilter = false }
                    }
                Button("Reset filters") {
                    search = ""
                    resetAdditional?()
                }
                .help("Clear search comparisons and restore this table's predefined filters")
            }
            if let error = TableQuery(search: search, fields: fields).error {
                TableQueryErrorLabel(message: error)
            }
        }
        .controlSize(.small)
    }
}

struct TableQueryErrorLabel: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundColor(.orange)
            .textSelection(.enabled)
    }
}

private struct TableFilterEditor<Row>: View {
    let fields: [TableField<Row>]
    @Binding var search: String
    let close: () -> Void
    @State private var fieldID: String
    @State private var operation: String
    @State private var value = ""
    @FocusState private var valueFocused: Bool

    init(fields: [TableField<Row>], search: Binding<String>, close: @escaping () -> Void) {
        self.fields = fields
        _search = search
        self.close = close
        _fieldID = State(initialValue: fields.first?.id ?? "")
        _operation = State(initialValue: Self.defaultOperation(fields.first?.kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a filter").font(.headline)
            Picker("Field", selection: $fieldID) {
                ForEach(fields) { Text($0.title).tag($0.id) }
            }
            if let field {
                Picker("Comparison", selection: $operation) {
                    ForEach(operations(for: field.kind), id: \.self) { Text(operationLabel($0)).tag($0) }
                }
                HStack {
                    TextField(valueHint(field.kind), text: $value)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filter value")
                        .focused($valueFocused)
                    if !field.predefinedValues.isEmpty {
                        Menu("Values") {
                            ForEach(field.predefinedValues, id: \.self) { preset in
                                Button(preset) { value = preset }
                            }
                        }
                        .fixedSize()
                    }
                }
                if !value.isEmpty, let error = candidateQuery.error { TableQueryErrorLabel(message: error) }
                Text("Filters combine with search and other filters. Reset filters clears them.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          candidateQuery.error == nil else { return }
                    search = candidate
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || candidateQuery.error != nil)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { valueFocused = true }
        .onChange(of: fieldID) { _ in
            operation = Self.defaultOperation(field?.kind)
            value = ""
        }
    }

    private var field: TableField<Row>? { fields.first { $0.id == fieldID } }
    private var candidate: String {
        guard let field else { return search }
        let clause = TableFilterSyntax.comparison(field: field, operation: operation, value: value)
        return TableFilterSyntax.appending(clause, to: search)
    }
    private var candidateQuery: TableQuery<Row> { TableQuery(search: candidate, fields: fields) }

    private static func defaultOperation(_ kind: TableFieldKind?) -> String {
        switch kind {
        case .text: return ":"
        case .number: return ">"
        default: return "="
        }
    }

    private func operations(for kind: TableFieldKind) -> [String] {
        switch kind {
        case .text: return [":", "=", "!=", ">", ">=", "<", "<="]
        case .boolean: return ["=", "!="]
        default: return ["=", "!=", ">", ">=", "<", "<="]
        }
    }

    private func operationLabel(_ operation: String) -> String {
        switch operation {
        case ":": return "Contains"
        case "=": return "Equals"
        case "!=": return "Does not equal"
        case ">": return "Greater than / after"
        case ">=": return "At least / on or after"
        case "<": return "Less than / before"
        default: return "At most / on or before"
        }
    }

    private func valueHint(_ kind: TableFieldKind) -> String {
        switch kind {
        case .text: return "Text or a predefined value"
        case .boolean: return "Yes or No"
        case .date: return "YYYY-MM-DD or ISO timestamp (UTC)"
        case let .number(unit):
            switch unit {
            case .count: return "Number, for example 40"
            case .percent: return "Percent, for example 40%"
            case .bytes: return "Size, for example 1GB"
            case .bytesPerSecond: return "Rate, for example 1MB/s"
            case .seconds: return "Duration, for example 5m"
            }
        }
    }
}

struct TableSortControls<Row>: View {
    let fields: [TableField<Row>]
    @Binding var sorting: TableComparator<Row>

    var body: some View {
        HStack(spacing: 6) {
            Picker("Sort", selection: $sorting) {
                ForEach(fields) { field in
                    Text(field.title).tag(TableComparator(field: field, order: sorting.order))
                }
            }
            .frame(width: 160)
            Button { sorting.ascending.toggle() } label: {
                Label(direction, systemImage: sorting.ascending ? "arrow.up" : "arrow.down")
            }
            .help("Reverse the sort direction for \(sorting.field.title)")
            .accessibilityLabel("Sort \(sorting.field.title): \(direction). Reverse direction.")
        }
        .controlSize(.small)
    }

    private var direction: String {
        switch sorting.field.kind {
        case .text: return sorting.ascending ? "A-Z" : "Z-A"
        case .date: return sorting.ascending ? "Old-new" : "New-old"
        case .boolean: return sorting.ascending ? "No-yes" : "Yes-no"
        case .number: return sorting.ascending ? "Low-high" : "High-low"
        }
    }
}

struct TableSortHeader<Row>: View {
    let field: TableField<Row>
    @Binding var sorting: TableComparator<Row>
    var title: String?
    var alignment: Alignment = .leading

    var body: some View {
        Button { sorting.select(field) } label: {
            HStack(spacing: 4) {
                Text(title ?? field.title).lineLimit(1)
                if sorting.field.id == field.id {
                    Image(systemName: sorting.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.borderless)
        .help("Sort by \(field.title); click again to reverse direction")
        .accessibilityLabel("Sort by \(field.title)")
        .accessibilityValue(sorting.field.id == field.id ? (sorting.ascending ? "Ascending" : "Descending") : "Not sorted")
    }
}

func tableSortOrder<Row>(_ sorting: Binding<TableComparator<Row>>) -> Binding<[TableComparator<Row>]> {
    Binding(
        get: { [sorting.wrappedValue] },
        set: { if let first = $0.first { sorting.wrappedValue = first } }
    )
}

/// Keeps embedded tables' search and sort, by key, for pages whose content is removed while
/// hidden. Own it above the page's visibility boundary so filters survive navigation.
final class TableStateStore: ObservableObject {
    private var searches: [String: String] = [:]
    private var sortings: [String: Any] = [:]

    func search(_ key: String) -> Binding<String> {
        Binding(
            get: { self.searches[key] ?? "" },
            set: { value in
                self.objectWillChange.send()
                self.searches[key] = value
            }
        )
    }

    func sorting<Row>(_ key: String, default initial: TableComparator<Row>) -> Binding<TableComparator<Row>> {
        Binding(
            get: { self.sortings[key] as? TableComparator<Row> ?? initial },
            set: { value in
                self.objectWillChange.send()
                self.sortings[key] = value
            }
        )
    }
}

/// A table with search, filter, sort, and row count, for pages that scroll as a whole.
/// It shows up to `maximumRows` rows before scrolling itself; columns sort by header and resize.
/// Search and sort live in `state` under `key`, so they survive the page being hidden.
struct EmbeddedDataTable<Row: Identifiable, Columns: TableColumnContent>: View
where Columns.TableRowValue == Row, Columns.TableColumnSortComparator == TableComparator<Row> {
    private let rows: [Row]
    private let fields: [TableField<Row>]
    private let initialSorting: TableComparator<Row>
    private let key: String
    private let identity: (Row) -> String
    private let prompt: String
    private let rowHeight: CGFloat
    private let maximumRows: Int
    private let columns: Columns
    @ObservedObject private var state: TableStateStore
    @State private var selection: Row.ID?

    init(
        _ rows: [Row], fields: [TableField<Row>], sortedBy initialSorting: TableComparator<Row>,
        state: TableStateStore, key: String,
        identity: @escaping (Row) -> String, prompt: String = "Search text or field > value",
        rowHeight: CGFloat = 26, maximumRows: Int = 12,
        @TableColumnBuilder<Row, TableComparator<Row>> columns: () -> Columns
    ) {
        self.rows = rows
        self.fields = fields
        self.initialSorting = initialSorting
        self.key = key
        self.identity = identity
        self.prompt = prompt
        self.rowHeight = rowHeight
        self.maximumRows = maximumRows
        self.columns = columns()
        self.state = state
    }

    var body: some View {
        let search = state.search(key)
        let sorting = state.sorting(key, default: initialSorting)
        let shown = TableQuery(search: search.wrappedValue, fields: fields)
            .apply(to: rows, sorting: sorting.wrappedValue, identity: identity)
        return VStack(alignment: .leading, spacing: 6) {
            TableSearchControls(search: search, fields: fields, prompt: prompt)
            HStack {
                TableSortControls(fields: fields, sorting: sorting)
                Spacer()
                Text(verbatim: "\(shown.count) of \(rows.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Table(shown, selection: $selection, sortOrder: tableSortOrder(sorting)) { columns }
                // Rows plus the header and the table's top and bottom insets.
                .frame(height: CGFloat(min(max(shown.count, 1), maximumRows)) * rowHeight + 40)
                .overlay {
                    if shown.isEmpty && !rows.isEmpty {
                        Text("No matching rows. Change or reset the filters.").foregroundColor(.secondary)
                    }
                }
        }
    }
}
