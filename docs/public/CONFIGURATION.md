# Configuration

Copy `configuration/oauth-clients.example.json` to the ignored `configuration/oauth-clients.json`. It contains public desktop provider client IDs only. Keep provider client secrets and account tokens in Keychain; never commit them. Configure a desktop OAuth registration for the macOS app.

In the app settings, choose local Ollama/Apple Intelligence, a compatible HTTPS endpoint and model, or ChatGPT login. API keys are retained in Keychain. Remote model settings change where mail evidence is sent; configure a trusted endpoint.

Optional iCloud needs a properly signed build with an authorized container. The shipped signing templates retain migration compatibility identifiers, while each distributor supplies its own Apple configuration. User workspace sync remains opt-in.

Settings → MCP Server provides an optional authenticated HTTP endpoint for local
mail, contacts and briefs. Tokens are generated automatically, stored in
Keychain, and can be copied or reset. Localhost is the default; LAN access is
explicitly enabled. See [MCP server setup and available tools](MCP-SERVER.md).

## Keychain access and build identity

`scripts/package-app.sh` uses the unique valid Developer ID Application identity
on the build machine when available. Set `MORROW_CODESIGN_IDENTITY` explicitly
when multiple identities exist. Machines without that certificate can use ad hoc
signing, but its code identity changes after rebuilding and may need new Keychain
authorization. A Developer ID signature retains a certificate-backed identity
across updates; this alone does not establish Apple notarization acceptance.

Mail and model credentials remain in the system Keychain. Successful reads are
cached only in process memory. Background reads and OAuth refresh writes do not
display authentication dialogs; denied access is latched until an explicit
authorization attempt. Settings provides **Authorize saved credential access**
for the mailbox and model service. Cancelling authorization leaves synchronization
paused for that credential instead of repeatedly requesting the login password.
Existing ad hoc-authorized items can require one authorization after switching
to the stable signed app. The app does not broaden the item's trusted-access list
or store credentials in plaintext files.

## Chat reading scope

The scope above Chat is a search boundary, not a preload of its message bodies. Browsing an inbox supplies a compact account/folder/filter description. An ordinary question starts without inbox mail content; selecting a message or attachment explicitly supplies that content. The agent requests search or reading tools as needed and receives at most 18 mail snippets in a round. Its running state shows how many messages have actually been provided.

The scope is captured when you submit. Navigating to another mailbox or adding an account during the request does not expand that request. Use the scope menu to search across all mailboxes. Automatic reading of new mail is a separate setting in the proactive mail pipeline.

## Mail pages and marking read

Settings → Sync and operation → Sync scope defaults to Inbox, Sent and Drafts.
Archives, Trash, Junk and custom folders are excluded from new downloads and
automatic analysis under this default. Cached mail remains searchable. The scope
can be widened later; synchronization resumes using existing cursors and bodies.

Automatic mail analysis uses its own Ollama configuration. IMAP, MIME processing,
attachment text extraction and EmbeddingGemma 2 indexing do not use model API
tokens. Chat and delegated work use the partner model configuration independently.

## One-click mail translation

Open a message and click **Translate** in the reader toolbar. Morrow translates
the subject and complete text body into the current interface language. The
translation bar lets you choose Simplified Chinese, English or Japanese, cancel,
retry, and switch between the original and translation. Translations are kept in
memory while that reader is open; the original message and reply language remain
unchanged. Attachments and text embedded in images are not translated.

Manual translation uses the model selected in Settings → Model, including its
configured remote endpoint, independently of automatic mail analysis. It works
while background partner work is paused. Long messages are translated in chunks;
sources over 256 KB and explicitly incomplete model responses produce an error.

The macOS mail list shows 50 messages per page by default. The range control lets you choose 25, 50 or 100. Previous/next moves between pages, and selection applies only to the displayed page.

“Mark all read” is independent of page selection. In an unfiltered IMAP folder it queries the server's current unread UID snapshot, including mail that has not yet downloaded, then marks that exact set. With a category/search or other view filter it applies to matching locally available messages across pages. Already-read messages are skipped. Undo restores the messages changed by that operation. The operation does not fetch message bodies or delete messages.
# Sidechat 媒体模型

媒体允许列表位于 `configuration/media-models.json`，打包后复制到 App 资源中。
可在本机 Morrow 数据目录放置 `media-models.json` 覆盖默认配置；凭据仍由原生 Keychain 读取，配置中不填写 API Key。

- 图片默认 `gpt-image-2.5-flare`；支持配置中授权的 GPT Image、Gemini Image 和 Nano Banana 型号。
- 视频生成默认 `veo-3.1-fast-generate-preview`，支持 4、6、8 秒。
- 视频理解默认 `gemini-omni-flash`，使用网关 `/v1beta/interactions`（Vertex Interactions，`store=false`）。普通 Chat Completions 不支持 Omni 型号；它不能用于视频生成。
- `list_media_models` 同时核对配置允许列表与网关当前模型目录。目录可见不代表所有型号已做付费生成验收。

Agent 工具包括 `generate_image`、`generate_video`、`check_media_job`、`analyze_video`、`list_workspace`、`stage_material` 和 `attach_workspace_file`。
媒体生成与视频理解使用网关额度，收费 POST 不自动重试。结果不确定的同一请求不能自动重新提交。
视频是异步任务；聊天中的任务卡继续查询已有任务，查询过程不调用聊天模型。

每个 session 使用独立临时工作区，`run_code` 的 `output/` 和生成的 `media/` 跨轮保留。
明确限制资料或邮件范围时使用独立子目录。归档会取消运行并删除整个 session 工作区；重新打开创建新的工作区。
临时目录可能被系统清理，关键文件应使用“保存到资料”或“导出文件”。已附进草稿的附件和保存到资料的文件会另存，归档后保留。
工作区写入工具单文件最多 128 MiB，每个 session 总量最多 512 MiB；添加到草稿或聊天资料的单文件最多 32 MiB。
