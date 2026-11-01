# Morrow website

Static zh/en landing page for the macOS desktop app. No analytics, email form, user mailbox access, or private product screenshots. Interactive scenes use fixed fictional content and never execute mail actions.

## Files and assets

- `index.html`, `styles.css`, `app.js`: site and interaction.
- `tokens.css`, `base.css`: Hallmark Coral scaffold; the root product design's system-sans voice is retained.
- `assets/morrow-icon.png`: generated brand icon; square, at least512px.
- `assets/hero.png`:1536x1024 conceptual brand art. It is not a product screenshot.
- The page uses derived `hero.webp` (about119KB), `morrow-icon-128.webp` (about4KB), and `favicon.png` (about8KB). Original generated assets are retained for the brand pipeline, not requested by the page.
- `assets/cotton.svg`, `felt.svg`: faint static paper texture. No photo library is used.

The image slots have no private-email fallback. Until the brand files arrive, a plain Morrow wordmark remains visible.

## Download manifest

Publish `/downloads/latest.json` using the checked-in schema. The page accepts a HTTPS URL or a same-origin `/downloads/…` path. With no valid URL, the download stays disabled and visitors can use the actual GitHub releases page. No release asset URL or version is invented.

```json
{
  "schemaVersion": 1,
  "version": "YOUR_RELEASE_VERSION",
  "macOS": {
    "url": null,
    "fileName": null,
    "sizeBytes": null,
    "sha256": null,
    "minimumVersion": "26.0",
    "architecture": "Apple Silicon"
  },
  "releaseUrl": "https://github.com/mapix/Morrow/releases"
}
```

## Build and deployment

Use the `website/` directory as Docker build context, not the repository root:

```sh
docker build -t YOUR_REGISTRY/morrow-website:YOUR_TAG website
```

The container listens on8080. `deploy/kubernetes.template.yaml` is a placeholder template only; it does not contain a real host, namespace, TLS secret or image. Publish your own image and configure the placeholders before deploying to a cluster.

## Verification

From the repository root, check JavaScript syntax and serve the static site:

```sh
node --check website/app.js
python3 -m http.server 4173 --directory website
```

Open the local preview and check hero visibility at1280×800, touch and keyboard controls at375px, desktop gutters at1920px, both languages, scene/session/response controls, no-JS readability, and null/valid/unavailable download manifest states. Syntax checks do not establish browser behavior; verify interactions in a browser before deployment.
