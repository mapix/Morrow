import SwiftUI

struct MailSyncProgress: Equatable {
    var processed = 0
    var total = 0
    var downloaded = 0
    var fraction: Double? { total > 0 ? min(1, max(0, Double(processed) / Double(total))) : nil }
}

struct MailSyncButton: View {
    @EnvironmentObject var model: AppModel
    @State private var showingProgress = false
    var body: some View {
        Button {
            if model.syncBusy { showingProgress.toggle() }
            else { let account = model.selectedAccount; Task { await model.sync(accountID: account) } }
        } label: {
            Image(systemName: model.syncBusy ? "arrow.down.circle" : "arrow.clockwise")
                .foregroundStyle(model.syncBusy ? Theme.accent2 : Theme.ink)
        }.buttonStyle(.plain).frame(width: 32, height: 36)
            .accessibilityIdentifier("mail.sync.control")
            .accessibilityLabel(L10n.t(model.syncBusy ? "正在同步邮箱，点击查看进度" : "同步当前邮箱"))
            .help(L10n.t(model.syncBusy ? "正在同步邮箱，点击查看进度" : "同步当前邮箱"))
            .popover(isPresented: $showingProgress) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.t("邮箱同步")).font(Theme.heading)
                    Text(L10n.status(model.syncStatus)).font(Theme.label).textSelection(.enabled)
                    if let progress = model.mailSyncProgress {
                        if let fraction = progress.fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
                        if progress.total > 0 { Text(L10n.format("下载 {0}/{1} · 本轮已保存原文 {2}", "\(progress.processed)", "\(progress.total)", "\(progress.downloaded)")).font(Theme.label) }
                    }
                    let processing = model.mailProcessingProgress
                    Text(L10n.format("后台加工：已整理 {0} · 等待 {1}", "\(processing.completed)", "\(processing.pending)")).font(Theme.label)
                    if processing.networkCount > 0 { Text(L10n.format("最近下载：{0} 封 / {1} 秒", "\(processing.networkCount)", String(format: "%.2f", processing.networkSeconds))).font(Theme.label) }
                    Text(L10n.format("服务器大小查询 {0} 秒 · 正文下载 {1} 秒", String(format: "%.2f", processing.sizeQuerySeconds), String(format: "%.2f", processing.bodyDownloadSeconds))).font(Theme.label)
                    Text(L10n.format("最近解析 {0} 秒 · 写入 {1} 秒", String(format: "%.3f", processing.parseSeconds), String(format: "%.3f", processing.storeSeconds))).font(Theme.label)
                    if let failure = model.mailProcessingFailure { Text(failure).font(Theme.label).foregroundStyle(Theme.error); Button(L10n.t("重试后台加工")) { model.scheduleMailDownloadProcessing(retry: true) } }
                    if model.syncBusy { Button(L10n.t("停止本次同步")) { model.stopMailSynchronization() }.buttonStyle(QuietButtonStyle()) }
                }.padding(20).frame(width: 340)
            }
    }
}

struct MailSyncStatusLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accent2)
            Text(L10n.status(model.syncStatus)).lineLimit(1).help(L10n.status(model.syncStatus))
            if let progress = model.mailSyncProgress, let fraction = progress.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 80)
                Text(L10n.format("下载 {0}/{1} · 本轮已保存原文 {2}", "\(progress.processed)", "\(progress.total)", "\(progress.downloaded)")).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(L10n.t("停止本次同步")) { model.stopMailSynchronization() }.buttonStyle(.link)
        }.font(Theme.small).foregroundStyle(Theme.secondary).padding(.horizontal, 20).frame(height: 36)
            .background(Theme.sheet).accessibilityIdentifier("mail.sync.progress")
    }
}

struct MailProcessingStatusLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            if model.mailProcessingBusy { ProgressView().controlSize(.small) }
            Text(L10n.format("后台加工：已整理 {0} · 等待 {1}", "\(model.mailProcessingProgress.completed)", "\(model.mailProcessingProgress.pending)")).lineLimit(1)
            Spacer(minLength: 0)
            if model.mailProcessingFailure != nil { Button(L10n.t("重试后台加工")) { model.scheduleMailDownloadProcessing(retry: true) }.buttonStyle(.link) }
        }.font(Theme.small).foregroundStyle(Theme.secondary).padding(.horizontal, 20).frame(height: 28).accessibilityIdentifier("mail.processing.progress")
    }
}
