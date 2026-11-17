"""Trusted PDF/XLSX/ZIP exporter child; data is never executed or fetched."""
from __future__ import annotations

from html import escape
from io import BytesIO
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import sys
import unicodedata
import zipfile
import zlib

# Export data is plain JSON; native numerical libraries need no thread pool here.
for variable in ('OPENBLAS_NUM_THREADS','OMP_NUM_THREADS','MKL_NUM_THREADS','NUMEXPR_NUM_THREADS'):
    os.environ[variable] = '1'
from extract_worker import memory_limit


class ExportProblem(ValueError):
    """A known, safe explanation for the caller; library diagnostics stay local."""


class ExportArchive(zipfile.ZipFile):
    """Keep highly compressible entries within our archive inspector's ratio bound."""
    def writestr(self, zinfo_or_arcname, data, compress_type=None, compresslevel=None):
        if isinstance(data, str): data = data.encode('utf-8')
        compressed = len(zlib.compress(data, 6))
        method = zipfile.ZIP_STORED if len(data) > 100 * max(compressed, 1) else zipfile.ZIP_DEFLATED
        return super().writestr(zinfo_or_arcname, data, compress_type=method, compresslevel=6)


def _output(root: Path, name: str):
    if (not name or Path(name).name != name or any(character in name for character in '/\\:\x00')
            or root.resolve() != root):
        raise ValueError("The managed output name is invalid.")
    path = root / name
    return path.open("xb")


def _pdf(root: Path, payload: dict) -> dict:
    from markdown_it import MarkdownIt
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.lib.units import mm
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont, TTFError
    from reportlab.platypus import SimpleDocTemplate, Paragraph, LongTable, TableStyle, XPreformatted, HRFlowable, CondPageBreak

    directory = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'Fonts'
    fonts = {}
    for name, filename in [('HajiBody','msyh.ttc'),('HajiBold','msyhbd.ttc'),
                           ('HajiSymbols','seguisym.ttf'),('HajiEmoji','seguiemj.ttf')]:
        path = directory / filename
        if not path.is_file():
            if name in {'HajiBody','HajiBold'}:
                raise ExportProblem('主机还缺少可嵌入的中文字体，请先保留文字原件。')
            continue
        try:
            face = TTFont(name, str(path), subfontIndex=0)
        except TTFError:
            if name in {'HajiBody','HajiBold'}:
                raise ExportProblem('主机的中文字体暂时不能嵌入PDF，请先保留文字原件。') from None
            continue
        pdfmetrics.registerFont(face)
        fonts[name] = face
    pdfmetrics.registerFontFamily('HajiBody', normal='HajiBody', bold='HajiBold', italic='HajiBody', boldItalic='HajiBold')
    ink, muted, gold, mist = [colors.HexColor(value) for value in ('#1B233A','#64748B','#D4AF67','#F3F6FC')]
    width = A4[0] - 40 * mm
    body = ParagraphStyle('Body', fontName='HajiBody', fontSize=10.5, leading=18,
                          textColor=ink, spaceAfter=8, wordWrap='CJK', allowWidows=0, allowOrphans=0)
    styles = {
        'title': ParagraphStyle('Title', parent=body, fontName='HajiBold', fontSize=22, leading=32, spaceAfter=20),
        'h1': ParagraphStyle('H1', parent=body, fontName='HajiBold', fontSize=17, leading=26, spaceBefore=15, spaceAfter=10, keepWithNext=True),
        'h2': ParagraphStyle('H2', parent=body, fontName='HajiBold', fontSize=13.5, leading=22, spaceBefore=12, spaceAfter=7, keepWithNext=True),
        'h3': ParagraphStyle('H3', parent=body, fontName='HajiBold', fontSize=11.5, leading=20, spaceBefore=10, spaceAfter=6, keepWithNext=True),
        'code': ParagraphStyle('Code', parent=body, fontSize=8.7, leading=13, backColor=mist,
                              borderPadding=8, spaceBefore=5, spaceAfter=12),
        'cell': ParagraphStyle('Cell', parent=body, fontSize=9, leading=14, spaceAfter=0),
        'headcell': ParagraphStyle('HeadCell', parent=body, fontName='HajiBold', fontSize=9, leading=14,
                                  textColor=colors.white, spaceAfter=0),
    }

    def font_for(character: str, bold: bool = False) -> str:
        primary = 'HajiBold' if bold else 'HajiBody'
        if character in '\r\n\t' or ord(character) in fonts[primary].face.charToGlyph:
            return primary
        for name in ('HajiSymbols', 'HajiEmoji'):
            if name in fonts and ord(character) in fonts[name].face.charToGlyph:
                return name
        raise ExportProblem(f'这份报告中的U+{ord(character):04X}字符暂时缺少可嵌入字形，请先保留Markdown原件。')

    def xml(text: str, bold: bool = False) -> str:
        parts, run, current = [], '', None
        for character in text:
            selected = font_for(character, bold)
            if current is not None and selected != current:
                value = escape(run)
                parts.append(f'<font name="{current}">{value}</font>')
                run = ''
            current = selected
            run += character
        if run:
            parts.append(f'<font name="{current}">{escape(run)}</font>')
        return ''.join(parts)

    def inline(token, bold: bool = False) -> str:
        parts, strong, links = [], int(bold), []
        for child in token.children or []:
            kind = child.type
            if kind == 'strong_open': strong += 1
            elif kind == 'strong_close': strong = max(int(bold), strong - 1)
            elif kind == 'code_inline': parts.append('<font color="#406AA9">' + xml(child.content, bool(strong)) + '</font>')
            elif kind in {'softbreak','hardbreak'}: parts.append('<br/>')
            elif kind == 'link_open': links.append(child.attrGet('href') or '')
            elif kind == 'link_close':
                address = links.pop() if links else ''
                if address: parts.append(xml(' (' + address + ')'))
            elif kind == 'image': raise ExportProblem('当前PDF导出用于文字报告，图片请作为独立原件一并交付。')
            elif kind in {'text','html_inline'}: parts.append(xml(child.content, bool(strong)))
        return ''.join(parts) or xml(token.content, bold)

    def wrapped_code(text: str) -> str:
        result = []
        for line in text.replace('\t', '    ').splitlines():
            current, used = '', 0.0
            for character in line:
                measured = pdfmetrics.stringWidth(character, font_for(character), styles['code'].fontSize)
                if current and used + measured > width - 20:
                    result.append(current)
                    current, used = '', 0.0
                current += character
                used += measured
            result.append(current)
        return '\n'.join(result)

    parser = MarkdownIt('commonmark', {'html':False}).enable('table')
    tokens = parser.parse(payload['markdown'])
    # A pipe inside a code span is literal data, never an extra table column.
    lines = payload['markdown'].splitlines(keepends=True)
    for table_token in tokens:
        if table_token.type != 'table_open' or not table_token.map: continue
        for number in range(*table_token.map):
            line, result, code_width, position = lines[number], [], 0, 0
            while position < len(line):
                character = line[position]
                if character == '`':
                    end = position
                    while end < len(line) and line[end] == '`': end += 1
                    run = end - position
                    slashes = 0
                    before = position - 1
                    while before >= 0 and line[before] == '\\': slashes += 1; before -= 1
                    if code_width or slashes % 2 == 0:
                        if code_width == run: code_width = 0
                        elif not code_width: code_width = run
                    result.append(line[position:end]); position = end; continue
                if character == '|' and code_width:
                    slashes, before = 0, position - 1
                    while before >= 0 and line[before] == '\\': slashes += 1; before -= 1
                    if slashes % 2 == 0: result.append('\\')
                result.append(character); position += 1
            lines[number] = ''.join(result)
    tokens = parser.parse(''.join(lines))
    story = [Paragraph(xml(payload['title'], True), styles['title'])]
    lists, quote, pending_bullet = [], 0, ''
    index, first_heading = 0, True
    while index < len(tokens):
        token = tokens[index]
        kind = token.type
        if kind == 'heading_open':
            content = tokens[index + 1]
            level = min(3, int(token.tag[1:]))
            if not (first_heading and content.content.strip() == payload['title'].strip()):
                story.append(Paragraph(inline(content, True), styles['h' + str(level)]))
            first_heading = False
            index += 3
            continue
        if kind in {'bullet_list_open','ordered_list_open'}:
            lists.append({'ordered':kind=='ordered_list_open','index':int(token.attrGet('start') or 1)-1})
        elif kind in {'bullet_list_close','ordered_list_close'}:
            lists.pop()
        elif kind == 'list_item_open':
            lists[-1]['index'] += 1
            pending_bullet = str(lists[-1]['index']) + '. ' if lists[-1]['ordered'] else '• '
        elif kind == 'list_item_close': pending_bullet = ''
        elif kind == 'blockquote_open': quote += 1
        elif kind == 'blockquote_close': quote -= 1
        elif kind == 'paragraph_open':
            content = tokens[index + 1]
            indent = len(lists) * 12 + quote * 12
            paragraph = ParagraphStyle('Indented', parent=body, leftIndent=indent,
                firstLineIndent=-10 if pending_bullet else 0, textColor=muted if quote else ink)
            story.append(Paragraph(xml(pending_bullet) + inline(content), paragraph))
            pending_bullet = ''
            index += 3
            continue
        elif kind in {'fence','code_block'}:
            story.append(XPreformatted(xml(wrapped_code(token.content)), styles['code']))
        elif kind == 'hr': story.append(HRFlowable(width='100%', thickness=0.5, color=gold, spaceAfter=12, spaceBefore=8))
        elif kind == 'table_open':
            rows, row, head = [], [], True
            index += 1
            while index < len(tokens) and tokens[index].type != 'table_close':
                part = tokens[index]
                if part.type == 'tr_open': row = []
                elif part.type == 'inline': row.append((inline(part, head), part.content))
                elif part.type == 'tr_close': rows.append(row)
                elif part.type == 'thead_close': head = False
                index += 1
            if rows:
                count = max(map(len, rows))
                if count > 12:
                    raise ExportProblem('PDF表格最多12列，更宽的数据请交付工作簿。')
                weights = [max(5, min(25, max(len(row[column][1]) if column < len(row) else 0 for row in rows))) for column in range(count)]
                minimum = min(50, width/count)
                widths = [minimum + (width-count*minimum)*value/sum(weights) for value in weights]
                data = [[Paragraph(row[column][0] if column < len(row) else '', styles['headcell'] if number == 0 else styles['cell'])
                         for column in range(count)] for number, row in enumerate(rows)]
                row_heights = [max(cell.wrap(widths[column]-16, 100000)[1] for column,cell in enumerate(row))+14 for row in data]
                frame_height = A4[1] - 43*mm
                split_in_row = int(max(row_heights[1:] or row_heights) > frame_height-row_heights[0]-30)
                table = LongTable(data, colWidths=widths, repeatRows=1, splitByRow=1, splitInRow=split_in_row, hAlign='LEFT', spaceAfter=14)
                table.setStyle(TableStyle([
                    ('BACKGROUND',(0,0),(-1,0),ink),('LINEBELOW',(0,0),(-1,0),0.7,gold),
                    ('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,mist]),
                    ('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),8),
                    ('RIGHTPADDING',(0,0),(-1,-1),8),('TOPPADDING',(0,0),(-1,-1),7),('BOTTOMPADDING',(0,0),(-1,-1),7),
                ]))
                if story and isinstance(story[-1], Paragraph) and story[-1].getKeepWithNext():
                    heading = story.pop()
                    heading_height = heading.wrap(width, frame_height)[1] + heading.getSpaceBefore() + heading.getSpaceAfter()
                    heading.keepWithNext = False
                    story.extend([CondPageBreak(min(frame_height-20,heading_height+sum(row_heights[:2]))), heading])
                story.append(table)
        index += 1

    pages = 0
    def footer(canvas, document):
        nonlocal pages
        pages = document.page
        if pages > 100: raise ExportProblem('这份PDF超过100页，请分成几卷交付。')
        canvas.saveState()
        canvas.setStrokeColor(gold)
        canvas.setLineWidth(0.4)
        canvas.line(20*mm, 16*mm, A4[0]-20*mm, 16*mm)
        canvas.setFont('HajiBody', 8)
        canvas.setFillColor(muted)
        canvas.drawCentredString(A4[0]/2, 11*mm, str(document.page))
        canvas.restoreState()
    with _output(root, payload['name']) as output:
        document = SimpleDocTemplate(output, pagesize=A4, leftMargin=20*mm, rightMargin=20*mm,
            topMargin=20*mm, bottomMargin=23*mm, title=payload['title'], author='HajiSaki', pageCompression=1)
        document.build(story, onFirstPage=footer, onLaterPages=footer)
    return {'format':'pdf','pages':pages}


def _xlsx(root: Path, payload: dict) -> dict:
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter
    from openpyxl.writer.excel import ExcelWriter
    from openpyxl.worksheet._writer import WorksheetWriter

    class MemoryExcelWriter(ExcelWriter):
        # The bounded data-only schema has no drawings, comments, links or macros.
        # Keep worksheet XML in memory instead of creating/deleting temporary files.
        def write_worksheet(self, sheet):
            with BytesIO() as xml:
                writer = WorksheetWriter(sheet, out=xml)
                writer.write()
                sheet._rels = writer._rels
                self._archive.writestr(sheet.path[1:], xml.getvalue())
                self.manifest.append(sheet)
    workbook = Workbook()
    total = 0
    for index, specification in enumerate(payload['sheets']):
        sheet = workbook.active if index == 0 else workbook.create_sheet()
        sheet.title = specification['name']
        sheet.sheet_view.showGridLines = False
        sheet.freeze_panes = 'B2' if len(specification['columns']) > 1 else 'A2'
        sheet.append(specification['columns'])
        for values in specification['rows']:
            sheet.append(values)
        sheet.auto_filter.ref = sheet.dimensions
        sheet.print_title_rows = '1:1'
        sheet.sheet_properties.pageSetUpPr.fitToPage = True
        sheet.page_setup.fitToWidth = 1
        sheet.page_setup.fitToHeight = 0
        sheet.page_setup.paperSize = sheet.PAPERSIZE_A4
        sheet.page_setup.orientation = 'landscape' if len(specification['columns']) >= 6 else 'portrait'
        sheet.print_options.horizontalCentered = True
        widths = []
        for column in range(1, len(specification['columns']) + 1):
            values = [format(sheet.cell(row,column).value, ',') if isinstance(sheet.cell(row,column).value,int)
                      and not isinstance(sheet.cell(row,column).value,bool) else str(sheet.cell(row,column).value or '')
                      for row in range(1, sheet.max_row+1)]
            measured = max(sum(2 if unicodedata.east_asian_width(char) in {'W','F'} else 1 for char in value) for value in values)
            width = max(12,min(60,measured+3))
            widths.append(width)
            sheet.column_dimensions[get_column_letter(column)].width = width
        for row in sheet:
            lines = 1
            for cell in row:
                if isinstance(cell.value, str):
                    # Values remain literal, including leading =/+/-/@; no DDE or external formulas.
                    cell.data_type = 's'
                    wrapped = sum(max(1,math.ceil(sum(2 if unicodedata.east_asian_width(char) in {'W','F'} else 1 for char in line)
                        /max(1,widths[cell.column-1]-3))) for line in cell.value.split('\n'))
                    lines = max(lines,wrapped)
                cell.font = Font(name='Microsoft YaHei',size=11,bold=cell.row==1,color='FFFFFF' if cell.row==1 else '1B233A')
                cell.fill = PatternFill('solid',fgColor='1B233A' if cell.row==1 else 'F3F6FC' if cell.row%2 else 'FFFFFF')
                cell.alignment = Alignment(vertical='top',horizontal='right' if isinstance(cell.value,(int,float)) and not isinstance(cell.value,bool) else 'left',wrap_text=True)
                if cell.row==1: cell.border = Border(bottom=Side(style='thin',color='D4AF67'))
                elif isinstance(cell.value,int) and not isinstance(cell.value,bool): cell.number_format = '#,##0'
            if lines*17+7>409: raise ExportProblem('工作簿里有单元格过长，请拆成几行，避免文字被截断。')
            sheet.row_dimensions[row[0].row].height = max(24,lines*17+7)
        total += len(specification['rows'])
    workbook.properties.creator = 'HajiSaki'
    with _output(root, payload['name']) as output, ExportArchive(output, 'w', allowZip64=False) as archive:
        MemoryExcelWriter(workbook, archive).save()
    return {'format':'xlsx','sheets':len(payload['sheets']),'data_rows':total}


def _zip(root: Path, payload: dict) -> dict:
    with _output(root, payload['name']) as output, ExportArchive(output,'w',allowZip64=False) as archive:
        for source in payload['sources']:
            name = PurePosixPath(source['name'])
            if name.is_absolute() or len(name.parts)>2 or any(part in {'.','..'} for part in name.parts):
                raise ValueError('Invalid archive entry path.')
            data = Path(source['path']).read_bytes()
            if len(data)!=source['size'] or hashlib.sha256(data).hexdigest()!=source['sha256']:
                raise ValueError('A package original changed during export.')
            archive.writestr(source['name'], data)
    return {'format':'zip','entries':len(payload['sources'])}


def main() -> None:
    job = memory_limit(384*1024**2)
    request_path = Path(sys.argv[1]).resolve()
    request = json.loads(request_path.read_text(encoding='utf-8'))
    root = Path(request['output_root'])
    try:
        result = {'pdf':_pdf,'xlsx':_xlsx,'zip':_zip}[request['kind']](root,request['payload'])
    except ExportProblem as error:
        (request_path.parent/'result.json').write_text(json.dumps({'error':str(error)},ensure_ascii=False),encoding='utf-8')
        raise SystemExit(2) from None
    result['bytes'] = (root/request['payload']['name']).stat().st_size
    (request_path.parent/'result.json').write_text(json.dumps(result,ensure_ascii=False),encoding='utf-8')


if __name__ == '__main__': main()
