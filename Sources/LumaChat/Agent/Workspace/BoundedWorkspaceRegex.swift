import Dispatch
import Foundation

/// A deliberately small regular-expression engine for native workspace search.
///
/// ICU/NSRegularExpression permits patterns whose backtracking cost is controlled
/// by untrusted input. This parser accepts the ordinary search constructs used by
/// the Agent (`.`, classes, groups, alternation, anchors, and repetition), rejects
/// backreferences/lookarounds/inline options, and evaluates with explicit operation
/// and monotonic-clock budgets. Memoization and the budgets make a pathological
/// pattern a bounded, truncatable search result instead of an uninterruptible task.
struct BoundedWorkspaceRegex: Sendable {
    static let maximumPatternBytes = 1_024
    static let maximumNodes = 1_024
    static let maximumNestingDepth = 32
    static let maximumExplicitRepetition = 1_000

    enum CompileError: LocalizedError, Equatable, Sendable {
        case patternTooLong(Int)
        case tooComplex
        case unsupported(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .patternTooLong(let maximum):
                "Regular expression exceeds the \(maximum)-byte safety limit."
            case .tooComplex:
                "Regular expression exceeds the search complexity limit."
            case .unsupported(let construct):
                "Regular expression construct is not supported by safe search: \(construct)"
            case .invalid(let detail):
                "Invalid regular expression: \(detail)"
            }
        }
    }

    enum MatchLimit: Error, Equatable, Sendable {
        case file
        case total
    }

    struct WorkBudget: Sendable {
        enum Scope: Equatable, Sendable {
            case file
            case total
        }

        private(set) var remainingOperations: Int
        private let deadline: UInt64
        private let scope: Scope
        private var operationsUntilClockCheck = 128

        init(maximumOperations: Int, maximumDuration: TimeInterval, scope: Scope) {
            remainingOperations = max(1, maximumOperations)
            let duration = max(0, maximumDuration)
            let nanoseconds = !duration.isFinite
                || duration >= Double(UInt64.max) / 1_000_000_000
                ? UInt64.max
                : UInt64(duration * 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            deadline = UInt64.max - now < nanoseconds ? UInt64.max : now + nanoseconds
            self.scope = scope
        }

        mutating func spend(_ amount: Int = 1) throws {
            let cost = max(1, amount)
            guard remainingOperations >= cost else { throw limit }
            remainingOperations -= cost
            operationsUntilClockCheck -= cost
            if operationsUntilClockCheck <= 0 {
                operationsUntilClockCheck = 128
                guard DispatchTime.now().uptimeNanoseconds <= deadline else { throw limit }
                try Task.checkCancellation()
            }
        }

        mutating func checkNow() throws {
            guard DispatchTime.now().uptimeNanoseconds <= deadline else { throw limit }
            try Task.checkCancellation()
        }

        private var limit: MatchLimit { scope == .file ? .file : .total }
    }

    private enum PredefinedClass: Sendable {
        case digit
        case notDigit
        case whitespace
        case notWhitespace
        case word
        case notWord
    }

    private struct ScalarClass: Sendable {
        var negated: Bool
        var ranges: [ClosedRange<UInt32>]
        var predefined: [PredefinedClass]
    }

    private enum Atom: Sendable {
        case literal(UInt32)
        case any
        case scalarClass(ScalarClass)
        case predefined(PredefinedClass)
        case startAnchor
        case endAnchor
        case wordBoundary(negated: Bool)
    }

    private enum NodeKind: Sendable {
        case empty
        case atom(Atom)
        case concatenation([Int])
        case alternation([Int])
        case repetition(child: Int, minimum: Int, maximum: Int?)
    }

    private struct Node: Sendable {
        var kind: NodeKind
    }

    private struct MemoKey: Hashable {
        var node: Int
        var position: Int
    }

    private let nodes: [Node]
    private let root: Int
    private let caseSensitive: Bool

    init(pattern: String, caseSensitive: Bool) throws {
        guard pattern.utf8.count <= Self.maximumPatternBytes else {
            throw CompileError.patternTooLong(Self.maximumPatternBytes)
        }
        var parser = Parser(pattern: pattern)
        let parsed = try parser.parse()
        nodes = parsed.nodes
        root = parsed.root
        self.caseSensitive = caseSensitive
    }

    /// Returns a one-based grapheme-cluster column for the first match.
    func firstMatch(
        in line: String,
        fileBudget: inout WorkBudget,
        totalBudget: inout WorkBudget
    ) throws -> Int? {
        try fileBudget.checkNow()
        try totalBudget.checkNow()
        let input = Array(line.unicodeScalars)
        var memo: [MemoKey: Set<Int>] = [:]
        memo.reserveCapacity(min(4_096, max(32, input.count * 2)))

        for start in 0...input.count {
            try spend(file: &fileBudget, total: &totalBudget)
            let endings = try endingPositions(
                node: root,
                at: start,
                input: input,
                memo: &memo,
                fileBudget: &fileBudget,
                totalBudget: &totalBudget
            )
            guard !endings.isEmpty else { continue }
            let scalarIndex = line.unicodeScalars.index(
                line.unicodeScalars.startIndex,
                offsetBy: start
            )
            let stringIndex = scalarIndex.samePosition(in: line) ?? line.endIndex
            return line.distance(from: line.startIndex, to: stringIndex) + 1
        }
        return nil
    }

    private func endingPositions(
        node nodeIndex: Int,
        at position: Int,
        input: [Unicode.Scalar],
        memo: inout [MemoKey: Set<Int>],
        fileBudget: inout WorkBudget,
        totalBudget: inout WorkBudget
    ) throws -> Set<Int> {
        try spend(file: &fileBudget, total: &totalBudget)
        let key = MemoKey(node: nodeIndex, position: position)
        if let cached = memo[key] { return cached }

        let result: Set<Int>
        switch nodes[nodeIndex].kind {
        case .empty:
            result = [position]

        case .atom(let atom):
            result = match(atom: atom, at: position, input: input).map { [$0] } ?? []

        case .concatenation(let children):
            var positions: Set<Int> = [position]
            for child in children where !positions.isEmpty {
                var next: Set<Int> = []
                for candidate in positions {
                    let endings = try endingPositions(
                        node: child,
                        at: candidate,
                        input: input,
                        memo: &memo,
                        fileBudget: &fileBudget,
                        totalBudget: &totalBudget
                    )
                    try merge(
                        endings,
                        into: &next,
                        fileBudget: &fileBudget,
                        totalBudget: &totalBudget
                    )
                }
                positions = next
            }
            result = positions

        case .alternation(let children):
            var positions: Set<Int> = []
            for child in children {
                let endings = try endingPositions(
                    node: child,
                    at: position,
                    input: input,
                    memo: &memo,
                    fileBudget: &fileBudget,
                    totalBudget: &totalBudget
                )
                try merge(
                    endings,
                    into: &positions,
                    fileBudget: &fileBudget,
                    totalBudget: &totalBudget
                )
            }
            result = positions

        case .repetition(let child, let minimum, let maximum):
            var frontier: Set<Int> = [position]
            var accepted: Set<Int> = minimum == 0 ? [position] : []
            var expanded: Set<Int> = []
            let repetitionLimit = maximum ?? (input.count + minimum + 1)
            if repetitionLimit > 0 {
                for iteration in 1...repetitionLimit {
                    guard !frontier.isEmpty else { break }
                    var next: Set<Int> = []
                    for candidate in frontier {
                        let endings = try endingPositions(
                            node: child,
                            at: candidate,
                            input: input,
                            memo: &memo,
                            fileBudget: &fileBudget,
                            totalBudget: &totalBudget
                        )
                        try merge(
                            endings,
                            into: &next,
                            fileBudget: &fileBudget,
                            totalBudget: &totalBudget
                        )
                    }
                    if iteration >= minimum {
                        try merge(
                            next,
                            into: &accepted,
                            fileBudget: &fileBudget,
                            totalBudget: &totalBudget
                        )
                    }
                    if maximum == nil, iteration >= minimum {
                        expanded.formUnion(frontier)
                        next.subtract(expanded)
                    }
                    frontier = next
                }
            }
            result = accepted
        }

        memo[key] = result
        return result
    }

    private func merge(
        _ source: Set<Int>,
        into destination: inout Set<Int>,
        fileBudget: inout WorkBudget,
        totalBudget: inout WorkBudget
    ) throws {
        for value in source where destination.insert(value).inserted {
            try spend(file: &fileBudget, total: &totalBudget)
        }
    }

    private func spend(
        file fileBudget: inout WorkBudget,
        total totalBudget: inout WorkBudget,
        amount: Int = 1
    ) throws {
        try totalBudget.spend(amount)
        try fileBudget.spend(amount)
    }

    private func match(atom: Atom, at position: Int, input: [Unicode.Scalar]) -> Int? {
        switch atom {
        case .literal(let value):
            guard position < input.count,
                  scalar(input[position], equals: value) else { return nil }
            return position + 1
        case .any:
            return position < input.count ? position + 1 : nil
        case .scalarClass(let scalarClass):
            guard position < input.count,
                  scalarClassMatches(scalarClass, scalar: input[position]) else { return nil }
            return position + 1
        case .predefined(let predefined):
            guard position < input.count,
                  predefinedMatches(predefined, scalar: input[position]) else { return nil }
            return position + 1
        case .startAnchor:
            return position == 0 ? position : nil
        case .endAnchor:
            return position == input.count ? position : nil
        case .wordBoundary(let negated):
            let previousIsWord = position > 0 && isWord(input[position - 1])
            let nextIsWord = position < input.count && isWord(input[position])
            let isBoundary = previousIsWord != nextIsWord
            return isBoundary != negated ? position : nil
        }
    }

    private func scalar(_ scalar: Unicode.Scalar, equals value: UInt32) -> Bool {
        if scalar.value == value { return true }
        guard !caseSensitive, let other = Unicode.Scalar(value) else { return false }
        return scalar.properties.lowercaseMapping == other.properties.lowercaseMapping
            || scalar.properties.uppercaseMapping == other.properties.uppercaseMapping
    }

    private func scalarClassMatches(_ scalarClass: ScalarClass, scalar: Unicode.Scalar) -> Bool {
        func inRanges(_ value: UInt32) -> Bool {
            scalarClass.ranges.contains { $0.contains(value) }
        }
        var matched = inRanges(scalar.value)
            || scalarClass.predefined.contains { predefinedMatches($0, scalar: scalar) }
        if !matched, !caseSensitive {
            for mapping in [scalar.properties.lowercaseMapping, scalar.properties.uppercaseMapping] {
                if mapping.unicodeScalars.count == 1,
                   let mapped = mapping.unicodeScalars.first,
                   inRanges(mapped.value) {
                    matched = true
                    break
                }
            }
        }
        return scalarClass.negated ? !matched : matched
    }

    private func predefinedMatches(_ predefined: PredefinedClass, scalar: Unicode.Scalar) -> Bool {
        switch predefined {
        case .digit: CharacterSet.decimalDigits.contains(scalar)
        case .notDigit: !CharacterSet.decimalDigits.contains(scalar)
        case .whitespace: CharacterSet.whitespacesAndNewlines.contains(scalar)
        case .notWhitespace: !CharacterSet.whitespacesAndNewlines.contains(scalar)
        case .word: isWord(scalar)
        case .notWord: !isWord(scalar)
        }
    }

    private func isWord(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    private struct Parser {
        private let scalars: [Unicode.Scalar]
        private var index = 0
        private var nodes: [Node] = []

        init(pattern: String) {
            scalars = Array(pattern.unicodeScalars)
        }

        mutating func parse() throws -> (nodes: [Node], root: Int) {
            let root = try parseAlternation(depth: 0)
            guard isAtEnd else {
                throw CompileError.invalid("unexpected '\(current)' at offset \(index)")
            }
            return (nodes, root)
        }

        private mutating func parseAlternation(depth: Int) throws -> Int {
            try checkDepth(depth)
            var alternatives = [try parseConcatenation(depth: depth)]
            while consume("|") {
                alternatives.append(try parseConcatenation(depth: depth))
            }
            return alternatives.count == 1
                ? alternatives[0]
                : try add(.alternation(alternatives))
        }

        private mutating func parseConcatenation(depth: Int) throws -> Int {
            var children: [Int] = []
            while !isAtEnd, current != ")", current != "|" {
                children.append(try parseQuantifiedAtom(depth: depth))
            }
            if children.isEmpty { return try add(.empty) }
            return children.count == 1
                ? children[0]
                : try add(.concatenation(children))
        }

        private mutating func parseQuantifiedAtom(depth: Int) throws -> Int {
            let atom = try parseAtom(depth: depth)
            guard !isAtEnd else { return atom }

            let repetition: (Int, Int?)?
            switch current {
            case "*":
                index += 1
                repetition = (0, nil)
            case "+":
                index += 1
                repetition = (1, nil)
            case "?":
                index += 1
                repetition = (0, 1)
            case "{":
                repetition = try parseExplicitRepetition()
            default:
                repetition = nil
            }
            guard let repetition else { return atom }
            if !isAtEnd, current == "*" || current == "+" || current == "?" || current == "{" {
                throw CompileError.unsupported("nested, lazy, or possessive quantifier")
            }
            return try add(.repetition(
                child: atom,
                minimum: repetition.0,
                maximum: repetition.1
            ))
        }

        private mutating func parseAtom(depth: Int) throws -> Int {
            guard !isAtEnd else { throw CompileError.invalid("missing expression") }
            let scalar = current
            index += 1
            switch scalar {
            case "(":
                if consume("?") {
                    guard consume(":") else {
                        throw CompileError.unsupported("lookaround or inline option")
                    }
                }
                let child = try parseAlternation(depth: depth + 1)
                guard consume(")") else { throw CompileError.invalid("unclosed group") }
                return child
            case "[":
                return try add(.atom(.scalarClass(try parseScalarClass())))
            case "\\":
                return try add(.atom(try parseEscape(inCharacterClass: false)))
            case ".": return try add(.atom(.any))
            case "^": return try add(.atom(.startAnchor))
            case "$": return try add(.atom(.endAnchor))
            case ")": throw CompileError.invalid("unmatched ')'")
            case "*", "+", "?", "{", "}":
                throw CompileError.invalid("quantifier has no preceding expression")
            default:
                return try add(.atom(.literal(scalar.value)))
            }
        }

        private mutating func parseScalarClass() throws -> ScalarClass {
            let negated = consume("^")
            var ranges: [ClosedRange<UInt32>] = []
            var predefined: [PredefinedClass] = []
            var hasMember = false

            while !isAtEnd, current != "]" {
                let first = try parseClassMember()
                hasMember = true
                if case .literal(let lower) = first,
                   !isAtEnd,
                   current == "-",
                   peek(after: 1) != "]" {
                    index += 1
                    let second = try parseClassMember()
                    guard case .literal(let upper) = second, lower <= upper else {
                        throw CompileError.invalid("invalid character-class range")
                    }
                    ranges.append(lower...upper)
                } else {
                    switch first {
                    case .literal(let value): ranges.append(value...value)
                    case .predefined(let value): predefined.append(value)
                    }
                }
            }
            guard consume("]") else { throw CompileError.invalid("unclosed character class") }
            guard hasMember else { throw CompileError.invalid("empty character class") }
            return ScalarClass(negated: negated, ranges: ranges, predefined: predefined)
        }

        private enum ClassMember {
            case literal(UInt32)
            case predefined(PredefinedClass)
        }

        private mutating func parseClassMember() throws -> ClassMember {
            guard !isAtEnd else { throw CompileError.invalid("unclosed character class") }
            let scalar = current
            index += 1
            guard scalar == "\\" else { return .literal(scalar.value) }
            let atom = try parseEscape(inCharacterClass: true)
            switch atom {
            case .literal(let value): return .literal(value)
            case .predefined(let value): return .predefined(value)
            default: throw CompileError.unsupported("zero-width escape in character class")
            }
        }

        private mutating func parseEscape(inCharacterClass: Bool) throws -> Atom {
            guard !isAtEnd else { throw CompileError.invalid("trailing escape") }
            let scalar = current
            index += 1
            switch scalar {
            case "d": return .predefined(.digit)
            case "D": return .predefined(.notDigit)
            case "s": return .predefined(.whitespace)
            case "S": return .predefined(.notWhitespace)
            case "w": return .predefined(.word)
            case "W": return .predefined(.notWord)
            case "b" where !inCharacterClass: return .wordBoundary(negated: false)
            case "B" where !inCharacterClass: return .wordBoundary(negated: true)
            case "n": return .literal(10)
            case "r": return .literal(13)
            case "t": return .literal(9)
            case "f": return .literal(12)
            case "v": return .literal(11)
            case "0"..."9": throw CompileError.unsupported("backreference")
            case "A", "Z", "z", "G", "p", "P", "k", "Q", "E", "x", "u", "c":
                throw CompileError.unsupported("\\\(scalar)")
            default: return .literal(scalar.value)
            }
        }

        private mutating func parseExplicitRepetition() throws -> (Int, Int?) {
            guard consume("{") else { throw CompileError.invalid("missing repetition") }
            let minimum = try parseDecimal()
            let maximum: Int?
            if consume("}") {
                maximum = minimum
            } else {
                guard consume(",") else { throw CompileError.invalid("invalid repetition") }
                if consume("}") {
                    maximum = nil
                } else {
                    let upper = try parseDecimal()
                    guard consume("}") else { throw CompileError.invalid("unclosed repetition") }
                    maximum = upper
                }
            }
            guard minimum <= BoundedWorkspaceRegex.maximumExplicitRepetition,
                  (maximum ?? minimum) <= BoundedWorkspaceRegex.maximumExplicitRepetition,
                  maximum.map({ $0 >= minimum }) ?? true else {
                throw CompileError.tooComplex
            }
            return (minimum, maximum)
        }

        private mutating func parseDecimal() throws -> Int {
            let start = index
            var value = 0
            while !isAtEnd, current.value >= 48, current.value <= 57 {
                guard value <= BoundedWorkspaceRegex.maximumExplicitRepetition else {
                    throw CompileError.tooComplex
                }
                value = value * 10 + Int(current.value - 48)
                index += 1
            }
            guard index > start else { throw CompileError.invalid("missing repetition count") }
            return value
        }

        private mutating func add(_ kind: NodeKind) throws -> Int {
            guard nodes.count < BoundedWorkspaceRegex.maximumNodes else {
                throw CompileError.tooComplex
            }
            nodes.append(Node(kind: kind))
            return nodes.count - 1
        }

        private func checkDepth(_ depth: Int) throws {
            guard depth <= BoundedWorkspaceRegex.maximumNestingDepth else {
                throw CompileError.tooComplex
            }
        }

        private var isAtEnd: Bool { index >= scalars.count }
        private var current: Unicode.Scalar { scalars[index] }

        private func peek(after offset: Int) -> Unicode.Scalar? {
            let target = index + offset
            return target < scalars.count ? scalars[target] : nil
        }

        @discardableResult
        private mutating func consume(_ expected: Unicode.Scalar) -> Bool {
            guard !isAtEnd, current == expected else { return false }
            index += 1
            return true
        }
    }
}
