#!/usr/bin/env python3
"""
Local Transcript Cleaner Tests for Edge Eloquent.
Validates:
- Russian vocal hesitations (эээ, э-э, ааа, эм, мм, м-м)
- Russian discourse fillers (ну, типа, как бы, короче, в общем)
- Context preservation ("Что это значит?", "Вот это да!", "Как бы то ни было")
- English vocal hesitations (um, uh, er, ah, hmm)
- English discourse fillers (basically, you know, kind of, sort of, actually, like)
- English context preservation ("I like pizza", "It looks like rain")
- Immediate duplicate repeated words ("завтра завтра", "я я я", "we we we")
- Hyphenated stuttering resolution ("в-в-встретимся", "W-w-wait", "х-хотел")
- Legitimate hyphenated word preservation ("кое-кто", "из-за", "state-of-the-art")
- Dangling comma and spacing normalization
- Sentence capitalization
- Realtime vs Final mode
- Structured diff metadata and removed tokens
"""

import unittest
import re


class LocalTranscriptCleaner:
    """Python implementation exactly mirroring Sources/EdgeEloquent/Transcription/LocalTranscriptCleaner.swift."""

    _hyphenated_word_regex = re.compile(r"(?:^|(?<=[^\w]))([\w]+(?:-[\w]+)+)(?=[^\w]|$)", re.UNICODE)
    _repeated_word_regex = re.compile(r"(?i)(?:^|(?<=[^\w]))([\w]+)(?:[\s,]+)\1(?=[^\w]|$)", re.UNICODE)

    _vocal_hesitations = [
        re.compile(r"(?i)(?:,\s*)?\b[эЭ]{2,}\b(?:\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?(?:^|(?<=[^\w]))[эЭ](?:[\-\–\—][эЭ])+(?=[^\w]|$)(\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?\b[аА]{2,}\b(?:\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?(?:^|(?<=[^\w]))[аА](?:[\-\–\—][аА])+(?=[^\w]|$)(\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?\b[эЭ][мМ]+\b(?:\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?\b[мМ]{2,}\b(?:\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?(?:^|(?<=[^\w]))[мМ](?:[\-\–\—][мМ])+(?=[^\w]|$)(\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?\b[хХ][мМ]+\b(?:\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?\b[гГ][мМ]\b(?:\s*,)?"),
        re.compile(r"(?i)(?:,\s*)?\b(?:um+|uh+|er+|ah+|hmm+)\b(?:\s*,)?"),
    ]

    _filler_rules = [
        (re.compile(r"(?i)(?:,\s*)?\byou\s+know\b(?:\s*,)?"), " "),
        (re.compile(r"(?i)(?:,\s*)?\b(?:sort|kind)\s+of\b(?:\s*,)?"), " "),
        (re.compile(r"(?i)(?:^|(?<=[,\.!?]\s))\bbasically[,\s]*"), ""),
        (re.compile(r"(?i),\s*basically\s*,"), " "),
        (re.compile(r"(?i)\bbasically\b(?:\s*,)?"), ""),
        (re.compile(r"(?i)(?:^|(?<=[,\.!?]\s))\bactually[,\s]*"), ""),
        (re.compile(r"(?i),\s*actually\s*,"), " "),
        (re.compile(r"(?i)(?:,\s*)?\bactually\b(?=\s*[,\.!?]|$)"), ""),
        (re.compile(r"(?i)\bactually\b(?=\s+that\b)"), ""),
        (re.compile(r"(?i),\s*like\s*,"), " "),
        (re.compile(r"(?i)(?:^|(?<=[,\.!?]\s))\blike[,\s]+(?=[a-zA-Z])"), ""),
        (re.compile(r"(?i)\b(was|were|am|is|are)\s+like\s+(?=[a-zA-Z]+ing\b)"), r"\1 "),
        (re.compile(r"(?i)\bкороче(?:\s+говоря)?\b(?:\s*,)?"), " "),
        (re.compile(r"(?i)(?:,\s*)?\bв\s+общем(?:\s+говоря)?\b(?:\s*,)?"), " "),
        (re.compile(r"(?i)(?:,\s*)?\bкак\s+бы\b(?!\s+(?:то\s+)?ни\s+было)(?:\s*,)?"), " "),
        (re.compile(r"(?i)(?:,\s*)?\bтипа\b(?:\s*,)?"), " "),
        (re.compile(r"(?i)(?<!\b(?:это|что)\s)(?:,\s*)?\bзначит\b(?=[,\s]|$)(?:\s*,)?"), " "),
        (re.compile(r"(?i)(?:^|(?<=[,\.!?]\s)|(?<=\s))\bну\b(?=[,\s]|$)(?:\s*,)?"), ""),
        (re.compile(r"(?i)[,\s]+\bвот\b(?=\s*[\.!?…])"), ""),
        (re.compile(r"(?i)(?:^|(?<=[,\.!?]\s)|(?<=\s))\bвот\b(?!\s+(?:это|этот|эта|эти|тот|та|те|здесь|тут|он|она|оно|они|так|почему|куда|где|когда|как|зачем))(?=[,\s]|$)(?:\s*,)?"), ""),
    ]

    _multiple_commas = re.compile(r"\s*,\s*,+")
    _space_before_punct = re.compile(r"\s+([,\.!?:;…])")
    _comma_before_term = re.compile(r",\s*([\.!?:;…])")
    _term_before_comma = re.compile(r"([\.!?:;…])\s*,")
    _multiple_spaces = re.compile(r"\s{2,}")
    _leading_punct = re.compile(r"^[\s,;]+")
    _trailing_punct = re.compile(r"[\s,;]+$")

    _unnatural_commas = [
        re.compile(r"(?i)\b(я|ты|он|она|оно|мы|вы|они|i|you|he|she|it|we|they)\s*,"),
        re.compile(r"(?i)\b(и|а|но|что|чтобы|если|когда|хотя|and|but|or|so|that|if|when)\s*,"),
        re.compile(r"(?i)\b(can|could|would|should|will|shall|might|may|must|am|is|are|was|were|been|можем|могу|хочу|будем|будет|буду)\s*,"),
        re.compile(r"(?i)\b(в|на|с|со|к|из|у|о|об|по|от|до|for|with|at|to|in|on|of|by|from)\s*,"),
    ]

    _sentence_cap = re.compile(r"([\.!?…]\s+)([\w])", re.UNICODE)

    @classmethod
    def resolve_hyphenated_stutter(cls, text: str) -> tuple[str, list[dict]]:
        if "-" not in text:
            return text, []

        diffs = []

        def replace_token(match):
            token = match.group(1)
            parts = token.split("-")
            if len(parts) < 2:
                return match.group(0)
            final_word = parts[-1]
            if not final_word:
                return match.group(0)

            is_stutter = True
            for prefix in parts[:-1]:
                if not prefix or len(prefix) >= len(final_word) or not final_word.lower().startswith(prefix.lower()):
                    is_stutter = False
                    break

            if is_stutter:
                if token[0].isupper():
                    replacement = final_word[0].upper() + final_word[1:]
                else:
                    replacement = final_word.lower()
                diffs.append({"type": "removedStutter", "original": token, "replacement": replacement})
                return replacement
            return match.group(0)

        result = cls._hyphenated_word_regex.sub(replace_token, text)
        return result, diffs

    @classmethod
    def deduplicate_repeated_words(cls, text: str) -> tuple[str, list[dict]]:
        current = text
        diffs = []
        for _ in range(5):
            def repl(m):
                word = m.group(1)
                full = m.group(0)
                diffs.append({"type": "removedRepetition", "original": full, "replacement": word})
                return word

            new_text, count = cls._repeated_word_regex.subn(repl, current)
            if count == 0:
                break
            current = new_text
        return current, diffs

    @classmethod
    def normalize_punctuation(cls, text: str) -> str:
        s = cls._multiple_commas.sub(",", text)
        s = cls._space_before_punct.sub(r"\1", s)
        s = cls._comma_before_term.sub(r"\1", s)
        s = cls._term_before_comma.sub(r"\1", s)
        for r in cls._unnatural_commas:
            s = r.sub(r"\1", s)
        s = cls._multiple_spaces.sub(" ", s)
        s = cls._leading_punct.sub("", s)
        s = cls._trailing_punct.sub("", s)
        return s.strip()

    @classmethod
    def capitalize_sentences(cls, text: str) -> str:
        if not text:
            return ""
        s = text[0].upper() + text[1:] if text[0].isalpha() else text
        s = cls._sentence_cap.sub(lambda m: m.group(1) + m.group(2).upper(), s)
        return s

    @classmethod
    def clean(cls, raw_text: str, is_final: bool = False) -> dict:
        trimmed = raw_text.strip()
        if not trimmed:
            return {"raw": raw_text, "cleaned": "", "removed_tokens": [], "diffs": []}

        text = trimmed
        diffs = []
        removed_tokens = set()

        # 1. Hyphenated stutter
        text, st_diffs = cls.resolve_hyphenated_stutter(text)
        diffs.extend(st_diffs)
        for d in st_diffs:
            removed_tokens.add(d["original"])

        # 2. Dedup
        text, d_diffs = cls.deduplicate_repeated_words(text)
        diffs.extend(d_diffs)
        for d in d_diffs:
            removed_tokens.add(d["original"])

        # 3. Hesitations
        for r in cls._vocal_hesitations:
            for match in r.finditer(text):
                tok = match.group(0).strip()
                if tok:
                    removed_tokens.add(tok)
                    diffs.append({"type": "removedFiller", "original": tok, "replacement": ""})
            text = r.sub(" ", text)

        # 4. Fillers
        for r, replacement in cls._filler_rules:
            for match in r.finditer(text):
                tok = match.group(0).strip()
                if tok:
                    removed_tokens.add(tok)
                    diffs.append({"type": "removedFiller", "original": tok, "replacement": replacement})
            text = r.sub(replacement, text)

        # 5. Dedup again
        text, d_diffs2 = cls.deduplicate_repeated_words(text)
        diffs.extend(d_diffs2)
        for d in d_diffs2:
            removed_tokens.add(d["original"])

        # 6. Normalize punctuation
        text = cls.normalize_punctuation(text)

        # 7. Capitalize
        text = cls.capitalize_sentences(text)

        # 8. Terminal punctuation
        if is_final and len(text) > 2 and text[-1] not in ".!?…":
            text += "."

        return {
            "raw": raw_text,
            "cleaned": text,
            "removed_tokens": sorted(list(removed_tokens)),
            "diffs": diffs,
        }

    @classmethod
    def clean_text(cls, raw_text: str, is_final: bool = False) -> str:
        return cls.clean(raw_text, is_final=is_final)["cleaned"]


class TestLocalTranscriptCleaner(unittest.TestCase):

    def test_russian_hesitations(self):
        input_text = "Эээ, мы, э-э, собирались пойти, ааа, в кино, эм, или мм, м-м, в кафе."
        cleaned = LocalTranscriptCleaner.clean_text(input_text, is_final=True)

        for hesitation in ["эээ", "э-э", "ааа", "эм", "м-м"]:
            self.assertNotIn(hesitation, cleaned.lower())

        self.assertEqual(cleaned, "Мы собирались пойти в кино или в кафе.")

    def test_russian_discourse_fillers(self):
        input_text = "Ну, короче, мы, типа, как бы договорились, в общем, завтра."
        cleaned = LocalTranscriptCleaner.clean_text(input_text, is_final=True)

        for filler in ["ну,", "короче", "типа", "как бы", "в общем"]:
            self.assertNotIn(filler, cleaned.lower())

        self.assertEqual(cleaned, "Мы договорились завтра.")

    def test_russian_context_preservation(self):
        q = "Что это значит?"
        self.assertEqual(LocalTranscriptCleaner.clean_text(q, is_final=True), "Что это значит?")

        excl = "Вот это да!"
        self.assertEqual(LocalTranscriptCleaner.clean_text(excl, is_final=True), "Вот это да!")

        idiom = "Как бы то ни было, мы победили."
        self.assertEqual(LocalTranscriptCleaner.clean_text(idiom, is_final=True), "Как бы то ни было, мы победили.")

        filler = "Вот, такие дела."
        self.assertEqual(LocalTranscriptCleaner.clean_text(filler, is_final=True), "Такие дела.")

    def test_english_hesitations(self):
        input_text = "Um, uh, we should er, ah, start the hmm meeting now."
        cleaned = LocalTranscriptCleaner.clean_text(input_text, is_final=True)

        for h in ["um", "uh", "er", "ah", "hmm"]:
            self.assertNotIn(h, cleaned.lower())

        self.assertEqual(cleaned, "We should start the meeting now.")

    def test_english_discourse_fillers(self):
        input_text = "Basically, we are, you know, kind of sort of ready, actually."
        cleaned = LocalTranscriptCleaner.clean_text(input_text, is_final=True)

        for f in ["basically", "you know", "kind of", "sort of", "actually"]:
            self.assertNotIn(f, cleaned.lower())

        self.assertEqual(cleaned, "We are ready.")

    def test_english_context_preservation(self):
        self.assertEqual(LocalTranscriptCleaner.clean_text("I like pizza.", is_final=True), "I like pizza.")
        self.assertEqual(LocalTranscriptCleaner.clean_text("It looks like rain.", is_final=True), "It looks like rain.")
        self.assertEqual(
            LocalTranscriptCleaner.clean_text("I was like thinking we can do this.", is_final=True),
            "I was thinking we can do this.",
        )
        self.assertEqual(
            LocalTranscriptCleaner.clean_text("It was, like, unbelievable.", is_final=True),
            "It was unbelievable.",
        )

    def test_repeated_immediate_words(self):
        ru = "Завтра завтра мы встретимся, я я хотел сказать."
        self.assertEqual(
            LocalTranscriptCleaner.clean_text(ru, is_final=True),
            "Завтра мы встретимся, я хотел сказать.",
        )

        multi = "я я я хотел это сделать"
        self.assertEqual(LocalTranscriptCleaner.clean_text(multi, is_final=True), "Я хотел это сделать.")

        en = "We we we can finish the the task."
        self.assertEqual(LocalTranscriptCleaner.clean_text(en, is_final=True), "We can finish the task.")

        sep = "завтра эээ завтра встретимся"
        self.assertEqual(LocalTranscriptCleaner.clean_text(sep, is_final=True), "Завтра встретимся.")

    def test_hyphenated_stuttering(self):
        ru = "В-в-встретимся завтра, я х-хотел спросить п-почему."
        self.assertEqual(
            LocalTranscriptCleaner.clean_text(ru, is_final=True),
            "Встретимся завтра, я хотел спросить почему.",
        )

        en = "W-w-wait for me, th-th-the meeting is starting."
        self.assertEqual(
            LocalTranscriptCleaner.clean_text(en, is_final=True),
            "Wait for me, the meeting is starting.",
        )

    def test_preserve_legitimate_hyphenated_words(self):
        legit = "Кое-кто из-за этого по-моему использовал state-of-the-art подход."
        self.assertEqual(
            LocalTranscriptCleaner.clean_text(legit, is_final=True),
            "Кое-кто из-за этого по-моему использовал state-of-the-art подход.",
        )

    def test_punctuation_and_spacing_normalization(self):
        messy = "  слово  ,   текст   .    второе слово  !  "
        self.assertEqual(
            LocalTranscriptCleaner.clean_text(messy, is_final=True),
            "Слово, текст. Второе слово!",
        )

        dangling = "Я, типа, не знаю, короче, что делать."
        self.assertEqual(LocalTranscriptCleaner.clean_text(dangling, is_final=True), "Я не знаю, что делать.")

        conj = "И, короче, мы пошли."
        self.assertEqual(LocalTranscriptCleaner.clean_text(conj, is_final=True), "И мы пошли.")

    def test_sentence_capitalization(self):
        inp = "привет всем. как ваши дела? надеюсь, всё отлично! удачи"
        self.assertEqual(
            LocalTranscriptCleaner.clean_text(inp, is_final=True),
            "Привет всем. Как ваши дела? Надеюсь, всё отлично! Удачи.",
        )

    def test_realtime_vs_final_transcript(self):
        in_flight = "я я сейчас говорю и"
        rt = LocalTranscriptCleaner.clean_text(in_flight, is_final=False)
        self.assertEqual(rt, "Я сейчас говорю и")
        self.assertFalse(rt.endswith("."))

        final = LocalTranscriptCleaner.clean_text(in_flight, is_final=True)
        self.assertEqual(final, "Я сейчас говорю и.")
        self.assertTrue(final.endswith("."))

    def test_structured_diff_metadata(self):
        raw = "Ну, эээ, завтра завтра встретимся в-в-встретимся."
        res = LocalTranscriptCleaner.clean(raw, is_final=True)
        self.assertEqual(res["raw"], raw)
        self.assertEqual(res["cleaned"], "Завтра встретимся.")
        self.assertTrue(len(res["removed_tokens"]) > 0)
        self.assertTrue(len(res["diffs"]) > 0)

        change_types = {d["type"] for d in res["diffs"]}
        self.assertIn("removedStutter", change_types)
        self.assertIn("removedRepetition", change_types)
        self.assertIn("removedFiller", change_types)


if __name__ == "__main__":
    unittest.main()
