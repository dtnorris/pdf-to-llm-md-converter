import Foundation
import AppKit
import Vision

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("ERROR: \(message)\n", stderr)
    exit(code)
}

guard CommandLine.arguments.count >= 3 else {
    fail("usage: apple_vision_ocr.swift INPUT.png OUTPUT.tsv [LANGUAGE]")
}

let input = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
let language = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "en-US"

guard let image = NSImage(contentsOfFile: input) else {
    fail("cannot load image: \(input)")
}

var proposedRect = NSRect(origin: .zero, size: image.size)
guard let cgImage = image.cgImage(
    forProposedRect: &proposedRect,
    context: nil,
    hints: nil
) else {
    fail("cannot create CGImage: \(input)")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = [language]
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

do {
    try handler.perform([request])
} catch {
    fail("Vision OCR failed: \(error)")
}

var lines = ["confidence\tx\ty\twidth\theight\ttext"]
for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    let text = candidate.string
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")

    lines.append(
        String(
            format: "%.4f\t%.6f\t%.6f\t%.6f\t%.6f\t%@",
            candidate.confidence,
            box.origin.x,
            box.origin.y,
            box.size.width,
            box.size.height,
            text
        )
    )
}

do {
    try (lines.joined(separator: "\n") + "\n").write(
        toFile: output,
        atomically: true,
        encoding: .utf8
    )
} catch {
    fail("cannot write TSV: \(error)")
}
