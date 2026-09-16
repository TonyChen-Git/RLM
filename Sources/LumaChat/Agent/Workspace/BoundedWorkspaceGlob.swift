import Foundation

/// A precompiled glob matcher with an explicit aggregate work budget. It avoids
/// compiling an ICU expression for every ignore rule and file.
struct BoundedWorkspaceGlob: Sendable {
    static let maximumPatternBytes = 512

    enum CompileError: LocalizedError, Equatable, Sendable {
        case patternTooLong(Int)

        var errorDescription: String? {
            switch self {
            case .patternTooLong(let maximum):
                "Glob exceeds the \(maximum)-byte safety limit."
            }
        }
    }

    enum MatchLimit: Error, Sendable {
        case exhausted
    }

    struct WorkBudget: Sendable {
        private(set) var remainingOperations: Int

        init(maximumOperations: Int = 2_000_000) {
            remainingOperations = max(1, maximumOperations)
        }

        mutating func spend(_ amount: Int) throws {
            let cost = max(1, amount)
            guard remainingOperations >= cost else { throw MatchLimit.exhausted }
            remainingOperations -= cost
            try Task.checkCancellation()
        }
    }

    private enum Token: Sendable, Equatable {
        case literal(Character)
        case anyCharacter
        case star(crossesSeparators: Bool)
        /// Git's `**/` form consumes zero or more complete path components.
        /// Keeping the slash in this token is important: `**/foo` must also
        /// match `foo`, and `a/**/b` must also match `a/b`.
        case globstarDirectories
        case characterClass(CharacterClass)
    }

    private struct CharacterClass: Sendable, Equatable {
        struct Range: Sendable, Equatable {
            var lowerBound: Character
            var upperBound: Character

            func contains(_ character: Character) -> Bool {
                lowerBound <= character && character <= upperBound
            }
        }

        var negated: Bool
        var literals: [Character]
        var ranges: [Range]

        func contains(_ character: Character) -> Bool {
            let found = literals.contains(character)
                || ranges.contains(where: { $0.contains(character) })
            return negated ? !found : found
        }
    }

    private let tokens: [Token]
    private let literal: [Character]?

    init(_ pattern: String) throws {
        guard pattern.utf8.count <= Self.maximumPatternBytes else {
            throw CompileError.patternTooLong(Self.maximumPatternBytes)
        }
        let characters = Array(pattern)
        var compiled: [Token] = []
        var index = 0
        var containsWildcard = false
        while index < characters.count {
            switch characters[index] {
            case "\\":
                if index + 1 < characters.count {
                    compiled.append(.literal(characters[index + 1]))
                    index += 2
                } else {
                    // A terminal backslash has nothing to quote and is literal.
                    compiled.append(.literal("\\"))
                    index += 1
                }
            case "*":
                containsWildcard = true
                var count = 1
                while index + count < characters.count, characters[index + count] == "*" {
                    count += 1
                }
                let next = index + count
                let isAtComponentStart = index == 0 || characters[index - 1] == "/"
                let isGlobstar = count >= 2 && isAtComponentStart
                if isGlobstar, next < characters.count, characters[next] == "/" {
                    if compiled.last != .globstarDirectories {
                        compiled.append(.globstarDirectories)
                    }
                    index = next + 1
                    continue
                }
                let token = Token.star(
                    crossesSeparators: isGlobstar && next == characters.count
                )
                if compiled.last != token { compiled.append(token) }
                index += count
            case "?":
                containsWildcard = true
                compiled.append(.anyCharacter)
                index += 1
            case "[":
                if let parsed = Self.parseCharacterClass(characters, openingIndex: index) {
                    containsWildcard = true
                    compiled.append(.characterClass(parsed.value))
                    index = parsed.nextIndex
                } else {
                    compiled.append(.literal("["))
                    index += 1
                }
            default:
                compiled.append(.literal(characters[index]))
                index += 1
            }
        }
        tokens = compiled
        if containsWildcard {
            literal = nil
        } else {
            literal = compiled.compactMap { token in
                guard case .literal(let character) = token else { return nil }
                return character
            }
        }
    }

    func matches(_ input: [Character], budget: inout WorkBudget) throws -> Bool {
        if let literal {
            try budget.spend(max(literal.count, input.count) + 1)
            return literal == input
        }

        var previous = [Bool](repeating: false, count: input.count + 1)
        previous[0] = true
        for token in tokens {
            let comparisonMultiplier: Int
            if case .characterClass(let characterClass) = token {
                comparisonMultiplier = max(
                    1,
                    characterClass.literals.count + characterClass.ranges.count
                )
            } else {
                comparisonMultiplier = 1
            }
            let (operationCost, overflowed) = (input.count + 1)
                .multipliedReportingOverflow(by: comparisonMultiplier)
            try budget.spend(overflowed ? Int.max : operationCost)
            var current = [Bool](repeating: false, count: input.count + 1)
            switch token {
            case .literal(let character):
                guard !input.isEmpty else {
                    previous = current
                    continue
                }
                for offset in 1...input.count {
                    current[offset] = previous[offset - 1] && input[offset - 1] == character
                }
            case .anyCharacter:
                guard !input.isEmpty else {
                    previous = current
                    continue
                }
                for offset in 1...input.count {
                    current[offset] = previous[offset - 1] && input[offset - 1] != "/"
                }
            case .star(let crossesSeparators):
                current[0] = previous[0]
                guard !input.isEmpty else {
                    previous = current
                    continue
                }
                for offset in 1...input.count {
                    current[offset] = previous[offset]
                        || (current[offset - 1]
                            && (crossesSeparators || input[offset - 1] != "/"))
                }
            case .globstarDirectories:
                // The zero-component transition preserves every currently
                // reachable offset. Once a transition starts, it may consume
                // arbitrary component text, but only exposes a new match state
                // immediately after a separator.
                current = previous
                var consuming = false
                guard !input.isEmpty else {
                    previous = current
                    continue
                }
                for offset in 0..<input.count {
                    consuming = consuming || previous[offset]
                    if consuming, input[offset] == "/" {
                        current[offset + 1] = true
                    }
                }
            case .characterClass(let characterClass):
                guard !input.isEmpty else {
                    previous = current
                    continue
                }
                for offset in 1...input.count {
                    let character = input[offset - 1]
                    current[offset] = previous[offset - 1]
                        && character != "/"
                        && characterClass.contains(character)
                }
            }
            previous = current
            if !previous.contains(true) { return false }
        }
        return previous[input.count]
    }

    private static func parseCharacterClass(
        _ pattern: [Character],
        openingIndex: Int
    ) -> (value: CharacterClass, nextIndex: Int)? {
        var index = openingIndex + 1
        guard index < pattern.count else { return nil }

        var negated = false
        if pattern[index] == "!" || pattern[index] == "^" {
            negated = true
            index += 1
        }

        var elements: [(character: Character, escaped: Bool)] = []
        var foundClosingBracket = false
        while index < pattern.count {
            let character = pattern[index]
            if character == "\\", index + 1 < pattern.count {
                elements.append((pattern[index + 1], true))
                index += 2
                continue
            }
            // A `]` in the first member position denotes itself; later ones
            // close the class, matching gitwildmatch/fnmatch behavior.
            if character == "]", !elements.isEmpty {
                foundClosingBracket = true
                index += 1
                break
            }
            elements.append((character, false))
            index += 1
        }
        guard foundClosingBracket, !elements.isEmpty else { return nil }

        var literals: [Character] = []
        var ranges: [CharacterClass.Range] = []
        var elementIndex = 0
        while elementIndex < elements.count {
            if elementIndex + 2 < elements.count,
               elements[elementIndex + 1].character == "-",
               !elements[elementIndex + 1].escaped {
                let lower = elements[elementIndex].character
                let upper = elements[elementIndex + 2].character
                if lower <= upper {
                    ranges.append(CharacterClass.Range(
                        lowerBound: lower,
                        upperBound: upper
                    ))
                } else {
                    // Invalid descending ranges are interpreted literally. It
                    // is safer and more useful than making the whole ignore
                    // evaluation fail for one malformed user rule.
                    literals.append(lower)
                    literals.append("-")
                    literals.append(upper)
                }
                elementIndex += 3
            } else {
                literals.append(elements[elementIndex].character)
                elementIndex += 1
            }
        }
        return (
            CharacterClass(negated: negated, literals: literals, ranges: ranges),
            index
        )
    }
}

struct WorkspaceGlobCandidate {
    var path: [Character]
    var name: [Character]
    var components: [[Character]]

    init(relativePath: String, name: String) {
        path = Array(relativePath)
        self.name = Array(name)
        components = relativePath.split(separator: "/").map { Array(String($0)) }
    }
}
