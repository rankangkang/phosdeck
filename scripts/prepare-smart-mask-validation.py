#!/usr/bin/env python3
"""Fetch the pinned Stage A inputs and compile the native research runner."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request
import zipfile
import shutil


REPO = Path(__file__).resolve().parent.parent
ROOT = REPO / 'build/smart-mask-validation'
FIXTURE = REPO / 'Tests/Fixtures/smart-mask-fixture.json'


def verify(path, expected):
    data = path.read_bytes()
    if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
        raise ValueError(f'Pinned file mismatch; existing file preserved: {path}')


def fetch(url, path, expected):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        verify(path, expected)
        return
    data = urllib.request.urlopen(url, timeout=60).read(expected['bytes'] + 1)
    if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
        raise ValueError(f'Download does not match pinned hash/size: {url}')
    fd, temporary = tempfile.mkstemp(prefix='.smart-mask-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, path)  # No overwrite if another preparation published first.
        verify(path, expected)
    finally:
        os.unlink(temporary)


def run(command):
    subprocess.run([str(x) for x in command], cwd=REPO, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--face-only', action='store_true', help='Prepare only the pinned local research face model; no runtime or photographs')
    args = parser.parse_args()
    fixture = json.loads(FIXTURE.read_text())
    ROOT.mkdir(parents=True, exist_ok=True)
    for model in fixture['modelFiles']:
        if args.face_only and model.get('id') != 'mickeyvanolst/face-parsing-coreml':
            continue
        if 'revision' in model:
            for file in model['files']:
                fetch(f'https://huggingface.co/{model["id"]}/resolve/{model["revision"]}/{file["path"]}',
                      ROOT / 'models' / file['path'], file)
        else:
            fetch(model['url'], ROOT / 'models' / model['path'], model)
    if args.face_only:
        compiled = ROOT / 'models/FaceParsing.mlmodelc'
        if not compiled.exists():
            with tempfile.TemporaryDirectory(prefix='face-compile-', dir=ROOT) as temporary:
                run(['xcrun', 'coremlcompiler', 'compile', ROOT / 'models/FaceParsing.mlpackage', temporary])
                shutil.copytree(Path(temporary) / 'FaceParsing.mlmodelc', compiled)
        print(f'Prepared pinned FaceParsing for local non-commercial research in {compiled}')
        return
    for sample in fixture['samples']:
        # Image byte length is frozen with the SHA; photographs remain ignored.
        fetch(sample['url'], ROOT / 'samples' / sample['file'], sample)
    (ROOT / 'samples/manifest.json').write_text(json.dumps(fixture['samples'], indent=2))
    runtime = fixture['runtime']
    source = ROOT / 'upstream/LiteRT'
    for file in runtime['sourceFiles']:
        fetch(f'https://raw.githubusercontent.com/{runtime["repo"]}/{runtime["revision"]}/{file["path"]}',
              source / file['path'], file)
    archive = ROOT / 'upstream/CLiteRT_mac.xcframework.zip'
    fetch(runtime['archiveURL'], archive,
          {'bytes': runtime['archiveBytes'], 'sha256': runtime['archiveSHA256']})
    binary_root = ROOT / 'upstream/CLiteRT_mac.xcframework'
    if not binary_root.exists():
        with zipfile.ZipFile(archive) as package:
            if sum(x.file_size for x in package.infolist()) > 256 * 1024 * 1024:
                raise ValueError('Runtime archive exceeds extraction budget')
            for name in package.namelist():
                path = Path(name)
                if path.is_absolute() or '..' in path.parts or path.parts[0] != binary_root.name:
                    raise ValueError('Unsafe runtime archive path')
            package.extractall(binary_root.parent)
    native = binary_root / 'macos-arm64_x86_64'
    headers = native / 'Headers'
    module = ROOT / 'runtime'
    module.mkdir(exist_ok=True)
    swift_sources = [source / x['path'] for x in runtime['sourceFiles'] if x['path'].endswith('.swift')]
    run(['swiftc', '-O', '-emit-library', '-emit-module', '-module-name', 'LiteRT',
         '-I', headers, '-L', native, '-lCLiteRT_mac', '-Xlinker', '-rpath', '-Xlinker', native,
         '-o', module / 'libLiteRT.dylib', *swift_sources])
    run(['swiftc', '-O', '-I', module, '-I', headers, '-L', module, '-lLiteRT',
         '-Xlinker', '-rpath', '-Xlinker', module,
         REPO / 'scripts/smart-mask-probe.swift', '-o', ROOT / 'smart-mask-probe'])
    run([ROOT / 'smart-mask-probe', 'self-test'])
    run([ROOT / 'smart-mask-probe', 'compile', ROOT / 'models'])
    print(f'Prepared pinned models, runtime and {len(fixture["samples"])} photographs in {ROOT}')


if __name__ == '__main__':
    main()
