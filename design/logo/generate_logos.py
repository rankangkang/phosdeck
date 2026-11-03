"""Generate the current Phosdeck logo assets from the approved wordmark."""
import json, math, os, subprocess
from pathlib import Path

OUT = os.path.dirname(os.path.abspath(__file__))


IVORY = dict(bg="#EEECE7", base="#E3E1DB", ink="#2A2B29", ink2="#5A5B56", lamp="#FF920E", socket="#3C3C38", sig="#B85F14", sep="#CFCCC4")


GRAPHITE = dict(bg="#232424", base="#1A1B1B", ink="#E8E6E0", ink2="#B3B2AC", lamp="#FF9B24", socket="#0E0F0F", sig="#F0A04A", sep="#3B3D3E")


def squircle(size, fill, stroke_c=None):
    r = size * 0.2237
    s = f' stroke="{stroke_c}" stroke-width="{size*0.004}"' if stroke_c else ""
    return f'<rect x="0" y="0" width="{size}" height="{size}" rx="{r}" fill="{fill}"{s}/>'


def ring_ticks(p, size, count, width):
    """Equal ticks all the way round, starting at 12 o'clock."""
    c, r1, r2 = size / 2, size * 0.335, size * 0.38
    out = []
    for i in range(count):
        ang = math.radians(-90 + i * 360 / count)
        out.append(f'<line x1="{c+r1*math.cos(ang):.1f}" y1="{c+r1*math.sin(ang):.1f}" x2="{c+r2*math.cos(ang):.1f}" '
                   f'y2="{c+r2*math.sin(ang):.1f}" stroke="{p["ink2"]}" stroke-width="{width}" stroke-linecap="butt"/>')
    return "".join(out)


def ab_base(p, size):
    """Socket ring with an equal full-circle scale."""
    c = size / 2
    scale = ring_ticks(p, size, FINAL_RING[0], size * FINAL_RING[1])
    return (squircle(size, p["bg"]) + scale +
            f'<circle cx="{c}" cy="{c}" r="{size*0.235}" fill="none" stroke="{p["ink"]}" stroke-width="{size*0.085}"/>')


def icon_ab_notch(p, size=1024):
    """As above, plus a pointer notch cut through the ring so it reads as a knob."""
    c = size / 2
    a = math.radians(-45)
    r_in, r_out = size * 0.19, size * 0.28
    return (ab_base(p, size) +
            f'<line x1="{c+r_in*math.cos(a):.1f}" y1="{c+r_in*math.sin(a):.1f}" x2="{c+r_out*math.cos(a):.1f}" '
            f'y2="{c+r_out*math.sin(a):.1f}" stroke="{p["bg"]}" stroke-width="{size*0.03}" stroke-linecap="butt"/>'
            f'<circle cx="{c}" cy="{c}" r="{size*0.095}" fill="{p["lamp"]}"/>')


def svg(w, h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img">'
            f'<title>{title}</title>{body}</svg>')


FINAL_RING = (24, 0.013)


def icon_final(p, size=1024):
    """The selected icon with an equal 24-tick full-circle scale."""
    return icon_ab_notch(p, size)


def write_selected_wordmarks():
    """Derive interface colors from the traced source without changing its geometry."""
    source = open(os.path.join(OUT, "wordmark-original.svg")).read()
    if "#242423" not in source or "#EC761B" not in source:
        raise ValueError("wordmark source colors missing")
    for theme, p in (("ivory", IVORY), ("graphite", GRAPHITE)):
        artwork = source.replace("#242423", p["ink"]).replace("#EC761B", p["lamp"])
        for name in ("wordmark-approved", "logo-wordmark"):
            open(os.path.join(OUT, f"{name}-{theme}.svg"), "w").write(artwork)


def final_sheet():
    W_, H_ = 1500, 620
    out = [f'<rect width="{W_}" height="{H_}" fill="#FAFAF8"/>',
           '<text x="30" y="44" font-family="PingFang SC, Helvetica" font-size="18" fill="#555">'
           '选定：图标 24 格整圈刻度 + 指针缺口 + 中心灯；字标灯座 o 带同样的缺口</text>']
    for j, p in enumerate((IVORY, GRAPHITE)):
        out.append(f'<g transform="translate({30+j*250},70) scale({220/1024})">{icon_final(p)}</g>')
    x = 540
    for s in (128, 64, 32, 16):
        for j, p in enumerate((IVORY, GRAPHITE)):
            out.append(f'<g transform="translate({x},{70+j*(s+12)}) scale({s/1024})">{icon_final(p)}</g>')
        x += s + 24
    for j, (theme, p) in enumerate((("ivory", IVORY), ("graphite", GRAPHITE))):
        # The approved SVG is the master wordmark artwork.
        artwork = open(os.path.join(OUT, f"wordmark-approved-{theme}.svg")).read()
        inner = artwork.split(">", 1)[1].rsplit("</svg>", 1)[0]
        bx = 30 + j * 730
        out.append(f'<rect x="{bx}" y="330" width="700" height="170" fill="{p["bg"]}"/>')
        out.append(f'<svg x="{bx+70}" y="356" width="560" height="118" viewBox="137 169 1903 400">{inner}</svg>')
        ts = 8 / 235
        out.append(f'<rect x="{bx}" y="515" width="700" height="32" fill="{p["bg"]}"/>')
        out.append(f'<svg x="{bx+12}" y="{515+16-203.5*ts:.2f}" width="{1903*ts:.2f}" height="{400*ts:.2f}" viewBox="137 169 1903 400">{inner}</svg>')
        out.append(f'<text x="{bx+200}" y="536" font-family="PingFang SC, Helvetica" font-size="12" fill="{p["ink2"]}">← 顶栏实际大小（x 高 8pt）</text>')
    return svg(W_, H_, "".join(out), "phosdeck logo, chosen direction")


APP_ICON = os.path.join(OUT, "..", "..", "Sources", "App", "AppIcon.icon")


def icon_artwork(p, size=1024):
    """The final icon without its tile: the system draws the tile, so the notch must be cut (masked), not painted."""
    c = size / 2
    a = math.radians(-45)
    r_in, r_out = size * 0.19, size * 0.28
    body = (ring_ticks(p, size, FINAL_RING[0], size * FINAL_RING[1]) +
            f'<mask id="notch" maskUnits="userSpaceOnUse" x="0" y="0" width="{size}" height="{size}">'
            f'<rect width="{size}" height="{size}" fill="#fff"/>'
            f'<line x1="{c+r_in*math.cos(a):.1f}" y1="{c+r_in*math.sin(a):.1f}" x2="{c+r_out*math.cos(a):.1f}" '
            f'y2="{c+r_out*math.sin(a):.1f}" stroke="#000" stroke-width="{size*0.03}"/></mask>'
            f'<circle cx="{c}" cy="{c}" r="{size*0.235}" fill="none" stroke="{p["ink"]}" stroke-width="{size*0.085}" mask="url(#notch)"/>'
            f'<circle cx="{c}" cy="{c}" r="{size*0.095}" fill="{p["lamp"]}"/>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">{body}</svg>\n'


def srgb(hex_colour):
    return "srgb:" + ",".join(f"{int(hex_colour[i:i+2], 16) / 255:.5f}" for i in (1, 3, 5)) + ",1.00000"


def write_app_icon():
    """Graphite is the primary app icon in both default and dark appearances.
    Flat layers retain the printed instrument look; tinted and clear remain system-derived."""
    os.makedirs(os.path.join(APP_ICON, "Assets"), exist_ok=True)
    icon_palette = dict(GRAPHITE, bg="#292A2A", base="#1C1D1C", lamp="#FF9B24")
    open(os.path.join(APP_ICON, "Assets", "graphite.svg"), "w").write(icon_artwork(icon_palette))
    icon = {
        "fill": {"solid": srgb(icon_palette["bg"])},
        "groups": [{
            "layers": [{"image-name": "graphite.svg", "name": "graphite", "glass": False}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "specular": False,
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": ["macOS"]},
    }
    open(os.path.join(APP_ICON, "icon.json"), "w").write(json.dumps(icon, indent=2) + "\n")
    try:
        xcodebuild = Path(subprocess.run(["xcrun", "--find", "xcodebuild"], check=True,
                                         capture_output=True, text=True).stdout.strip())
        ictool = xcodebuild.parents[3] / "Applications/Icon Composer.app/Contents/Executables/ictool"
    except (FileNotFoundError, subprocess.CalledProcessError):
        ictool = None
    if ictool is None or not ictool.is_file():
        print("ictool not found; skipped appicon previews")
        return
    for name, rendition in (("ivory", "Default"), ("graphite", "Dark")):
        subprocess.run([str(ictool), APP_ICON, "--export-image", "--output-file", os.path.join(OUT, f"appicon-{name}.png"),
                        "--platform", "macOS", "--rendition", rendition, "--width", "512", "--height", "512", "--scale", "1"],
                       check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    for theme, palette in (("ivory", IVORY), ("graphite", GRAPHITE)):
        path = os.path.join(OUT, f"logo-icon-{theme}.svg")
        open(path, "w").write(svg(1024, 1024, icon_final(palette), f"phosdeck icon ({theme})"))
    write_selected_wordmarks()
    write_app_icon()
    path = os.path.join(OUT, "final.svg")
    open(path, "w").write(final_sheet())
    subprocess.run(["rsvg-convert", "-z", "1.5", "-o", os.path.join(OUT, "final.png"), path], check=True)
    print("ok")
