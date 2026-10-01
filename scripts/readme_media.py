"""Builds the README pictures from the client's screen goldens.

The goldens come from clients/flutter/test/goldens/screens_test.dart with
invented people and messages. This script only frames them: a macOS window
around the desktop screen, phones around the mobile screens, and a short
animated tour. Run it through scripts/update_screenshots.sh, which
regenerates the goldens first:

    uv run --with 'pillow~=12.0' scripts/readme_media.py

It also writes docs/assets/readme/sources.json, the SHA-256 of every input
and of this script. The client's hygiene test compares those hashes, so a
changed screen or frame without new pictures fails the build.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
GOLDENS = ROOT / "clients/flutter/test/goldens/screens"
OUT = ROOT / "docs/assets/readme"
FONT = ROOT / "clients/flutter/assets/fonts/InstrumentSans-VF.ttf"
LANGUAGES = ("en", "es")
MODES = ("light", "dark")

# The goldens are rendered at one pixel per point, so the frames are too;
# drawing them larger would only enlarge the files.
SCALE = 1

# GitHub's page backgrounds. The GIF has no partial transparency, so each
# theme gets its own GIF drawn on the colour it will sit on.
PAGE = {"light": (255, 255, 255), "dark": (13, 17, 23)}

PHONE_TRIO = ("phone_chats", "phone_conversation", "phone_card_code")
TOUR = (
    "phone_chats",
    "phone_conversation",
    "phone_contacts",
    "phone_card",
    "phone_card_code",
    "phone_card_link",
)
HOLD_MS = 1800
FADE_FRAMES = 3
FADE_MS = 50


def font(size: int, weight: int) -> ImageFont.FreeTypeFont:
    face = ImageFont.truetype(str(FONT), size)
    face.set_variation_by_axes([weight])
    return face


def golden(language: str, name: str, mode: str) -> Path:
    return GOLDENS / language / f"{name}_{mode}.png"


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    # Drawn four times larger and reduced, so the corners are smooth.
    big = Image.new("L", (size[0] * 4, size[1] * 4), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, big.width - 1, big.height - 1), radius * 4, fill=255
    )
    return big.resize(size, Image.Resampling.LANCZOS)


def with_shadow(shape: Image.Image, margin: int, blur: int, alpha: int) -> Image.Image:
    """Places an RGBA shape on a transparent canvas with a soft shadow."""
    canvas = Image.new(
        "RGBA", (shape.width + 2 * margin, shape.height + 2 * margin), (0, 0, 0, 0)
    )
    shadow = Image.new("L", canvas.size, 0)
    shadow.paste(shape.getchannel("A").point(lambda a: a * alpha // 255), (margin, margin + blur // 3))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.putalpha(shadow)
    canvas.alpha_composite(shape, (margin, margin))
    return canvas


def mac_window(screen: Image.Image, mode: str) -> Image.Image:
    bar = 28 * SCALE
    radius = 12 * SCALE
    screen = screen.resize((screen.width * SCALE, screen.height * SCALE), Image.Resampling.LANCZOS)
    width, height = screen.width, screen.height + bar
    if mode == "light":
        bar_colour, line, title, edge = (236, 236, 236), (214, 214, 214), (77, 77, 77), (0, 0, 0, 40)
    else:
        bar_colour, line, title, edge = (46, 46, 48), (24, 24, 26), (214, 214, 214), (255, 255, 255, 40)
    window = Image.new("RGBA", (width, height), bar_colour + (255,))
    window.paste(screen.convert("RGBA"), (0, bar))
    draw = ImageDraw.Draw(window)
    draw.line((0, bar - 1, width, bar - 1), fill=line, width=1)
    for i, colour in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy, r = (20 + 20 * i) * SCALE, bar // 2, 6 * SCALE
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=colour)
    draw.text((width // 2, bar // 2), "Arveil", font=font(13 * SCALE, 600), fill=title, anchor="mm")
    window.putalpha(rounded_mask(window.size, radius))
    border = Image.new("RGBA", window.size, (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        (0, 0, width - 1, height - 1), radius, outline=edge, width=SCALE
    )
    window.alpha_composite(border)
    return with_shadow(window, margin=40 * SCALE, blur=24 * SCALE, alpha=90)


def phone(screen: Image.Image, mode: str) -> Image.Image:
    """A plain phone: bezel, status bar with a camera and the time."""
    status = 32
    bezel = 10
    w, h = screen.width, screen.height + status
    body_w, body_h = w + 2 * bezel, h + 2 * bezel
    s = SCALE
    body = Image.new("RGBA", (body_w * s, body_h * s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(body)
    frame = (28, 28, 30) if mode == "light" else (58, 58, 62)
    draw.rounded_rectangle((0, 0, body.width - 1, body.height - 1), 52 * s, fill=frame)
    glass = Image.new("RGB", (w * s, h * s))
    top = screen.getpixel((screen.width // 2, 2))[:3]
    glass.paste(top, (0, 0, glass.width, status * s))
    glass.paste(screen.convert("RGB").resize((w * s, screen.height * s), Image.Resampling.LANCZOS), (0, status * s))
    ink = (20, 20, 20) if sum(top) > 384 else (235, 235, 235)
    gd = ImageDraw.Draw(glass)
    gd.text((28 * s, status * s // 2), "18:41", font=font(14 * s, 600), fill=ink, anchor="lm")
    cx, cy, r = glass.width // 2, status * s // 2, 6 * s
    gd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(12, 12, 12))
    # Battery and signal, drawn as simple shapes.
    bx = glass.width - 52 * s
    gd.rounded_rectangle((bx, cy - 6 * s, bx + 22 * s, cy + 6 * s), 3 * s, outline=ink, width=s + 1)
    gd.rectangle((bx + 3 * s, cy - 3 * s, bx + 16 * s, cy + 3 * s), fill=ink)
    for i in range(4):
        x = glass.width - 92 * s + i * 6 * s
        gd.rectangle((x, cy + 5 * s - (i + 1) * 3 * s, x + 3 * s, cy + 5 * s), fill=ink)
    body.paste(glass, (bezel * s, bezel * s), rounded_mask(glass.size, 42 * s))
    return body


def trio(language: str, mode: str) -> Image.Image:
    phones = [phone(Image.open(golden(language, n, mode)), mode) for n in PHONE_TRIO]
    gap = 36 * SCALE
    row = Image.new(
        "RGBA",
        (sum(p.width for p in phones) + gap * (len(phones) - 1), phones[0].height),
        (0, 0, 0, 0),
    )
    x = 0
    for p in phones:
        row.alpha_composite(p, (x, 0))
        x += p.width + gap
    return with_shadow(row, margin=28 * SCALE, blur=18 * SCALE, alpha=70)


def tour(language: str, mode: str) -> tuple[list[Image.Image], list[int]]:
    stills = []
    for name in TOUR:
        framed = phone(Image.open(golden(language, name, mode)), mode)
        page = Image.new("RGBA", framed.size, PAGE[mode] + (255,))
        page.alpha_composite(framed)
        stills.append(page.convert("RGB"))
    frames, durations = [], []
    for i, still in enumerate(stills):
        frames.append(still)
        durations.append(HOLD_MS)
        following = stills[(i + 1) % len(stills)]
        for step in range(1, FADE_FRAMES + 1):
            frames.append(Image.blend(still, following, step / (FADE_FRAMES + 1)))
            durations.append(FADE_MS)
    return frames, durations


def save_gif(frames: list[Image.Image], durations: list[int], path: Path) -> None:
    # Each frame gets its own palette: one shared across six screens loses
    # small accents such as the colour of each author's name.
    quantized = [
        f.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        for f in frames
    ]
    quantized[0].save(
        path,
        save_all=True,
        append_images=quantized[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=1,
    )


def save_png(image: Image.Image, path: Path) -> None:
    # Full colour: a palette merges the white bubbles into the background.
    image.save(path, optimize=True)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    inputs: set[Path] = set()
    for language in LANGUAGES:
        out = OUT / language
        out.mkdir(parents=True, exist_ok=True)
        for mode in MODES:
            desktop = golden(language, "desktop_conversation", mode)
            inputs.add(desktop)
            save_png(mac_window(Image.open(desktop), mode), out / f"desktop_{mode}.png")
            inputs.update(golden(language, n, mode) for n in PHONE_TRIO)
            save_png(trio(language, mode), out / f"phones_{mode}.png")
            inputs.update(golden(language, n, mode) for n in TOUR)
            frames, durations = tour(language, mode)
            save_gif(frames, durations, out / f"tour_{mode}.gif")
    manifest = {
        "script": sha256(Path(__file__)),
        "inputs": {
            str(p.relative_to(GOLDENS)): sha256(p) for p in sorted(inputs)
        },
    }
    (OUT / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"README pictures updated in {OUT.relative_to(ROOT)}.")


if __name__ == "__main__":
    main()
