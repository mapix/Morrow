# Morrow native correspondence workbench

The November 2, 2026 commercial-quality redesign supersedes the old Coral/Furrow design. This is a macOS application, not a marketing page.

## Product and hierarchy

Mail, recipients, delivery state, saved work and original evidence define the interface. The workspace, mail folders and conversations are separate navigation groups. A readable main surface is paired with a resizable optional assistant pane. Narrow windows show either the mail index or selected reader instead of clipping two panes.

Every screen uses a compact page header, a functional toolbar, one main object and explicit empty/loading/error states. Work home presents current matters, decisions and saved output, not a personality slogan. Reports keep document typography; indices use short aligned rows.

## Shared system

`Sources/MorrowApp/Theme.swift` is the single native color/type source. `InteractionStyles.swift` defines pointer, press, focus, hover, selected and disabled states. `WorkspaceChrome.swift` supplies page and section headers.

- Neutral canvas #F4F5F7, white content, sidebar #ECEFF3.
- Ink #212A35, secondary #4F5A68, muted #667180, boundaries #DDE1E7.
- One action blue #2B61AF, independent success #327356 and failure #BB3C3C.
- Interface system sans; titles22pt, sections15pt, controls13pt, reading15pt, metadata11–12pt. Monospace is reserved for code and real identifiers.
- Space4/8/12/16/24/32; page edge24pt; control height28–32pt; control radius5pt, resource radius6pt.
- Content stays flat. Containers encode grouping; no nested ornamental cards, paper texture, decorative status dots or button shadows.

Appearance choices are system/light/dark. Legacy Coral and Forest IDs migrate to the new light style without changing stored mail, task identities or input.

## Behavioral quality

A sent/queued/unverified delivery cannot appear editable. Current output links show actual state while historical message text retains its original timestamped facts. New chat requests, explicit task continuation and answers to a particular question have separate identities and permission boundaries.

New Inbox notifications do not wait for AI analysis and do not fire for history backfills, Sent, Trash or duplicate copies. Automatic mail analysis remains local and bounded. SMTP acceptance commits before cache copies; failed copy creation never triggers another SMTP submission.

Original email layout, original PDF/image attachments and source links remain available. Preview is local; remote-only attachments are fetched after an explicit preview/save action. Critical files saved as materials or draft attachments survive temporary workspace cleanup.

## Evidence and closure

`docs/public/UI-QUALITY-PLAN.md` is the full surface/performance checklist. Native page renders, real interactions and benchmarks are separate evidence. A green narrow test run or static design critique does not complete the goal. Private account data, screenshots and measurements remain under evidence/private; public demonstrations use synthetic mail.
