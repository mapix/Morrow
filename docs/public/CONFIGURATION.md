# Configuration

Copy `configuration/oauth-clients.example.json` to the ignored `configuration/oauth-clients.json`. It contains public provider client IDs only. Keep provider client secrets and account tokens in Keychain; never commit them. Google desktop and iOS registrations are distinct. The iOS reverse callback scheme is derived during the build from the configured iOS client ID.

In the app settings, choose local Ollama/Apple Intelligence, a compatible HTTPS endpoint and model, or ChatGPT login. API keys are retained in Keychain. Remote model settings change where mail evidence is sent; configure a trusted endpoint.

Optional iCloud needs a properly signed build with an authorized container. The shipped signing templates retain migration compatibility identifiers, while each distributor supplies its own Apple configuration. User workspace sync remains opt-in.

## Chat reading scope

The scope above Chat is a search boundary, not a preload of its message bodies. Browsing an inbox supplies a compact account/folder/filter description. An ordinary question starts without inbox mail content; selecting a message or attachment explicitly supplies that content. The agent requests search or reading tools as needed and receives at most 18 mail snippets in a round. Its running state shows how many messages have actually been provided.

The scope is captured when you submit. Navigating to another mailbox or adding an account during the request does not expand that request. Use the scope menu to search across all mailboxes. Automatic reading of new mail is a separate setting in the proactive mail pipeline.
