//
//  LocalTranscriptCleaner.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent On-Device Audio Intelligence.
//  Deterministic local speech normalizer and transcript cleaner:
//  - Strips vocal hesitation sounds (эээ, ааа, эм, мм, um, uh, er, ah, etc.)
//  - Removes conversational filler phrases (ну, типа, как бы, короче, вот, значит, в общем,
//    you know, sort of, kind of, basically, actually, like).
//  - Resolves hyphenated stuttering (в-в-встретимся -> встретимся, х-хотел -> хотел).
//  - Collapses immediate duplicate repeated words (завтра завтра -> завтра, я я -> я).
//  - Normalizes whitespace, sentence capitalization, and punctuation/commas.
//  - Fast, thread-safe, regex-cached pure Swift.
//

import Foundation

/// Represents the result of cleaning an on-device speech transcript.
public struct CleanedTranscript: Sendable, Equatable {
    /// The original raw input transcript.
    public let rawText: String
    /// The cleaned and normalized transcript.
    public let cleanedText: String
    /// Distinct list of removed tokens, fillers, or stutters for transparency.
    public let removedTokens: [String]
    /// Structured list of diff changes applied during cleaning.
    public let diffs: [TranscriptDiff]
    /// Indicates whether this transcript was processed as a final utterance or an in-flight realtime segment.
    public let isFinal: Bool
    
    public init(
        rawText: String,
        cleanedText: String,
        removedTokens: [String] = [],
        diffs: [TranscriptDiff] = [],
        isFinal: Bool = false
    ) {
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.removedTokens = removedTokens
        self.diffs = diffs
        self.isFinal = isFinal
    }
}

/// Represents an individual change applied to the transcript during cleanup.
public struct TranscriptDiff: Sendable, Equatable {
    public enum ChangeType: String, Sendable, Equatable {
        case removedFiller
        case removedRepetition
        case removedStutter
        case normalizedPunctuation
        case normalizedCapitalization
    }
    
    public let changeType: ChangeType
    public let original: String
    public let replacement: String
    
    public init(changeType: ChangeType, original: String, replacement: String) {
        self.changeType = changeType
        self.original = original
        self.replacement = replacement
    }
}

/// Protocol defining a local transcript cleaning provider.
public protocol LocalCleanupProvider: Sendable {
    func clean(_ rawText: String) -> String
}

/// Thread-safe, high-performance, deterministic transcript cleaner for Russian and English speech.
public struct LocalTranscriptCleaner: LocalCleanupProvider, Sendable {
    public static let shared = LocalTranscriptCleaner()
    
    public init() {}
    
    // MARK: - Pre-compiled & Cached Regex Storage
    
    private final class RegexContainer: @unchecked Sendable {
        static let shared = RegexContainer()
        
        // Stutter detection: matches words containing hyphens
        let hyphenatedWordRegex: NSRegularExpression
        
        // Immediate word repetitions: "завтра завтра", "я я", "we we"
        let repeatedWordRegex: NSRegularExpression
        
        // Russian & English vocal hesitations
        let vocalHesitationRegexes: [NSRegularExpression]
        
        // Russian & English conversational filler phrases
        let fillerRules: [(regex: NSRegularExpression, replacement: String, tokenName: String)]
        
        // Punctuation and whitespace normalization regexes
        let spaceBeforePunctRegex: NSRegularExpression
        let multipleCommasRegex: NSRegularExpression
        let commaBeforeTerminatorRegex: NSRegularExpression
        let terminatorBeforeCommaRegex: NSRegularExpression
        let multipleSpacesRegex: NSRegularExpression
        let leadingPunctRegex: NSRegularExpression
        let trailingPunctRegex: NSRegularExpression
        let unnaturalCommaRegexes: [NSRegularExpression]
        let sentenceCapRegex: NSRegularExpression
        
        private init() {
            func compile(_ pattern: String) -> NSRegularExpression {
                do {
                    return try NSRegularExpression(pattern: pattern, options: [])
                } catch {
                    fatalError("Invalid regex pattern: \(pattern), error: \(error)")
                }
            }
            
            // Hyphenated word tokens for stutter resolution
            hyphenatedWordRegex = compile(#"(?:^|(?<=[^\p{L}]))([\p{L}]+(?:-[\p{L}]+)+)(?=[^\p{L}]|$)"#)
            
            // Repeated consecutive word deduplication
            repeatedWordRegex = compile(#"(?i)(?:^|(?<=[^\p{L}]))([\p{L}]+)(?:[\s,]+)\1(?=[^\p{L}]|$)"#)
            
            // Vocal hesitation sounds (Russian & English) with optional comma stripping
            vocalHesitationRegexes = [
                // Russian hesitations: эээ, ээ, э-э, э-э-э
                compile(#"(?i)(?:,\s*)?\b[эЭ]{2,}\b(?:\s*,)?"#),
                compile(#"(?i)(?:,\s*)?(?:^|(?<=[^\p{L}]))[эЭ](?:[\-\–\—][эЭ])+(?=[^\p{L}]|$)(?:\s*,)?"#),
                // Russian hesitations: ааа, аа, а-а
                compile(#"(?i)(?:,\s*)?\b[аА]{2,}\b(?:\s*,)?"#),
                compile(#"(?i)(?:,\s*)?(?:^|(?<=[^\p{L}]))[аА](?:[\-\–\—][аА])+(?=[^\p{L}]|$)(?:\s*,)?"#),
                // Russian hesitations: эм, эмм
                compile(#"(?i)(?:,\s*)?\b[эЭ][мМ]+\b(?:\s*,)?"#),
                // Russian hesitations: мм, ммм, м-м
                compile(#"(?i)(?:,\s*)?\b[мМ]{2,}\b(?:\s*,)?"#),
                compile(#"(?i)(?:,\s*)?(?:^|(?<=[^\p{L}]))[мМ](?:[\-\–\—][мМ])+(?=[^\p{L}]|$)(?:\s*,)?"#),
                // Russian hesitations: хм, хмм, гм
                compile(#"(?i)(?:,\s*)?\b[хХ][мМ]+\b(?:\s*,)?"#),
                compile(#"(?i)(?:,\s*)?\b[гГ][мМ]\b(?:\s*,)?"#),
                // English hesitations: um, uh, er, ah, hmm
                compile(#"(?i)(?:,\s*)?\b(?:um+|uh+|er+|ah+|hmm+)\b(?:\s*,)?"#)
            ]
            
            // Discourse & conversational filler rules
            var rules: [(regex: NSRegularExpression, replacement: String, tokenName: String)] = []
            
            // English fillers
            rules.append((compile(#"(?i)(?:,\s*)?\byou\s+know\b(?:\s*,)?"#), " ", "you know"))
            rules.append((compile(#"(?i)(?:,\s*)?\b(?:sort|kind)\s+of\b(?:\s*,)?"#), " ", "sort of / kind of"))
            rules.append((compile(#"(?i)(?:^|(?<=[,\.!?]\s))\bbasically[,\s]*"#), "", "basically"))
            rules.append((compile(#"(?i),\s*basically\s*,"#), " ", "basically"))
            rules.append((compile(#"(?i)\bbasically\b(?:\s*,)?"#), "", "basically"))
            rules.append((compile(#"(?i)(?:^|(?<=[,\.!?]\s))\bactually[,\s]*"#), "", "actually"))
            rules.append((compile(#"(?i),\s*actually\s*,"#), " ", "actually"))
            rules.append((compile(#"(?i)(?:,\s*)?\bactually\b(?=\s*[,\.!?]|$)"#), "", "actually"))
            rules.append((compile(#"(?i)\bactually\b(?=\s+that\b)"#), "", "actually"))
            rules.append((compile(#"(?i),\s*like\s*,"#), " ", "like"))
            rules.append((compile(#"(?i)(?:^|(?<=[,\.!?]\s))\blike[,\s]+(?=[a-zA-Z])"#), "", "like"))
            rules.append((compile(#"(?i)\b(was|were|am|is|are)\s+like\s+(?=[a-zA-Z]+ing\b)"#), "$1 ", "like"))
            
            // Russian fillers
            // "короче говоря" / "короче"
            rules.append((compile(#"(?i)\bкороче(?:\s+говоря)?\b(?:\s*,)?"#), " ", "короче"))
            // "в общем говоря" / "в общем"
            rules.append((compile(#"(?i)(?:,\s*)?\bв\s+общем(?:\s+говоря)?\b(?:\s*,)?"#), " ", "в общем"))
            // "как бы" (preserving "как бы то ни было", "как бы ни было")
            rules.append((compile(#"(?i)(?:,\s*)?\bкак\s+бы\b(?!\s+(?:то\s+)?ни\s+было)(?:\s*,)?"#), " ", "как бы"))
            // "типа"
            rules.append((compile(#"(?i)(?:,\s*)?\bтипа\b(?:\s*,)?"#), " ", "типа"))
            // "значит" (when filler: not preceded by "это" or "что")
            rules.append((compile(#"(?i)(?<!\b(?:это|что)\s)(?:,\s*)?\bзначит\b(?=[,\s]|$)(?:\s*,)?"#), " ", "значит"))
            // "ну" (standalone or introductory)
            rules.append((compile(#"(?i)(?:^|(?<=[,\.!?]\s)|(?<=\s))\bну\b(?=[,\s]|$)(?:\s*,)?"#), "", "ну"))
            // "вот" at sentence end: ", вот."
            rules.append((compile(#"(?i)[,\s]+\bвот\b(?=\s*[\.!?\u2026])"#), "", "вот"))
            // "вот" (introductory/parenthetical when not pointing to demonstratives/locations)
            rules.append((compile(#"(?i)(?:^|(?<=[,\.!?]\s)|(?<=\s))\bвот\b(?!\s+(?:это|этот|эта|эти|тот|та|те|здесь|тут|он|она|оно|они|так|почему|куда|где|когда|как|зачем))(?=[,\s]|$)(?:\s*,)?"#), "", "вот"))
            
            self.fillerRules = rules
            
            // Punctuation and whitespace normalization regexes
            spaceBeforePunctRegex = compile(#"\s+([,\.!?:;\u2026])"#)
            multipleCommasRegex = compile(#"\s*,\s*,+"#)
            commaBeforeTerminatorRegex = compile(#",\s*([\.!?:;\u2026])"#)
            terminatorBeforeCommaRegex = compile(#"([\.!?:;\u2026])\s*,"#)
            multipleSpacesRegex = compile(#"\s{2,}"#)
            leadingPunctRegex = compile(#"^[\s,;]+"#)
            trailingPunctRegex = compile(#"[\s,;]+$"#)
            
            // Unnatural commas after pronouns, conjunctions, aux verbs, prepositions
            unnaturalCommaRegexes = [
                compile(#"(?i)\b(я|ты|он|она|оно|мы|вы|они|i|you|he|she|it|we|they)\s*,"#),
                compile(#"(?i)\b(и|а|но|что|чтобы|если|когда|хотя|and|but|or|so|that|if|when)\s*,"#),
                compile(#"(?i)\b(can|could|would|should|will|shall|might|may|must|am|is|are|was|were|been|можем|могу|хочу|будем|будет|буду)\s*,"#),
                compile(#"(?i)\b(в|на|с|со|к|из|у|о|об|по|от|до|for|with|at|to|in|on|of|by|from)\s*,"#)
            ]
            
            sentenceCapRegex = compile(#"([\.!?…]\s+)([\p{L}])"#)
        }
    }
    
    private static var regexCache: RegexContainer {
        RegexContainer.shared
    }
    
    // MARK: - Public Interface
    
    /// Standard protocol conformance: cleans raw text and produces the cleaned string.
    public func clean(_ rawText: String) -> String {
        Self.cleanText(rawText, isFinal: false)
    }
    
    /// Cleans raw speech transcript and returns structured result with diff metadata.
    public func clean(_ rawText: String, isFinal: Bool) -> CleanedTranscript {
        Self.clean(rawText, isFinal: isFinal)
    }
    
    /// Cleans raw speech transcript and returns the cleaned text.
    public func cleanText(_ rawText: String, isFinal: Bool = false) -> String {
        Self.cleanText(rawText, isFinal: isFinal)
    }
    
    /// Static entry point returning structured result with diff metadata.
    public static func clean(_ rawText: String, isFinal: Bool = false) -> CleanedTranscript {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CleanedTranscript(rawText: rawText, cleanedText: "", isFinal: isFinal)
        }
        
        var text = trimmed
        var diffs: [TranscriptDiff] = []
        var removedTokenSet = Set<String>()
        
        // 1. Resolve hyphenated stuttering (e.g., "в-в-встретимся" -> "встретимся", "х-хотел" -> "хотел")
        let stutterResult = resolveHyphenatedStutter(text)
        text = stutterResult.text
        diffs.append(contentsOf: stutterResult.diffs)
        for diff in stutterResult.diffs {
            removedTokenSet.insert(diff.original)
        }
        
        // 2. Initial deduplication of immediate repeated words (e.g. "завтра завтра" -> "завтра")
        let dedupResult1 = deduplicateRepeatedWords(text)
        text = dedupResult1.text
        diffs.append(contentsOf: dedupResult1.diffs)
        for diff in dedupResult1.diffs {
            removedTokenSet.insert(diff.original)
        }
        
        // 3. Strip vocal hesitations (эээ, ээ, э-э, ааа, эм, мм, м-м, um, uh, er, ah, hmm)
        for regex in regexCache.vocalHesitationRegexes {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            if !matches.isEmpty {
                for match in matches {
                    if let r = Range(match.range, in: text) {
                        let token = String(text[r]).trimmingCharacters(in: .whitespaces)
                        if !token.isEmpty {
                            removedTokenSet.insert(token)
                            diffs.append(TranscriptDiff(changeType: .removedFiller, original: token, replacement: ""))
                        }
                    }
                }
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            }
        }
        
        // 4. Strip conversational discourse fillers (ну, типа, как бы, короче, вот, значит, в общем, you know, etc.)
        for rule in regexCache.fillerRules {
            let range = NSRange(text.startIndex..., in: text)
            let matches = rule.regex.matches(in: text, options: [], range: range)
            if !matches.isEmpty {
                for match in matches {
                    if let r = Range(match.range, in: text) {
                        let matchedText = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !matchedText.isEmpty {
                            removedTokenSet.insert(matchedText)
                            diffs.append(TranscriptDiff(changeType: .removedFiller, original: matchedText, replacement: rule.replacement))
                        }
                    }
                }
                text = rule.regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: rule.replacement)
            }
        }
        
        // 5. Secondary deduplication of repeated words that were previously separated by fillers (e.g. "завтра эээ завтра")
        let dedupResult2 = deduplicateRepeatedWords(text)
        text = dedupResult2.text
        diffs.append(contentsOf: dedupResult2.diffs)
        for diff in dedupResult2.diffs {
            removedTokenSet.insert(diff.original)
        }
        
        // 6. Normalize punctuation, commas after conjunctions/pronouns/adverbs, and whitespace
        text = normalizePunctuationAndSpacing(text)
        
        // 7. Sentence capitalization
        text = restoreSentenceCapitalization(text)
        
        // 8. Terminal punctuation for completed final transcripts
        if isFinal && text.count > 2 {
            if let lastChar = text.last, !".!?…".contains(lastChar) {
                text.append(".")
            }
        }
        
        let removedTokens = Array(removedTokenSet).sorted()
        return CleanedTranscript(
            rawText: rawText,
            cleanedText: text,
            removedTokens: removedTokens,
            diffs: diffs,
            isFinal: isFinal
        )
    }
    
    /// Static entry point returning the cleaned string directly.
    public static func cleanText(_ rawText: String, isFinal: Bool = false) -> String {
        clean(rawText, isFinal: isFinal).cleanedText
    }
    
    /// Static protocol-compatible overload.
    public static func clean(_ rawText: String) -> String {
        cleanText(rawText, isFinal: false)
    }
    
    // MARK: - Internal Processing Steps
    
    /// Resolves hyphenated stutters like "в-в-встретимся" -> "встретимся", "х-хотел" -> "хотел",
    /// while strictly preserving legitimate hyphenated words like "кое-кто", "из-за", "state-of-the-art".
    private static func resolveHyphenatedStutter(_ text: String) -> (text: String, diffs: [TranscriptDiff]) {
        guard text.contains("-") else { return (text, []) }
        
        var result = text
        var diffs: [TranscriptDiff] = []
        let range = NSRange(result.startIndex..., in: result)
        let matches = regexCache.hyphenatedWordRegex.matches(in: result, options: [], range: range)
        
        // Iterate in reverse so modifying character ranges does not invalidate preceding match ranges
        for match in matches.reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[tokenRange])
            let parts = token.components(separatedBy: "-")
            guard parts.count >= 2, let finalWord = parts.last, !finalWord.isEmpty else { continue }
            
            var isStutter = true
            for prefix in parts.dropLast() {
                guard !prefix.isEmpty,
                      prefix.count < finalWord.count,
                      finalWord.lowercased().hasPrefix(prefix.lowercased()) else {
                    isStutter = false
                    break
                }
            }
            
            if isStutter {
                let isFirstUpper = token.first?.isUppercase == true
                let replacement: String
                if isFirstUpper {
                    replacement = finalWord.prefix(1).uppercased() + finalWord.dropFirst()
                } else {
                    replacement = finalWord.lowercased()
                }
                result.replaceSubrange(tokenRange, with: replacement)
                diffs.append(TranscriptDiff(changeType: .removedStutter, original: token, replacement: replacement))
            }
        }
        
        return (result, diffs)
    }
    
    /// Deduplicates immediate repeated words such as "завтра завтра" -> "завтра", "я я" -> "я", "we we" -> "we".
    private static func deduplicateRepeatedWords(_ text: String) -> (text: String, diffs: [TranscriptDiff]) {
        var current = text
        var diffs: [TranscriptDiff] = []
        var iterations = 0
        let maxIterations = 5
        
        while iterations < maxIterations {
            let range = NSRange(current.startIndex..., in: current)
            let matches = regexCache.repeatedWordRegex.matches(in: current, options: [], range: range)
            if matches.isEmpty { break }
            
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: current),
                      let wordRange = Range(match.range(at: 1), in: current) else { continue }
                let fullMatch = String(current[fullRange])
                let retainedWord = String(current[wordRange])
                current.replaceSubrange(fullRange, with: retainedWord)
                diffs.append(TranscriptDiff(changeType: .removedRepetition, original: fullMatch, replacement: retainedWord))
            }
            iterations += 1
        }
        
        return (current, diffs)
    }
    
    /// Normalizes punctuation spacing, cleans dangling commas left after filler removal,
    /// and ensures proper whitespace.
    private static func normalizePunctuationAndSpacing(_ text: String) -> String {
        var s = text
        
        // 1. Collapse multiple consecutive commas: ", ," or ",,," -> ","
        var range = NSRange(s.startIndex..., in: s)
        s = regexCache.multipleCommasRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: ",")
        
        // 2. Remove space before punctuation marks: "word , text" -> "word, text"
        range = NSRange(s.startIndex..., in: s)
        s = regexCache.spaceBeforePunctRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$1")
        
        // 3. Comma followed by sentence terminator: ", ." -> "."
        range = NSRange(s.startIndex..., in: s)
        s = regexCache.commaBeforeTerminatorRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$1")
        
        // 4. Sentence terminator followed by comma: ". ," -> "."
        range = NSRange(s.startIndex..., in: s)
        s = regexCache.terminatorBeforeCommaRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$1")
        
        // 5. Clean unnatural commas left after filler removal (e.g. after pronouns, conjunctions, aux verbs, prepositions)
        for commaRegex in regexCache.unnaturalCommaRegexes {
            range = NSRange(s.startIndex..., in: s)
            s = commaRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$1")
        }
        
        // 6. Collapse multiple spaces into a single space
        range = NSRange(s.startIndex..., in: s)
        s = regexCache.multipleSpacesRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
        
        // 7. Strip leading and trailing punctuation & spaces
        range = NSRange(s.startIndex..., in: s)
        s = regexCache.leadingPunctRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        
        range = NSRange(s.startIndex..., in: s)
        s = regexCache.trailingPunctRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Restores sentence capitalization:
    /// - Capitalizes the first character of the transcript.
    /// - Capitalizes the first character following sentence terminators (. ! ? …).
    private static func restoreSentenceCapitalization(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        
        var s = text
        // Capitalize very first character if alphabetic
        if let first = s.first, first.isLetter, first.isLowercase {
            s = first.uppercased() + s.dropFirst()
        }
        
        // Capitalize following sentence terminators
        let range = NSRange(s.startIndex..., in: s)
        let matches = regexCache.sentenceCapRegex.matches(in: s, options: [], range: range)
        for match in matches.reversed() {
            guard let punctRange = Range(match.range(at: 1), in: s),
                  let charRange = Range(match.range(at: 2), in: s) else { continue }
            let charStr = String(s[charRange])
            let punctStr = String(s[punctRange])
            let uppercased = charStr.uppercased()
            s.replaceSubrange(punctRange.lowerBound..<charRange.upperBound, with: punctStr + uppercased)
        }
        
        return s
    }
}
