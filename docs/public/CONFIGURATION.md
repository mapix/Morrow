# Configuration

Copy `configuration/oauth-clients.example.json` to the ignored `configuration/oauth-clients.json`. It contains public provider client IDs only. Keep provider client secrets and account tokens in Keychain; never commit them. Google desktop and iOS registrations are distinct. The iOS reverse callback scheme is derived during the build from the configured iOS client ID.

In the app settings, choose local Ollama/Apple Intelligence, a compatible HTTPS endpoint and model, or ChatGPT login. API keys are retained in Keychain. Remote model settings change where mail evidence is sent; configure a trusted endpoint.

Optional iCloud needs a properly signed build with an authorized container. The shipped signing templates retain migration compatibility identifiers, while each distributor supplies its own Apple configuration. User workspace sync remains opt-in.
