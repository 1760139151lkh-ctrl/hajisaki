"""Render a single PDF page in the resource-limited document worker."""
from __future__ import annotations

import base64
from io import BytesIO
import math

MAX_PIXELS = 6_000_000
# Base64 and JSON metadata must fit the existing 4MiB encrypted relay body.
MAX_IMAGE_BYTES = 3 * 1024**2 - 8192


def render_page(request: dict) -> dict:
    import pypdfium2 as pdfium

    try:
        document = pdfium.PdfDocument(request['path'])
    except pdfium.PdfiumError as error:
        if error.err_code == 4:
            return {'supported':False,'reason':'这份PDF有密码，请先保存原件阅读。'}
        return {'supported':False,'reason':'这份PDF暂时没能展开，原件仍可保存。'}
    try:
        document.init_forms()
        total = len(document)
        index = request['page']
        if not 0 <= index < total:
            return {'supported':False,'reason':'这一张纸页还没有找到。','pages':total}
        page = document[index]
        try:
            width, height = page.get_size()
            if not all(math.isfinite(value) and value > 0 for value in (width,height)):
                return {'supported':False,'reason':'这一张纸页的尺寸还不能展开，请保存原件阅读。'}
            scale = min(request['width']/width, math.sqrt(MAX_PIXELS/(width*height)))
            bitmap = page.render(scale=scale, draw_annots=True)
            try:
                image = bitmap.to_pil()
                try:
                    with BytesIO() as output:
                        image.save(output, format='PNG')
                        data = output.getvalue()
                    mime = 'image/png'
                    if len(data) > MAX_IMAGE_BYTES:
                        # Photographic pages keep their pixel dimensions and declare the real codec.
                        with image.convert('RGB') as rgb, BytesIO() as output:
                            rgb.save(output, format='JPEG', quality=90)
                            data = output.getvalue()
                        mime = 'image/jpeg'
                    if len(data) > MAX_IMAGE_BYTES:
                        return {'supported':False,'reason':'这一页的图像较大，请保存原件完整阅读。'}
                    return {'supported':True,'page':index,'pages':total,'width':image.width,'height':image.height,
                            'mime':mime,'image_base64':base64.b64encode(data).decode('ascii')}
                finally:
                    image.close()
            finally:
                bitmap.close()
        finally:
            page.close()
    finally:
        document.close()
