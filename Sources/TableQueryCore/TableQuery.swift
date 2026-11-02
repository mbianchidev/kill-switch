import Foundation

public enum TableNumberUnit: Equatable, Sendable {
    case count, percent, bytes, bytesPerSecond, seconds

    fileprivate func multiplier(for suffix: String) -> Decimal? {
        let suffix = suffix.lowercased()
        if suffix.isEmpty { return 1 }
        switch self {
        case .count: return nil
        case .percent: return suffix == "%" ? 1 : nil
        case .seconds:
            switch suffix {
            case "ms": return Decimal(1) / 1_000
            case "s", "sec", "seconds": return 1
            case "m", "min", "minutes": return 60
            case "h", "hr", "hours": return 3_600
            case "d", "days": return 86_400
            default: return nil
            }
        case .bytes, .bytesPerSecond:
            let unit = self == .bytesPerSecond && suffix.hasSuffix("/s") ? String(suffix.dropLast(2)) : suffix
            let powers = ["b": 0, "kb": 1, "kib": 1, "mb": 2, "mib": 2, "gb": 3, "gib": 3,
                          "tb": 4, "tib": 4, "pb": 5, "pib": 5, "eb": 6, "eib": 6]
            guard let power = powers[unit] else { return nil }
            return (0..<power).reduce(Decimal(1)) { value, _ in value * 1_024 }
        }
    }
}

public enum TableFieldKind: Equatable, Sendable {
    case text, number(TableNumberUnit), boolean, date
}

fileprivate enum TableValue: Sendable {
    case text(String), number(Decimal), boolean(Bool), date(Date)

    var searchText: String {
        switch self {
        case let .text(value): return value
        case let .number(value): return NSDecimalNumber(decimal: value).stringValue
        case let .boolean(value): return value ? "yes true" : "no false"
        case let .date(value): return value.ISO8601Format()
        }
    }

    func compare(to other: Self, natural: Bool = false) -> ComparisonResult {
        switch (self, other) {
        case let (.number(left), .number(right)):
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case let (.date(left), .date(right)): return left.compare(right)
        case let (.boolean(left), .boolean(right)):
            return left == right ? .orderedSame : (left ? .orderedDescending : .orderedAscending)
        default:
            return natural ? searchText.localizedStandardCompare(other.searchText)
                : searchText.localizedCaseInsensitiveCompare(other.searchText)
        }
    }
}

public struct TableField<Row>: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let aliases: [String]
    public let kind: TableFieldKind
    public let predefinedValues: [String]
    public let searchable: Bool
    fileprivate let value: @Sendable (Row) -> TableValue?

    private init(
        _ id: String, title: String, aliases: [String], kind: TableFieldKind,
        predefinedValues: [String] = [], searchable: Bool, value: @escaping @Sendable (Row) -> TableValue?
    ) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.kind = kind
        self.predefinedValues = predefinedValues
        self.searchable = searchable
        self.value = value
    }

    public static func text(
        _ id: String, title: String, aliases: [String] = [], values: [String] = [], searchable: Bool = true,
        value: @escaping @Sendable (Row) -> String?
    ) -> Self {
        Self(id, title: title, aliases: aliases, kind: .text, predefinedValues: values, searchable: searchable) {
            value($0).map(TableValue.text)
        }
    }

    public static func number(
        _ id: String, title: String, aliases: [String] = [], unit: TableNumberUnit = .count, searchable: Bool = false,
        value: @escaping @Sendable (Row) -> Decimal?
    ) -> Self {
        Self(id, title: title, aliases: aliases, kind: .number(unit), searchable: searchable) { row in
            value(row).flatMap { $0.isNaN ? nil : .number($0) }
        }
    }

    public static func number(
        _ id: String, title: String, aliases: [String] = [], unit: TableNumberUnit = .count, searchable: Bool = false,
        value: @escaping @Sendable (Row) -> Double?
    ) -> Self {
        number(id, title: title, aliases: aliases, unit: unit, searchable: searchable) { row -> Decimal? in
            value(row).flatMap { $0.isFinite ? Decimal(string: String($0), locale: Locale(identifier: "en_US_POSIX")) : nil }
        }
    }

    public static func boolean(
        _ id: String, title: String, aliases: [String] = [], value: @escaping @Sendable (Row) -> Bool?
    ) -> Self {
        Self(id, title: title, aliases: aliases, kind: .boolean, predefinedValues: ["Yes", "No"], searchable: false) {
            value($0).map(TableValue.boolean)
        }
    }

    public static func date(
        _ id: String, title: String, aliases: [String] = [], value: @escaping @Sendable (Row) -> Date?
    ) -> Self {
        Self(id, title: title, aliases: aliases, kind: .date, searchable: false) { value($0).map(TableValue.date) }
    }
}

public struct TableComparator<Row>: SortComparator, Sendable {
    public let field: TableField<Row>
    public var order: SortOrder
    public var ascending: Bool {
        get { order == .forward }
        set { order = newValue ? .forward : .reverse }
    }

    public init(field: TableField<Row>, order: SortOrder = .forward) {
        self.field = field
        self.order = order
    }

    public mutating func select(_ field: TableField<Row>) {
        self = Self(field: field, order: self.field.id == field.id && ascending ? .reverse : .forward)
    }

    public func compare(_ left: Row, _ right: Row) -> ComparisonResult {
        compareValues(field.value(left), field.value(right))
    }

    private func compareValues(_ left: TableValue?, _ right: TableValue?) -> ComparisonResult {
        switch (left, right) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (left?, right?):
            let comparison = left.compare(to: right, natural: true)
            if ascending || comparison == .orderedSame { return comparison }
            return comparison == .orderedAscending ? .orderedDescending : .orderedAscending
        }
    }

    public func sorted(_ rows: [Row], identity: (Row) -> String) -> [Row] {
        let projected = rows.map { (row: $0, value: field.value($0), id: identity($0)) }
        return projected.sorted { left, right in
            let comparison = compareValues(left.value, right.value)
            return comparison == .orderedSame
                ? left.id.localizedStandardCompare(right.id) == .orderedAscending
                : comparison == .orderedAscending
        }.map { $0.row }
    }

    public static func == (left: Self, right: Self) -> Bool {
        left.field.id == right.field.id && left.order == right.order
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(field.id)
        hasher.combine(order)
    }
}

public enum TableFilterSyntax {
    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func appending(_ clause: String, to search: String) -> String {
        let existing = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let clause = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? clause : existing + " AND " + clause
    }
}

public struct TableQuery<Row>: Sendable {
    public let error: String?
    private let fields: [TableField<Row>]
    private let terms: [TableTerm]

    public init(search: String, fields: [TableField<Row>]) {
        self.fields = fields
        switch parseTableQuery(search, fields: fields) {
        case let .success(terms): self.terms = terms; error = nil
        case let .failure(error): terms = []; self.error = error.message
        }
    }

    public func matches(_ row: Row) -> Bool {
        guard error == nil else { return false }
        return terms.allSatisfy { term in
            switch term {
            case let .text(text):
                return fields.contains { $0.searchable && $0.value(row)?.searchText.localizedCaseInsensitiveContains(text) == true }
            case let .comparison(index, operation, expected):
                guard let actual = fields[index].value(row) else { return false }
                if operation == .contains {
                    return actual.searchText.localizedCaseInsensitiveContains(expected.searchText)
                }
                let comparison = actual.compare(to: expected)
                switch operation {
                case .equal: return comparison == .orderedSame
                case .notEqual: return comparison != .orderedSame
                case .greater: return comparison == .orderedDescending
                case .greaterOrEqual: return comparison != .orderedAscending
                case .less: return comparison == .orderedAscending
                case .lessOrEqual: return comparison != .orderedDescending
                case .contains: return false
                }
            }
        }
    }

    public func filter(_ rows: [Row]) -> [Row] { rows.filter(matches) }

    public func apply(
        to rows: [Row], sorting: TableComparator<Row>, identity: (Row) -> String
    ) -> [Row] {
        sorting.sorted(filter(rows), identity: identity)
    }
}

private enum TableOperation: String, Sendable {
    case equal = "=", notEqual = "!=", greater = ">", greaterOrEqual = ">="
    case less = "<", lessOrEqual = "<=", contains = ":"
}

private enum TableTerm: Sendable {
    case text(String), comparison(Int, TableOperation, TableValue)
}

private enum TableToken {
    case word(String, quoted: Bool), operation(String), boundary
}

private struct TableParseError: Error {
    let message: String
}

private func normalizedField(_ value: String) -> String {
    value.lowercased().filter { $0.isLetter || $0.isNumber }
}

private func fieldSuffix(_ words: [String], aliases: [String: Int]) -> (start: Int, field: Int)? {
    for start in words.indices {
        if let field = aliases[normalizedField(words[start...].joined(separator: " "))] {
            return (start, field)
        }
    }
    return nil
}

private func tokenizeTableQuery(_ search: String) -> Result<[TableToken], TableParseError> {
    let characters = Array(search)
    var tokens: [TableToken] = []
    var word = ""
    var index = 0
    func finishWord() {
        if !word.isEmpty {
            tokens.append(word.uppercased() == "AND" ? .boundary : .word(word, quoted: false))
            word = ""
        }
    }
    while index < characters.count {
        let character = characters[index]
        if character.isWhitespace { finishWord(); index += 1; continue }
        if character == "\"" {
            finishWord()
            index += 1
            var value = ""
            while index < characters.count && characters[index] != "\"" {
                if characters[index] == "\\", index + 1 < characters.count,
                   characters[index + 1] == "\\" || characters[index + 1] == "\"" {
                    index += 1
                }
                value.append(characters[index])
                index += 1
            }
            guard index < characters.count else { return .failure(TableParseError(message: "Close the quoted search value with a double quote.")) }
            tokens.append(.word(value, quoted: true))
            index += 1
        } else if "<>=!".contains(character) {
            finishWord()
            var operation = ""
            while index < characters.count && "<>=!".contains(characters[index]) {
                operation.append(characters[index])
                index += 1
            }
            tokens.append(.operation(operation))
        } else {
            word.append(character)
            index += 1
        }
    }
    finishWord()
    return .success(tokens)
}

private func parseTableQuery<Row>(
    _ search: String, fields: [TableField<Row>]
) -> Result<[TableTerm], TableParseError> {
    var aliases: [String: Int] = [:]
    for (index, field) in fields.enumerated() {
        for alias in [field.id, field.title] + field.aliases {
            let key = normalizedField(alias)
            if let existing = aliases[key], existing != index {
                return .failure(TableParseError(message: "The filter field '\(alias)' is ambiguous."))
            }
            aliases[key] = index
        }
    }
    let raw: [TableToken]
    switch tokenizeTableQuery(search) {
    case let .success(tokens): raw = tokens
    case let .failure(error): return .failure(error)
    }
    var tokens: [TableToken] = []
    // Resolve full field-name suffixes, but keep bare IPv6 endpoints literal.
    for token in raw {
        if case let .word(text, quoted: false) = token, !text.hasPrefix("::"), let colon = text.firstIndex(of: ":") {
            let prefix = String(text[..<colon])
            if !prefix.isEmpty && normalizedField(prefix).isEmpty {
                tokens.append(token)
                continue
            }
            var words: [String] = []
            for previous in tokens.reversed() {
                guard case let .word(word, _) = previous else { break }
                words.insert(word, at: 0)
            }
            if !prefix.isEmpty { words.append(prefix) }
            if fieldSuffix(words, aliases: aliases) != nil || text == ":" {
                if !prefix.isEmpty { tokens.append(.word(prefix, quoted: false)) }
                tokens.append(.operation(":"))
                let value = String(text[text.index(after: colon)...])
                if !value.isEmpty { tokens.append(value.uppercased() == "AND" ? .boundary : .word(value, quoted: false)) }
                continue
            }
        }
        tokens.append(token)
    }
    var terms: [TableTerm] = []
    var index = 0
    var hasClause = false
    while index < tokens.count {
        if case .boundary = tokens[index] {
            guard hasClause, index + 1 < tokens.count else {
                return .failure(TableParseError(message: "AND must separate complete search terms or filters. Quote it to search for the word literally."))
            }
            hasClause = false
            index += 1
            continue
        }
        var words: [String] = []
        while index < tokens.count, case let .word(word, _) = tokens[index] {
            words.append(word)
            index += 1
        }
        if index == tokens.count { terms += words.map(TableTerm.text); break }
        if case .boundary = tokens[index] {
            terms += words.map(TableTerm.text)
            hasClause = hasClause || !words.isEmpty
            continue
        }
        guard case let .operation(rawOperation) = tokens[index],
              let operation = TableOperation(rawValue: rawOperation == "==" ? "=" : rawOperation) else {
            return .failure(TableParseError(message: "Use =, !=, >, >=, <, <=, or : between a field and its value."))
        }
        guard let suffix = fieldSuffix(words, aliases: aliases) else {
            return .failure(TableParseError(message: "Unknown filter field '\(words.last ?? "")'. Use a column name or a supported short name."))
        }
        terms += words[..<suffix.start].map(TableTerm.text)
        let field = fields[suffix.field]
        index += 1
        guard index < tokens.count, case let .word(rawValue, _) = tokens[index] else {
            return .failure(TableParseError(message: "Enter a value after \(field.title) \(rawOperation)."))
        }
        var value = rawValue
        index += 1
        if case let .number(unit) = field.kind, numericParts(value)?.suffix.isEmpty == true,
           index < tokens.count, case let .word(suffix, _) = tokens[index],
           !suffix.isEmpty, unit.multiplier(for: suffix) != nil {
            value += suffix
            index += 1
        }
        if operation == .contains && field.kind != .text {
            return .failure(TableParseError(message: "Use =, !=, >, >=, <, or <= for \(field.title)."))
        }
        if case .boolean = field.kind, operation != .equal && operation != .notEqual {
            return .failure(TableParseError(message: "Use = or != with Yes or No for \(field.title)."))
        }
        guard let expected = parseTableValue(value, kind: field.kind) else {
            return .failure(TableParseError(message: "Invalid value '\(value)' for \(field.title). \(tableValueHint(field.kind))"))
        }
        terms.append(.comparison(suffix.field, operation, expected))
        hasClause = true
    }
    return .success(terms)
}

private func numericParts(_ text: String) -> (number: Decimal, suffix: String)? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = text.range(of: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"#, options: .regularExpression),
          let number = Decimal(string: String(text[range]), locale: Locale(identifier: "en_US_POSIX")),
          !number.isNaN else { return nil }
    return (number, String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces))
}

private func parseTableValue(_ text: String, kind: TableFieldKind) -> TableValue? {
    switch kind {
    case .text: return .text(text)
    case let .number(unit):
        guard let parts = numericParts(text), let multiplier = unit.multiplier(for: parts.suffix) else { return nil }
        let value = parts.number * multiplier
        return value.isNaN ? nil : .number(value)
    case .boolean:
        switch text.lowercased() {
        case "yes", "true", "1": return .boolean(true)
        case "no", "false", "0": return .boolean(false)
        default: return nil
        }
    case .date:
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        day.isLenient = false
        if let date = day.date(from: text), day.string(from: date) == text { return .date(date) }
        let timestamp = ISO8601DateFormatter()
        if let date = timestamp.date(from: text) { return .date(date) }
        timestamp.formatOptions.insert(.withFractionalSeconds)
        return timestamp.date(from: text).map(TableValue.date)
    }
}

private func tableValueHint(_ kind: TableFieldKind) -> String {
    switch kind {
    case .text: return "Quote values containing spaces."
    case .boolean: return "Use Yes, No, true, or false."
    case .date: return "Use YYYY-MM-DD or an ISO 8601 timestamp; dates use UTC."
    case let .number(unit):
        switch unit {
        case .count: return "Use a number."
        case .percent: return "Use a number, optionally followed by %."
        case .bytes: return "Use bytes or a unit such as KB, MB, GB, or GiB."
        case .bytesPerSecond: return "Use bytes per second or a unit such as MB/s."
        case .seconds: return "Use seconds or a unit such as ms, m, or h."
        }
    }
}
