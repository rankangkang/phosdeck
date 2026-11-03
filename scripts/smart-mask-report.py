#!/usr/bin/env python3
"""Render Stage A model outputs. Requires numpy and Pillow, no ML framework."""
import argparse
import html
import json
import os
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def softmax(logits):
    values = np.exp(logits - logits.max(axis=-1, keepdims=True))
    return values / values.sum(axis=-1, keepdims=True)


def resize(values, size, nearest=False):
    return np.asarray(Image.fromarray(values.astype(np.float32)).resize(
        size, Image.Resampling.NEAREST if nearest else Image.Resampling.BILINEAR))


def paste_roi(values, roi, size, nearest=False):
    w, h = size
    x0, y0, x1, y1 = [round(a * b) for a, b in zip(roi, [w, h, w, h])]
    assert 0 <= x0 < x1 <= w and 0 <= y0 < y1 <= h
    result = np.zeros((h, w), np.float32)
    result[y0:y1, x0:x1] = resize(values, (x1 - x0, y1 - y0), nearest)
    return result


def read_tensor(path, shape):
    values = np.fromfile(path, dtype='<f4')
    if values.size != np.prod(shape) or not np.isfinite(values).all():
        raise ValueError(f'Invalid output tensor: {path}')
    return values.reshape(shape)


def overlay(original, coverage, color=(52, 215, 230)):
    rgb = np.asarray(original.convert('RGB'), dtype=np.float32)
    alpha = np.clip(coverage, 0, 1)[..., None] * .58
    return Image.fromarray(np.rint(rgb * (1 - alpha) + np.array(color) * alpha).astype(np.uint8))


def coverage_png(values, path):
    assert values.ndim == 2 and np.isfinite(values).all()
    quantized = np.rint(np.clip(values, 0, 1) * 65535).astype(np.uint16)
    Image.fromarray(quantized).save(path)
    restored = np.asarray(Image.open(path), dtype=np.uint16)
    assert np.array_equal(quantized, restored), f'16-bit PNG round trip failed: {path}'
    return path.stat().st_size


def self_test():
    a = softmax(np.array([[-1000., -1000., -1000.], [1000., 999., 998.]]))
    assert np.isfinite(a).all() and np.allclose(a.sum(-1), 1)
    asymmetric = np.array([[1., 0.], [.5, .25]])
    mapped = paste_roi(asymmetric, [.5, 0, 1, .5], (4, 4), True)
    assert np.array_equal(mapped[:2, 2:], asymmetric)
    assert not mapped[2:].any() and not mapped[:, :2].any()
    x, y = np.array([.2, .8]), np.array([.5, .1])
    assert np.allclose(np.maximum(x, y), [.5, .8])
    assert np.allclose(x * (1 - y), [.1, .72])
    assert np.allclose(x * y, [.1, .08])
    print('smart-mask-report self-test passed (softmax, ROI, add/subtract/intersect)')


PARTS = {
    'face_skin': '脸部皮肤', 'body_skin': '身体皮肤', 'skin': '组合皮肤',
    'hair': '头发', 'clothes': '衣服', 'brows': '眉毛', 'eyes': '整只眼睛',
    'lips': '嘴唇', 'face_skin_coarse': '粗分皮肤减五官',
}


def summarize(reports, measurements):
    result = {}
    for name, report in reports.items():
        entry = {key: report[key] for key in ['loadSeconds', 'processPeakBytes', 'baselinePeakBytes', 'computeUnits']}
        if name == 'sam':
            entry['encodeSecondsP50P95Max'] = np.percentile([x['encodeSeconds'] for x in report['results']], [50, 95, 100]).tolist()
            warm = [t for x in report['results'] for v in x['outputs'] for t in v['promptSeconds'][1:]]
            entry['cachedPromptSecondsP50P95Max'] = np.percentile(warm, [50, 95, 100]).tolist()
            first = report['results'][0]
            entry['firstImageModelComponentsSeconds'] = sum(report['loadSeconds']) + first['preprocessSeconds'] + first['encodeSeconds'] + first['outputs'][0]['promptSeconds'][0]
        else:
            warm = [t for x in report['results'] for t in x['inferenceSeconds'][1:]]
            entry['warmInferenceSecondsP50P95Max'] = np.percentile(warm, [50, 95, 100]).tolist()
        result[name] = entry
    keys = ['face_skin', 'body_skin', 'hair', 'clothes', 'brows', 'eyes', 'lips']
    objects = [x['object16PNGBytes'] for x in measurements]
    parts = [sum(x['part16PNGBytes'][k] for k in keys) for x in measurements if 'part16PNGBytes' in x]
    result['storage'] = {
        'objectPNGBytesP50P95Max': np.percentile(objects, [50, 95, 100]).tolist(),
        'sevenPartPNGTotalBytesP50P95Max': np.percentile(parts, [50, 95, 100]).tolist(),
        'note': '16-bit PNG payload only; excludes recipe JSON/base64/history and app integration',
    }
    return result


def generate(root):
    samples = json.loads((root / 'samples/manifest.json').read_text())
    reports = {name: json.loads((root / f'results/final-{name}/{name}-report.json').read_text())
               for name in ['sam', 'body', 'face']}
    indexed = {name: {x['id']: x for x in report['results']} for name, report in reports.items()}
    output = root / 'review'
    output.mkdir(exist_ok=True)
    cards, measurements, person_rows = [], [], []
    general_sheet = Image.new('RGB', (4 * 300, len(samples) * 220), (30, 30, 30))
    draw = ImageDraw.Draw(general_sheet)
    for row, sample in enumerate(samples):
        sid = sample['id']
        original = Image.open(root / 'samples' / sample['file']).convert('RGB')
        size = original.size
        sam = indexed['sam'][sid]
        assert size == (sam['width'], sam['height'])
        images, controls = [original], []
        selection = None
        variants = []
        for variant in sam['outputs']:
            logits = read_tensor(root / 'results/final-sam' / variant['file'], (256, 256))
            # SAM's native binary decision is logit > 0, after interpolation.
            full = resize(logits, size)
            binary = (full > 0).astype(np.float32)
            images.append(overlay(original, binary))
            name = variant['variant']
            markers = ImageDraw.Draw(images[-1])
            for x, y, label in variant['points']:
                if label in (0, 1):
                    px, py = x * size[0], y * size[1]
                    radius = max(3, min(size) / 130)
                    markers.ellipse((px-radius, py-radius, px+radius, py+radius),
                                    outline='lime' if label == 1 else 'red', width=2)
            images[-1].save(output / f'{sid}-{name}.jpg', quality=90)
            variants.append({'name': name, 'coverageFraction': float(binary.mean()),
                             'scores': variant['scores']})
            if name == 'refined':
                selection = binary
                # Save a separate sigmoid coverage for storage measurement; it is not calibrated confidence.
                soft = 1 / (1 + np.exp(-np.clip(full, -30, 30)))
                object_bytes = coverage_png(soft, output / f'{sid}-object-16.png')
        assert selection is not None
        candidate_html = ''
        candidates = []
        for candidate in range(3):
            path = root / 'results/final-sam' / f'{sid}-candidate-{candidate}.f32'
            if not path.exists():
                continue
            values = read_tensor(path, (256, 256))
            candidate_mask = (resize(values, size) > 0).astype(np.float32)
            overlay(original, candidate_mask).save(output / f'{sid}-candidate-{candidate}.jpg', quality=90)
            candidates.append(f'<figure><img src="{sid}-candidate-{candidate}.jpg"><figcaption>候选 {candidate+1} · 模型分数 {sam["outputs"][-1]["scores"][candidate]:.3f}</figcaption></figure>')
        if candidates:
            candidate_html = '<details><summary>SAM 的三个候选（默认取模型分数最高者）</summary><div class="variants">' + ''.join(candidates) + '</div></details>'
        for col, picture in enumerate(images):
            thumbnail = picture.copy()
            thumbnail.thumbnail((296, 190))
            general_sheet.paste(thumbnail, (col * 300 + (300 - thumbnail.width) // 2, row * 220))
            caption = f'{sid} {sample["category"]}' if col == 0 else ['point', 'box', 'refined'][col-1]
            draw.text((col * 300 + 3, row * 220 + 193), caption, fill='white')
        record = {'id': sid, 'variants': variants, 'object16PNGBytes': object_bytes}
        if sample['category'] == 'Person':
            body = indexed['body'][sid]
            face = indexed['face'][sid]
            logits = read_tensor(root / 'results/final-body' / body['file'], (256, 256, 6))
            probabilities = softmax(logits)
            assert np.allclose(probabilities.sum(-1), 1, atol=1e-6)
            body_masks = [paste_roi(probabilities[..., c], body['roi'], size) * selection for c in range(6)]
            labels = np.fromfile(root / 'results/final-face' / face['file'], dtype=np.uint8)
            assert labels.size == 512 * 512 and labels.max() <= 18
            labels = labels.reshape(512, 512)

            def face_mask(classes):
                return paste_roi(np.isin(labels, classes).astype(np.float32), face['roi'], size, True) * selection

            features = face_mask([2, 3, 4, 5, 6, 11, 12, 13])
            facial_domain = face_mask(list(range(1, 14)))
            face_rectangle = paste_roi(np.ones((1, 1)), face['roi'], size, True)
            coarse_skin = body_masks[3] * (1 - features)
            # Fine labels replace coarse face skin inside the face ROI; preserve outside coarse coverage.
            fine_skin = np.maximum(coarse_skin * (1 - face_rectangle), face_mask([1, 10]))
            parts = {'face_skin': fine_skin, 'body_skin': body_masks[2] * (1 - facial_domain),
                     'hair': body_masks[1], 'clothes': body_masks[4],
                     'brows': face_mask([2, 3]), 'eyes': face_mask([4, 5]),
                     'lips': face_mask([12, 13]), 'face_skin_coarse': coarse_skin}
            parts['skin'] = np.maximum(parts['face_skin'], parts['body_skin'])
            assert not np.any(parts['skin'] * features), 'Skin overlaps recognized brows/eyes/lips'
            sizes, areas = {}, {}
            panel = [original, overlay(original, selection)]
            for key in PARTS:
                values = parts[key]
                assert np.max(values * (1 - selection)) == 0, 'Part escaped selected instance'
                sizes[key] = coverage_png(values, output / f'{sid}-{key}-16.png')
                areas[key] = float((values > .5).mean())
                rgba = np.zeros((size[1], size[0], 4), np.uint8)
                rgba[..., :3] = [52, 215, 230]
                rgba[..., 3] = np.rint(np.clip(values, 0, 1) * 190).astype(np.uint8)
                Image.fromarray(rgba).save(output / f'{sid}-{key}.png')
                controls.append(f'<label><input type="checkbox" data-layer="{sid}-{key}"> {PARTS[key]}</label>')
            panel += [overlay(original, parts[k]) for k in ['skin', 'hair', 'clothes', 'brows', 'eyes', 'lips']]
            person_rows.append((sid, panel))
            record.update({'part16PNGBytes': sizes, 'partCoverageFraction': areas,
                           'skinStrategiesMeanAbsoluteDifference': float(np.abs(fine_skin - coarse_skin).mean())})
        author = sample['source']['Author']
        source = sample['source']['OriginalLandingURL']
        credit = f'{html.escape(author)} · <a href="{html.escape(source, quote=True)}">照片来源</a> · <a href="https://creativecommons.org/licenses/by/2.0/">CC BY 2.0</a>；本页缩放并叠加模型结果'
        layers = ''.join(f'<img class="layer" id="{sid}-{key}" src="{sid}-{key}.png" hidden>' for key in PARTS) if controls else ''
        cards.append(f'<article><h2>{sid} · {html.escape(sample["category"])}</h2>'
                     f'<p class="credit">{credit}</p><div class="variants">'
                     + ''.join(f'<figure><img src="{sid}-{name}.jpg"><figcaption>{title}</figcaption></figure>'
                               for name, title in [('point', '首次中心点'), ('box', '固定标注框'), ('refined', '框＋添加点＋排除点（绿／红）')])
                     + '</div>' + candidate_html + (f'<div class="controls">{"".join(controls)}</div><div class="stack">'
                        f'<img src="../samples/{sample["file"]}">{layers}</div>' if controls else '') + '</article>')
        measurements.append(record)
    general_sheet.save(output / 'objects-contact.jpg', quality=90)
    people_sheet = Image.new('RGB', (8 * 240, len(person_rows) * 230), (30, 30, 30))
    d = ImageDraw.Draw(people_sheet)
    for row, (sid, pictures) in enumerate(person_rows):
        for col, picture in enumerate(pictures):
            thumb = picture.copy(); thumb.thumbnail((236, 195))
            people_sheet.paste(thumb, (col * 240 + (240-thumb.width)//2, row * 230))
            d.text((col*240+3, row*230+198), ['original', 'object', 'skin', 'hair', 'clothes', 'brows', 'eyes', 'lips'][col], fill='white')
            if col == 0: d.text((3, row*230+213), sid, fill='white')
    people_sheet.save(output / 'people-contact.jpg', quality=92)
    (output / 'measurements.json').write_text(json.dumps(measurements, indent=2))
    (output / 'statistics.json').write_text(json.dumps(summarize(reports, measurements), indent=2))
    document = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>轻量智能蒙版 · 阶段 A</title>
<style>body{background:#222;color:#eee;font:15px system-ui;margin:24px}a{color:#8cdee6}h1{font-size:24px}h2{font-size:18px}article{border-top:1px solid #555;padding:18px 0}.credit{color:#ccc;font-size:13px}.variants{display:flex;gap:12px}figure{margin:0;flex:1}figure img{width:100%;max-height:420px;object-fit:contain}figcaption{text-align:center}.controls{display:flex;flex-wrap:wrap;gap:12px;margin:12px 0}.stack{position:relative;display:inline-block;max-width:100%}.stack>img:first-child{display:block;max-width:100%;max-height:700px}.layer{position:absolute;inset:0;width:100%;height:100%}label{cursor:pointer}</style>
<h1>轻量智能蒙版 · 阶段 A 组合实测</h1>
<p>20 张公开照片。SAM 2.1 Tiny / SelfieMulticlass 256 / BiSeNet CPU。以下是研究输出，尚未进入 App。</p>
<p>点击人物部位复选框可叠加查看；“组合皮肤”使用 max 合并脸部与身体皮肤。多人照片只分析固定框中的目标。人脸 ROI 来自公开标注，相当于手动脸框，本轮未验证自动人脸定位。</p>
<p>首次点与框由固定标注推导；两张自行车与水中人物在预览后补充了固定的人工正／负点，其余仍使用几何点。所有点均保留在 fixture，不能据此推定真人操作三次一定能修好。没有像素真值，模型自评分不是准确率。遮挡、发丝和相邻对象归属请逐张审阅。</p>'''
    document += ''.join(cards) + '''<script>document.querySelectorAll('input[data-layer]').forEach(x=>x.addEventListener('change',()=>document.getElementById(x.dataset.layer).hidden=!x.checked));</script></html>'''
    (output / 'index.html').write_text(document)
    print(f'Review: {os.path.relpath(output / "index.html")}; all 16-bit mask round trips verified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', type=Path,
                        default=Path(__file__).resolve().parent.parent / 'build/smart-mask-validation')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        generate(args.root)
