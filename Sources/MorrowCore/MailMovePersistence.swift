import Foundation
import CryptoKit

/// Prepare a confirmed location change without downloading or discarding the
/// original payload. File paths are independent even when their bytes are shared.
struct PreparedMailMove {
    var message: MailMessage
    var createdFiles: [URL]
    func rollbackFiles() { for file in createdFiles { try? FileManager.default.removeItem(at: file) } }
}

enum MailMovePersistence {
    static func prepare(source: MailMessage, target: MailMessage?, destination: MailFolder,
                        receipt: MailMoveReceipt?, localOnly: Bool, root: URL) throws -> PreparedMailMove {
        guard source.accountID == destination.accountID, !destination.path.isEmpty else { throw MailError.message("不能把邮件移动到其他账户。") }
        let managedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard ["raw", "attachments"].allSatisfy({ root.appendingPathComponent($0).resolvingSymlinksInPath().path.hasPrefix(managedRoot) }) else { throw MailError.message("邮件缓存目录不在当前工作区，未执行文件移动。") }
        var moved = source
        if !localOnly {
            guard let validity = receipt?.destinationValidity, validity > 0, validity <= UInt64(UInt32.max),
                  let uid = receipt?.destinationUID, uid > 0, uid <= UInt64(UInt32.max), receipt?.sourceUID == source.uid else { throw MailError.message("服务器移动回执的源或目标UID无法核验，需同步核对。") }
            moved.id = source.accountID + ":" + destination.path + ":" + String(validity) + ":" + String(uid)
            moved.uid = uid; moved.uidValidity = validity
        }
        moved.folder = destination.path
        if let target, target.id != source.id {
            guard target.accountID == source.accountID, target.folder == destination.path,
                  target.uid == moved.uid, target.uidValidity == moved.uidValidity,
                  target.canonicalID == source.canonicalID, target.text == source.text, target.html == source.html else { throw MailError.message("目标位置已有不匹配的本机记录，未覆盖。") }
            let sourceRaw = root.appendingPathComponent("raw/" + MailStore.hash(source.id) + ".eml")
            let targetRaw = root.appendingPathComponent("raw/" + MailStore.hash(target.id) + ".eml")
            if FileManager.default.fileExists(atPath: sourceRaw.path), FileManager.default.fileExists(atPath: targetRaw.path) {
                guard sourceRaw.resolvingSymlinksInPath().path.hasPrefix(managedRoot), targetRaw.resolvingSymlinksInPath().path.hasPrefix(managedRoot) else { throw MailError.message("原始邮件路径不在当前工作区。") }
                guard try digest(sourceRaw) == digest(targetRaw) else { throw MailError.message("目标记录的原始邮件与源邮件不一致，未覆盖。") }
            }
            var merged = target
            merged.analysis = source.analysis; merged.labels = source.labels; merged.note = source.note
            merged.actionDone = source.actionDone; merged.snoozedUntil = source.snoozedUntil
            merged.isRead = source.isRead; merged.isStarred = source.isStarred; merged.localFlagModifiedAt = source.localFlagModifiedAt
            return PreparedMailMove(message: merged, createdFiles: [])
        }
        guard moved.id != source.id else { return PreparedMailMove(message: moved, createdFiles: []) }
        let manager = FileManager.default
        var created: [URL] = [], succeeded = false
        defer { if !succeeded { for file in created { try? manager.removeItem(at: file) } } }
        func link(_ origin: URL, _ target: URL) throws {
            guard origin.resolvingSymlinksInPath().path.hasPrefix(managedRoot), target.resolvingSymlinksInPath().path.hasPrefix(managedRoot) else { throw MailError.message("邮件文件路径不在当前工作区。") }
            guard let info = try? manager.attributesOfItem(atPath: origin.path), info[.type] as? FileAttributeType == .typeRegular else { throw MailError.message("原始邮件文件不可用，未移除本机记录。") }
            if manager.fileExists(atPath: target.path) {
                guard try digest(origin) == digest(target) else { throw MailError.message("目标文件已有不同内容，未覆盖。") }
            } else { try manager.linkItem(at: origin, to: target); created.append(target) }
        }
        let raw = root.appendingPathComponent("raw/" + MailStore.hash(source.id) + ".eml")
        let movedRaw = root.appendingPathComponent("raw/" + MailStore.hash(moved.id) + ".eml")
        if manager.fileExists(atPath: raw.path) { try link(raw, movedRaw); moved.raw = Data() }
        for index in moved.attachments.indices {
            let original = moved.attachments[index]
            moved.attachments[index].id = MailStore.hash(moved.id + ":attachment:" + String(index))
            if let stored = original.storedPath {
                let origin = URL(fileURLWithPath: stored).standardizedFileURL
                guard origin.path.hasPrefix(root.appendingPathComponent("attachments").standardizedFileURL.path + "/") else { throw MailError.message("附件路径不在本机邮件库中。") }
                let target = root.appendingPathComponent("attachments/" + moved.attachments[index].id)
                try link(origin, target); moved.attachments[index].storedPath = target.path; moved.attachments[index].data = Data()
            }
            if var reference = moved.attachments[index].remoteReference {
                reference.folder = moved.folder; reference.uid = moved.uid; reference.validity = moved.uidValidity
                moved.attachments[index].remoteReference = reference
            }
        }
        succeeded = true
        return PreparedMailMove(message: moved, createdFiles: created)
    }
    private static func digest(_ path: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
