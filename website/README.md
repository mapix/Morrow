# Morrow product website

A static Chinese/English product page for the macOS mail workspace. The page has no analytics, mailing-list form, mailbox access, or private mailbox content. Its interactive examples use fixed fictional mail, contacts and responses; no example executes a mail action.

## Presentation

The site follows the native workbench direction: neutral gray canvas, white content, a restrained blue action color and system sans typography. Semantic colors, typography and spacing live in `tokens.css`; `base.css` contains shared defaults and `styles.css` supplies page composition. Paper textures, artificial window chrome, oversized slogans, decorative shadows and generated app mockups are not used.

The neutral canvas, ink, secondary text, boundaries, selection and action colors match the native `Theme.swift` light palette. Controls use its 5px radius; resources use 6px. Styles, scripts and icon URLs carry a revision to refresh earlier browser caches.

The masthead uses `assets/morrow-icon-128.webp` and `assets/favicon.png`, exported from the November 2 inbox-and-spark icon. The app packaging source is `assets/morrow-icon.png`; its editable geometry lives in `../scripts/make-icon.swift`. `assets/morrow-workbench-20261102.webp` is a 1440×900 export of the accepted native interface, using only `UIQualityFixture` fictional content. The original email and attachment area is rendered, and every displayed address belongs to `example.com`. Both the source pixels and optimized WebP were reviewed; its SHA-256 is pinned in the publication allowlist. The image can be opened at full size and has bilingual alt text. Earlier landing artwork remains historical brand material.

## Public release boundary

`downloads/latest.json` remains the authoritative public download manifest. The current manifest points to **v0.17.1**, a Developer ID signed, Apple-notarized and stapled macOS build. The site illustrates the current native project interface. The page makes this distinction beside the first download action and again in the download section. Features in a public binary are defined by its release notes.

The manifest accepts a HTTPS URL or a same-origin `/downloads/…` path, rejects embedded credentials, and displays the actual version, system requirements, size and SHA-256 when provided. An absent or invalid URL keeps downloading disabled. GitHub release and source links remain available; a failed manifest request exposes a retry action. Requests have a five-second timeout and never include mailbox credentials.

## Local preview

```sh
node --check website/app.js
python3 -m http.server 4178 --directory website
```

Use browser-harness for browser inspection and interaction. Verify 1280×800 and 1920px layouts, 375/320px narrow layouts, Chinese/English, keyboard focus and tab arrow navigation, no-JS content, and pending/ready/unavailable download states. Do not click a download during routine UI verification.

Syntax and static DOM checks prove source consistency. Browser captures and actual interactions are required before publication. Without JavaScript, the page displays the product and directs downloads to GitHub.

## Deployment files

The production site is [morrow.novarock.io](https://morrow.novarock.io/). It runs as the `morrow-website` Kubernetes deployment in the `morrow` namespace behind the existing HTTPS ingress. Use an explicit, reviewed static-file list as the build context. The generic `Dockerfile` remains available for clean builds; production may reuse the previously deployed compatible nginx runtime.

For an update, retain the previous image and deployment specification, build a unique website image, import it into the node container runtime, update only the website container image, and wait for readiness. Verify the public HTML, styles, script, icons, native screenshot and download manifest against their source SHA-256 values. Roll back to the recorded previous image if readiness or public verification fails. Website publishing does not publish a desktop binary.

## Latest local source verification

2026-11-02: an isolated local headless Chrome/CDP instance inspected this page through browser-harness. Widths 320, 375, 1280 and 1920 had no horizontal overflow; the 1920 layout kept the 1180px container. Chinese/English switching, scene click and keyboard navigation, conversation selection, automatic-response example selection, visible keyboard focus, valid public-manifest metadata, unavailable-manifest fallback/retry, and no-JS source content were checked. Resource requests stayed on the local origin; no release download was started and no mail action or deployment was executed.

This earlier check covered locally served source. The native screenshot has its own accepted fixture evidence. Production verification is recorded separately below.

## November 2 landing update verification

The updated page passed Chinese and English layouts at 320, 375, 768, 1280 and 1920px, with no overflowing content or broken images. Actual browser actions verified language switching, scene and session keyboard navigation, visible focus, automatic-response choices, and the hero download anchor. Unavailable manifests exposed retry; retry recovered; an invalid download URL stayed disabled. Without JavaScript, product content and the GitHub download fallback remained available. A clean reload reported no JavaScript errors; all eight resource requests returned successfully from the local origin.

The native screenshot is an 82,896-byte WebP. Its reviewed fictional content contains no real mailbox data. Public download metadata still points to v0.11.1, as confirmed by the live manifest and published GitHub releases.

## Production publication

November 2, 2026: the updated site is live at [morrow.novarock.io](https://morrow.novarock.io/). Website source commit: `779e5ad3b02c103fddcbc09a50125e12b69b001e`. Image: `morrow-website:landing-20261102-workbench`; previous image `morrow-website:0.11.1` is retained for rollback.

The rolling update completed with one ready replica and no restarts. Public HTTPS verification matched all nine served files to their source SHA-256 values; `/healthz` returned `ok`. The live browser verified Chinese and English at 320, 375, 1280 and 1920px, full native-image loading, scene and conversation selection, and the download anchor. All same-origin resources returned HTTP 200. Download metadata remains the verified public v0.11.1 release.

## 0.17.1 download update

The public download is `Morrow-0.17.1-macOS-arm64.zip`, 532874646 bytes, SHA-256 `9c3ee0a0f8c33e7cf417262b77e973932bf7ff036e11100b299ad80645bccf62`. Apple accepted the submission, the ticket is stapled, and Gatekeeper assessment passed. Public release: https://github.com/mapix/Morrow/releases/tag/v0.17.1. The earlier v0.11.1 entries above describe historical verification.
