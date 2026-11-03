import Foundation
import MorrowCore

extension AppModel {
    func responderImage(_ rule: MailResponder, mail: MailMessage, prompt: String) async throws -> (MailAttachment, ResponderImageReceipt) {
        try rule.validate()
        guard let image = rule.imageReply, rule.matches(mail) else { throw MailError.message("本响应器没有图片回复授权，或邮件不匹配。") }
        let client = try mediaClient(), model = image.model ?? client.configuration.defaultImageModel
        try client.validateImage(model: model, prompt: prompt, size: image.size, quality: image.quality, images: [])
        let claim = ResponderImageReceipt(rule: rule, mail: mail, model: model)
        let directory = store.root.appendingPathComponent("responder-media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath() else { throw MailError.message("响应器媒体目录无效。") }
        let file = directory.appendingPathComponent(claim.id)
        let receipt: ResponderImageReceipt
        let data: Data
        if try await store.claimResponderImage(claim, dailyLimit: rule.dailyLimit) {
            // Persist the claim before submitting. A timeout, restart or lost
            // response leaves it pending and cannot silently charge again.
            let output = try await client.generateImage(model: model, prompt: prompt, size: image.size, quality: image.quality, idempotencyKey: claim.id)
            guard output.data.count <= 32 * 1024 * 1024 else { throw MailError.message("生成图片超过32MiB，未作为附件交付。") }
            _ = try GatewayMediaClient.imageMIME(output.data)
            try Task.checkCancellation()
            try output.data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var complete = claim; complete.state = "complete"; complete.mimeType = output.mimeType
            complete.contentHash = MailStore.hash(output.data); complete.bytes = output.data.count; complete.costUSD = output.costUSD
            try await store.save(complete, kind: "responder-image", id: claim.id)
            receipt = complete; data = output.data
        } else {
            guard let saved = try await store.object(ResponderImageReceipt.self, kind: "responder-image", id: claim.id),
                  saved.state == "complete", saved.ruleFingerprint == claim.ruleFingerprint,
                  saved.sourceBodyVersion == mail.bodyVersion else { throw MailError.message("该邮件的生图请求已提交，结果待确认；未重复生成或发送。") }
            guard file.resolvingSymlinksInPath() == file else { throw MailError.message("生成图片文件路径已变化，未读取或重新生成。") }
            data = try BoundedFileReader.read(file, maximumBytes: 32 * 1024 * 1024)
            guard saved.contentHash == MailStore.hash(data), saved.bytes == data.count,
                  saved.mimeType == (try GatewayMediaClient.imageMIME(data)) else { throw MailError.message("生成图片文件已变化或丢失，未重新生成或发送。") }
            receipt = saved
        }
        let ext = receipt.mimeType == "image/jpeg" ? "jpg" : receipt.mimeType == "image/webp" ? "webp" : "png"
        var attachment = MailAttachment(name: "generated-image." + ext, mimeType: receipt.mimeType ?? "image/png", data: data)
        attachment.id = "responder-image:" + receipt.id
        return (attachment, receipt)
    }
}
