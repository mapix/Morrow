# Smail Agentic Native system

Hallmark v2.0.0. Coral selected by the user, superseding Vantage and Atelier. SwiftUI and AppKit desktop application. The native window title bar and the app's top navigation bar are hidden.

## Main object

The foreground object is an ongoing piece of work: an editable reply, a source-backed report, or a structured choice that lets the partner continue. One broad work document is visible on entry. Other work is recalled through a compact switcher. Original emails, execution details and earlier versions open on demand.

## Visual system

Warm pale gray ground, cotton sheet surfaces, dark warm ink, and restrained coral for focus, links and selected navigation. All colors and fonts are declared in `Sources/SmailApp/Theme.swift`; `tokens.css` and `base.css` record the Hallmark reference. System sans typography preserves Chinese and macOS readability. No Atelier serif face remains.

Controls use an 8pt radius, dark primary buttons, immediate coral focus and faint shadows falling right. Text fields have a distinct muted border instead of separator color. The desktop translation keeps the theme's warm paper, pressed controls and restrained voice. It does not reproduce the website's paper animation or textures as decoration in the work surface.

## Navigation

A 210pt left sidebar has four primary entries: work, mail, contacts and attachments, followed by accounts and chat sessions. A management menu holds history, work outputs, responders, memory and sync status. Settings is a separate visible control at the bottom. Icons have accessibility names and tooltips. The main document has a capped readable width; larger windows grow the margins. Native traffic lights and the macOS menu remain system controls.

The app has no permanent task list. A resizable right Chat pane is now persistent by explicit user request; its context follows the primary native view and selection. Existing mail reading, folders, search, contacts, calendar and composer remain available through Mail and settings.

## Work interaction

Natural delegation becomes an editable agreement with purpose, completion condition, scope, plan and authority. Acceptance starts the work. Current mail identities and future filters define the scope. New mail continues the same matter; reports keep their identity and revisions, and earlier replies stay folded. A report revision does not finish an ongoing responsibility.

Replies are editable where they are presented. Decisions create persistent receipts. Source lists are folded under “依据邮件”; history is folded under “原邮件与工作记录”. Sent replies show their actual delivery or explicit simulation state.

## OpenUI and responders

A native profile of OpenUI Lang 1.0 renders model-produced forms, tables, choices and actions in SwiftUI. Rendering has no side effects. Form edits persist with revisions; user-triggered actions pass a typed ActionEvent to allowed host operations. Completed setup forms are folded and cannot run again. Query, Mutation and arbitrary remote execution are unsupported.

Responders combine account, sender, subject and body conditions. They can prepare drafts or automatically reply to new matching mail. Existing mail is marked seen when a rule is created. Preview does not send. Pause and resume update both the rule and its associated work. Responses have persistent canonical receipts to prevent duplicates.

## Data and verification

Demo mail uses example.com. Simulated delivery writes only a local Sent copy. Original messages remain available. Actual native captures and test logs are recorded in `docs/agentic/CONTINUOUS-WORK-QA.md`. CSS lint is a reference check; it does not prove the native window or browser render tier passed.


## Unified partner pane and new primary views

Contacts and attachments have dedicated rail entries. Contacts use a compact index plus a source-backed profile and chronological mail history. Attachments use one filterable index with explicit selection and original-mail links. Both synchronize a typed context snapshot with the right Chat pane.

The right pane holds conversation and OpenUI. Its coral scope anchor sits directly above the input, showing the actual current or fixed object. The session switcher stays at the top. Message provenance and references expand on demand; routine role labels, timestamps and permanent explanations are absent. A bounded material strip and native rich input provide file, screenshot and microphone actions. Sent instructions retain their submitted scope even when the user changes the left view. The input is singular; the old work-document bottom composer is removed.

Native email composition and attachment text preview remain in the primary area so the right pane can cooperate. Host receipts reflect actual saves and actions; LLM prose never substitutes for a completed write. Editing a draft fixes its host identity and preserves concurrent user changes as separate suggestions.


## Sessions and managed memory

User revisions add a 210pt left navigation sidebar with mailboxes and chat Sessions, plus a right session switcher. Session input, materials and pinned context persist independently. The contact correction editor is removed; conversation is the single input surface. The memory workspace manages scope, provenance, versions, validity and user controls. Read/unread has explicit labels and functional row treatment. Density switches preserve reading contrast. Model edits stage before applying to background requests.
