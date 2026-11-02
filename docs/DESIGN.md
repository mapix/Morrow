# Smail design system

Hallmark v2.0.0, app screen scope. Theme: Furrow (deal 2/3, 2026-10-30).

## Product argument

Mail becomes a queue of decisions, with the original correspondence always one click away. Agent output is evidence tied to mail, editable and distinguishable from the original.

## Material and audience

Native macOS, Chinese interface, professionals with several personal and work mailboxes. No brand imagery or invented metrics. Demo correspondence is explicitly labelled and isolated from real mail.

## Signature

A ruled action ledger: the matter, who is waiting, evidence, and next action. An inbox list and reading pane retain familiar mail workflows.

## Tokens

Warm paper and deeper neutral sidebar; near-black text; tangerine for compose and active selection; restrained green for completed states. All colors and fonts live in Theme.swift, derived from tokens.css. System Chinese typography, native focus rings, 6-point control radius, 8-point spacing scale. No decorative gradients, cards nested inside cards, synthetic avatars, or ornamental motion.

## Screen states

Inbox, action queue, semantic search, reader, composer, accounts, agent settings and indexing each support empty, loading, error and full states. Settings use inline labelled forms. Native keyboard navigation and commands. Deleting mail moves it to Trash; reversible actions expose Undo. Permanent deletion requires confirmation.

## Native translation

Hallmark's browser CSS rules are translated into SwiftUI color/font tokens, AppKit focus/keyboard semantics, split view resize behavior and Reduce Motion. CSS render lint cannot validate a native window; native screenshots and interaction checks are required.
