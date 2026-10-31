import Foundation
import CMail

/// Reads only central-directory-selected entries and bounds compressed and
/// expanded sizes. No entry is ever written to a filesystem path.
enum OfficeZIP {
    struct Entry { let name: String; let offset: Int; let compressed: Int; let expanded: Int; let method: Int; let flags: Int }
    static func entries(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw MailError.message("Office ZIP 不完整。") }
        let lower = max(0, data.count - 65557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: { integer(data, $0, 4) == 0x06054b50 }) else { throw MailError.message("Office ZIP 目录无效。") }
        guard integer(data, end + 4, 2) == 0, integer(data, end + 6, 2) == 0 else { throw MailError.message("不支持分卷 Office 文档。") }
        let count = integer(data, end + 10, 2), start = integer(data, end + 16, 4)
        guard count <= 20000, start < data.count else { throw MailError.message("Office ZIP 目录超过限制。") }
        var cursor = start, output: [Entry] = []
        for _ in 0..<count {
            guard cursor <= data.count - 46, integer(data, cursor, 4) == 0x02014b50 else { throw MailError.message("Office ZIP 条目无效。") }
            let nameLength = integer(data, cursor + 28, 2), extra = integer(data, cursor + 30, 2), comment = integer(data, cursor + 32, 2)
            guard cursor + 46 + nameLength + extra + comment <= data.count else { throw MailError.message("Office ZIP 目录不完整。") }
            let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            output.append(Entry(name: name, offset: integer(data, cursor + 42, 4), compressed: integer(data, cursor + 20, 4), expanded: integer(data, cursor + 24, 4), method: integer(data, cursor + 10, 2), flags: integer(data, cursor + 8, 2)))
            cursor += 46 + nameLength + extra + comment
        }
        return output
    }
    static func read(_ entry: Entry, data: Data, maxBytes: Int) throws -> Data {
        guard entry.flags & 1 == 0, entry.expanded <= maxBytes, entry.compressed <= 32 * 1024 * 1024, entry.offset <= data.count - 30, integer(data, entry.offset, 4) == 0x04034b50 else { throw MailError.message("文档已加密、无效或展开内容超过限制。") }
        let start = entry.offset + 30 + integer(data, entry.offset + 26, 2) + integer(data, entry.offset + 28, 2)
        guard start <= data.count, entry.compressed <= data.count - start else { throw MailError.message("Office ZIP 正文不完整。") }
        let input = Data(data[start..<(start + entry.compressed)])
        if entry.method == 0 { guard input.count == entry.expanded else { throw MailError.message("ZIP 长度不符。") }; return input }
        guard entry.method == 8 else { throw MailError.message("ZIP 压缩方法不受支持。") }
        var output = Data(count: max(1, entry.expanded)), written = 0
        let capacity = output.count
        let result = input.withUnsafeBytes { source in output.withUnsafeMutableBytes { target in sm_inflate_raw(source.bindMemory(to: UInt8.self).baseAddress, input.count, target.bindMemory(to: UInt8.self).baseAddress, capacity, &written) } }
        guard result == 0, written == entry.expanded else { throw MailError.message("Office ZIP 正文解压失败。") }
        return output.prefix(written)
    }
    private static func integer(_ data: Data, _ start: Int, _ length: Int) -> Int { guard start >= 0, length <= data.count - start else { return -1 }; return (0..<length).reduce(0) { $0 | Int(data[start + $1]) << (8 * $1) } }
}
