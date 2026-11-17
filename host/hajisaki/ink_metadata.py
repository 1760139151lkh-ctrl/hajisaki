"""Read bounded, declarative ink provenance from an exported PNG.

Metadata is client-supplied evidence, never an instruction or an authority grant.
Unknown keys and arbitrary text are not forwarded to the model.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
import re
import struct
import zlib
from xml.etree.ElementTree import ParseError

from defusedxml.common import DefusedXmlException
from defusedxml.ElementTree import fromstring


def _bounded_inflate(data: bytes) -> bytes | None:
    inflater = zlib.decompressobj()
    result = inflater.decompress(data, 65537)
    return result if len(result) <= 65536 and inflater.eof and not inflater.unused_data else None


def _declaration(value: object) -> dict | None:
    if not isinstance(value, dict) or value.get('format') != 'hajisaki-ink-v1':
        return None
    count, background = value.get('stroke_count'), value.get('background_present')
    if type(count) is not int or not 1 <= count <= 1000000 or type(background) is not bool:
        return None
    pixels, bounds, colors = value.get('image_pixels'), value.get('ink_bounds'), value.get('colors_rgba')
    if not isinstance(pixels, dict) or any(type(pixels.get(k)) is not int or not 1 <= pixels[k] <= 16384 for k in ('width', 'height')):
        return None
    if not isinstance(bounds, dict) or any(type(bounds.get(k)) not in (int, float) or not math.isfinite(bounds[k]) or not 0 <= bounds[k] <= 1 for k in ('x', 'y', 'width', 'height')):
        return None
    if bounds['x'] + bounds['width'] > 1.000001 or bounds['y'] + bounds['height'] > 1.000001:
        return None
    if not isinstance(colors, list) or len(colors) > 16 or any(not isinstance(c, str) or re.fullmatch(r'#[0-9A-Fa-f]{8}', c) is None for c in colors):
        return None
    return {'format': 'hajisaki-ink-v1', 'stroke_count': count, 'background_present': background,
            'coordinate_space': 'normalized-top-left',
            'image_pixels': {k: pixels[k] for k in ('width', 'height')},
            'ink_bounds': {k: round(bounds[k], 6) for k in ('x', 'y', 'width', 'height')},
            'colors_rgba': colors}


def read_ink_metadata(path: Path) -> dict | None:
    try:
        size = path.stat().st_size
        with path.open('rb') as stream:
            if stream.read(8) != b'\x89PNG\r\n\x1a\n':
                return None
            for _ in range(4096):
                header = stream.read(8)
                if len(header) != 8:
                    break
                length, kind = struct.unpack('>I4s', header)
                if length > size - stream.tell() - 4 or kind == b'IEND':
                    break
                if kind not in (b'tEXt', b'zTXt', b'iTXt') or length > 65536:
                    stream.seek(length + 4, 1)
                    continue
                payload, crc = stream.read(length), stream.read(4)
                if len(crc) != 4 or zlib.crc32(kind + payload) & 0xFFFFFFFF != struct.unpack('>I', crc)[0]:
                    continue
                keyword, separator, body = payload.partition(b'\0')
                if keyword not in (b'Description', b'XML:com.adobe.xmp') or not separator:
                    continue
                encoding = 'latin-1'
                if kind == b'zTXt':
                    body = _bounded_inflate(body[1:]) if body[:1] == b'\0' else None
                elif kind == b'iTXt':
                    if len(body) < 2 or body[0] not in (0, 1) or body[1] != 0:
                        continue
                    compressed, parts = body[0], body[2:].split(b'\0', 2)
                    if len(parts) != 3:
                        continue
                    body = _bounded_inflate(parts[2]) if compressed else parts[2]
                    encoding = 'utf-8'
                if body is not None:
                    if keyword == b'XML:com.adobe.xmp':
                        # ImageIO bridges PNG Description to the standard XMP
                        # dc:description property. Never enable XML entities.
                        root = fromstring(body, forbid_dtd=True, forbid_entities=True, forbid_external=True)
                        nodes = root.findall('.//{http://purl.org/dc/elements/1.1/}description/{http://www.w3.org/1999/02/22-rdf-syntax-ns#}Alt/{http://www.w3.org/1999/02/22-rdf-syntax-ns#}li')
                        texts = [node.text or '' for node in nodes if node.get('{http://www.w3.org/XML/1998/namespace}lang') in (None, 'x-default')][:16]
                    else:
                        texts = [body.decode(encoding)]
                    for text in texts:
                        try:
                            value = json.loads(text)
                        except (ValueError, UnicodeError):
                            continue
                        declaration = _declaration(value)
                        if declaration is not None:
                            return declaration
    except (OSError, ValueError, UnicodeError, zlib.error, struct.error, OverflowError, RecursionError, ParseError, DefusedXmlException):
        pass
    return None
