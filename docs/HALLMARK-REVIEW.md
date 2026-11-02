fix

# Hallmark native finish review

2026-10-30 · Furrow · app screen scope · independent review.

Reviewed the four supplied NSHostingView content renders: partner, inbox/reader, account setup, and composer. They contain the intended app content. They are not OS window screenshots. System Chinese typography is allowed in this scope; marketing hero, fold, section rhythm, and mobile browser gates do not apply to this macOS product.

## Findings

1. **Unavailable send looks available:** the composer shows an enabled primary “发送” for `you@example.com`, while `queueSend` rejects demo accounts. Disable sending for that selected account and show “示例邮箱不能发送” with a connection action before the user submits. [ComposerView.swift](../Sources/MorrowApp/ComposerView.swift:53), [AppModel.swift](../Sources/MorrowApp/AppModel.swift:362).
2. **Account entry affordance:** empty email and authorization fields blend into the static labelled rows, making the editing region hard to locate. Give the editable values the existing paper field treatment or a native bordered field while retaining their visible labels. [SettingsView.swift](../Sources/MorrowApp/SettingsView.swift:27).
3. **Gate 39b, control hit bounds:** the custom button styles end at 32–34 pt, and the plain reader/composer icon buttons have no explicit target expansion. Keep the compact painted keys, expand their hit regions to 44 pt, and verify adjacent targets do not overlap. [Theme.swift](../Sources/MorrowApp/Theme.swift:39), [ReaderView.swift](../Sources/MorrowApp/ReaderView.swift:16), [ComposerView.swift](../Sources/MorrowApp/ComposerView.swift:34).
4. **Unlabelled empty instruction area:** the partner editor has an accessibility label but appears as a large blank field; the nearest visible instruction is far above it. Add an empty-state placeholder such as “告诉伙伴需要推进的事”, disappearing when typing begins. [PartnerViews.swift](../Sources/MorrowApp/PartnerViews.swift:39).

## Theme and signature

Furrow describes the rendered app: warm paper, a deeper sidebar, restrained orange selection and primary actions, ink rules, and a working ledger. The matter, evidence, and next action are legible together; the original mail remains recognizably separate from analysis and reply suggestions. There is no wholesale gap in the theme or product idea. The outstanding gap is the consistency of editable and actionable states.

The previous white search placeholder, vertical row dividers, fabricated deadline hours, unsupported attendance confirmation, and blank offscreen mail list are not reopened by this review; the supplied renders show those visual/copy corrections.

## QA limits

CUA reported the Mac locked. Interactive native window QA did not pass and was not performed in this review. These static renders do not prove keyboard focus visibility, VoiceOver behavior, target activation, split view resizing, sheet layout at shorter window sizes, scrolling to lower content, or loading/error states. Verify those after unlocking, including the account form with server settings expanded and the composer with CC and scheduling enabled. The demo data is explicitly `example.com`; this review provides no IMAP, SMTP, OAuth, or other provider acceptance evidence.

Preserve the ruled ledger, direct source-mail access, explicit demo identity, and cautious reply wording while fixing.

## Implementer resolution

All four findings were addressed in the current build: demo sending is disabled with a connection action; account values have bordered paper fields and example formats; compact painted buttons have 44pt hit expansion with icon buttons treated separately; the partner editor has a visible empty hint. Account configuration uses a bounded scroll region for expanded server settings. Updated native content renders were inspected by the implementer. No interactive window, keyboard focus, hit activation, resize or provider acceptance is inferred from these images.
