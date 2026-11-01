import Foundation

enum PatchError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum CommentEncoding: String, CaseIterable {
    case auto = "auto"
    case windows1251 = "windows-1251"
    case utf8 = "utf-8"

    var title: String {
        switch self {
        case .auto: return "Автоматически: UTF-8 → Windows-1251"
        case .windows1251: return "Всегда Windows-1251"
        case .utf8: return "Только UTF-8"
        }
    }
}

struct PatchProfile: Decodable {
    let version: String
    let sha256: String
    let dylib: String
    let architectures: [String: ArchitectureProfile]
    let legacy_sha256: [String]
}

struct ArchitectureProfile: Decodable {
    let cpu: UInt32
    let patch_site: String
    let expected: String
    let cave: String
    let cave_capacity: Int
    let editor: EditorProfile
}

struct EditorProfile: Decodable {
    let patch_site: String
    let expected: String
    let thunk_offset: Int
}

struct TargetApplication {
    let url: URL
    let version: String
    let binary: Data
}

struct AppliedPatch {
    let application: URL
    let backup: URL
}

func address(_ text: String) throws -> UInt64 {
    guard text.hasPrefix("0x"), let result = UInt64(text.dropFirst(2), radix: 16) else {
        throw PatchError.invalid("Повреждён профиль патча: неверный адрес.")
    }
    return result
}

func bytesFromHex(_ text: String) throws -> Data {
    let chars = Array(text.utf8)
    guard chars.count <= 4096, chars.count % 2 == 0 else {
        throw PatchError.invalid("Повреждён профиль патча: неверные инструкции.")
    }
    var result = Data()
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let pair = String(bytes: chars[i..<i+2], encoding: .ascii),
              let byte = UInt8(pair, radix: 16) else {
            throw PatchError.invalid("Повреждён профиль патча: неверные инструкции.")
        }
        result.append(byte)
    }
    return result
}
