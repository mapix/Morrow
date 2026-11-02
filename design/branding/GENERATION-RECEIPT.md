# Generated Smail assets

Historical receipt: the October 31 raster icon was superseded on November 2 by the inbox-and-spark redesign in `scripts/make-icon.swift` and `website/assets/morrow-icon.png`. The current icon is drawn with native Core Graphics; the receipt below describes the earlier assets.

Generated on 2026-10-31 with the requested `gpt-image-2.5-flare` model, using the unmodified imagegen skill CLI and the configured API endpoint. Both requests completed.

| Asset | Size | Quality | Source |
| --- | --- | --- | --- |
| Native app icon | 1024 × 1024 | high | `output/imagegen/smail-icon-flare.png` |
| Landing background | 1536 × 1024 | high | `output/imagegen/smail-landing-flare.png` |

Prompts are retained in `tmp/imagegen/smail-assets.jsonl`. Neither image contains invented app UI or product metrics. The native icon is an opaque full square; macOS and iOS apply their own presentation. The landing artwork is composed with real product screenshots and editable text after native verification.

Visual review: clear single-envelope silhouette, coral on warm neutral paper, no words/robots/watermark, no baked outer iOS mask. Native packaging uses the generated raster directly. The background has negative space for real product material.

Chinese, English and Japanese brand posters are composed in `output/branding/`. Copy and the deterministic composition source are retained separately. The current posters use brand artwork and accurate native-mail-partner copy; they contain no invented product screenshots, metrics, account data or unverified cloud/platform claims. A screenshot-based poster can be added after the final native-window capture.
