//
//  LocalTranscriptCleanerTests.swift
//  EdgeEloquentTests
//
//  Created for Edge Eloquent On-Device Audio Intelligence.
//  Comprehensive unit tests for LocalTranscriptCleaner.
//

import XCTest
@testable import EdgeEloquent

final class LocalTranscriptCleanerTests: XCTestCase {
    
    // MARK: - 1. Russian Hesitation Sounds
    
    func testRussianHesitations() {
        let input = "Эээ, мы, э-э, собирались пойти, ааа, в кино, эм, или мм, м-м, в кафе."
        let cleaned = LocalTranscriptCleaner.cleanText(input, isFinal: true)
        
        // Assert pure hesitations are eliminated
        XCTAssertFalse(cleaned.contains("эээ"), "Should not contain 'эээ'")
        XCTAssertFalse(cleaned.contains("э-э"), "Should not contain 'э-э'")
        XCTAssertFalse(cleaned.contains("ааа"), "Should not contain 'ааа'")
        XCTAssertFalse(cleaned.contains("эм"), "Should not contain 'эм'")
        XCTAssertFalse(cleaned.contains("м-м"), "Should not contain 'м-м'")
        
        XCTAssertEqual(cleaned, "Мы собирались пойти в кино или в кафе.")
    }
    
    // MARK: - 2. Russian Conversational Fillers
    
    func testRussianDiscourseFillers() {
        let input = "Ну, короче, мы, типа, как бы договорились, в общем, завтра."
        let cleaned = LocalTranscriptCleaner.cleanText(input, isFinal: true)
        
        XCTAssertFalse(cleaned.lowercased().contains("ну,"), "Should remove 'ну,'")
        XCTAssertFalse(cleaned.lowercased().contains("короче"), "Should remove 'короче'")
        XCTAssertFalse(cleaned.lowercased().contains("типа"), "Should remove 'типа'")
        XCTAssertFalse(cleaned.lowercased().contains("как бы"), "Should remove 'как бы'")
        XCTAssertFalse(cleaned.lowercased().contains("в общем"), "Should remove 'в общем'")
        
        XCTAssertEqual(cleaned, "Мы договорились завтра.")
    }
    
    func testRussianContextPreservation() {
        // "Что это значит?" - "значит" is a verb here and must NOT be removed
        let question = "Что это значит?"
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(question, isFinal: true), "Что это значит?")
        
        // "Вот это да!" - "вот" is a demonstrative exclamation and must NOT be removed
        let exclamation = "Вот это да!"
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(exclamation, isFinal: true), "Вот это да!")
        
        // "как бы то ни было" - idiom must NOT have "как бы" stripped
        let idiom = "Как бы то ни было, мы победили."
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(idiom, isFinal: true), "Как бы то ни было, мы победили.")
        
        // "Вот, такие дела." -> "Вот" is an introductory filler before comma
        let fillerHere = "Вот, такие дела."
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(fillerHere, isFinal: true), "Такие дела.")
    }
    
    // MARK: - 3. English Hesitations
    
    func testEnglishHesitations() {
        let input = "Um, uh, we should er, ah, start the hmm meeting now."
        let cleaned = LocalTranscriptCleaner.cleanText(input, isFinal: true)
        
        XCTAssertFalse(cleaned.lowercased().contains("um"), "Should strip 'um'")
        XCTAssertFalse(cleaned.lowercased().contains("uh"), "Should strip 'uh'")
        XCTAssertFalse(cleaned.lowercased().contains("er"), "Should strip 'er'")
        XCTAssertFalse(cleaned.lowercased().contains("ah"), "Should strip 'ah'")
        XCTAssertFalse(cleaned.lowercased().contains("hmm"), "Should strip 'hmm'")
        
        XCTAssertEqual(cleaned, "We should start the meeting now.")
    }
    
    // MARK: - 4. English Discourse Fillers
    
    func testEnglishDiscourseFillers() {
        let input = "Basically, we are, you know, kind of sort of ready, actually."
        let cleaned = LocalTranscriptCleaner.cleanText(input, isFinal: true)
        
        XCTAssertFalse(cleaned.lowercased().contains("basically"), "Should strip 'basically'")
        XCTAssertFalse(cleaned.lowercased().contains("you know"), "Should strip 'you know'")
        XCTAssertFalse(cleaned.lowercased().contains("kind of"), "Should strip 'kind of'")
        XCTAssertFalse(cleaned.lowercased().contains("sort of"), "Should strip 'sort of'")
        XCTAssertFalse(cleaned.lowercased().contains("actually"), "Should strip 'actually'")
        
        XCTAssertEqual(cleaned, "We are ready.")
    }
    
    func testEnglishLikeContextPreservation() {
        // "I like pizza." - 'like' is the predicate verb and must be preserved
        let verbInput = "I like pizza."
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(verbInput, isFinal: true), "I like pizza.")
        
        // "It looks like rain." - 'like' is prepositional/comparative and must be preserved
        let prepInput = "It looks like rain."
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(prepInput, isFinal: true), "It looks like rain.")
        
        // "I was like thinking we can do this." - 'like' is speech filler and must be cleaned
        let fillerInput = "I was like thinking we can do this."
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(fillerInput, isFinal: true), "I was thinking we can do this.")
        
        // "It was, like, unbelievable." - 'like' between commas is speech filler
        let commaLike = "It was, like, unbelievable."
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(commaLike, isFinal: true), "It was unbelievable.")
    }
    
    // MARK: - 5. Immediate Duplicate Repeated Words
    
    func testRepeatedImmediateWords() {
        // Russian repetition
        let russian = "Завтра завтра мы встретимся, я я хотел сказать."
        let cleanedRussian = LocalTranscriptCleaner.cleanText(russian, isFinal: true)
        XCTAssertEqual(cleanedRussian, "Завтра мы встретимся, я хотел сказать.")
        
        // Multiple repetitions (3 in a row)
        let multiRep = "я я я хотел это сделать"
        let cleanedMulti = LocalTranscriptCleaner.cleanText(multiRep, isFinal: true)
        XCTAssertEqual(cleanedMulti, "Я хотел это сделать.")
        
        // English repetition
        let english = "We we we can finish the the task."
        let cleanedEnglish = LocalTranscriptCleaner.cleanText(english, isFinal: true)
        XCTAssertEqual(cleanedEnglish, "We can finish the task.")
        
        // Repetition separated by a filler: "завтра эээ завтра"
        let sepByFiller = "завтра эээ завтра встретимся"
        let cleanedSep = LocalTranscriptCleaner.cleanText(sepByFiller, isFinal: true)
        XCTAssertEqual(cleanedSep, "Завтра встретимся.")
    }
    
    // MARK: - 6. Hyphenated Stuttering
    
    func testHyphenatedStuttering() {
        // Russian stutters
        let inputRussian = "В-в-встретимся завтра, я х-хотел спросить п-почему."
        let cleanedRussian = LocalTranscriptCleaner.cleanText(inputRussian, isFinal: true)
        XCTAssertEqual(cleanedRussian, "Встретимся завтра, я хотел спросить почему.")
        
        // English stutters
        let inputEnglish = "W-w-wait for me, th-th-the meeting is starting."
        let cleanedEnglish = LocalTranscriptCleaner.cleanText(inputEnglish, isFinal: true)
        XCTAssertEqual(cleanedEnglish, "Wait for me, the meeting is starting.")
    }
    
    func testPreserveLegitimateHyphenatedWords() {
        // Hyphenated words that are NOT stutters must be strictly preserved
        let input = "Кое-кто из-за этого по-моему использовал state-of-the-art подход."
        let cleaned = LocalTranscriptCleaner.cleanText(input, isFinal: true)
        XCTAssertEqual(cleaned, "Кое-кто из-за этого по-моему использовал state-of-the-art подход.")
    }
    
    // MARK: - 7. Whitespace, Punctuation & Comma Normalization
    
    func testPunctuationAndSpacingNormalization() {
        let messy = "  слово  ,   текст   .    второе слово  !  "
        let cleaned = LocalTranscriptCleaner.cleanText(messy, isFinal: true)
        XCTAssertEqual(cleaned, "Слово, текст. Второе слово!")
    }
    
    func testDanglingCommasAfterFillerRemoval() {
        // When parenthetical fillers are removed between subject and verb, leftover commas must be cleaned
        let input = "Я, типа, не знаю, короче, что делать."
        let cleaned = LocalTranscriptCleaner.cleanText(input, isFinal: true)
        XCTAssertEqual(cleaned, "Я не знаю, что делать.")
        
        // Conjunction + comma: "И, короче, мы пошли" -> "И мы пошли."
        let conjunction = "И, короче, мы пошли."
        let cleanedConj = LocalTranscriptCleaner.cleanText(conjunction, isFinal: true)
        XCTAssertEqual(cleanedConj, "И мы пошли.")
    }
    
    // MARK: - 8. Sentence Capitalization
    
    func testSentenceCapitalization() {
        let input = "привет всем. как ваши дела? надеюсь, всё отлично! удачи"
        let cleaned = LocalTranscriptCleaner.cleanText(input, isFinal: true)
        XCTAssertEqual(cleaned, "Привет всем. Как ваши дела? Надеюсь, всё отлично! Удачи.")
    }
    
    // MARK: - 9. Realtime vs Final Transcript
    
    func testRealtimeVsFinalTranscript() {
        let inFlight = "я я сейчас говорю и"
        let cleanedRealtime = LocalTranscriptCleaner.cleanText(inFlight, isFinal: false)
        // Realtime should NOT force terminal punctuation
        XCTAssertEqual(cleanedRealtime, "Я сейчас говорю и")
        XCTAssertFalse(cleanedRealtime.hasSuffix("."))
        
        let cleanedFinal = LocalTranscriptCleaner.cleanText(inFlight, isFinal: true)
        // Final transcript should ensure terminal punctuation
        XCTAssertEqual(cleanedFinal, "Я сейчас говорю и.")
        XCTAssertTrue(cleanedFinal.hasSuffix("."))
    }
    
    // MARK: - 10. Structured Diff Metadata & Removed Tokens
    
    func testStructuredDiffMetadata() {
        let raw = "Ну, эээ, завтра завтра встретимся в-в-встретимся."
        let result = LocalTranscriptCleaner.clean(raw, isFinal: true)
        
        XCTAssertEqual(result.rawText, raw)
        XCTAssertEqual(result.cleanedText, "Завтра встретимся.")
        XCTAssertFalse(result.removedTokens.isEmpty)
        XCTAssertFalse(result.diffs.isEmpty)
        
        // Validate diff categories
        let hasStutter = result.diffs.contains { $0.changeType == .removedStutter }
        let hasRepetition = result.diffs.contains { $0.changeType == .removedRepetition }
        let hasFiller = result.diffs.contains { $0.changeType == .removedFiller }
        
        XCTAssertTrue(hasStutter, "Diff should record stutter removal")
        XCTAssertTrue(hasRepetition, "Diff should record repetition removal")
        XCTAssertTrue(hasFiller, "Diff should record filler removal")
    }
    
    // MARK: - 11. Empty and Edge Input
    
    func testEmptyAndEdgeInput() {
        XCTAssertEqual(LocalTranscriptCleaner.cleanText(""), "")
        XCTAssertEqual(LocalTranscriptCleaner.cleanText("    "), "")
        XCTAssertEqual(LocalTranscriptCleaner.cleanText("\n\t  \n"), "")
        XCTAssertEqual(LocalTranscriptCleaner.cleanText("а"), "А")
    }
    
    // MARK: - 12. Thread Safety and Performance
    
    func testThreadSafetyUnderConcurrentLoad() {
        let cleaner = LocalTranscriptCleaner.shared
        let expectation = expectation(description: "Concurrent cleaning completed")
        expectation.expectedFulfillmentCount = 100
        
        let sampleInputs = [
            "Ну, эээ, завтра завтра встретимся в-в-встретимся, короче, в общем.",
            "Um, uh, basically, we should, you know, sort of like leave now.",
            "Х-хотел спросить, типа, как дела?",
            "W-w-wait for me, th-th-the meeting is tomorrow.",
            "Кое-кто из-за этого по-моему опоздал."
        ]
        
        let group = DispatchGroup()
        for i in 0..<100 {
            DispatchQueue.global().async(group: group) {
                let input = sampleInputs[i % sampleInputs.count]
                let cleaned = cleaner.clean(input)
                XCTAssertFalse(cleaned.isEmpty)
                expectation.fulfill()
            }
        }
        
        waitForExpectations(timeout: 5.0)
    }
}
