import Foundation
import SourceKittenFramework

public struct IdentifierNameRule: ASTRule, ConfigurationProviderRule, ManuallyTestedExamplesRule {
    public var configuration = NameConfiguration(minLengthWarning: 3,
                                                 minLengthError: 2,
                                                 maxLengthWarning: 40,
                                                 maxLengthError: 60,
                                                 excluded: ["id"])

    public init() {}

    public static let description = RuleDescription(
        identifier: "identifier_name",
        name: "Identifier Name",
        description: "Identifier names should only contain alphanumeric characters and " +
            "start with a lowercase character or should only contain capital letters. " +
            "In an exception to the above, variable names may start with a capital letter " +
            "when they are declared static and immutable. Variable names should not be too " +
            "long or too short.",
        kind: .style,
        nonTriggeringExamples: IdentifierNameRuleExamples.nonTriggeringExamples,
        triggeringExamples: IdentifierNameRuleExamples.triggeringExamples,
        deprecatedAliases: ["variable_name"]
    )

    public func validate(
        file: SwiftLintFile,
        kind: SwiftDeclarationKind,
        dictionary: SourceKittenDictionary
    ) -> [StyleViolation] {
        guard !dictionary.enclosedSwiftAttributes.contains(.override) else {
            return []
        }

        return validateName(dictionary: dictionary, kind: kind).map { name, offset in
            guard !configuration.excluded.contains(name), let firstCharacter = name.first else {
                return []
            }

            let isFunction = SwiftDeclarationKind.functionKinds.contains(kind)
            let description = Self.description

            let type = self.type(for: kind)
            if !isFunction {
                let allowedSymbols = configuration.allowedSymbols.union(.alphanumerics)
                if !allowedSymbols.isSuperset(of: CharacterSet(charactersIn: name)) {
                    return [
                        StyleViolation(ruleDescription: description,
                                       severity: .error,
                                       location: Location(file: file, byteOffset: offset),
                                       reason: "\(type) name should only contain alphanumeric " +
                            "characters: '\(name)'")
                    ]
                }

                if let severity = severity(forLength: name.count) {
                    let reason = "\(type) name should be between " +
                        "\(configuration.minLengthThreshold) and " +
                        "\(configuration.maxLengthThreshold) characters long: '\(name)'"
                    return [
                        StyleViolation(ruleDescription: Self.description,
                                       severity: severity,
                                       location: Location(file: file, byteOffset: offset),
                                       reason: reason)
                    ]
                }
            }

            let firstCharacterIsAllowed = configuration.allowedSymbols
                .isSuperset(of: CharacterSet(charactersIn: String(firstCharacter)))
            guard !firstCharacterIsAllowed else {
                return []
            }
            let requiresCaseCheck = configuration.validatesStartWithLowercase || isFunction
            if requiresCaseCheck &&
                kind != .varStatic && name.isViolatingCase && !name.isOperator {
                let reason = "\(type) name should start with a lowercase character: '\(name)'"
                return [
                    StyleViolation(ruleDescription: description,
                                   severity: .error,
                                   location: Location(file: file, byteOffset: offset),
                                   reason: reason)
                ]
            }

            return []
        } ?? []
    }

    private func validateName(
        dictionary: SourceKittenDictionary,
        kind: SwiftDeclarationKind
    ) -> (name: String, offset: ByteCount)? {
        guard
            var name = dictionary.name,
            let offset = dictionary.offset,
            kinds.contains(kind),
            !name.hasPrefix("$")
        else { return nil }

        if
            kind == .enumelement,
            let parenIndex = name.firstIndex(of: "("),
            parenIndex > name.startIndex
        {
            let index = name.index(before: parenIndex)
            name = String(name[...index])
        }

        return (name.nameStrippingLeadingUnderscoreIfPrivate(dictionary), offset)
    }

    private let kinds: Set<SwiftDeclarationKind> = {
        return SwiftDeclarationKind.variableKinds
            .union(SwiftDeclarationKind.functionKinds)
            .union([.enumelement])
    }()

    private func type(for kind: SwiftDeclarationKind) -> String {
        if SwiftDeclarationKind.functionKinds.contains(kind) {
            return "Function"
        } else if kind == .enumelement {
            return "Enum element"
        } else {
            return "Variable"
        }
    }
}

private extension String {
    var isViolatingCase: Bool {
        let firstCharacter = String(self[startIndex])
        guard firstCharacter.isUppercase() else {
            return false
        }
        guard count > 1 else {
            return true
        }
        let secondCharacter = String(self[index(after: startIndex)])
        return secondCharacter.isLowercase()
    }

    var isOperator: Bool {
        let operators = ["/", "=", "-", "+", "!", "*", "|", "^", "~", "?", ".", "%", "<", ">", "&"]
        return operators.contains(where: hasPrefix)
    }
}
