# MCP Server

Morrow includes an optional authenticated **Streamable HTTP** MCP server.
Open **Settings → MCP Server** to enable it. It starts disabled and listens on
`http://127.0.0.1:8765/mcp` by default. The port can be changed in settings.

## Connect a client

Use **Copy MCP configuration** to copy a JSON configuration containing the URL
and authentication header. Clients that accept the `mcpServers` format can use:

```json
{
  "mcpServers": {
    "morrow": {
      "url": "http://127.0.0.1:8765/mcp",
      "headers": { "Authorization": "<authorization-header>" }
    }
  }
}
```

Replace `<authorization-header>` with `Bearer ` followed by your copied token.
For clients with a different configuration format, select Streamable HTTP,
enter the copied URL, and add `Authorization: Bearer <your-token>` as a header.
The server uses preconfigured Bearer authentication, not OAuth discovery.

The token is automatically generated from 32 cryptographically random bytes
and saved in this Mac's Keychain. It is independent of mail and model credentials,
is specific to the local workspace, and is not included in iCloud sync.
**Copy token** works while the server is disabled. **Reset token** replaces it
and immediately rejects the previous token, including requests waiting to return
mail data. If saving the new token fails, the previous token remains valid.
Copied client configurations contain the token and should be kept private.

## Listening and lifecycle

- Local access binds only to IPv4 loopback (`127.0.0.1`).
- **Allow LAN connections** binds to all IPv4 interfaces. Replace `127.0.0.1` in
  a client's URL with this Mac's LAN IP. Authentication remains required.
- HTTP should be used on trusted networks. Use an HTTPS reverse proxy for remote
  access; Morrow does not supply TLS certificates or public hosting.
- Settings persist locally. An enabled server starts again when Morrow opens.
  Closing the window leaves it running; disabling it or quitting Morrow stops it.
- If the port is occupied or Keychain access fails, settings shows the error and
  a retry action. The server does not claim to be running before it has bound.

## Available tools

| Tool | Result |
| --- | --- |
| `list_accounts` | Mailbox IDs, names, addresses and enabled state |
| `list_folders` | Cached folders, optionally filtered by account |
| `list_mail` | Cached mail previews, filtered by account/folder, newest first |
| `search_mail` | Local keyword/filter search, with no remote/model calls |
| `get_mail` | Cached text, addressing and attachment metadata |
| `list_contacts` | Manual contacts and contacts derived from cached mail |
| `list_briefs` | Saved briefs/reports and source mail IDs |
| `get_brief` | Saved report text and source mail IDs |

Enabling the server grants a token holder read access to all locally cached
mailboxes, contacts and briefs in this workspace. These tools do not send mail,
mark messages read, alter user records, synchronize remote mail, call models,
execute code, expose credentials, return raw MIME/attachment bytes, or reveal
local attachment paths. Mail text is untrusted content for a connecting agent.
Saved reports are not newly verified by reading them.

List tools accept `limit` (1–100, default 25) and, where applicable, `offset`.
`has_more` and `next_offset` indicate additional results. Search uses Morrow's
existing keyword retrieval rather than an exhaustive all-history export;
narrow a query when the returned results indicate more matches.
Mail/brief text is returned in pages of up to 20,000 Unicode characters.
Use `next_offset` to continue. Mail's `content_availability` identifies partial
cached content; the server does not download missing bodies or attachments.

## Protocol and verification

The endpoint accepts authenticated HTTP/1.1 POST requests containing a single
JSON-RPC 2.0 message with `Content-Type: application/json` and
`Accept: application/json, text/event-stream`. It returns JSON, or HTTP 202 for
notifications/client responses. It is stateless: no session IDs, server-initiated
events, legacy SSE endpoint, resources or prompts. Authenticated GET and DELETE
return 405. Supported protocol versions are `2025-11-25`, `2025-06-18`,
`2025-03-26` and `2024-11-05`.

Browser Origin headers are rejected, loopback Host headers are validated, and
responses use `Cache-Control: no-store`. Requests have bounded headers/bodies,
32 concurrent connections and a 15-second connection deadline.

Run `swift test --filter 'MCP|PresentationTests'` for HTTP, token, local
persistence, query privacy and translation verification. When the optional
agent runtime dependencies are installed, the same suite also connects the
official TypeScript MCP client to a real local HTTP listener. That check uses
synthetic data and never accesses a user's mail or token.
