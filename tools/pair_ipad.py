"""Issue one private iPad pairing through the existing local owner API."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'host'))
from hajisaki.config import protect_credentials, secure_data_directory


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=ROOT / 'runtime')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--name', default='HajiSaki iPad Air 11')
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('A local gateway port is required.')
    data = secure_data_directory(args.data_dir.resolve())
    target = data / 'ipad-pairing.json'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    base = f'http://127.0.0.1:{args.port}'
    if target.exists():
        pairing = json.loads(target.read_text(encoding='utf-8'))
    else:
        owner = json.loads((data / 'pairing.json').read_text(encoding='utf-8'))
        request = urllib.request.Request(base + '/api/devices',
            data=json.dumps({'name': args.name, 'role': 'companion'}).encode('utf-8'),
            headers={'Authorization': 'Bearer ' + owner['token'], 'X-Haji-Device': owner['device'],
                     'Content-Type': 'application/json'})
        with opener.open(request, timeout=20) as response:
            pairing = json.load(response)
        with target.open('x', encoding='utf-8') as output:
            json.dump(pairing, output, ensure_ascii=False, indent=2)
        protect_credentials(target)
    # Validate the actual issued credential without printing or copying it to logs.
    request = urllib.request.Request(base + '/api/status',
        headers={'Authorization': 'Bearer ' + pairing['token'], 'X-Haji-Device': pairing['device']})
    with opener.open(request, timeout=20) as response:
        status = json.load(response)
    print(json.dumps({'private_pairing_file': str(target), 'gateway_port': args.port,
                      'device_name': pairing.get('name'), 'provider': status['provider']['name'],
                      'credential_accepted': True}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
