import Foundation

struct ReviewSyntaxHighlighter: Sendable {
    func language(for path: String) -> ReviewLanguage? {
        let lowercased = path.lowercased()
        let name = URL(fileURLWithPath: lowercased).lastPathComponent
        let fileExtension = URL(fileURLWithPath: lowercased).pathExtension
        return switch fileExtension {
        case "swift": .swift
        case "m", "mm", "h": .objectiveC
        case "c", "cc", "cpp", "cxx", "hpp": .cFamily
        case "js", "jsx", "mjs", "cjs": .javascript
        case "ts", "tsx": .typescript
        case "py", "pyi": .python
        case "rb": .ruby
        case "sh", "bash", "zsh", "fish": .shell
        case "rs": .rust
        case "go": .go
        case "java": .java
        case "kt", "kts": .kotlin
        case "json", "jsonc": .json
        case "yaml", "yml": .yaml
        case "html", "htm", "xml": .html
        case "css", "scss", "sass", "less": .css
        case "md", "markdown": .markdown
        default:
            if ["makefile", "dockerfile"].contains(name) { .shell } else { nil }
        }
    }

    func spans(in line: String, language: ReviewLanguage?) -> [ReviewSyntaxSpan] {
        guard let language, !line.isEmpty else { return [] }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard fullRange.length <= 256 * 1_024 else { return [] }

        var candidates: [ReviewSyntaxSpan] = []
        var occupied = Array(repeating: false, count: fullRange.length)

        func intersects(_ range: NSRange) -> Bool {
            guard range.location >= 0,
                  range.length >= 0,
                  range.location <= occupied.count,
                  range.length <= occupied.count - range.location else { return true }
            return occupied[range.location..<(range.location + range.length)].contains(true)
        }

        func reserve(_ range: NSRange, role: ReviewSyntaxRole) {
            guard range.length > 0, !intersects(range) else { return }
            for index in range.location..<(range.location + range.length) {
                occupied[index] = true
            }
            candidates.append(ReviewSyntaxSpan(
                location: range.location,
                length: range.length,
                role: role
            ))
        }

        let stringPattern: String
        switch language {
        case .shell:
            stringPattern = #"\"(?:\\.|[^\"\\])*\"|'[^']*'"#
        case .markdown:
            stringPattern = #"`[^`]*`"#
        default:
            stringPattern = #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        }
        matches(pattern: stringPattern, in: line).forEach { reserve($0, role: .string) }

        if let comment = commentRange(in: line, language: language, occupied: occupied) {
            reserve(comment, role: .comment)
        }

        let directivePattern: String?
        switch language {
        case .swift, .objectiveC, .cFamily:
            directivePattern = #"^\s*#[A-Za-z_][A-Za-z0-9_]*"#
        case .markdown:
            directivePattern = #"^\s{0,3}#{1,6}(?=\s)"#
        default:
            directivePattern = nil
        }
        if let directivePattern {
            matches(pattern: directivePattern, in: line).forEach { reserve($0, role: .directive) }
        }

        matches(pattern: #"(?<![A-Za-z0-9_])(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?)(?![A-Za-z0-9_])"#, in: line)
            .forEach { reserve($0, role: .number) }

        let keywords = keywords(for: language)
        if !keywords.isEmpty {
            let alternatives = keywords
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            matches(pattern: "\\b(?:\(alternatives))\\b", in: line)
                .forEach { reserve($0, role: .keyword) }
        }

        return candidates.sorted {
            if $0.location == $1.location { return $0.length < $1.length }
            return $0.location < $1.location
        }
    }

    private func matches(pattern: String, in value: String) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).map(\.range)
    }

    private func commentRange(
        in line: String,
        language: ReviewLanguage,
        occupied: [Bool]
    ) -> NSRange? {
        let markers: [String]
        switch language {
        case .python, .ruby, .shell, .yaml:
            markers = ["#"]
        case .swift, .objectiveC, .cFamily, .javascript, .typescript, .rust,
             .go, .java, .kotlin:
            markers = ["//", "/*"]
        case .css:
            markers = ["/*"]
        case .html, .markdown:
            markers = ["<!--"]
        case .json:
            markers = []
        }
        let value = line as NSString
        var best: NSRange?
        for marker in markers {
            var search = NSRange(location: 0, length: value.length)
            while search.length > 0 {
                let found = value.range(of: marker, options: [], range: search)
                guard found.location != NSNotFound else { break }
                let markerEnd = min(occupied.count, found.location + found.length)
                let isInsideString = found.location < markerEnd
                    && occupied[found.location..<markerEnd].contains(true)
                if !isInsideString,
                   best == nil || found.location < best!.location {
                    best = NSRange(location: found.location, length: value.length - found.location)
                    break
                }
                let next = found.location + max(1, found.length)
                search = NSRange(location: next, length: value.length - next)
            }
        }
        return best
    }

    private func keywords(for language: ReviewLanguage) -> [String] {
        switch language {
        case .swift:
            ["actor", "associatedtype", "async", "await", "break", "case", "catch", "class",
             "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for",
             "func", "guard", "if", "import", "in", "init", "let", "nil", "protocol", "return",
             "self", "some", "static", "struct", "switch", "throw", "throws", "true", "try", "var",
             "where", "while"]
        case .javascript, .typescript:
            ["async", "await", "break", "case", "catch", "class", "const", "continue", "default",
             "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if",
             "import", "in", "instanceof", "interface", "let", "new", "null", "return", "static",
             "switch", "throw", "true", "try", "typeof", "undefined", "var", "while", "yield"]
        case .python:
            ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
             "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
             "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
             "try", "while", "with", "yield"]
        case .objectiveC, .cFamily, .java, .kotlin:
            ["auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default",
             "do", "double", "else", "enum", "false", "final", "float", "for", "if", "import", "int",
             "interface", "long", "new", "null", "private", "protected", "public", "return", "short",
             "static", "struct", "switch", "this", "throw", "true", "try", "void", "while"]
        case .rust:
            ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
             "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
             "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type",
             "unsafe", "use", "where", "while"]
        case .go:
            ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
             "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
             "return", "select", "struct", "switch", "type", "var"]
        case .ruby:
            ["begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure",
             "false", "for", "if", "in", "module", "next", "nil", "redo", "rescue", "retry", "return",
             "self", "super", "then", "true", "unless", "until", "when", "while", "yield"]
        case .shell:
            ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
             "then", "time", "until", "while"]
        case .json, .yaml:
            ["false", "null", "true"]
        case .html, .css, .markdown:
            []
        }
    }
}
