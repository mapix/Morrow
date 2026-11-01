# Responder sandbox runtime

Morrow pins `@anthropic-ai/sandbox-runtime` to **0.0.81**. Install the reproducible production dependencies with:

```sh
npm ci --ignore-scripts --omit=dev --prefix Runtime/SandboxRuntime
```

The macOS app bundles this directory and its production dependencies. It uses an existing Node.js22.12+ installation. No runtime download, account credential, or unsandboxed fallback is used during a response. SRT is a research preview; SDK upgrades require rerunning the real boundary tests.

## Boundaries

The trusted Swift host verifies the mailbox identity, exact sender email allowlist, folder, provider UID/provenance, reply target, optional receiving-service DMARC result, and current rule version. It supplies only the triggering message's bounded text and explicitly requested attachment text to a private temporary workspace.

Each tool invocation calls the SRT library. Its generated Seatbelt policy and proxy network rules enforce:

- Read: the current workspace and required public runtime/system files. Personal home directories, mailbox stores and Keychain files are denied.
- Write: only `output/` and `tmp/`; `input/` is immutable to commands.
- Network: deny by default. Explicit domain entries grant only HTTPS port443. Local binding, arbitrary Unix sockets and Apple Events are disabled.
- Credentials: a clean environment, plus additional Keychain RPC denies in the same generated Seatbelt profile. This closes SRT's general developer profile's SecurityServer allowance.
- Budget:15s default command deadline, per-process CPU time, bounded file size and128KiB combined command output. Output trees are inspected for16MiB/128-entry/depth8 budgets. A file-budget breach stops the command and invalidates its result.

The bridge decodes only the pinned SDK's documented quoting grammar into argv before adding Keychain denies. It retains the SDK's full filesystem/network profile and proxy environment. An unfamiliar wrapper shape, missing runtime, failed tool, timeout or resource violation stops delivery.

Model requests and the final SMTP gateway remain trusted Swift host operations. SMTP credentials are never staged or passed into the sandbox. The host revalidates the original sender, source body revision, mailbox identity, rule version and exact prepared reply before claiming the outbox item and again immediately before SMTP.

## Lifecycle

Every delivered responder reply completes read → plan → tools → independent verification. Fixed text follows the same loop and cannot be rewritten. Automatic replies target the original From address, never Reply-To/CC/BCC. Queued replies have a10s cancellation window. Rule changes cancel active loops and queued deliveries. Interrupted preparation becomes a visible retryable failure; uncertain SMTP delivery is never automatically retried.


## Verification

```sh
swift test --filter Responder
```

This includes actual SRT input/output/filesystem/network/time/output-boundary checks and isolated simulated-mail pipeline tests. `Tests/Fixtures/Sandbox/keychain-probe.c` verifies the credential-service RPC fence without reading any credential. Optional local-model acceptance is enabled only with `MORROW_LIVE_RESPONDER_MODEL`; its mailbox is always synthetic.
## Chat coding data

Chat can submit Python source directly through `run_code.python`. The host
selects an installed Python interpreter, stages a private script, and executes
it with the same SRT filesystem, network and output limits. Python currently
requires Xcode, Command Line Tools, or an installed Homebrew/local interpreter.

`import maildata` exposes `query(sql, max_rows=1000)`. Tables are `mail_index`
(all permitted metadata), `mail` (metadata plus lazy full text), `contacts`, and
`accounts` (nonsecret fields). A private Unix socket carries queries to the
host. SQL runs against an isolated memory database with a scoped metadata
index; the original SQLite database is opened read-only only by the host and
is never attached to the query connection or made visible in the sandbox.
Bodies are fetched on demand through a function that checks the scoped IDs.

Only read queries and selected built-in functions are accepted. Each query
has a five-second execution budget, a two-MiB SQLite value limit, at most 2000
returned rows, 64 KiB per returned cell, and 512 KiB per response. Truncation is
explicit. Scripts should aggregate/filter first and print concise results and
real source IDs. Scratch files live only for the current run.

This data socket is enabled by the Chat host. Normal responder commands retain
their staged-input-only access. Explicit upload-only Chat scopes receive no
mail data client. There are no original mailbox copies or persistent second
databases.
