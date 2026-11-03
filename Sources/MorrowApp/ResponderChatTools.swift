import Foundation
import MorrowCore

extension AppModel {
    func responderConfiguration(_ rule: MailResponder) throws -> OpenUIJSON {
        func json<T: Encodable>(_ value: T) throws -> OpenUIJSON { try JSONDecoder().decode(OpenUIJSON.self, from: JSONEncoder().encode(value)) }
        return .object(["id": .string(rule.id), "title": .string(rule.title), "enabled": .bool(rule.enabled), "saved": .bool(true),
            "accountID": .string(rule.accountID), "folderPath": .string(rule.folderPath ?? ""), "senderAllowlist": .array(rule.allowedSenders.map(OpenUIJSON.string)),
            "subjectContains": .string(rule.subjectContains), "bodyContains": .string(rule.bodyContains), "response": .string(rule.response),
            "delivery": .string(rule.delivery), "dailyLimit": .number(Double(rule.dailyLimit)), "useAI": .bool(rule.useAI),
            "requireAuthentication": .bool(rule.requireAuthentication == true), "trustedAuthService": rule.trustedAuthService.map(OpenUIJSON.string) ?? .null,
            "imageReply": try rule.imageReply.map(json) ?? .null, "policy": try json(rule.policy), "configurationFingerprint": .string(rule.configurationFingerprint), "status": .string(rule.status)])
    }
    func performResponderChatTool(_ name: String, args: [String: OpenUIJSON], context: SDKChatContext, receiptID: String) async throws -> OpenUIJSON {
        if name == "list_responders" {
            return .array(responders.filter { !$0.archived }.map { .object(["id": .string($0.id), "title": .string($0.title), "enabled": .bool($0.enabled), "accountID": .string($0.accountID), "bodyContains": .string($0.bodyContains), "imageReply": .bool($0.imageReply != nil), "status": .string($0.status)]) })
        }
        if name == "setup_responder" {
            let instruction = args["instruction"]?.text ?? ""
            guard !instruction.isEmpty else { throw MailError.message("请明确响应器目的和来源白名单。") }
            var rule = MailResponder()
            if let id = args["responderID"]?.text, !id.isEmpty {
                guard let snapshot = context.responderSnapshots[id], let current = try await store.object(MailResponder.self, kind: "responder", id: id),
                      snapshot.configurationFingerprint == current.configurationFingerprint else { throw MailError.message("请先read_responder读取当前规则；规则已变化时重新核对。") }
                rule = snapshot
            } else { rule.id = receiptID }
            rule.title = args["title"]?.text ?? (rule.title.isEmpty ? "新的响应器" : rule.title)
            rule.response = args["response"]?.text ?? instruction
            rule.accountID = args["accountID"]?.text ?? rule.accountID
            rule.folderPath = args["folderPath"]?.text ?? rule.folderPath
            rule.subjectContains = args["subjectContains"]?.text ?? rule.subjectContains
            rule.bodyContains = args["bodyContains"]?.text ?? rule.bodyContains
            rule.delivery = args["delivery"]?.text ?? rule.delivery
            if let limit = args["dailyLimit"] { guard let value = Int(limit.text), (1...100).contains(value) else { throw MailError.message("每日响应上限须为1到100。") }; rule.dailyLimit = value }
            if case .array(let senders) = args["senderAllowlist"] {
                let values = senders.map { $0.text.lowercased() }
                guard values.allSatisfy({ MailResponder.validSender($0) && (context.userProvidedSenderAddresses.contains($0) || context.instruction.localizedCaseInsensitiveContains($0)) }) else { throw MailError.message("来源白名单必须是用户明确给出的精确邮箱地址；请在响应器界面填写。") }
                rule.senderAllowlist = values; rule.sender = values.joined(separator: ", ")
            }
            if args["imageReply"] == .bool(true) {
                rule.imageReply = ResponderImageReply(model: args["imageModel"]?.text, size: args["imageSize"]?.text ?? "1024x1024", quality: args["imageQuality"]?.text ?? "auto")
                try rule.imageReply?.validate(); rule.useAI = true
                var policy = rule.policy; if !policy.allowedTools.contains("generateImage") { policy.allowedTools.append("generateImage") }; policy.maximumSeconds = max(360, policy.maximumSeconds); rule.executionPolicy = policy
                if args["dailyLimit"] == nil && rule.boundAccountFingerprint == nil { rule.dailyLimit = 3 }
            } else if args["imageReply"] == .bool(false) {
                rule.imageReply = nil; var policy = rule.policy; policy.allowedTools.removeAll { $0 == "generateImage" }; rule.executionPolicy = policy
            }
            if accounts.first(where: { $0.id == rule.accountID })?.imapHost == "imap.gmail.com" { rule.trustedAuthService = "mx.google.com" }
            rule.sessionID = context.sessionID
            // Keep an existing editor's version for conflict detection, while
            // the displayed new rule is disabled until the user's save action.
            var page = OpenUIInteraction(source: try responderReviewSource(rule))
            page.responderDraft = rule; page.sessionID = context.sessionID
            context.presentation = page
            let message = rule.boundAccountFingerprint == nil ? "响应器设置已准备，尚未保存或启用。" : "响应器变更已准备，尚未保存；原规则保留当前启用状态。"
            return .object(["responderID": .string(rule.id), "reviewRequired": .bool(true), "saved": .bool(false), "enabled": .bool(rule.enabled), "interactionID": .string(page.id), "message": .string(message + "请核对来源、关键词、回复方式和图片生成费用，在Chat中点击保存并启用响应器。")])
        }
        let id = args["responderID"]?.text ?? ""
        guard let rule = try await store.object(MailResponder.self, kind: "responder", id: id), !rule.archived else { throw MailError.message("响应器不存在或已归档。") }
        if name == "read_responder" { context.responderSnapshots[id] = rule; return try responderConfiguration(rule) }
        if name == "responder_status" {
            let receipts = try await store.load(ResponderReceipt.self, kind: "responder-receipt")
                .filter { $0.responderID == id && (context.allowedIDs?.contains($0.mailID) ?? true) }.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            return .object(["configuration": try responderConfiguration(rule), "receipts": .array(receipts.prefix(20).map { .object(["id": .string($0.id), "mailID": .string($0.mailID), "state": .string($0.state), "detail": .string($0.detail), "draftID": $0.draftID.map(OpenUIJSON.string) ?? .null]) }), "coverage": .string("最近20条实际执行回执；没有回执表示尚无可核验的执行结果")])
        }
        guard name == "test_responder", ["测试", "试跑", "验证", "是否生效", "test"].contains(where: context.instruction.localizedCaseInsensitiveContains),
              let mail = try await store.message(args["messageID"]?.text ?? ""), !isOutbound(mail), context.allowedIDs?.contains(mail.id) ?? true else { throw MailError.message("试跑需要用户明确要求及本轮允许的匹配来信。") }
        let draft = try await responderDraft(rule, mail: mail)
        context.evidenceIDs.insert(mail.id)
        if let image = draft.attachments.first, let lease = context.workspaceLease {
            let path = "media/" + MailStore.hash(image.id) + "." + (image.mimeType == "image/jpeg" ? "jpg" : image.mimeType == "image/webp" ? "webp" : "png")
            let file = try await sessionWorkspaces.write(image.data, path: path, lease: lease)
            context.generatedMedia.append(.init(id: image.id, name: image.name, path: path, mimeType: image.mimeType, bytes: file.bytes, lease: lease))
        }
        return .object(["responderID": .string(id), "mailID": .string(mail.id), "previewBody": .string(draft.body), "to": .string(draft.to), "attachmentCount": .number(Double(draft.attachments.count)), "draftPreparationVerified": .bool(true), "sent": .bool(false), "saved": .bool(false), "message": .string("试跑已通过起草与核对，仅返回预览；未发送邮件，也未更改启用状态。")])
    }
    func responderReviewSource(_ rule: MailResponder) throws -> String {
        func q(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        func input(_ key: String, _ label: String, _ value: String, area: Bool = false) throws -> String { "FormControl(\(try q(label)), \(area ? "TextArea" : "Input")(\(try q(key)), \(try q(label)), \(try q(value))))" }
        func choice(_ key: String, _ label: String, _ options: [String], _ value: String) throws -> String {
            let labels = ["ai": "AI按要求起草", "fixed": "固定正文", "draft": "准备草稿", "send": "自动回复", "none": "不生成图片", "image": "生成一张图片", "dmarc": "DMARC验证", "address": "仅地址白名单", "auto": "自动", "low": "低", "medium": "中", "high": "高"]
            let rows = options.map { ["label": labels[$0] ?? $0, "value": $0] }
            let encoded = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
            return "Choice(\(try q(key)), \(try q(label)), \(encoded), \(try q(value)))"
        }
        let accountsJSON = String(decoding: try JSONEncoder().encode(accounts.filter(\.enabled).map { ["label": $0.email, "value": $0.id] }), as: UTF8.self)
        let accountField = "Choice(\"accountID\", \"来源邮箱\", \(accountsJSON), \(try q(rule.accountID)))"
        let fields = try [input("title", "名称", rule.title), accountField, input("folder", "来源文件夹", rule.folderPath ?? "INBOX"),
            input("sender", "发件邮箱白名单", rule.allowedSenders.joined(separator: ", ")), input("subject", "主题包含", rule.subjectContains), input("body", "正文包含", rule.bodyContains),
            input("response", "回复要求", rule.response, area: true), choice("contentMode", "回复内容", ["ai", "fixed"], rule.useAI ? "ai" : "fixed"),
            choice("delivery", "响应方式", ["draft", "send"], rule.delivery), input("dailyLimit", "每天响应上限", String(rule.dailyLimit)),
            choice("imageReply", "图片附件", ["none", "image"], rule.imageReply == nil ? "none" : "image"),
            input("imageModel", "图片模型（留空使用配置默认）", rule.imageReply?.model ?? ""), choice("imageSize", "图片尺寸", ["auto", "1024x1024", "1536x1024", "1024x1536"], rule.imageReply?.size ?? "1024x1024"),
            choice("imageQuality", "图片质量", ["auto", "low", "medium", "high", "xhigh", "max"], rule.imageReply?.quality ?? "auto"),
            choice("authentication", "发件身份验证", ["dmarc", "address"], rule.requireAuthentication == true ? "dmarc" : "address"), input("authService", "可信认证服务", rule.trustedAuthService ?? "")]
        return "root = Form(\"responder\", [CardHeader(\"确认响应器\", \"只处理保存后匹配的新来信；图片生成有费用，每封最多一张。自动发送只回复原发件人，发送前有10秒撤回窗口。\"), " + fields.joined(separator: ", ") + ", Button(\"保存并启用响应器\", @SaveResponder())])"
    }
}
