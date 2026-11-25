//
//  AttemptLog.swift
//  glance
//
//  Photos of failed unlock attempts (an unrecognized face, or a spoof caught by liveness), stored as plain JPEGs under
//  Application Support. The date and kind live in each file name, so there is no separate index to keep in sync.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted on the main queue whenever attempts are added or removed, and when the "last seen" mark moves.
    nonisolated static let attemptLogDidChange = Notification.Name("AttemptLog.didChange")
}

nonisolated enum AttemptLog {
    enum Kind: String, CaseIterable, Sendable {
        case unrecognized
        case spoof
    }

    struct Attempt: Identifiable, Hashable, Sendable {
        let url: URL
        let date: Date
        let kind: Kind
        var id: URL { url }
    }

    static let defaultLimit = 50
    static let maxPixelSize = 1280
    static let jpegQuality = 0.7

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("glance", isDirectory: true)
            .appendingPathComponent("attempts", isDirectory: true)
    }

    /// Fresh per call — `DateFormatter` isn't Sendable, and at most a few dozen files are ever parsed at once.
    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        return formatter
    }

    private static func parse(_ fileName: String, formatter: DateFormatter) -> (date: Date, kind: Kind)? {
        guard fileName.hasSuffix(".jpg") else { return nil }
        let stem = fileName.dropLast(4)
        guard let separator = stem.lastIndex(of: "_"),
              let kind = Kind(rawValue: String(stem[stem.index(after: separator)...])),
              let date = formatter.date(from: String(stem[..<separator])) else { return nil }
        return (date, kind)
    }

    /// Writes `image` as a downscaled JPEG, then drops the oldest attempts beyond `limit`.
    @discardableResult
    static func record(
        _ image: CGImage,
        kind: Kind,
        date: Date = Date(),
        in directory: URL = defaultDirectory,
        limit: Int = defaultLimit
    ) throws -> Attempt {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = makeFormatter()
        let url = directory.appendingPathComponent("\(formatter.string(from: date))_\(kind.rawValue).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImageDestinationImageMaxPixelSize: maxPixelSize,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

        for stale in list(in: directory).dropFirst(limit) {
            try? FileManager.default.removeItem(at: stale.url)
        }
        postDidChange()
        // The file name keeps millisecond precision, so report the date exactly as `list` will.
        return Attempt(url: url, date: parse(url.lastPathComponent, formatter: formatter)?.date ?? date, kind: kind)
    }

    /// Newest first. Files whose names don't parse are ignored, so stray files in the folder are harmless.
    static func list(in directory: URL = defaultDirectory) -> [Attempt] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let formatter = makeFormatter()
        return urls
            .compactMap { url in
                parse(url.lastPathComponent, formatter: formatter).map { Attempt(url: url, date: $0.date, kind: $0.kind) }
            }
            .sorted { $0.date > $1.date }
    }

    /// Attempts newer than `lastSeen`; with no mark yet, every attempt counts.
    static func unseenCount(since lastSeen: Date?, in directory: URL = defaultDirectory) -> Int {
        let attempts = list(in: directory)
        guard let lastSeen else { return attempts.count }
        return attempts.filter { $0.date > lastSeen }.count
    }

    static func delete(_ attempt: Attempt) {
        try? FileManager.default.removeItem(at: attempt.url)
        postDidChange()
    }

    /// Removes recognized attempt files only; anything else in the folder is left alone.
    static func deleteAll(in directory: URL = defaultDirectory) {
        for attempt in list(in: directory) {
            try? FileManager.default.removeItem(at: attempt.url)
        }
        postDidChange()
    }

    private static func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .attemptLogDidChange, object: nil)
        }
    }
}
