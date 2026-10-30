import Foundation

/// `project.json` 的宽容解码。
///
/// 不用 `Codable`：实测字段类型不稳定（`workshopid` 可能是 null / 数字 / 缺失，
/// `type` 大小写混杂，`tags` 可能缺失），严格解码会整条失败。
public struct ProjectJSON: Sendable, Equatable {
    public let title: String?
    public let type: String?
    public let preview: String?
    public let workshopID: String?
    public let contentRating: String?
    public let tags: [String]

    public static func decode(_ data: Data) throws -> ProjectJSON {
        // 去掉 UTF-8 BOM，JSONSerialization 不接受
        var payload = data
        if payload.starts(with: [0xEF, 0xBB, 0xBF]) {
            payload = payload.dropFirst(3)
        }

        let object = try JSONSerialization.jsonObject(with: payload)
        guard let json = object as? [String: Any] else {
            throw DecodeError.notAnObject
        }

        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ProjectJSON(
            title: (title?.isEmpty == false) ? title : nil,
            type: (json["type"] as? String)?.lowercased(),
            preview: json["preview"] as? String,
            workshopID: Self.stringValue(json["workshopid"]),
            contentRating: json["contentrating"] as? String,
            tags: (json["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    public enum DecodeError: Error, Equatable {
        case notAnObject
    }
}
