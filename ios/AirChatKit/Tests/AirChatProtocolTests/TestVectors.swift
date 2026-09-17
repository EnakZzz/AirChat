import Foundation
import XCTest
@testable import AirChatProtocol

/// Loads the cross-platform golden vectors from `<repo>/testdata`.
///
/// The same JSON files drive the Kotlin tests, which is what keeps the two ports byte-exact.
/// Discovery walks up from `#filePath` so the vectors are found in the source checkout, and falls
/// back to a bundled copy for CI runs where the test bundle is relocated.
enum TestVectors {

    static let directory: URL = locate()

    private static func locate() -> URL {
        if let override = ProcessInfo.processInfo.environment["AIRCHAT_TESTDATA_DIR"] {
            return URL(fileURLWithPath: override)
        }

        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("testdata")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("frames.json").path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }

        let bundled = Bundle(for: TestVectorsAnchor.self).resourceURL?.appendingPathComponent("testdata")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("frames.json").path) {
            return bundled
        }

        fatalError("could not locate testdata/; set AIRCHAT_TESTDATA_DIR")
    }

    static func load(_ fileName: String) throws -> [String: Any] {
        let url = directory.appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AirChatError.format("\(fileName) is not a JSON object")
        }
        return object
    }

    static func array(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let value = object[key] as? [[String: Any]] else {
            throw AirChatError.format("missing array key \(key)")
        }
        return value
    }

    static func hex(_ value: Any?) -> Data {
        guard let string = value as? String else { return Data() }
        return ByteOps.fromHex(string)
    }

    static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let string = value as? String { return string == "true" }
        return false
    }
}

/// Anchor class used to resolve the test bundle.
private final class TestVectorsAnchor {}
