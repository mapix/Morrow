import Foundation
import MorrowCore

struct MailProcessingProgress: Equatable {
    var completed = 0
    var pending = 0
    var pendingBytes = 0
    var parseSeconds: Double = 0
    var storeSeconds: Double = 0
    var networkSeconds: Double = 0
    var networkCount = 0
    var networkBytes = 0
    var sizeQuerySeconds: Double = 0
    var bodyDownloadSeconds: Double = 0
    var activeUID: UInt64?
}

extension AppModel {
    func enqueueDownloadedMail(_ raw: Data, job: MailDownloadJob) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            let state = try await store.mailDownloadQueueState()
            if state.count < MailDownloadJob.maximumPending && raw.count <= MailDownloadJob.maximumPendingBytes - state.bytes { break }
            if let failure = mailProcessingFailure { throw MailError.message("下载已暂停，加工队列需要重试：" + failure) }
            scheduleMailDownloadProcessing()
            try await Task.sleep(for: .milliseconds(100))
        }
        let accepted = try await store.queueMailDownload(raw, job: job)
        if accepted { scheduleMailDownloadProcessing() }
        return accepted
    }
    func scheduleMailDownloadProcessing(retry: Bool = false) {
        guard !isQualityPreview else { return }
        guard mailDownloadProcessingTask == nil, retry || mailProcessingFailure == nil else { return }
        if retry { mailProcessingFailure = nil }
        mailDownloadProcessingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            self.mailProcessingBusy = true
            var incoming: [MailMessage] = [], lastPublished = Date()
            defer {
                self.mailDownloadProcessingTask = nil; self.mailProcessingBusy = false; self.mailProcessingProgress.activeUID = nil
                if !Task.isCancelled && self.mailProcessingFailure == nil { Task { if let state = try? await self.store.mailDownloadQueueState(), state.count > 0 { self.scheduleMailDownloadProcessing() } } }
            }
            do {
                while !Task.isCancelled {
                    let jobs = try await self.store.queuedMailDownloads()
                    self.mailProcessingProgress.pending = jobs.count
                    self.mailProcessingProgress.pendingBytes = jobs.reduce(0) { $0 + $1.byteCount }
                    guard let job = jobs.first else { break }
                    guard self.accounts.contains(where: { $0.id == job.accountID }) else { try await self.store.discardQueuedMailDownload(job); continue }
                    self.mailProcessingProgress.activeUID = job.uid
                    let rawURL = await self.store.rawURL(job.id)
                    let started = ProcessInfo.processInfo.systemUptime
                    let worker = Task.detached(priority: .utility) { () throws -> MailMessage in
                        try Task.checkCancellation()
                        let raw = try BoundedFileReader.read(rawURL, maximumBytes: 64 * 1024 * 1024)
                        var mail = MIMEParser.parse(raw, accountID: job.accountID, folder: job.folder, uid: job.uid, validity: job.validity)
                        mail.raw = Data(); mail.analysis = PartnerEngine.baseline(mail)
                        for i in mail.attachments.indices { mail.attachments[i].id = MailStore.hash(job.id + ":attachment:" + String(i)) }
                        return mail
                    }
                    var mail = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    self.mailProcessingProgress.parseSeconds = ProcessInfo.processInfo.systemUptime - started
                    MailReaderMetrics.record("sync_mime_parse", since: started)
                    let seen = self.downloadSeenOverride(job)
                    mail.isRead = seen?.0 ?? job.read; mail.isStarred = job.starred; if let seen { mail.localFlagModifiedAt = seen.1 }
                    let write = ProcessInfo.processInfo.systemUptime
                    if let saved = try await self.store.commitDownloadedMail(mail, job: job) {
                        self.mailProcessingProgress.completed += 1; incoming.append(saved)
                        if job.isNewArrival == true {
                            // Fresh inbox mail jumps the historical processing
                            // queue and publishes before notification clicks.
                            await self.reload(incoming: incoming); incoming.removeAll(keepingCapacity: true)
                            await self.notifyNewArrival(saved, isNewArrival: true)
                            self.process(); lastPublished = Date()
                        }
                    }
                    self.mailProcessingProgress.storeSeconds = ProcessInfo.processInfo.systemUptime - write
                    MailReaderMetrics.record("sync_processed_store", since: write)
                    if incoming.count >= 16 || Date().timeIntervalSince(lastPublished) >= 2 {
                        await self.reload(incoming: incoming); incoming.removeAll(keepingCapacity: true); self.process(); lastPublished = Date()
                    }
                }
                if !incoming.isEmpty { await self.reload(incoming: incoming); self.process() }
            } catch {
                if !Task.isCancelled { self.mailProcessingFailure = error.localizedDescription }
                if !incoming.isEmpty { await self.reload(incoming: incoming); self.process() }
            }
        }
    }
}
