import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

/// Word-level diff (LCS) for the Lab's raw-versus-cleaned transcript view.
enum LabWordDiff {
    enum Kind: Equatable { case same, removed, added }
    struct Segment: Equatable, Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    /// Past this many words on either side no diff is produced (nil); the view shows both texts instead.
    static let maximumWords = 1500

    static func diff(_ old: String, _ new: String) -> [Segment]? {
        let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
        guard a.count <= maximumWords, b.count <= maximumWords else { return nil }
        var raw: [(Kind, String)] = []
        // table[i][j] = LCS length of a[i...] and b[j...]
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { raw.append((.same, a[i])); i += 1; j += 1 }
            else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] { raw.append((.removed, a[i])); i += 1 }
            else { raw.append((.added, b[j])); j += 1 }
        }
        return raw.enumerated().map { Segment(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }
}

/// Pulls one JSON object out of model output that may wrap it in prose or a code fence.
enum LabJSON {
    static func firstObject(in text: String) -> Data? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(characters[start...index]).data(using: .utf8) }
            default: break
            }
        }
        return nil
    }
}

/// The Grounded target answer converted to pixels of the chosen image, drawn only on the Lab's own preview.
struct LabGroundedTarget: Equatable {
    let label: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static let systemPrompt = "You locate one user interface element in the image. " + LocalGrounding.instruction()

    static func parse(_ output: String, imageWidth: Int, imageHeight: Int) -> LabGroundedTarget? {
        guard let box = LocalGrounding.parse(output, imageWidth: imageWidth, imageHeight: imageHeight) else { return nil }
        return LabGroundedTarget(label: box.label, x: box.x, y: box.y, width: box.width, height: box.height)
    }
}
