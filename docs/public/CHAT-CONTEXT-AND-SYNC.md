# Chat hints and mail download processing

## Chat

Automatic left-pane context carries `scopeMode: hint`. It supplies stable referents and bounded selected evidence, not a search ceiling. The user's task determines the query: selecting a mail in one account does not prevent searching another account or an archive. Bodies from the entire mailbox are never preloaded as context.

Only an intentional restriction uses `scopeMode: scope`. The UI identifies that restriction and lets the user return to UI hints. Explicit file-only requests, accepted work agreements and responder source allowlists retain their own authority. Existing pinned contexts remain explicit unless they were marked as hints by the app.

## Downloads and processing

The IMAP downloader saves raw mail at its final private cache path and adds a durable processing receipt. A separate utility task parses MIME, stores the lightweight projection, then queues indexes and AI analysis. Downloading does not await vector indexing or AI analysis. No duplicate raw-mail spool or database copy is created.

History fetches request up to64UIDs, with size preflight and a16MiB raw batch budget. The overall response and single-mail safety limits remain64MiB. Oversized or incompatible messages use the existing protected single-message path. Original read flags are preserved with BODY.PEEK.

The persistent processing queue accepts at most32messages/128MiB. A full queue backpressures downloads; processing errors stop further expansion and can be retried. Stopping synchronization cancels networking while already saved jobs remain available for processing or restart. MIME jobs and final message rows share one completion transaction; attachment cache IDs remain stable across retries.

The sync popover reports server size-query time, body-download time, last batch count/bytes, MIME parsing, database writes and pending processing. Network progress is distinct from processing progress; indexed/AI-completed counts remain separate.

## Incremental IMAP and incoming-mail notifications

Automatic mail understanding uses a separately configured Ollama model. Each
mail provides only its first1,000body characters and attachment names; automatic
contact extraction uses the same bounded evidence. Valid existing analysis is
reused, and unavailable Ollama does not trigger a paid gateway fallback.

Automatic attachment downloads default to10MiB. Larger messages use
BODYSTRUCTURE plus BODY.PEEK for their text and permitted small parts; larger
attachments retain their filename, size and server-part association. They do not
enter automatic attachment extraction. Explicit saves may fetch a referenced
part within the native64MiB wire limit; larger parts remain linked for download
through the provider. Original read flags are preserved.

The desktop client retains a per-account, per-folder server cursor: UIDVALIDITY,
HIGHESTMODSEQ, UIDNEXT and the known UID set. The first sync establishes a
complete inventory; existing local messages and durable download jobs are reused.
Later syncs negotiate the authenticated server's standard IMAP capabilities:

- QRESYNC reconciles changed flags and VANISHED UIDs when ENABLE QRESYNC succeeds.
- CONDSTORE fetches only flags changed since the previous mod-sequence. Without
  QRESYNC, UID SEARCH ALL reconciles additions and deletions when SELECT reports
  changes. An unchanged folder requires only SELECT, without a full UID or flag
  query. Servers without modification tracking retain full flag reconciliation.
- A changed UIDVALIDITY, a reset modification sequence or NOMODSEQ requires a
  fresh inventory. Already downloaded bodies are reused while their UIDs remain
  valid. No cursor is advanced on failed inventory or metadata writes.

Remote flag changes, deletion metadata, queued-job flags and the cursor commit
in one database transaction. History bodies download separately. Missing UIDs
are calculated from the persisted inventory and local messages/jobs, so stopping
and restarting does not reset downloaded history. Only these missing messages
count toward download progress. Concurrent local flag edits remain protected.

IDLE uses separate TLS connections for selected INBOX and archive folders (including Gmail's All Mail) when
present. Notifications are coalesced and trigger sync for the affected account;
periodic sync remains as recovery and coverage for other folders or servers
without IDLE. Listening renews every 25 minutes, reconnects with bounded backoff,
and triggers catch-up after reconnecting. History downloads yield between raw
batches when incoming-mail notifications need attention.

Morrow listens while the macOS app runs and catches up after reconnecting.
POP3 remains polled.

Protocol checks use synthetic loopback peers. They cover an unchanged 85,433-UID
folder with no FETCH/SEARCH, CONDSTORE deltas, QRESYNC deletions, UIDVALIDITY
resets, legacy fallback, IDLE/DONE renewal and cancellation, persistent history
receipts, local-edit races and transaction rollback. These checks do not certify
latency or extension support for a particular live provider.

## Mail synchronization scope

Settings → Sync and operation selects the folders to download. The default is
Inbox, Sent and Drafts. Other choices are Inbox only, inclusion of archives and
custom folders without Trash/Junk, or all folders. Gmail folder names with a
prefix are recognized even when SPECIAL-USE flags are absent.

Excluded folders are still listed, but their inventories and missing bodies are
not fetched, and their IDLE connections are closed. Existing cached messages,
raw files, indexes and sync cursors remain available. Changing scope cancels an
active download; saved processing jobs remain durable. Restoring a folder later
resumes from its cursor and locally missing UIDs, rather than erasing its cache.

UIDs marked \\Deleted remain in the server membership cursor until expunged,
but are excluded from body downloads. This exclusion survives an unchanged sync
and is removed if the server clears the flag. Permanent server removal continues
to reconcile local copies in folders that are being synchronized.

New automatic mail and contact analysis uses only folders in the selected sync
scope. Prior valid analysis and contact claims are retained. Explicit contact
refresh and manual reading can still use cached mail from excluded folders.

## Processing and model costs

| Stage | Execution | Model API usage |
| --- | --- | --- |
| IMAP inventory, flags and body download | Mail provider connection | None |
| MIME parsing, attachment extraction, rule signals and SQLite storage | Local code | None |
| Full-text and EmbeddingGemma 2 vector indexes | Local code and local Metal model | None |
| Automatic summaries, categorization and contact insights | Separately configured Ollama model | No gateway fallback; a remote Ollama endpoint sends evidence to that endpoint |
| Chat, delegated work and enabled responders | Partner model configuration | Depends on the selected service; remote providers can consume API tokens |

Automatic understanding processes unfinished or stale eligible local mail, which
can include an existing history backlog. Each mail supplies its first 1,000 body
characters and attachment names; contact extraction groups up to eight mail
excerpts. Valid completed results are reused, including across Gmail copies.
Local Ollama inference consumes local compute and memory, even though it does
not use a gateway API allowance. Disabling automatic mail reading stops summary
and contact inference; local mail storage and indexing remain independent.

## Viewing referenced mail

Work documents, briefs and inspectors keep every referenced mail ID in source
order and display at most 50 reference rows per page. Closed disclosure groups
do not resolve or construct mail rows. Rows use the existing mailbox ID index;
expanding a reference list does not scan the complete mailbox, read raw bodies,
or invoke a model. Missing references retain a placeholder on their page. Opening
an individual reference continues to use the normal asynchronous mail reader.

## Connection recovery

Read-only IMAP operations reconnect and retry once after a transient timeout or
closed connection. Failed sockets are discarded; cached sessions unused for
five minutes are reopened before the next operation. MOVE, STORE, APPEND and
SMTP delivery are not automatically replayed after an uncertain response.

A failed history read stops that pass while retaining the server cursor, saved
mail and durable jobs. The normal background synchronization interval provides
the next recovery attempt. Background failures remain in account/sync status and
do not open a global modal; the sync control exposes details and manual retry.
An explicit user retry can report a persistent failure. Credential-access failures
continue to wait for explicit authorization rather than displaying password
dialogs or pretending that another network retry can grant access.
# 发件箱、已发送与附件预览

侧栏“发件箱”显示待发送、发送中与发送结果待核对的记录；“已发送”显示本机缓存与服务器同步的已投递邮件。“草稿箱”保留可编辑的未发送草稿。
SMTP 成功后，原生发送流程先提交不可重复投递的状态与回执，再保存本机副本及服务器副本。本机或 IMAP 副本失败不会重新提交 SMTP；已确认发送的记录也不能被草稿编辑器覆盖。
应用可按固定 RFC Message-ID 与真实服务器 Sent 副本核对历史中断记录，恢复本机状态与副本。没有确认依据的记录保留“需要核对发送结果”，不自动重发。Gmail 已自动保存 SMTP 发件，因此不再重复 IMAP APPEND。

邮件正文下方的附件区域支持图片与 PDF 原件预览、缩放与展开查看，使用本机 ImageIO/PDFKit，不调用 AI 模型。已有本机附件直接读取；仅关联的远程附件在点击预览后按需获取，不改变自动同步的附件下载范围。
原件预览单文件最多 64 MB；超过限制或加密/损坏的文件保留保存入口与明确提示。
