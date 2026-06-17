#!/usr/bin/env xcrun swift

import CreateML
import Foundation

struct TrainingSample: Decodable {
    let outcome: String
    let features: Features
    let prediction: Prediction?
    let textContext: String
}

struct Features: Decodable {
    let wordLength: Int
    let candidateLength: Int
    let sourceLanguage: String?
    let targetLanguage: String
    let terminatorType: String
    let isShortWord: Bool
    let isTechnicalContext: Bool
    let appMode: String
    let ruleScore: Double
    let runnerUpScore: Double
    let scoreDelta: Double
    let hasDigits: Bool
    let hasMixedCase: Bool
    let hasPunctuation: Bool
    let wasLearned: Bool
    let wasSuppressed: Bool
}

struct Prediction: Decodable {
    let action: String
    let confidence: Double
}

struct Arguments {
    var input = URL(fileURLWithPath: "dist/training/correction_safety_synthetic.jsonl")
    var csvOutput = URL(fileURLWithPath: "dist/training/correction_safety_training.csv")
    var modelOutput = URL(fileURLWithPath: "dist/training/CorrectionSafetyClassifier.mlmodel")
    var targetColumn = "targetAction"
    var seed = 42
}

enum TrainerError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidArgument(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            "Missing value for \(flag)"
        case .invalidArgument(let message):
            message
        }
    }
}

func parseArguments(_ rawArguments: [String]) throws -> Arguments {
    var arguments = Arguments()
    var index = 1
    while index < rawArguments.count {
        let flag = rawArguments[index]
        func value() throws -> String {
            guard index + 1 < rawArguments.count else { throw TrainerError.missingValue(flag) }
            index += 1
            return rawArguments[index]
        }

        switch flag {
        case "--input":
            arguments.input = URL(fileURLWithPath: try value())
        case "--csv-output":
            arguments.csvOutput = URL(fileURLWithPath: try value())
        case "--model-output":
            arguments.modelOutput = URL(fileURLWithPath: try value())
        case "--target-column":
            let target = try value()
            guard ["targetAction", "outcome"].contains(target) else {
                throw TrainerError.invalidArgument("--target-column must be targetAction or outcome")
            }
            arguments.targetColumn = target
        case "--seed":
            guard let seed = Int(try value()) else {
                throw TrainerError.invalidArgument("--seed must be an integer")
            }
            arguments.seed = seed
        case "--help", "-h":
            printHelp()
            exit(0)
        default:
            throw TrainerError.invalidArgument("Unknown argument: \(flag)")
        }
        index += 1
    }
    return arguments
}

func printHelp() {
    print("""
    Train CorrectionSafetyClassifier.mlmodel from Keyboard Switcher JSONL samples.

    Usage:
      scripts/train_correction_safety_model.swift \\
        --input dist/training/correction_safety_synthetic.jsonl \\
        --model-output dist/training/CorrectionSafetyClassifier.mlmodel

    Options:
      --target-column targetAction|outcome   Default: targetAction
      --csv-output PATH                      Flattened CSV path
      --seed INT                             Train/test split seed
    """)
}

func loadSamples(from url: URL) throws -> [TrainingSample] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text
        .split(separator: "\n")
        .compactMap { line -> TrainingSample? in
            let data = Data(line.utf8)
            return try decoder.decode(TrainingSample.self, from: data)
        }
}

func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}

func boolInt(_ value: Bool) -> String {
    value ? "1" : "0"
}

func writeCSV(samples: [TrainingSample], to url: URL) throws {
    let header = [
        "targetAction",
        "outcome",
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
        "predictionConfidence",
        "textContext"
    ]

    var lines = [header.joined(separator: ",")]
    lines.reserveCapacity(samples.count + 1)

    for sample in samples {
        let features = sample.features
        let row = [
            sample.prediction?.action ?? "do_nothing",
            sample.outcome,
            String(features.wordLength),
            String(features.candidateLength),
            features.sourceLanguage ?? "unknown",
            features.targetLanguage,
            features.terminatorType,
            boolInt(features.isShortWord),
            boolInt(features.isTechnicalContext),
            features.appMode,
            String(format: "%.6f", features.ruleScore),
            String(format: "%.6f", features.runnerUpScore),
            String(format: "%.6f", features.scoreDelta),
            boolInt(features.hasDigits),
            boolInt(features.hasMixedCase),
            boolInt(features.hasPunctuation),
            boolInt(features.wasLearned),
            boolInt(features.wasSuppressed),
            String(format: "%.6f", sample.prediction?.confidence ?? 0),
            sample.textContext
        ].map(csvEscape)
        lines.append(row.joined(separator: ","))
    }

    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

func evaluateClassifier(_ classifier: MLClassifier, trainingData: MLDataTable, testingData: MLDataTable) -> (trainingError: Double, validationError: Double) {
    let trainingError = classifier.trainingMetrics.classificationError
    let validationMetrics = classifier.evaluation(on: testingData)
    return (trainingError, validationMetrics.classificationError)
}

func featureColumns(for targetColumn: String) -> [String] {
    [
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
        "predictionConfidence",
        "textContext"
    ].filter { $0 != targetColumn }
}

do {
    let arguments = try parseArguments(CommandLine.arguments)
    let inputURL = arguments.input.standardizedFileURL
    let csvURL = arguments.csvOutput.standardizedFileURL
    let modelURL = arguments.modelOutput.standardizedFileURL

    let samples = try loadSamples(from: inputURL)
    guard samples.count >= 20 else {
        throw TrainerError.invalidArgument("Need at least 20 samples, found \(samples.count)")
    }

    try writeCSV(samples: samples, to: csvURL)

    let data = try MLDataTable(contentsOf: csvURL)
    let (trainingData, testingData) = data.randomSplit(by: 0.8, seed: arguments.seed)
    let classifier = try MLClassifier(
        trainingData: trainingData,
        targetColumn: arguments.targetColumn,
        featureColumns: featureColumns(for: arguments.targetColumn)
    )
    let metrics = evaluateClassifier(classifier, trainingData: trainingData, testingData: testingData)

    let metadata = MLModelMetadata(
        author: "Keyboard Switcher",
        shortDescription: "Local correction safety classifier for EN/RU/HE keyboard layout switching.",
        version: "0.1-stage4"
    )

    try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try classifier.write(to: modelURL, metadata: metadata)

    print("Loaded samples: \(samples.count)")
    print("CSV: \(csvURL.path)")
    print("Model: \(modelURL.path)")
    print("Target: \(arguments.targetColumn)")
    print(String(format: "Training classification error: %.4f", metrics.trainingError))
    print(String(format: "Validation classification error: %.4f", metrics.validationError))
} catch {
    fputs("Training failed: \(error)\n", stderr)
    exit(1)
}
