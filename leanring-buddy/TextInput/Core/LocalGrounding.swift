import Foundation

/// Grounded-target contract for local vision models. Qwen3-VL is trained to answer with `bbox_2d` on a 0–1000
/// grid relative to the image, and the worker may downscale the image before inference, so the host asks for
/// that model-native frame and converts to pixels of the image it sent. Asking for raw pixels made the model
/// answer in its native grid anyway (y = 875 on an 800 px image).
nonisolated public enum LocalGrounding {
    public static let gridSize = 1000.0

    public static func instruction(label: String? = nil) -> String {
        let name = label.map { "\"\($0)\"" } ?? "\"<short element name>\""
        return "Answer with only a JSON object of the form {\"label\": \(name), \"bbox_2d\": [x1, y1, x2, y2]} "
            + "where the box is on a 0–1000 grid relative to the image: (0, 0) is the top-left corner and "
            + "(1000, 1000) the bottom-right corner, x1 < x2, y1 < y2."
    }

    /// The first JSON object in `output` with a string label and a valid 0–1000 `bbox_2d`, in image pixels.
    public static func parse(_ output: String, imageWidth: Int, imageHeight: Int) -> LocalVisionBox? {
        guard imageWidth > 0, imageHeight > 0, let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"),
              open < close, let data = String(output[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let label = object["label"] as? String, let raw = object["bbox_2d"] as? [Any], raw.count == 4 else { return nil }
        let values = raw.compactMap(number)
        guard values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= gridSize * 1.02 }),
              values[0] < values[2], values[1] < values[3] else { return nil }
        let scaleX = Double(imageWidth) / gridSize, scaleY = Double(imageHeight) / gridSize
        return LocalVisionBox(label: label, x: values[0] * scaleX, y: values[1] * scaleY,
                              width: (values[2] - values[0]) * scaleX, height: (values[3] - values[1]) * scaleY)
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
