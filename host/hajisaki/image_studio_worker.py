"""Resource-limited compositor for native photo editing and scratchpads."""
from __future__ import annotations

import base64
from io import BytesIO
import json
import math
import os
from pathlib import Path
import sys
import warnings

for variable in ('OPENBLAS_NUM_THREADS', 'OMP_NUM_THREADS', 'MKL_NUM_THREADS', 'NUMEXPR_NUM_THREADS'):
    os.environ[variable] = '1'
from extract_worker import memory_limit


MAX_PIXELS = 6_000_000
MAX_PREVIEW_BYTES = 3*1024**2 - 8192


def thumbnail(image, width, animated):
    from PIL import Image
    from thash import encode, thumb_hash_to_rgba

    image.thumbnail((width, width), Image.Resampling.LANCZOS)
    signature = encode(image, target_size=32, backend='pure')
    pw, ph, pixels = thumb_hash_to_rgba(signature, base_size=32)
    with Image.frombytes('RGBA', (pw, ph), pixels) as placeholder, BytesIO() as stream:
        placeholder.save(stream, format='PNG')
        placeholder_data = base64.b64encode(stream.getvalue()).decode('ascii')
    budget = 128*1024 if width <= 480 else 320*1024
    while True:
        with BytesIO() as stream:
            image.save(stream, format='PNG')
            data, mime = stream.getvalue(), 'image/png'
        if len(data) <= budget:
            break
        for quality in (88, 70):
            with BytesIO() as stream:
                if image.mode == 'RGBA':
                    image.save(stream, format='WEBP', quality=quality, method=4)
                    mime = 'image/webp'
                else:
                    image.save(stream, format='JPEG', quality=quality, optimize=True)
                    mime = 'image/jpeg'
                data = stream.getvalue()
            if len(data) <= budget:
                break
        if len(data) <= budget:
            break
        if max(image.size) <= 160:
            return {'supported':False,'reason':'这张缩略图暂时没有完整收齐，原件仍在。'}
        image.thumbnail((max(160,image.width//2), max(160,image.height//2)), Image.Resampling.LANCZOS)
    return {'supported':True,'width':image.width,'height':image.height,'mime':mime,
            'image_base64':base64.b64encode(data).decode('ascii'),
            'thumbhash':base64.b64encode(bytes(signature)).decode('ascii'),
            'placeholder_base64':placeholder_data,'animated':animated}


def fit_size(width, height, pixels=MAX_PIXELS):
    scale = min(1, math.sqrt(pixels/(width*height)), 4096/max(width, height))
    return max(1, round(width*scale)), max(1, round(height*scale))


def perspective_coefficients(source, width, height):
    """Map output pixels to source pixels using a projective homography."""
    rows = []
    for (x, y), (u, v) in zip([(0, 0), (width, 0), (width, height), (0, height)], source):
        rows.append([x, y, 1, 0, 0, 0, -u*x, -u*y, u])
        rows.append([0, 0, 0, x, y, 1, -v*x, -v*y, v])
    for column in range(8):
        pivot = max(range(column, 8), key=lambda row: abs(rows[row][column]))
        if abs(rows[pivot][column]) < 1e-10:
            raise ValueError('Invalid page corners')
        rows[column], rows[pivot] = rows[pivot], rows[column]
        divisor = rows[column][column]
        rows[column] = [value/divisor for value in rows[column]]
        for row in range(8):
            if row != column:
                multiplier = rows[row][column]
                rows[row] = [a-multiplier*b for a, b in zip(rows[row], rows[column])]
    return tuple(row[8] for row in rows)


def render(request):
    from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageOps, PngImagePlugin

    Image.MAX_IMAGE_PIXELS = 64_000_000
    warnings.simplefilter('error', Image.DecompressionBombWarning)
    thumb_width = request.get('thumbnail_width', 0)
    animated = False
    if request.get('path'):
        with Image.open(request['path'], formats=['PNG', 'JPEG', 'WEBP', *(['GIF'] if thumb_width else [])]) as original:
            if original.width*original.height > 64_000_000:
                raise ValueError('Image dimensions exceed the decode budget')
            original.draft('RGB', (thumb_width, thumb_width) if thumb_width else (2200, 2200))
            if original.width*original.height > 24_000_000:
                return {'supported': False, 'reason': '这张原图像素较多，请先缩小尺寸再展开。'}
            with ImageOps.exif_transpose(original) as oriented:
                animated = bool(getattr(original, 'is_animated', False))
                oriented.thumbnail((thumb_width,thumb_width) if thumb_width else fit_size(oriented.width, oriented.height), Image.Resampling.LANCZOS)
                image = oriented.convert('RGBA' if 'A' in oriented.getbands() or 'transparency' in oriented.info else 'RGB')
    else:
        image = Image.new('RGB', (1280, 1600), '#F6F7FB')
    if thumb_width:
        try:
            return thumbnail(image, thumb_width, animated)
        finally:
            image.close()
    mask = Image.new('L', image.size, 0)
    count = 0
    colors = []
    try:
        for operation in request['operations']:
            kind = operation['kind']
            width, height = image.size
            points = [(point['x']*width, point['y']*height) for point in operation['points']]
            if kind in {'pen', 'number', 'mosaic'}:
                count += 1
                rgba = tuple(int(operation['color'][i:i+2], 16) for i in (1, 3, 5, 7))
                if operation['color'] not in colors and len(colors) < 16:
                    colors.append(operation['color'])
                ink = rgba if image.mode == 'RGBA' else rgba[:3]
                draw = ImageDraw.Draw(image)
                marks = ImageDraw.Draw(mask)
                thickness = max(1, round(operation['width']*min(width, height)))
                if kind == 'pen':
                    radius = thickness/2
                    draw.line(points, fill=ink, width=thickness, joint='curve')
                    marks.line(points, fill=255, width=thickness, joint='curve')
                    for x, y in (points[0], points[-1]):
                        box = (x-radius, y-radius, x+radius, y+radius)
                        draw.ellipse(box, fill=ink); marks.ellipse(box, fill=255)
                elif kind == 'number':
                    x, y = points[0]
                    radius = max(12, round(min(width, height)*0.032))
                    box = (x-radius, y-radius, x+radius, y+radius)
                    draw.ellipse(box, fill=ink); marks.ellipse(box, fill=255)
                    font_path = Path(os.environ.get('WINDIR', 'C:/Windows'))/'Fonts'/'arialbd.ttf'
                    font = ImageFont.truetype(str(font_path), round(radius*1.1)) if font_path.is_file() else ImageFont.load_default(round(radius*1.1))
                    draw.text((x, y), str(operation['number']), font=font, fill='white', anchor='mm')
                else:
                    left, right = sorted((round(points[0][0]), round(points[1][0])))
                    top, bottom = sorted((round(points[0][1]), round(points[1][1])))
                    left, top = max(0, min(left, width-1)), max(0, min(top, height-1))
                    right, bottom = max(left+1, min(right, width)), max(top+1, min(bottom, height))
                    with image.crop((left, top, right, bottom)) as region:
                        cells = (max(1, math.ceil((right-left)/max(8, min(width, height)*0.035))),
                                 max(1, math.ceil((bottom-top)/max(8, min(width, height)*0.035))))
                        with region.resize(cells, Image.Resampling.NEAREST) as small:
                            with small.resize(region.size, Image.Resampling.NEAREST) as mosaic:
                                image.paste(mosaic, (left, top))
                    marks.rectangle((left, top, right, bottom), fill=255)
            elif kind == 'rotate':
                rotated = image.transpose(Image.Transpose.ROTATE_270)
                rotated_mask = mask.transpose(Image.Transpose.ROTATE_270)
                image.close(); mask.close(); image, mask = rotated, rotated_mask
            elif kind == 'perspective':
                output_width = (math.dist(points[0], points[1])+math.dist(points[3], points[2]))/2
                output_height = (math.dist(points[0], points[3])+math.dist(points[1], points[2]))/2
                if min(output_width, output_height) < 32:
                    return {'supported': False, 'reason': '这四个角靠得太近了，请重新框住纸张。'}
                size = fit_size(output_width, output_height)
                coefficients = perspective_coefficients(points, *size)
                transformed = image.transform(size, Image.Transform.PERSPECTIVE, coefficients, Image.Resampling.BICUBIC)
                transformed_mask = mask.transform(size, Image.Transform.PERSPECTIVE, coefficients, Image.Resampling.NEAREST)
                image.close(); mask.close(); image, mask = transformed, transformed_mask
            elif kind == 'paper':
                with ImageOps.grayscale(image) as gray, ImageOps.autocontrast(gray, cutoff=1) as balanced:
                    with ImageEnhance.Contrast(balanced).enhance(1.4) as contrast:
                        with ImageEnhance.Brightness(contrast).enhance(1.08) as bright:
                            enhanced = bright.convert('RGB')
                if image.mode == 'RGBA':
                    with image.getchannel('A') as alpha:
                        enhanced.putalpha(alpha)
                image.close(); image = enhanced
        if request.get('output'):
            info = PngImagePlugin.PngInfo()
            info.add_text('HajiSakiEdit', json.dumps({'format': 'hajisaki-image-edit-v1',
                'source_sha256': request.get('source_sha256', ''), 'operation_count': len(request['operations'])}, separators=(',', ':')))
            bounds = mask.getbbox()
            if bounds and count:
                left, top, right, bottom = bounds
                declaration = {'format': 'hajisaki-ink-v1', 'stroke_count': count,
                    'background_present': bool(request.get('path')),
                    'image_pixels': {'width': image.width, 'height': image.height},
                    'ink_bounds': {'x': left/image.width, 'y': top/image.height,
                        'width': (right-left)/image.width, 'height': (bottom-top)/image.height},
                    'colors_rgba': colors}
                info.add_text('Description', json.dumps(declaration, separators=(',', ':')))
            with Path(request['output']).open('xb') as stream:
                image.save(stream, format='PNG', pnginfo=info)
                stream.flush(); os.fsync(stream.fileno())
            return {'supported': True, 'width': image.width, 'height': image.height}
        image.thumbnail((1280, 1600), Image.Resampling.LANCZOS)
        with BytesIO() as stream:
            image.save(stream, format='PNG')
            content, mime = stream.getvalue(), 'image/png'
        if len(content) > MAX_PREVIEW_BYTES:
            with BytesIO() as stream:
                if image.mode == 'RGBA':
                    with Image.new('RGB', image.size, '#F6F7FB') as matte, image.getchannel('A') as alpha:
                        matte.paste(image, mask=alpha)
                        matte.save(stream, format='JPEG', quality=90)
                else:
                    image.save(stream, format='JPEG', quality=90)
                content, mime = stream.getvalue(), 'image/jpeg'
        if len(content) > MAX_PREVIEW_BYTES:
            return {'supported': False, 'reason': '这张画页还没能完整展开，请保留原稿。'}
        return {'supported': True, 'width': image.width, 'height': image.height,
                'mime': mime, 'image_base64': base64.b64encode(content).decode('ascii')}
    finally:
        image.close(); mask.close()


if __name__ == '__main__':
    job = memory_limit(512*1024**2)
    try:
        result = render(json.loads(sys.stdin.buffer.read(2*1024**2+1)))
    except (ValueError, OSError, MemoryError, OverflowError, SyntaxError, Warning):
        result = {'supported': False, 'reason': '这张图片暂时不能安全展开，原件与画稿都还在。'}
    sys.stdout.buffer.write(json.dumps(result, ensure_ascii=False).encode('utf-8'))
