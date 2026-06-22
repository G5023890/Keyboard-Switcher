#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import random
import re
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RESOURCES = REPO_ROOT / "KeyboardSwitcher" / "Resources"
DEFAULT_OUTPUT = REPO_ROOT / "dist" / "training" / "correction_safety_synthetic.jsonl"

LANGUAGES = ("en", "ru", "he")

ENGLISH = {
    0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"),
    5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"),
    11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"),
    16: ("y", "Y"), 17: ("t", "T"), 31: ("o", "O"), 32: ("u", "U"), 34: ("i", "I"),
    35: ("p", "P"), 37: ("l", "L"), 38: ("j", "J"), 40: ("k", "K"), 45: ("n", "N"),
    33: ("[", "{"), 30: ("]", "}"), 41: (";", ":"), 39: ("'", '"'), 42: ("\\", "|"),
    43: (",", "<"), 47: (".", ">"), 44: ("/", "?"), 50: ("`", "~"), 46: ("m", "M"),
}

RUSSIAN = {
    0: ("ф", "Ф"), 1: ("ы", "Ы"), 2: ("в", "В"), 3: ("а", "А"), 4: ("р", "Р"),
    5: ("п", "П"), 6: ("я", "Я"), 7: ("ч", "Ч"), 8: ("с", "С"), 9: ("м", "М"),
    11: ("и", "И"), 12: ("й", "Й"), 13: ("ц", "Ц"), 14: ("у", "У"), 15: ("к", "К"),
    16: ("н", "Н"), 17: ("е", "Е"), 31: ("щ", "Щ"), 32: ("г", "Г"), 34: ("ш", "Ш"),
    35: ("з", "З"), 37: ("д", "Д"), 38: ("о", "О"), 40: ("л", "Л"), 45: ("т", "Т"),
    33: ("х", "Х"), 30: ("ъ", "Ъ"), 41: ("ж", "Ж"), 39: ("э", "Э"), 42: ("ё", "Ё"),
    43: ("б", "Б"), 47: ("ю", "Ю"), 44: (".", ","), 50: ("ё", "Ё"), 46: ("ь", "Ь"),
}

HEBREW = {
    0: ("ש", "ש"), 1: ("ד", "ד"), 2: ("ג", "ג"), 3: ("כ", "כ"), 4: ("י", "י"),
    5: ("ע", "ע"), 6: ("ז", "ז"), 7: ("ס", "ס"), 8: ("ב", "ב"), 9: ("ה", "ה"),
    11: ("נ", "נ"), 12: ("/", "/"), 13: ("'", "'"), 14: ("ק", "ק"), 15: ("ר", "ר"),
    16: ("ט", "ט"), 17: ("א", "א"), 31: ("ם", "ם"), 32: ("ו", "ו"), 34: ("ן", "ן"),
    35: ("פ", "פ"), 37: ("ך", "ך"), 38: ("ח", "ח"), 40: ("ל", "ל"), 45: ("מ", "מ"),
    46: ("צ", "צ"),
}

TABLES = {
    "en": ENGLISH,
    "ru": RUSSIAN,
    "he": HEBREW,
}

HEBREW_WORDS = [
    "שלום", "תודה", "כן", "לא", "אני", "אתה", "את", "זה", "מה", "עם", "על", "של",
    "יום", "בית", "טוב", "מים", "אור", "עיר", "זמן", "ספר", "ילד", "דרך", "עבודה",
]

TECHNICAL_TOKENS = [
    "macOS", "iOS", "SwiftUI", "CoreML", "Xcode", "URLSession", "WKWebView",
    "example.com", "user@example.com", "/Users/grigory/file.txt", "api_response",
    "com.apple.Terminal", "HTTP/3", "feature/login-fix", "ViewModel", "parseJSON",
]


def read_words(path, limit=None):
    words = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            columns = line.strip().split("\t")
            word = columns[0].strip().lower()
            if not word or word in {"word", "lang"} or word.startswith("#"):
                continue
            if not word_alpha(word):
                continue
            words.append(word)
            if limit and len(words) >= limit:
                break
    return words


def read_short_whitelist(path, language, limit=None):
    words = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            columns = line.strip().split("\t")
            if len(columns) < 2 or columns[0] != language:
                continue
            word = columns[1].strip().lower()
            if not word_alpha(word):
                continue
            words.append(word)
            if limit and len(words) >= limit:
                break
    return words


def word_alpha(word):
    return bool(re.fullmatch(r"[A-Za-zА-Яа-яЁё\u0590-\u05FF]+", word))


def stroke_for_char(char, language):
    table = TABLES[language]
    for key_code, variants in table.items():
        if variants[0] == char:
            return key_code, False
        if len(variants) > 1 and variants[1] == char:
            return key_code, True
    return None


def strokes_for_text(text, language):
    strokes = []
    for char in text:
        stroke = stroke_for_char(char, language)
        if stroke is None:
            return None
        strokes.append(stroke)
    return strokes


def char_for_stroke(stroke, language):
    key_code, shifted = stroke
    variants = TABLES[language].get(key_code)
    if not variants:
        return None
    return variants[1] if shifted and len(variants) > 1 else variants[0]


def replay(strokes, language):
    chars = []
    for stroke in strokes:
        char = char_for_stroke(stroke, language)
        if char is None:
            return None
        chars.append(char)
    return "".join(chars)


def detect_language(text):
    counts = {
        "en": sum(1 for ch in text.lower() if "a" <= ch <= "z"),
        "ru": sum(1 for ch in text if "\u0400" <= ch <= "\u04ff"),
        "he": sum(1 for ch in text if "\u0590" <= ch <= "\u05ff"),
    }
    language, count = max(counts.items(), key=lambda item: item[1])
    return language if count else None


def has_mixed_case(text):
    return any(ch.islower() for ch in text) and any(ch.isupper() for ch in text)


def has_punctuation(text):
    return any(not ch.isalnum() for ch in text)


def text_context(features):
    if features["isTechnicalContext"]:
        return "technical_text"
    if features["hasDigits"] or features["hasPunctuation"]:
        return "structured_token"
    if features["hasMixedCase"]:
        return "mixed_case"
    return "plain_text"


def prediction_for(features):
    if features["appMode"] == "excluded":
        return "do_nothing", 1.0, "app is excluded"
    if features["wasSuppressed"]:
        return "do_nothing", 0.98, "user suppression exists"
    if features["isTechnicalContext"] or features["hasDigits"] or features["hasPunctuation"]:
        return "do_nothing", 0.92, "technical or structured token"
    if features["hasMixedCase"]:
        return "do_nothing", 0.88, "mixed casing looks intentional"
    required = {
        "strict": (0.82, 0.30),
        "normal": (0.74, 0.20),
        "textFocused": (0.66, 0.16),
    }.get(features["appMode"], (1.0, 1.0))
    required_score, required_delta = required
    if features["isShortWord"]:
        required_score += 0.08
        required_delta += 0.06
    if features["ruleScore"] >= required_score and features["scoreDelta"] >= required_delta:
        return "auto_correct", min(0.98, features["ruleScore"]), "clear score and delta"
    if features["ruleScore"] >= max(0.46, required_score - 0.18) and features["scoreDelta"] >= max(0.08, required_delta * 0.5):
        return "suggest_only", min(0.90, max(features["ruleScore"], 0.55)), "borderline score or delta"
    return "do_nothing", 0.82, "score too low"


def make_features(
    typed_text,
    candidate,
    target_language,
    app_mode="normal",
    terminator_type="space",
    rule_score=0.90,
    runner_up_score=0.08,
    technical=False,
    learned=False,
    suppressed=False,
):
    return {
        "wordLength": len(typed_text),
        "candidateLength": len(candidate),
        "sourceLanguage": detect_language(typed_text),
        "targetLanguage": target_language,
        "terminatorType": terminator_type,
        "isShortWord": len(typed_text) <= 2 or len(candidate) <= 2,
        "isTechnicalContext": technical,
        "appMode": app_mode,
        "ruleScore": round(rule_score, 4),
        "runnerUpScore": round(runner_up_score, 4),
        "scoreDelta": round(max(0, rule_score - runner_up_score), 4),
        "hasDigits": any(ch.isdigit() for ch in typed_text + candidate),
        "hasMixedCase": has_mixed_case(typed_text) or has_mixed_case(candidate),
        "hasPunctuation": has_punctuation(typed_text) or has_punctuation(candidate),
        "wasLearned": learned,
        "wasSuppressed": suppressed,
    }


def make_sample(outcome, features, reason):
    action, confidence, explanation = prediction_for(features)
    return {
        "id": str(uuid.uuid4()).upper(),
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "outcome": outcome,
        "features": features,
        "prediction": {
            "action": action,
            "confidence": round(confidence, 4),
            "modelIdentifier": "SyntheticRuleBasedSafetyFallback v1",
            "explanation": explanation,
        },
        "decisionReason": reason,
        "textContext": text_context(features),
    }


def positive_samples(words, target_language, source_language, rng):
    samples = []
    for word in words:
        strokes = strokes_for_text(word, target_language)
        if not strokes:
            continue
        typed = replay(strokes, source_language)
        if not typed or typed == word or not word_alpha(typed):
            continue
        app_mode = rng.choice(["normal", "textFocused", "strict"])
        score = rng.uniform(0.82, 0.96) if len(word) > 2 else rng.uniform(0.78, 0.90)
        runner = rng.uniform(0.03, 0.18)
        features = make_features(
            typed,
            word,
            target_language,
            app_mode=app_mode,
            rule_score=score,
            runner_up_score=runner,
        )
        outcome = "auto_corrected" if prediction_for(features)[0] == "auto_correct" else "suggested"
        samples.append(make_sample(outcome, features, f"synthetic {source_language}->{target_language} layout mismatch"))
    return samples


def technical_negative_samples():
    samples = []
    for token in TECHNICAL_TOKENS:
        features = make_features(
            token,
            token.lower(),
            detect_language(token) or "en",
            app_mode="strict",
            rule_score=0.12,
            runner_up_score=0.08,
            technical=True,
        )
        samples.append(make_sample("suggestion_ignored", features, "synthetic technical token should not autocorrect"))
    return samples


def same_language_negative_samples(words, language, rng):
    samples = []
    for word in words:
        score = rng.uniform(0.02, 0.22)
        runner = rng.uniform(0.01, min(score, 0.16))
        features = make_features(
            word,
            word,
            language,
            app_mode=rng.choice(["normal", "strict"]),
            rule_score=score,
            runner_up_score=runner,
        )
        samples.append(make_sample("suggestion_ignored", features, "synthetic valid current-layout word"))
    return samples


def suppressed_short_word_samples(rng):
    pairs = [
        ("b", "и", "ru"),
        ("z", "я", "ru"),
        ("ш", "i", "en"),
        ("ф", "a", "en"),
        ("u", "ו", "he"),
        ("ak", "של", "he"),
    ]
    samples = []
    for typed, candidate, language in pairs:
        features = make_features(
            typed,
            candidate,
            language,
            app_mode=rng.choice(["normal", "strict"]),
            rule_score=rng.uniform(0.45, 0.72),
            runner_up_score=rng.uniform(0.22, 0.38),
            suppressed=True,
        )
        samples.append(make_sample("undone", features, "synthetic short-word false positive"))
    return samples


def load_word_sources(limit_per_source):
    return {
        "en_core": read_short_whitelist(RESOURCES / "short_words_auto_whitelist.tsv", "en", limit_per_source),
        "en_common": read_words(RESOURCES / "en_auto_core_50k.tsv", limit_per_source),
        "ru_core": read_short_whitelist(RESOURCES / "short_words_auto_whitelist.tsv", "ru", limit_per_source),
        "ru_freq": read_words(RESOURCES / "ru_auto_core_100k.tsv", limit_per_source),
        "he": HEBREW_WORDS,
    }


def build_dataset(limit_per_source, seed):
    rng = random.Random(seed)
    sources = load_word_sources(limit_per_source)
    samples = []

    samples += positive_samples(sources["ru_core"] + sources["ru_freq"], "ru", "en", rng)
    samples += positive_samples(sources["en_core"] + sources["en_common"], "en", "ru", rng)
    samples += positive_samples(sources["he"], "he", "en", rng)
    samples += positive_samples(sources["he"], "he", "ru", rng)
    samples += positive_samples(sources["en_core"][:limit_per_source], "en", "he", rng)
    samples += positive_samples(sources["ru_core"][:limit_per_source], "ru", "he", rng)

    samples += technical_negative_samples()
    samples += same_language_negative_samples(sources["en_common"][:limit_per_source], "en", rng)
    samples += same_language_negative_samples(sources["ru_freq"][:limit_per_source], "ru", rng)
    samples += same_language_negative_samples(sources["he"], "he", rng)
    samples += suppressed_short_word_samples(rng)

    rng.shuffle(samples)
    return samples


def main():
    parser = argparse.ArgumentParser(description="Generate synthetic correction safety JSONL for future Core ML training.")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--limit-per-source", type=int, default=2500)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    samples = build_dataset(max(1, args.limit_per_source), args.seed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for sample in samples:
            handle.write(json.dumps(sample, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            handle.write("\n")

    outcome_counts = {}
    for sample in samples:
        outcome_counts[sample["outcome"]] = outcome_counts.get(sample["outcome"], 0) + 1

    print(f"Wrote {len(samples)} samples to {args.output}")
    for outcome, count in sorted(outcome_counts.items()):
        print(f"{outcome}: {count}")


if __name__ == "__main__":
    main()
