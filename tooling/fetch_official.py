"""Fetch a Huawei public tool archive and verify its published SHA-256.

Downloads remain project-local and can resume after an interrupted transfer.
This does not install tools, accept account agreements, or change global PATH.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import time
import urllib.parse
import urllib.request
import urllib.error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    args = parser.parse_args()
    parsed = urllib.parse.urlparse(args.url)
    if parsed.scheme != 'https' or parsed.hostname not in {'mirrors.huaweicloud.com', 'repo.huaweicloud.com'}:
        parser.error('Use an HTTPS archive from the official Huawei public repository.')
    root = pathlib.Path(__file__).resolve().parent / 'downloads'
    root.mkdir(parents=True, exist_ok=True)
    destination = root / pathlib.PurePosixPath(parsed.path).name
    headers = {'User-Agent': 'Mozilla/5.0 HajiSaki-Toolchain-Fetch/1.0'}
    opener = urllib.request.build_opener()
    with opener.open(urllib.request.Request(args.url + '.sha256', headers=headers), timeout=45) as response:
        expected = response.read().decode().split()[0].lower()
    if len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
        raise RuntimeError('Invalid published SHA-256 metadata')
    (root / (destination.name + '.sha256')).write_text(expected + '\n', encoding='utf-8')
    last_report = 0.0
    for attempt in range(5):
        size = destination.stat().st_size if destination.exists() else 0
        request_headers = dict(headers)
        if size:
            request_headers['Range'] = f'bytes={size}-'
        try:
            with opener.open(urllib.request.Request(args.url, headers=request_headers), timeout=45) as response:
                if size and response.status == 200:
                    raise RuntimeError('Server ignored resume Range; existing file retained')
                total = int(response.headers.get('Content-Length', '0')) + size
                print(f'{destination.name}: resume {size / 1048576:.1f} / {total / 1048576:.1f} MiB', flush=True)
                with destination.open('ab') as output:
                    while chunk := response.read(1024 * 1024):
                        output.write(chunk)
                        size += len(chunk)
                        if time.monotonic() - last_report >= 20:
                            print(f'{destination.name}: {size / 1048576:.1f} MiB', flush=True)
                            last_report = time.monotonic()
                if size != total:
                    raise RuntimeError('Incomplete archive response')
            break
        except urllib.error.HTTPError as exc:
            if exc.code == 416 and size:
                break
            print(f'Attempt {attempt + 1}: HTTP {exc.code}', flush=True)
            if attempt == 4:
                raise
        except Exception as exc:
            print(f'Attempt {attempt + 1}: {type(exc).__name__}: {exc}', flush=True)
            if attempt == 4:
                raise
    with destination.open('rb') as downloaded:
        actual = hashlib.file_digest(downloaded, 'sha256').hexdigest()
    if actual != expected:
        raise RuntimeError(f'Archive SHA-256 mismatch; retained for diagnosis: {destination}')
    manifest = {'url': args.url, 'sha256': actual, 'bytes': destination.stat().st_size, 'verified': True}
    (root / (destination.name + '.json')).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(manifest), flush=True)


if __name__ == '__main__':
    main()
