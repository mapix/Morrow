import Foundation
import SwiftUI
import MorrowCore

@MainActor final class CloudWorkspaceModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var enabling = false
    @Published private(set) var busy = false
    @Published private(set) var message = "iCloud sync is off."
    @Published private(set) var lastSync: Date?
    @Published private(set) var conflicts: [CloudWorkspaceConflict] = []
    private let service: CloudSyncService
    private let store: MailStore
    private let defaultsKey: String
    private var loop: Task<Void, Never>?
    private var observedRevision = 0
    private var operationID = UUID()
    var onImport: (() async -> Void)?
    init(store: MailStore) {
        self.store = store; service = CloudSyncService(store: store)
        defaultsKey = "SmailICloudEnabled:" + MailStore.hash(store.root.path)
    }
    func restore() async {
        let requested = UserDefaults.standard.bool(forKey: defaultsKey)
        await refresh()
        if requested { await setEnabled(true) }
    }
    func setEnabled(_ value: Bool) async {
        guard !value || !busy else { return }
        let operation = UUID(); operationID = operation
        busy = true; enabling = value
        if value {
            do {
                try await service.start(); guard operationID == operation else { return }
                UserDefaults.standard.set(true, forKey: defaultsKey); beginLoop()
            }
            catch {
                guard operationID == operation else { return }
                await service.stop(); UserDefaults.standard.set(false, forKey: defaultsKey)
                message = error.localizedDescription; busy = false; enabling = false; return
            }
        } else {
            enabled = false; enabling = false; loop?.cancel(); loop = nil
            UserDefaults.standard.set(false, forKey: defaultsKey); await service.stop()
        }
        guard operationID == operation else { return }
        await refresh(operation: operation); guard operationID == operation else { return }
        busy = false; enabling = false
    }
    func sync() async {
        guard enabled, !busy else { return }
        let operation = operationID
        busy = true
        do { try await service.sync() } catch { /* The service retains the retryable status. */ }
        guard operationID == operation else { return }
        await refresh(operation: operation); guard operationID == operation else { return }
        busy = false
    }
    func resolve(_ conflict: CloudWorkspaceConflict, restoreLocal: Bool) async {
        do {
            if restoreLocal { try await store.restoreCloudConflict(conflict.id); await onImport?() }
            else { try await store.remove(kind: "cloud-conflict", id: conflict.id) }
            await refresh()
        } catch { message = error.localizedDescription }
    }
    private func beginLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }; await self.sync()
            }
        }
    }
    private func refresh(operation: UUID? = nil) async {
        let status = await service.status()
        guard operation == nil || operationID == operation else { return }
        let loadedConflicts = (try? await store.load(CloudWorkspaceConflict.self, kind: "cloud-conflict")) ?? []
        guard operation == nil || operationID == operation else { return }
        enabled = status.enabled; message = status.message; lastSync = status.lastSync
        if !enabled { UserDefaults.standard.set(false, forKey: defaultsKey) }
        conflicts = loadedConflicts
        if status.importedRevision != observedRevision { observedRevision = status.importedRevision; await onImport?() }
    }
}

struct CloudWorkspaceSettingsView: View {
    @ObservedObject var cloud: CloudWorkspaceModel
    @State private var explainEnable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.t("iCloud同步"), isOn: Binding(get: { cloud.enabled || cloud.enabling }, set: { value in
                if value { explainEnable = true } else { Task { await cloud.setEnabled(false) } }
            }))
            Text(L10n.t("默认关闭。开启后，对话、对话文件、联系人、长期记忆与工作资料同步到你的私人iCloud。邮箱密码、GPT凭据、模型索引、自动发送队列留在本机；邮件和邮件附件由各设备连接邮箱后同步。")).font(Theme.label).foregroundStyle(Theme.secondary)
            Text(L10n.t(cloud.message)).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled)
            if let date = cloud.lastSync { Text(date.uiFormatted()).font(Theme.small).foregroundStyle(Theme.muted) }
            if cloud.enabled { Button(L10n.t("现在同步")) { Task { await cloud.sync() } }.buttonStyle(QuietButtonStyle()).disabled(cloud.busy) }
            if cloud.busy { ProgressView().controlSize(.small) }
            ForEach(cloud.conflicts) { conflict in
                HStack {
                    Text(L10n.t("同步冲突，已保留本机版本") + ": " + conflict.kind).font(Theme.label)
                    Spacer()
                    Button(L10n.t("恢复本机版本")) { Task { await cloud.resolve(conflict, restoreLocal: true) } }.buttonStyle(.link)
                    Button(L10n.t("保留云端版本")) { Task { await cloud.resolve(conflict, restoreLocal: false) } }.buttonStyle(.link)
                }
            }
        }.alert(L10n.t("开启私人iCloud同步？"), isPresented: $explainEnable) {
            Button(L10n.t("取消"), role: .cancel) {}
            Button(L10n.t("开启同步")) { Task { await cloud.setEnabled(true) } }
        } message: { Text(L10n.t("将此工作区的对话、文件、联系人、记忆和资料上传到你的Apple iCloud账户。关闭后停止同步，本机和云端内容会保留。")) }
    }
}
