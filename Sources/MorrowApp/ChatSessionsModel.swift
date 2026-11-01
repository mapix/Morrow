import Foundation
import MorrowCore

enum ChatTaskContext { @TaskLocal static var sessionID: String? }

extension AppModel {
    func openSessionSource(_ id: String, chatID: String) async {
        guard var session = chatSessions.first(where: { $0.id == id }) else { error = "来源会话已不存在。"; return }
        guard chat.contains(where: { $0.id == chatID && ($0.sessionID ?? "legacy") == id }) else { error = "来源消息已不存在。"; return }
        if session.archived {
            session.archived = false; session.updatedAt = Date()
            do {
                _ = try await store.saveSessionMetadata(session)
                guard let i = chatSessions.firstIndex(where: { $0.id == id }) else { return }
                chatSessions[i].archived = false; chatSessions[i].updatedAt = session.updatedAt
            } catch { self.error = "来源会话未恢复：" + error.localizedDescription; return }
        }
        switchChatSession(id); chatExpanded = true; chatFocusNonce += 1
        scrollChatID = nil
        await Task.yield()
        guard activeSessionID == id else { return }
        scrollChatID = chatID
    }
    var taskSessionID: String { ChatTaskContext.sessionID ?? activeSessionID }
    var activeSession: ChatSession? { cachedSession(activeSessionID) }
    var visibleChat: [PartnerChat] { chatHistory(in: activeSessionID) }
    var taskChatHistory: [PartnerChat] { chatHistory(in: taskSessionID) }
    var currentSessionBusy: Bool { sidebarTask != nil && executingSessionID == activeSessionID }
    func restoreChatSessions() async {
        if chatSessions.isEmpty { let session = ChatSession(id: "legacy", title: chat.isEmpty ? "新对话" : "之前的对话"); chatSessions = [session]; try? await store.save(session, kind: "chat-session", id: session.id) }
        if chat.contains(where: { $0.sessionID == nil }), !chatSessions.contains(where: { $0.id == "legacy" }) { let old = ChatSession(id: "legacy", title: "之前的对话"); chatSessions.append(old); try? await store.save(old, kind: "chat-session", id: old.id) }
        let legacy = chat.filter { $0.sessionID == nil }
        for var message in legacy { message.sessionID = "legacy"; try? await store.save(message, kind: "chat", id: message.id) }
        if !legacy.isEmpty { chat = chat.map { value in var message = value; if message.sessionID == nil { message.sessionID = "legacy" }; return message } }
        activeSessionID = workspacePreferences.activeSessionID.flatMap { id in chatSessions.first { $0.id == id && !$0.archived }?.id } ?? chatSessions.first(where: { !$0.archived })?.id ?? "legacy"
        if let current = activeSession { chatInput = current.input; chatMaterials = current.materials; chatPinnedContext = current.pinnedContext; newChatWork = current.newWork }
    }
    @discardableResult func createChatSession(title: String = "新对话") async -> String {
        persistCurrentSessionDraft()
        let session = ChatSession(title: title); chatSessions.append(session)
        do { try await store.save(session, kind: "chat-session", id: session.id) } catch { self.error = error.localizedDescription }
        switchChatSession(session.id); return session.id
    }
    func switchChatSession(_ id: String) {
        guard let session = chatSessions.first(where: { $0.id == id && !$0.archived }) else { return }
        chatExpanded = true; chatFocusNonce += 1
        guard id != activeSessionID else { return }
        persistCurrentSessionDraft(); activeSessionID = id
        chatInput = session.input; chatMaterials = session.materials; chatPinnedContext = session.pinnedContext; newChatWork = session.newWork
        workspacePreferences.activeSessionID = id; chatFocusNonce += 1; chatExpanded = true
        Task { try? await store.save(workspacePreferences, kind: "workspace-preferences", id: "main") }
    }
    func persistCurrentSessionDraft() {
        sessionDraftTask?.cancel(); sessionDraftTask = nil
        guard let i = chatSessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        var snapshot = chatSessions[i]
        snapshot.input = chatInput; snapshot.materials = chatMaterials; snapshot.pinnedContext = chatPinnedContext; snapshot.newWork = newChatWork; snapshot.draftRevision += 1
        chatSessions[i] = snapshot
        Task { do { _ = try await store.saveSessionDraft(snapshot) } catch { self.error = error.localizedDescription } }
    }
    func scheduleSessionDraft() {
        sessionDraftTask?.cancel()
        guard let i = chatSessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        // Capture the owner and complete input now. A delayed save must not
        // consult whichever conversation happens to be selected in 300 ms.
        var snapshot = chatSessions[i]
        snapshot.input = chatInput; snapshot.materials = chatMaterials; snapshot.pinnedContext = chatPinnedContext; snapshot.newWork = newChatWork; snapshot.draftRevision += 1
        chatSessions[i] = snapshot
        sessionDraftTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation(); _ = try await store.saveSessionDraft(snapshot) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func chatEditorInput(in sessionID: String) -> String {
        sessionID == activeSessionID ? chatInput : chatSessions.first(where: { $0.id == sessionID })?.input ?? ""
    }
    func setChatEditorInput(_ value: String, in sessionID: String) {
        guard let i = chatSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if sessionID == activeSessionID {
            guard chatInput != value else { return }
            chatInput = value; scheduleSessionDraft()
        } else {
            // AppKit may finish an IME composition after its old view is
            // detached. Retain that final edit in its original conversation.
            guard chatSessions[i].input != value else { return }
            var snapshot = chatSessions[i]; snapshot.input = value; snapshot.draftRevision += 1
            chatSessions[i] = snapshot
            Task { do { _ = try await store.saveSessionDraft(snapshot) } catch { self.error = error.localizedDescription } }
        }
    }
    func sessionMaterials(_ id: String) -> [ChatMaterial] {
        id == activeSessionID ? chatMaterials : chatSessions.first { $0.id == id }?.materials ?? []
    }
    func attachChatMaterial(_ material: ChatMaterial, to id: String) async throws {
        guard let i = chatSessions.firstIndex(where: { $0.id == id }) else { throw MailError.message("来源会话不存在，资料未添加。") }
        guard sessionMaterials(id).count < 8 else { throw MailError.message("每次对话最多带8份资料，资料未添加。") }
        if id == activeSessionID {
            chatMaterials.append(material); persistCurrentSessionDraft()
        } else {
            chatSessions[i].materials.append(material); chatSessions[i].draftRevision += 1
            _ = try await store.saveSessionDraft(chatSessions[i])
        }
    }
    func renameChatSession(_ id: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = chatSessions.firstIndex(where: { $0.id == id }) else { return }
        chatSessions[i].title = String(trimmed.prefix(80)); chatSessions[i].updatedAt = Date()
        do { _ = try await store.saveSessionMetadata(chatSessions[i]) } catch { self.error = error.localizedDescription }
    }
    func pinChatSession(_ id: String, pinned: Bool) async {
        guard chatSessions.contains(where: { $0.id == id }) else { return }
        do {
            let saved = try await store.setSessionPinned(id, pinned: pinned)
            guard let index = chatSessions.firstIndex(where: { $0.id == id }) else { return }
            chatSessions[index].pinnedAt = saved.pinnedAt
            chatSessions[index].updatedAt = max(chatSessions[index].updatedAt, saved.updatedAt)
        } catch { self.error = error.localizedDescription }
    }
    func archiveChatSession(_ id: String, archived: Bool = true) async {
        guard let i = chatSessions.firstIndex(where: { $0.id == id }), id != executingSessionID else { return }
        if id == activeSessionID { persistCurrentSessionDraft() }
        chatSessions[i].archived = archived; chatSessions[i].updatedAt = Date()
        do { _ = try await store.saveSessionMetadata(chatSessions[i]) } catch { self.error = error.localizedDescription }
        if id == activeSessionID && archived {
            if let other = chatSessions.first(where: { !$0.archived }) { switchChatSession(other.id) } else { _ = await createChatSession() }
        }
    }
    func recordChat(_ value: PartnerChat, presentation: OpenUIInteraction? = nil) async throws {
        var message = value; message.sessionID = value.sessionID ?? taskSessionID
        let id = message.sessionID!
        if message.role == "partner", message.memoryIDs == nil { message.memoryIDs = retrievedMemoryIDs[id] }
        let session = chatSessions.first { $0.id == id } ?? ChatSession(id: id)
        let saved = try await store.commitChat(message, session: session, presentation: presentation)
        if let presentation { if let i = openUIInteractions.firstIndex(where: { $0.id == presentation.id }) { openUIInteractions[i] = presentation } else { openUIInteractions.append(presentation) } }
        if let i = chatSessions.firstIndex(where: { $0.id == id }) { chatSessions[i].title = saved.title; chatSessions[i].updatedAt = saved.updatedAt } else { chatSessions.append(saved) }
        if let i = chat.firstIndex(where: { $0.id == message.id }) { chat[i] = message } else { chat.append(message) }
        if message.role == "user" { scheduleMemoryExtraction(message) }
    }
}
