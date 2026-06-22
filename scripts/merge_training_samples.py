#!/usr/bin/env python3
import argparse
import hashlib
import json
import random
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SYNTHETIC = REPO_ROOT / "dist" / "training" / "correction_safety_synthetic.jsonl"
DEFAULT_LOCAL = REPO_ROOT / "dist" / "training" / "correction_safety_local.jsonl"
DEFAULT_OUTPUT = REPO_ROOT / "dist" / "training" / "correction_safety_mixed.jsonl"


def read_jsonl(path):
    samples = []
    if not path.exists():
        return samples

    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                sample = json.loads(stripped)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSONL: {error}") from error
            validate_sample(sample, path, line_number)
            samples.append(sample)
    return samples


def validate_sample(sample, path, line_number):
    required = ["outcome", "features", "prediction", "textContext"]
    missing = [key for key in required if key not in sample]
    if missing:
        raise ValueError(f"{path}:{line_number}: missing keys: {', '.join(missing)}")

    features = sample["features"]
    feature_keys = [
        "wordLength",
        "candidateLength",
        "sourceLanguage",
        "targetLanguage",
        "terminatorType",
        "isShortWord",
        "isTechnicalContext",
        "appMode",
        "ruleScore",
        "runnerUpScore",
        "scoreDelta",
        "hasDigits",
        "hasMixedCase",
        "hasPunctuation",
        "wasLearned",
        "wasSuppressed",
    ]
    missing_features = [key for key in feature_keys if key not in features]
    if missing_features:
        raise ValueError(f"{path}:{line_number}: missing feature keys: {', '.join(missing_features)}")


def canonical_key(sample):
    features = sample["features"]
    prediction = sample.get("prediction") or {}
    key = {
        "outcome": sample.get("outcome"),
        "textContext": sample.get("textContext"),
        "predictionAction": prediction.get("action"),
        "features": features,
    }
    encoded = json.dumps(key, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def weighted_samples(samples, weight, source):
    weighted = []
    for sample in samples:
        for copy_index in range(weight):
            clone = dict(sample)
            clone["_source"] = source
            clone["_weightCopy"] = copy_index + 1
            weighted.append(clone)
    return weighted


def deduplicated(samples):
    seen = set()
    result = []
    for sample in samples:
        key = canonical_key(sample)
        if key in seen:
            continue
        seen.add(key)
        result.append(sample)
    return result


def write_jsonl(samples, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        for sample in samples:
            clean_sample = {
                key: value
                for key, value in sample.items()
                if not key.startswith("_")
            }
            handle.write(json.dumps(clean_sample, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            handle.write("\n")


def count_by(samples, key):
    counts = {}
    for sample in samples:
        value = sample.get(key, "-")
        counts[value] = counts.get(value, 0) + 1
    return counts


def main():
    parser = argparse.ArgumentParser(
        description="Merge synthetic and exported local correction safety samples for Core ML training."
    )
    parser.add_argument("--synthetic", type=Path, default=DEFAULT_SYNTHETIC)
    parser.add_argument("--local", type=Path, default=DEFAULT_LOCAL)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--synthetic-weight", type=int, default=1)
    parser.add_argument("--local-weight", type=int, default=4)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--allow-missing-local",
        action="store_true",
        help="Write a synthetic-only mixed dataset when the local export file does not exist.",
    )
    args = parser.parse_args()

    if args.synthetic_weight < 1 or args.local_weight < 1:
        raise SystemExit("Weights must be positive integers.")

    synthetic = deduplicated(read_jsonl(args.synthetic))
    if not synthetic:
        raise SystemExit(f"No synthetic samples found at {args.synthetic}")

    if not args.local.exists() and not args.allow_missing_local:
        raise SystemExit(
            f"Local samples file not found: {args.local}\n"
            "Export local samples from Settings/Diagnostics first, or pass --allow-missing-local."
        )

    local = deduplicated(read_jsonl(args.local))
    merged = weighted_samples(synthetic, args.synthetic_weight, "synthetic")
    merged += weighted_samples(local, args.local_weight, "local")

    rng = random.Random(args.seed)
    rng.shuffle(merged)
    write_jsonl(merged, args.output)

    print(f"Synthetic unique samples: {len(synthetic)}")
    print(f"Local unique samples: {len(local)}")
    print(f"Synthetic weight: {args.synthetic_weight}")
    print(f"Local weight: {args.local_weight}")
    print(f"Mixed output samples: {len(merged)}")
    print(f"Output: {args.output}")
    print("Outcome counts:")
    for outcome, count in sorted(count_by(merged, "outcome").items()):
        print(f"  {outcome}: {count}")


if __name__ == "__main__":
    main()
