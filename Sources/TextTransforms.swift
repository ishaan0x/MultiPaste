import Foundation

enum TextTransform: CaseIterable {
    case lowercase
    case uppercase
    case normal
    case title
    case spongeBob

    var menuTitle: String {
        switch self {
        case .lowercase:
            return "Lowercase"
        case .uppercase:
            return "Uppercase"
        case .normal:
            return "Normal"
        case .title:
            return "Title Case"
        case .spongeBob:
            return "SpongeBob Case"
        }
    }

    var pickerShortcut: Character {
        switch self {
        case .lowercase:
            return "l"
        case .uppercase:
            return "u"
        case .normal:
            return "n"
        case .title:
            return "t"
        case .spongeBob:
            return "s"
        }
    }

    var statusMessage: String {
        switch self {
        case .lowercase:
            return "lower"
        case .uppercase:
            return "UPPER"
        case .normal:
            return "Normal"
        case .title:
            return "Title"
        case .spongeBob:
            return "sPoNgE"
        }
    }

    func apply(to text: String) -> String {
        switch self {
        case .lowercase:
            return text.lowercased()
        case .uppercase:
            return text.uppercased()
        case .normal:
            return TextTransformer.toSentenceCase(text)
        case .title:
            return TextTransformer.toTitleCase(text)
        case .spongeBob:
            return TextTransformer.toSpongeBobCase(text, uppercaseProbability: 0.42)
        }
    }
}

enum TextTransformer {
    static func toSentenceCase(_ text: String) -> String {
        let lowercased = text.lowercased()
        var output = ""
        var capitalizeNextLetter = true

        for character in lowercased {
            let scalar = String(character)

            if character.isLetter {
                if capitalizeNextLetter {
                    output.append(scalar.uppercased())
                    capitalizeNextLetter = false
                } else {
                    output.append(character)
                }
            } else {
                output.append(character)
            }

            if ".!?".contains(character) || character == "\n" {
                capitalizeNextLetter = true
            }
        }

        return capitalizePronounI(in: output)
    }

    static func toTitleCase(_ text: String) -> String {
        let lowercased = text.lowercased()
        var output = ""
        var shouldCapitalize = true

        for character in lowercased {
            let scalar = String(character)

            if character.isLetter {
                if shouldCapitalize {
                    output.append(scalar.uppercased())
                } else {
                    output.append(character)
                }

                shouldCapitalize = false
            } else {
                output.append(character)
                shouldCapitalize = !character.isNumber && character != "'"
            }
        }

        return output
    }

    static func toSpongeBobCase(_ text: String, uppercaseProbability: Double) -> String {
        let lowercased = text.lowercased()
        var rng = SeededGenerator(seed: stableSeed(for: text))
        var output = ""

        for character in lowercased {
            guard character.isLetter else {
                output.append(character)
                continue
            }

            let scalar = String(character)
            if rng.nextUnitInterval() < uppercaseProbability {
                output.append(scalar.uppercased())
            } else {
                output.append(character)
            }
        }

        return output
    }

    private static func capitalizePronounI(in text: String) -> String {
        let pattern = #"\bi(?:\b|'[a-z]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var output = text

        for match in matches.reversed() {
            guard
                let range = Range(match.range, in: output),
                let first = output[range].first
            else {
                continue
            }

            let replacement = String(first).uppercased() + output[range].dropFirst()
            output.replaceSubrange(range, with: replacement)
        }

        return output
    }

    private static func stableSeed(for text: String) -> UInt64 {
        let offsetBasis: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        var hash = offsetBasis
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }

        return hash == 0 ? 1 : hash
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 1 : seed
    }

    mutating func nextUnitInterval() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27

        let value = state &* 2_685_821_657_736_338_717
        return Double(value) / Double(UInt64.max)
    }
}

private extension Character {
    var isLetter: Bool {
        unicodeScalars.allSatisfy(CharacterSet.letters.contains(_:))
    }

    var isNumber: Bool {
        unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains(_:))
    }
}
