import Foundation

public enum BoundedFileReader {
    /// Caller owns security-scoped access. The byte cap also covers file growth
    /// between metadata inspection and reading, without mapping a huge file.
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else { throw MailError.message("文件大小限制无效。") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw MailError.message("请选择普通文件。") }
        guard let size = values.fileSize, size <= maximumBytes else { throw MailError.message("文件超过大小限制，请使用网盘链接。") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var data = Data(); data.reserveCapacity(min(size, maximumBytes))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try file.read(upToCount: min(1024 * 1024, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw MailError.message("文件超过大小限制，请使用网盘链接。") }
        return data
    }
}
