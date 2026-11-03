# Configure responders in Chat

Chat can prepare a responder's source mailbox, folder, exact sender allowlist,
subject/body conditions, reply instructions, delivery mode and daily limit.
The conditions must all match. A body keyword is stored as an actual condition,
not merely mentioned in the reply instructions.

`setup_responder` returns a native review form in Chat. Preparing it ends tool
use for that turn. The rule is saved and enabled only when the user clicks
**保存并启用响应器**. Existing rules retain their current state until the user saves
the changes. Saving uses the reviewed rule ID and checks its version to prevent
duplicate creation or overwriting a newer edit.

Use `read_responder` before editing an existing rule. `responder_status` returns
the saved configuration and up to 20 actual execution receipts. Queued, drafted,
sent, skipped, failed and uncertain states have different meanings; absence of
a receipt is not proof that a test passed.

## Image attachments

Image replies are an explicit, optional permission. Old rules keep their text
behavior. With image replies enabled, the responder reads the matching mail,
plans a prompt under the user's instructions, generates one image through the
configured gateway, verifies its reply and attaches the real image. The
configured image model is fixed when the rule is saved. The incoming mail cannot
choose a different model, recipient, account or network policy.

New image rules prepared by Chat default to three requests per day and a
360-second execution budget. The user can review these settings. Failed and
uncertain image requests also consume the daily media allowance. Request claims
are atomic and stored before a paid call; an uncertain result is not submitted
again. Retrying a failed reply reuses an already generated image for the same
rule and source version.

The image receipt binds the output to the source body and rule version. Before
automatic delivery, the host validates the image's bytes, MIME type, size and
receipt as well as the reply and recipient. Only the original From address is
eligible; Reply-To, CC and BCC cannot expand the recipient. By default, source
matching uses the bound mailbox, exact From address and keywords without
requiring authentication headers. Detailed DMARC validation is an optional
setting. Automatic-mail exclusions and the 10-second cancellation window remain
in effect.

## Test and follow the result

`test_responder` takes a saved responder ID and a matching mail ID. It only
prepares a verified preview; it does not send or enable a rule. Image preview
tests have generation costs and use the same persistent receipt and daily
allowance as automatic execution. A successful preview does not prove SMTP
delivery or that a future real incoming mail will pass source authentication.

After saving, use `responder_status` to inspect actual incoming-mail execution
and delivery. A message sent from the bound mailbox to itself will not test a
rule whose allowlist specifies another sender; the test source must match the
configured source.
