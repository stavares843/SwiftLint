import Foundation
import SourceKittenFramework

extension NSRange {
    private func equals(_ other: NSRange) -> Bool {
        return NSEqualRanges(self, other)
    }

    private func isStrictSubset(of other: NSRange) -> Bool {
        if equals(other) { return false }
        return NSUnionRange(self, other).equals(other)
    }

    fileprivate func isStrictSubset(in others: [NSRange]) -> Bool {
        return others.contains(where: isStrictSubset)
    }
}

public struct ClosureSpacingRule: CorrectableRule, ConfigurationProviderRule, OptInRule {
    public var configuration = SeverityConfiguration(.warning)

    public init() {}

    public static let description = RuleDescription(
        identifier: "closure_spacing",
        name: "Closure Spacing",
        description: "Closure expressions should have a single space inside each brace.",
        kind: .style,
        nonTriggeringExamples: [
            Example("[].map ({ $0.description })"),
            Example("[].filter { $0.contains(location) }"),
            Example("extension UITableViewCell: ReusableView { }"),
            Example("extension UITableViewCell: ReusableView {}")
        ],
        triggeringExamples: [
            Example("[].filter(↓{$0.contains(location)})"),
            Example("[].map(↓{$0})"),
            Example("(↓{each in return result.contains(where: ↓{e in return e}) }).count"),
            Example("filter ↓{ sorted ↓{ $0 < $1}}")
        ],
        corrections: [
            Example("[].filter(↓{$0.contains(location)})"):
                Example("[].filter({ $0.contains(location) })"),
            Example("[].map(↓{$0})"):
                Example("[].map({ $0 })"),
            // Nested braces `{ {} }` do not get corrected on the first pass.
            Example("filter ↓{sorted { $0 < $1}}"):
                Example("filter { sorted { $0 < $1} }"),
            // The user has to run tool again to fix remaining nested violations.
            Example("filter { sorted ↓{ $0 < $1} }"):
                Example("filter { sorted { $0 < $1 } }"),
            Example("(↓{each in return result.contains(where: {e in return 0})}).count"):
                Example("({ each in return result.contains(where: {e in return 0}) }).count"),
            // second pass example
            Example("({ each in return result.contains(where: ↓{e in return 0}) }).count"):
                Example("({ each in return result.contains(where: { e in return 0 }) }).count")
        ]
    )

    // this helps cut down the time to search through a file by
    // skipping lines that do not have at least one `{` and one `}` brace
    private func lineContainsBraces(in range: NSRange, content: NSString) -> NSRange? {
        let start = content.range(of: "{", options: [.literal], range: range)
        guard start.length != 0 else { return nil }
        let end = content.range(of: "}", options: [.literal, .backwards], range: range)
        guard end.length != 0 else { return nil }
        guard start.location < end.location else { return nil }
        return NSRange(location: start.location, length: end.location - start.location + 1)
    }

    // returns ranges of braces `{` or `}` in the same line
    private func validBraces(in file: SwiftLintFile) -> [NSRange] {
        let nsstring = file.contents.bridge()
        let bracePattern = regex("\\{|\\}")
        let linesTokens = file.syntaxTokensByLines
        let kindsToExclude = SyntaxKind.commentAndStringKinds

        // find all lines and occurrences of open { and closed } braces
        var linesWithBraces = [[NSRange]]()
        for eachLine in file.lines {
            guard let nsrange = lineContainsBraces(in: eachLine.range, content: nsstring) else {
                continue
            }

            let braces = bracePattern.matches(in: file.contents, options: [],
                                              range: nsrange).map { $0.range }
            // filter out braces in comments and strings
            let tokens = linesTokens[eachLine.index].filter {
                guard let tokenKind = $0.kind else { return false }
                return kindsToExclude.contains(tokenKind)
            }
            let tokenRanges = tokens.compactMap {
                file.stringView.byteRangeToNSRange($0.range)
            }
            linesWithBraces.append(braces.filter({ !$0.intersects(tokenRanges) }))
        }
        return linesWithBraces.flatMap { $0 }
    }

    // find ranges where violation exist. Returns ranges sorted by location.
    private func findViolations(file: SwiftLintFile) -> [NSRange] {
        // match open braces to corresponding closing braces
        func matchBraces(validBraceLocations: [NSRange]) -> [NSRange] {
            if validBraceLocations.isEmpty { return [] }
            var validBraces = validBraceLocations
            var ranges = [NSRange]()
            var bracesAsString = validBraces.map({
                file.contents.substring(from: $0.location, length: $0.length)
            }).joined()
            while let foundRange = bracesAsString.range(of: "{}") {
                let startIndex = bracesAsString.distance(from: bracesAsString.startIndex,
                                                         to: foundRange.lowerBound)
                let location = validBraces[startIndex].location
                let length = validBraces[startIndex + 1 ].location + 1 - location
                ranges.append(NSRange(location: location, length: length))
                bracesAsString.replaceSubrange(foundRange, with: "")
                validBraces.removeSubrange(startIndex...startIndex + 1)
            }
            return ranges
        }

        // matching ranges of `{...}`
        return matchBraces(validBraceLocations: validBraces(in: file))
            .filter {
                // removes enclosing brances to just content
                let content = file.contents.substring(from: $0.location + 1, length: $0.length - 2)
                if content.isEmpty || content == " " {
                    // case when {} is not a closure
                    return false
                }
                let cleaned = content.trimmingCharacters(in: .whitespaces)
                return content != " " + cleaned + " "
            }
            .sorted {
                $0.location < $1.location
            }
    }

    public func validate(file: SwiftLintFile) -> [StyleViolation] {
        return findViolations(file: file).compactMap {
            StyleViolation(ruleDescription: Self.description,
                           severity: configuration.severity,
                           location: Location(file: file, characterOffset: $0.location))
        }
    }

    // this will try to avoid nested ranges `{{}{}}` in single line
    private func removeNested(_ ranges: [NSRange]) -> [NSRange] {
        return ranges.filter { current in
            return !current.isStrictSubset(in: ranges)
        }
    }

    public func correct(file: SwiftLintFile) -> [Correction] {
        var matches = removeNested(findViolations(file: file)).filter {
            file.ruleEnabled(violatingRanges: [$0], for: self).isNotEmpty
        }
        guard matches.isNotEmpty else { return [] }

        // `matches` should be sorted by location from `findViolations`.
        let start = NSRange(location: 0, length: 0)
        let end = NSRange(location: file.contents.utf16.count, length: 0)
        matches.insert(start, at: 0)
        matches.append(end)

        var fixedSections = [String]()

        var matchIndex = 0
        while matchIndex < matches.count - 1 {
            defer { matchIndex += 1 }
            // inverses the ranges to select non rule violation content
            let current = matches[matchIndex].location + matches[matchIndex].length
            let nextMatch = matches[matchIndex + 1]
            let next = nextMatch.location
            let length = next - current
            let nonViolationContent = file.contents.substring(from: current, length: length)
            if nonViolationContent.isNotEmpty {
                fixedSections.append(nonViolationContent)
            }
            // selects violation ranges and fixes them before adding back in
            if nextMatch.length > 1 {
                let violation = file.contents.substring(from: nextMatch.location + 1,
                                                        length: nextMatch.length - 2)
                let cleaned = "{ " + violation.trimmingCharacters(in: .whitespaces) + " }"
                fixedSections.append(cleaned)
            }

            // Catch all. Break at the end of loop.
            if next == end.location { break }
        }

        // removes the start and end inserted above
        if matches.count > 2 {
            matches.remove(at: matches.count - 1)
            matches.remove(at: 0)
        }

        // write changes to actual file
        file.write(fixedSections.joined())

        return matches.map {
            Correction(ruleDescription: Self.description,
                       location: Location(file: file, characterOffset: $0.location))
        }
    }
}
