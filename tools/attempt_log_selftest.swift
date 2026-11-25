//
//  attempt_log_selftest.swift
//  glance (tools)
//
//  Offline test for AttemptLog's file naming, ordering, limit and deletion.
//  This project has no test target, so this compiles as a standalone script:
//
//      swiftc -parse-as-library -o /tmp/attempt_log_selftest \
//        glance/AttemptLog.swift tools/attempt_log_selftest.swift && /tmp/attempt_log_selftest
//

import Foundation
import CoreGraphics
import ImageIO

@main
enum AttemptLogSelfTest {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
    }

    static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func names(_ attempts: [AttemptLog.Attempt]) -> [String] {
        attempts.map(\.url.lastPathComponent)
    }

    static func main() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attempt-log-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = makeImage(width: 1920, height: 1080)
        let base = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC

        let first = try AttemptLog.record(image, kind: .unrecognized, date: base, in: dir)
        check(FileManager.default.fileExists(atPath: first.url.path), "record writes a file")
        check(first.url.lastPathComponent == "2027-01-15T08-00-00-000Z_unrecognized.jpg",
              "file name encodes UTC date and kind (\(first.url.lastPathComponent))")
        check(names(AttemptLog.list(in: dir)) == [first.url.lastPathComponent], "list returns the recorded attempt")
        check(AttemptLog.list(in: dir).first?.date == base, "parsed date round-trips")

        if let source = CGImageSourceCreateWithURL(first.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
            check(max(width, height) <= 1280, "JPEG longest edge <= 1280 (got \(width)x\(height))")
        } else {
            check(false, "JPEG is readable")
        }

        let second = try AttemptLog.record(image, kind: .spoof, date: base.addingTimeInterval(60), in: dir)
        check(AttemptLog.list(in: dir).map(\.kind) == [.spoof, .unrecognized], "list is newest first, kinds preserved")

        check(AttemptLog.unseenCount(since: nil, in: dir) == 2, "no last-seen mark means every attempt is unseen")
        check(AttemptLog.unseenCount(since: base.addingTimeInterval(30), in: dir) == 1, "only attempts after the mark are unseen")

        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("bad_name.jpg"))
        check(AttemptLog.list(in: dir).count == 2, "unknown file names are skipped")

        AttemptLog.delete(second)
        check(names(AttemptLog.list(in: dir)) == [first.url.lastPathComponent], "delete removes only that attempt")

        for offset in 0..<5 {
            try AttemptLog.record(image, kind: .unrecognized, date: base.addingTimeInterval(Double(100 + offset)), in: dir, limit: 3)
        }
        let limited = AttemptLog.list(in: dir)
        check(limited.count == 3, "limit keeps only the newest N (got \(limited.count))")
        check(limited.first?.date == base.addingTimeInterval(104), "newest attempt survives the trim")

        AttemptLog.deleteAll(in: dir)
        check(AttemptLog.list(in: dir).isEmpty, "deleteAll removes every attempt")
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path),
              "deleteAll leaves unrelated files alone")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
