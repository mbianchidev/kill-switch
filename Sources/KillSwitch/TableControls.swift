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
        let value = field.kind == .text ? TableFilterSyntax.quoted(value) : value.trimmingCharacters(in: .whitespacesAndNewlines)
        let clause = "\(field.id) \(operation) \(value)"
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
