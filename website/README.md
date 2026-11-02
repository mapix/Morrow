# Morrow product website

A static Chinese/English product page for the macOS mail workspace. The page has no analytics, mailing-list form, mailbox access, or private screenshots. Its interactive examples use fixed fictional mail, contacts and responses; no example executes a mail action.

## Presentation

The site follows the native workbench direction: neutral gray canvas, white content, a restrained blue action color and system sans typography. Semantic colors, typography and spacing live in `tokens.css`; `base.css` contains shared defaults and `styles.css` supplies page composition. Paper textures, artificial window chrome, oversized slogans, decorative shadows and generated app mockups are not used.

The masthead uses `assets/morrow-icon-128.webp` and `assets/favicon.png`, exported from the November 2 inbox-and-spark icon. The app packaging source is `assets/morrow-icon.png`; its editable geometry lives in `../scripts/make-icon.swift`. Earlier landing artwork remains historical brand material. New native UI screenshots should only be added after the rendered build is verified and private data is excluded.

## Public release boundary

`downloads/latest.json` remains the authoritative public download manifest. This UI work does not publish an application, change signing or notarization records, or replace a release artifact. The current manifest points to **v0.11.1**; current native interface improvements are still in development. The page makes this distinction beside the first download action and again in the download section. Features in a public binary are defined by its release notes.

The manifest accepts a HTTPS URL or a same-origin `/downloads/…` path, rejects embedded credentials, and displays the actual version, system requirements, size and SHA-256 when provided. An absent or invalid URL keeps downloading disabled. GitHub release and source links remain available; a failed manifest request exposes a retry action. Requests have a five-second timeout and never include mailbox credentials.

## Local preview

```sh
node --check website/app.js
python3 -m http.server 4178 --directory website
```

Use browser-harness for browser inspection and interaction. Verify 1280×800 and 1920px layouts, 375/320px narrow layouts, Chinese/English, keyboard focus and tab arrow navigation, no-JS content, and pending/ready/unavailable download states. Do not click a download during routine UI verification.

Syntax and static DOM checks prove only source consistency. Actual browser captures and interaction results must be recorded separately before publication. This task does not deploy the website.

## Deployment files

`Dockerfile` and `deploy/` retain their existing behavior. Use `website/` as the Docker build context rather than the repository root. Deployment templates are placeholders; no registry, host, namespace, TLS configuration or live deployment is supplied by this UI change.

## Latest local source verification

2026-11-02: an isolated local headless Chrome/CDP instance inspected this page through browser-harness. Widths 320, 375, 1280 and 1920 had no horizontal overflow; the 1920 layout kept the 1180px container. Chinese/English switching, scene click and keyboard navigation, conversation selection, automatic-response example selection, visible keyboard focus, valid public-manifest metadata, unavailable-manifest fallback/retry, and no-JS source content were checked. Resource requests stayed on the local origin; no release download was started and no mail action or deployment was executed.

This confirms the locally served source only. It does not prove a deployed page, a new public app release, or native interface behavior.
