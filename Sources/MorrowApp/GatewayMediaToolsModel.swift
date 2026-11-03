import Foundation
import MorrowCore
import UniformTypeIdentifiers

extension AppModel {
    func mediaClient() throws -> GatewayMediaClient {
        if let gatewayMediaClientOverride { return gatewayMediaClientOverride }
        let config = try GatewayMediaConfiguration.load(path: store.root.appendingPathComponent("media-models.json"))
        let key = try SecretStore.read(accountID: ModelEndpoint.credentialID(config.baseURL))
        return GatewayMediaClient(configuration: config, apiKey: key)
    }
    func restoreSDKMediaOutput(_ result: OpenUIJSON, context: SDKChatContext) async throws {
        if let id = result.object["jobID"]?.text, let lease = context.workspaceLease,
           !context.mediaJobs.contains(where: { $0.id == id }) {
            context.mediaJobs.append(.init(id: id, model: result.object["model"]?.text ?? "Veo", lease: lease))
        }
        guard let value = result.object["preview"] else { return }
        let preview = try JSONDecoder().decode(AgentWorkspaceMedia.self, from: JSONEncoder().encode(value))
        guard preview.lease == context.workspaceLease else { throw MailError.message("旧工作区已清理，生成回执不可恢复文件。") }
        _ = try await sessionWorkspaces.file(preview.path, lease: preview.lease)
        if !context.generatedMedia.contains(where: { $0.id == preview.id }) { context.generatedMedia.append(preview) }
    }
    func performSDKMediaTool(_ name: String, args: [String: OpenUIJSON], context: SDKChatContext, callID: String) async throws -> OpenUIJSON {
        guard let lease = context.workspaceLease else { throw MailError.message("会话临时工作区不可用。") }
        try await sessionWorkspaces.validate(lease)
        let requestID = MailStore.hash(context.sessionID + ":media:" + callID)
        func encoded<T: Encodable>(_ value: T) throws -> OpenUIJSON { try JSONDecoder().decode(OpenUIJSON.self, from: JSONEncoder().encode(value)) }
        func saveOutput(_ output: GatewayMediaOutput, prefix: String) async throws -> OpenUIJSON {
            let ext = output.mimeType == "video/mp4" ? "mp4" : output.mimeType == "image/jpeg" ? "jpg" : output.mimeType == "image/webp" ? "webp" : "png"
            let path = "media/" + prefix + "." + ext
            let file = try await sessionWorkspaces.write(output.data, path: path, lease: lease)
            let preview = AgentWorkspaceMedia(id: prefix, name: String(path.split(separator: "/").last!), path: path, mimeType: output.mimeType, bytes: file.bytes, lease: lease)
            if !context.generatedMedia.contains(where: { $0.id == preview.id }) { context.generatedMedia.append(preview) }
            return .object(["path": .string(path), "mimeType": .string(output.mimeType), "bytes": .number(Double(file.bytes)), "model": .string(output.model),
                "preview": try encoded(preview),
                "costUSD": output.costUSD.map { .number($0) } ?? .null, "instruction": .string("文件已生成并存入当前会话工作区，回答将显示预览。要附到草稿，请read_draft后attach_workspace_file。归档会删除临时文件。")])
        }
        switch name {
        case "list_workspace": return try encoded(await sessionWorkspaces.list(lease))
        case "stage_material":
            let id = args["materialID"]?.text ?? ""
            guard let material = context.materials.first(where: { $0.id == id }) else { throw MailError.message("本轮未带入此资料，不能读取任意文件。") }
            let data = try chatMaterialData(material)
            return try encoded(await sessionWorkspaces.write(data, path: "output/material-" + MailStore.hash(id).prefix(12) + "." + (material.name.split(separator: ".").last.map(String.init) ?? "bin"), lease: lease))
        case "list_media_models":
            let client = try mediaClient(), available = try await client.availableModels()
            let config = client.configuration
            return .object(["models": try encoded(config.models.filter { $0.enabled && available.contains($0.id) }),
                "defaultImageModel": .string(config.defaultImageModel), "defaultVideoModel": .string(config.defaultVideoModel),
                "defaultVideoUnderstandingModel": .string(config.defaultVideoUnderstandingModel), "verifiedAt": .string(config.verifiedAt)])
        case "generate_image", "generate_video":
            if let previous = try await store.object(OpenUIJSON.self, kind: "agent-media-request", id: requestID) {
                guard previous.object["generation"]?.text == lease.generation else { throw MailError.message("旧工作区已清理，此生成请求未重新提交。") }
                if previous.object["state"]?.text == "complete", let result = previous.object["result"] {
                    try await restoreSDKMediaOutput(result, context: context); return result
                }
                throw MailError.message("此媒体请求已发起且结果待确认，未重复发起收费生成。")
            }
            let client = try mediaClient(), config = client.configuration
            let model = args["model"]?.text ?? (name == "generate_image" ? config.defaultImageModel : config.defaultVideoModel)
            let prompt = args["prompt"]?.text ?? ""
            _ = try config.require(model, capability: name == "generate_image" ? "image_generation" : "video_generation")
            let size = args["size"]?.text ?? (name == "generate_image" ? "1024x1024" : "1280x720"), quality = args["quality"]?.text ?? "auto"
            let seconds = Int(args["seconds"]?.text ?? "4") ?? 0
            var images: [Data] = [], reference: Data?
            if name == "generate_image" {
                if case .array(let paths) = args["imagePaths"] {
                    guard paths.count <= 4 else { throw MailError.message("最多使用4张参考图片。") }
                    for path in paths { images.append(try await sessionWorkspaces.read(path.text, lease: lease, maximumBytes: 20 * 1024 * 1024)) }
                }
                try client.validateImage(model: model, prompt: prompt, size: size, quality: quality, images: images)
            } else {
                if let path = args["imagePath"]?.text { reference = try await sessionWorkspaces.read(path, lease: lease, maximumBytes: 20 * 1024 * 1024) }
                try client.validateVideo(model: model, prompt: prompt, seconds: seconds, size: size, reference: reference)
            }
            // A changed SDK call ID must not silently repeat an uncertain paid request.
            let fingerprint = MailStore.hash(lease.generation + name + model + prompt + size + quality + String(seconds) + (images + (reference.map { [$0] } ?? [])).map { MailStore.hash($0) }.joined())
            if let pending = try await store.object(OpenUIJSON.self, kind: "agent-media-pending", id: fingerprint), pending.object["state"]?.text == "submitting" { throw MailError.message("相同媒体请求结果待确认，未重新发起收费生成。") }
            let marker: OpenUIJSON = .object(["sessionID": .string(context.sessionID), "generation": .string(lease.generation), "state": .string("submitting"), "model": .string(model)])
            try await store.save(marker, kind: "agent-media-request", id: requestID)
            try await store.save(marker, kind: "agent-media-pending", id: fingerprint)
            let reply: OpenUIJSON
            if name == "generate_image" {
                let output = try await client.generateImage(model: model, prompt: prompt, size: size, quality: quality, images: images, idempotencyKey: requestID)
                reply = try await saveOutput(output, prefix: requestID)
            } else {
                let job = try await client.createVideo(model: model, prompt: prompt, seconds: seconds, size: size, reference: reference, idempotencyKey: requestID)
                try await sessionWorkspaces.validate(lease)
                let id = job.object["id"]?.text ?? ""
                guard !id.isEmpty else { throw MailError.message("视频网关没有返回任务ID，未重新发起生成。") }
                let record: OpenUIJSON = .object(["sessionID": .string(context.sessionID), "generation": .string(lease.generation), "model": .string(model), "job": job])
                try await store.save(record, kind: "agent-media-job", id: MailStore.hash(context.sessionID + ":" + id))
                context.mediaJobs.append(.init(id: id, model: model, lease: lease))
                reply = .object(["jobID": .string(id), "model": .string(model), "costUSD": job.object["costUSD"] ?? .null, "status": job.object["status"] ?? .string("queued"), "instruction": .string("视频请求已提交；还没有成品。用check_media_job查询，完成后才能说视频已生成。")])
            }
            try await store.save(OpenUIJSON.object(["sessionID": .string(context.sessionID), "generation": .string(lease.generation), "state": .string("complete"), "result": reply]), kind: "agent-media-request", id: requestID)
            try await store.remove(kind: "agent-media-pending", id: fingerprint)
            return reply
        case "check_media_job":
            let id = args["jobID"]?.text ?? "", key = MailStore.hash(context.sessionID + ":" + id)
            guard let record = try await store.object(OpenUIJSON.self, kind: "agent-media-job", id: key), record.object["sessionID"]?.text == context.sessionID,
                  record.object["generation"]?.text == lease.generation else { throw MailError.message("该视频任务不属于当前活动会话工作区。") }
            if let saved = record.object["output"], case .object = saved { try await restoreSDKMediaOutput(saved, context: context); context.mediaJobs.removeAll { $0.id == id }; return saved }
            let client = try mediaClient(), job = try await client.videoStatus(id)
            if job.object["status"]?.text == "completed" {
                let output = try await client.videoContent(id), result = try await saveOutput(output, prefix: key)
                var value = record.object; value["output"] = result; value["job"] = job
                try await store.save(OpenUIJSON.object(value), kind: "agent-media-job", id: key)
                context.mediaJobs.removeAll { $0.id == id }
                return result
            }
            return .object(["jobID": .string(id), "status": job.object["status"] ?? .string("unknown"), "job": job, "nextPollAfterSeconds": .number(10)])
        case "analyze_video":
            let client = try mediaClient(), path = args["path"]?.text ?? "", data = try await sessionWorkspaces.read(path, lease: lease, maximumBytes: 20 * 1024 * 1024)
            let mime = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.preferredMIMEType ?? "video/mp4"
            let analysis = try await client.analyzeVideo(model: args["model"]?.text ?? client.configuration.defaultVideoUnderstandingModel, prompt: args["prompt"]?.text ?? "", data: data, mimeType: mime)
            return .object(["text": .string(analysis.text), "costUSD": analysis.costUSD.map { .number($0) } ?? .null, "path": .string(path), "workspaceGeneration": .string(lease.generation)])
        case "attach_workspace_file":
            guard !context.readOnly else { throw MailError.message("本轮仅查询，未修改草稿。") }
            let id = args["draftID"]?.text ?? "", path = args["path"]?.text ?? ""
            guard let snapshot = context.draftSnapshots[id], var draft = try await store.object(ComposeDraft.self, kind: "draft", id: id), draft.state == "draft",
                  draft.updatedAt == snapshot.updatedAt else { throw MailError.message("请先read_draft核对当前可编辑草稿；草稿已变化或不可编辑。") }
            if let live = liveSidebarDraft(id: id), !sameDraftContent(live, snapshot) { throw MailError.message("草稿编辑内容已变化，请重新read_draft。") }
            let data = try await sessionWorkspaces.read(path, lease: lease, maximumBytes: 32 * 1024 * 1024)
            guard let latest = try await store.object(ComposeDraft.self, kind: "draft", id: id), latest.state == "draft", latest.updatedAt == snapshot.updatedAt else { throw MailError.message("草稿已被用户修改，未覆盖。") }
            if let live = liveSidebarDraft(id: id), !sameDraftContent(live, snapshot) { throw MailError.message("草稿编辑内容已变化，未覆盖。") }
            draft = snapshot
            let mime = context.generatedMedia.first { $0.path == path }?.mimeType ?? (try? GatewayMediaClient.imageMIME(data)) ?? (path.hasSuffix(".mp4") ? "video/mp4" : "application/octet-stream")
            draft.attachments.append(.init(name: String(path.split(separator: "/").last ?? "attachment"), mimeType: mime, data: data)); draft.updatedAt = Date()
            let saved = try await persistWorkingDraft(draft, artifactID: workingArtifact(for: id)?.id, expectedUpdatedAt: snapshot.updatedAt)
            if let live = liveSidebarDraft(id: id), !sameDraftContent(live, snapshot) {
                _ = try await persistWorkingDraft(live, artifactID: workingArtifact(for: id)?.id, expectedUpdatedAt: saved.updatedAt)
                throw MailError.message("你在保存时修改了草稿，编辑内容已保留，请重新核对后添加附件。")
            }
            if composer?.id == id { composer = saved }; if workingDraft?.id == id { workingDraft = saved }
            context.draftSnapshots[id] = saved; if !context.draftIDs.contains(id) { context.draftIDs.append(id) }
            return .object(["draftID": .string(id), "attachmentCount": .number(Double(saved.attachments.count)), "saved": .bool(true), "sent": .bool(false)])
        default: throw MailError.message("未知媒体工具。")
        }
    }
}
