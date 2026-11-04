# Morrow product website

A static Chinese/English landing page for the native macOS AI mail workspace. The November 4 redesign takes its exhibition structure, oversized type, persistent navigation, searchable feature index, changing palettes, and exploratory interactions from [Shopify Editions Fall 2026](https://www.shopify.com/editions/fall2026). Its content, artwork, icons, and interactions are implemented for Morrow; no Shopify assets or fonts are copied.

## Presentation

The opening combines a vertical Morrow wordmark, a chapter index, and an interactive constellation of mail, files, memory, and follow-up work. Eight chapters cover mail, search, people and files, Chat, memory, responders, model choice, and the native Mac experience. A download section and six expandable questions complete the page.

Interactions include a searchable feature dialog, feature details, an eight-chapter exhibition view with arrow-key navigation, three search examples, contact and attachment selection, independent Chat examples, example memory editing and pausing, responder simulations, model data-path choices, native image enlargement, and three palette choices. The default palette changes with the chapter being read. Chinese and English share the same layout and interactions.

Semantic colors and fonts live in `tokens.css`; shared defaults in `base.css`; composition and responsive rules in `styles.css`. The page uses system fonts and no external JavaScript or image dependencies. The opening canvas only animates while visible; reduced motion disables ambient animation and transitions. Product content is visible without JavaScript, including a GitHub release fallback.

`assets/morrow-workbench-20261102.webp` is the existing 1440×900 export of the native interface, using only `UIQualityFixture` fictional content and `example.com` addresses. Its reviewed SHA-256 remains pinned in the publication allowlist. The icon assets are the existing November 2 inbox-and-spark icon. The constellation and other feature artwork are CSS, SVG, and canvas illustrations rather than screenshots of additional shipped interfaces.

## Examples and download boundary

All mail, contacts, files, results, and responder interactions on this page are fixed fictional examples. Example memory edits reset on reload. Nothing connects to a mailbox, runs a model, reads personal data, or sends email. There is no analytics or mailing-list form.

`downloads/latest.json` is the authoritative public download manifest and currently points to **v0.17.1**. The page shows the current project; public binary features are defined by the release notes. A website update does not release a desktop binary.

The manifest accepts a HTTPS URL or a same-origin `/downloads/…` path, rejects embedded credentials and unsafe schemes, and displays version, system requirements, size, and SHA-256. Missing or invalid metadata keeps downloading disabled, preserves the GitHub release fallback, and exposes retry. Manifest requests have a five-second timeout and omit credentials.

## Local preview and verification

```sh
node --check website/app.js
python3 -m http.server 4178 --directory website
python3 scripts/check-publication.py --worktree
```

November 4, 2026: local headless Chrome controlled through browser-harness passed 38 interaction/layout assertions and eight fallback assertions. Chinese and English were checked at 320, 375, 768, 1280, and 1920px with no horizontal overflow. Actual UI actions covered search and detail dialogs, menu Escape, tab arrow navigation, contacts and files, Chat outputs and sources, memory editing and pausing, both responder modes, model paths, palettes, exhibition navigation, language switching, and checksum disclosure. All images loaded, fresh reloads reported no runtime errors, and resources stayed on the local origin.

Fallback checks covered unavailable manifests, GitHub release fallback, retry recovery, an invalid `javascript:` download URL, reduced motion, and no-JavaScript product content. Additional browser captures checked the chapter color changes. No release download or mail action was executed. Local screenshots and detailed checks are kept in ignored evidence; the production verification is recorded below.

## Mouse and navigation follow-up

The November 4 follow-up adds a damped pointer ring, connected square-node trails, nearby-node wires, feature corner highlights, click pulses, and layered hero parallax. These effects preserve the native cursor and never capture clicks. They are disabled for coarse pointers and reduced motion, stop when the page is hidden, and settle without an ongoing animation loop away from the hero.

The desktop chapter menu now enters row by row as the hero scrolls away, stays centered in the viewport, and animates its current-chapter ring. Anchor navigation uses an eased transition that can be interrupted with the wheel, touch, or scrolling keys. Browser history retains chapter anchors. Chapter titles fill from outline to solid type as they enter the viewport. On narrow screens the menu becomes a horizontal chapter rail with the selected item kept in view; jump targets clear both fixed bars.

Browser-harness checks passed 16 desktop/pointer checks and 16 touch/layout/reduced-motion checks. They covered actual pointer movement and card clicks, staggered entry, indicator alignment, centered navigation, eased landing positions, wheel interruption, subsequent navigation, browser history, English title overlays, stopped idle animation, touch suppression, mobile anchor positions, selected-chip visibility, both languages at 320/375/768/1280/1920px, and immediate reduced-motion navigation. The test browser reported no JavaScript errors. Captures and checks remain in ignored local evidence.

## Production deployment

The November 4 redesign is live at [morrow.novarock.io](https://morrow.novarock.io/) in the `morrow-website` Kubernetes deployment, namespace `morrow`, behind the existing HTTPS ingress.

The previously published November 2 design used source commit `779e5ad3b02c103fddcbc09a50125e12b69b001e`, image `morrow-website:landing-20261102-workbench`, and retained `morrow-website:0.11.1` for rollback. That deployment passed HTTPS file hash and readiness checks. These historical results do not verify the new design.

November 4 publication used source commit `838e16b68d1fcbae9f3e618c5a98daa825b6b83c` and image `docker.io/library/morrow-website:landing-20261104-explore-838e16b`. The image reuses the existing nginx 1.25.5 runtime, restores its non-root user, and copies an explicitly reviewed static-file list. The deployment retains its existing writable cache and runtime volumes, security settings, service, and ingress. Only the website image changed. Deployment generation 7 completed with one ready replica and no restarts; the November 2 image remains available for rollback.

Public HTTPS verification matched all 11 served files byte for byte to the release source. `/healthz` returned `ok`. The public browser verified search, chapter navigation, language switching, 320/375/1280/1920px layouts, and complete native-image loading. It reported no JavaScript errors, blocked resources, or CSP violations. The live download manifest still identifies v0.17.1; no download or mail operation was executed.

HTML, scripts, and styles use `Cache-Control: no-cache, no-transform`. Revalidation keeps new releases current, and `no-transform` prevents Cloudflare from rewriting fictional email addresses or injecting additional scripts into the verified HTML. The release commits and publication privacy checks succeeded on GitHub.

For an authorized update, retain the previous image and deployment specification, build a unique image from an explicit reviewed static-file list, update the website container, wait for readiness, and compare public served files with source SHA-256 values. Roll back if readiness or verification fails. Run the publication gate on the reviewed staged index before any push.

The current public download is `Morrow-0.17.1-macOS-arm64.zip`, 532874646 bytes, SHA-256 `9c3ee0a0f8c33e7cf417262b77e973932bf7ff036e11100b299ad80645bccf62`. Existing release records report Developer ID signing, Apple notarization and stapling. [Public release](https://github.com/mapix/Morrow/releases/tag/v0.17.1).
