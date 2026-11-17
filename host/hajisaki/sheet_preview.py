"""Read one bounded worksheet window; values and formulas are never evaluated."""
from __future__ import annotations

from datetime import date, datetime, time
from pathlib import Path
import math
import re


def read_sheet(request: dict) -> dict:
    from openpyxl import load_workbook
    # CAS originals are named by digest and have no file extension.
    source = Path(request['path']).open('rb')
    try:
        workbook = load_workbook(source, read_only=True, data_only=False, keep_links=False)
    except BaseException:
        source.close()
        raise
    try:
        names = workbook.sheetnames
        index = request['page']
        if index >= len(names):
            return {'supported':False,'reason':'这一页工作表还没有找到。'}
        sheet = workbook[names[index]]
        if sheet.max_row is None or sheet.max_column is None:
            sheet.calculate_dimension(force=True)
        total = max(0,(sheet.max_row or 1)-1)
        columns = min(64,sheet.max_column or 1)
        offset, limit = request['offset'], request['limit']

        def color(value):
            rgb = getattr(value,'rgb',None) if getattr(value,'type',None)=='rgb' else None
            return '#' + rgb[-6:] if isinstance(rgb,str) and re.fullmatch(r'[0-9a-fA-F]{6,8}',rgb) else None

        def cell_value(cell):
            value = cell.value
            truncated = isinstance(value,str) and len(value)>2000
            if truncated: value=value[:2000]
            if isinstance(value,(date,datetime,time)): value=value.isoformat()
            elif isinstance(value,float) and not math.isfinite(value): value=str(value)
            elif value is not None and not isinstance(value,(str,int,float,bool)): value=str(value)[:2000]
            fill, font = getattr(cell,'fill',None),getattr(cell,'font',None)
            return {'value':value,'kind':getattr(cell,'data_type','n'),'truncated':truncated,
                    'bold':bool(getattr(font,'bold',False)), 'color':color(getattr(font,'color',None)),
                    'background':color(getattr(fill,'fgColor',None)) if getattr(fill,'fill_type',None)=='solid' else None,
                    'align':getattr(getattr(cell,'alignment',None),'horizontal',None),
                    'number_format':str(getattr(cell,'number_format','General'))[:128]}

        header = next(sheet.iter_rows(min_row=1,max_row=1,min_col=1,max_col=columns),())
        rows = []
        if offset < total:
            for row in sheet.iter_rows(min_row=offset+2,max_row=min(sheet.max_row,offset+limit+1),min_col=1,max_col=columns):
                rows.append([cell_value(cell) for cell in row])
        return {'supported':True,'sheet_names':names,'sheet':index,'name':sheet.title,
                'columns':columns,'total_columns':sheet.max_column,'header':[cell_value(cell) for cell in header],
                'rows':rows,'row_offset':offset,'data_rows':total,'complete':offset+len(rows)>=total,
                'freeze':str(sheet.freeze_panes) if hasattr(sheet,'freeze_panes') and sheet.freeze_panes else None}
    finally:
        try: workbook.close()
        finally: source.close()
