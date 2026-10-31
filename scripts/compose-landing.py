#!/usr/bin/env python3
"""Compose editable brand copy over the requested model-generated background."""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
COLORS = {"ink": "#302722", "secondary": "#65594f"}
FONT = str(next(Path("/System/Library/AssetsV2").glob("com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc"), Path("/System/Library/Fonts/PingFang.ttc")))
OUTPUT = ROOT / "output/branding"
OUTPUT.mkdir(parents=True, exist_ok=True)
COPY = {
    "zh-Hans": ("邮件，交给伙伴。", "主动整理，持续跟进，与你一起推进每件事。", "Swift 原生邮件伙伴"),
    "en": ("Your mail.\nA partner for it.", "Delegate the work. Stay close to what matters.", "A native Swift email partner"),
    "ja": ("メールに、パートナーを。", "メールを整理し、大切な仕事を一緒に進めます。", "Swiftでつくるメールパートナー"),
}
for locale, (title, detail, footer) in COPY.items():
    canvas = Image.open(ROOT / "output/imagegen/morrow-landing-flare.png").convert("RGB")
    draw = ImageDraw.Draw(canvas)
    wordmark = ImageFont.truetype(FONT, 48)
    heading = ImageFont.truetype(FONT, 90 if locale == "en" else 76 if locale == "ja" else 96)
    body = ImageFont.truetype(FONT, 31)
    small = ImageFont.truetype(FONT, 24)
    draw.text((96, 80), "Morrow", font=wordmark, fill=COLORS["ink"])
    draw.multiline_text((92, 205), title, font=heading, fill=COLORS["ink"], spacing=12)
    detail_y = 480 if locale == "en" else 364
    draw.text((96, detail_y), detail, font=body, fill=COLORS["secondary"])
    draw.text((96, 898), footer, font=small, fill=COLORS["secondary"])
    canvas.save(OUTPUT / f"morrow-landing-{locale}.png")
(OUTPUT / "copy.json").write_text(json.dumps(COPY, ensure_ascii=False, indent=2), encoding="utf-8")
print("Composed Chinese, English and Japanese landing artwork.")
