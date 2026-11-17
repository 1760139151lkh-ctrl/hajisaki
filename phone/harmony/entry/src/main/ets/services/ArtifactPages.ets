import { Artifact } from '../model/Types';
import { http } from '@kit.NetworkKit';
import { Gateway, GatewayError } from './Gateway';
import { LocalStore } from './LocalStore';

export interface DocumentResponse { supported: boolean; reason?: string }
export interface SheetCell {
  value: string | number | boolean | null;
  kind: string;
  truncated: boolean;
  bold: boolean;
  color: string | null;
  background: string | null;
  align: string | null;
  number_format: string;
}
export interface SheetPage extends DocumentResponse {
  sheet_names: string[];
  sheet: number;
  name: string;
  columns: number;
  total_columns: number;
  header: SheetCell[];
  rows: SheetCell[][];
  row_offset: number;
  data_rows: number;
  complete: boolean;
}
export interface ArchiveEntry { name: string; size: number; directory: boolean }
export interface ArchivePage extends DocumentResponse {
  entries: ArchiveEntry[];
  next_page: number;
  complete: boolean;
  total_entries: number;
  expanded_size: number;
}
export interface PdfPage extends DocumentResponse {
  page: number;
  pages: number;
  width: number;
  height: number;
  mime: string;
  image_base64: string;
  source_sha256: string;
}
export interface ReadingPlace { page: number; sheet: number; offset: number; zoom: number }
export interface ReadPage<T> { data: T; stored: boolean }

export function documentSize(size: number): string {
  return size < 1024 ? size + ' B' : size < 1024*1024 ? (size/1024).toFixed(1)+' KB' : (size/(1024*1024)).toFixed(1)+' MB';
}
export function cellText(cell: SheetCell): string {
  if (cell.value === null) return '';
  if (typeof cell.value === 'number' && Number.isInteger(cell.value) && cell.number_format === '#,##0')
    return String(cell.value).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return String(cell.value);
}

/** Immutable source digests separate cached pages, format versions and reading places. */
export class ArtifactPages {
  private gateway: Gateway;
  private local: LocalStore;
  constructor(gateway: Gateway, local: LocalStore) { this.gateway=gateway; this.local=local; }

  async read<T extends DocumentResponse>(kind: string, artifact: Artifact, key: string, path: string,
    valid: (value: T) => boolean, readTimeoutMs: number = 20000): Promise<ReadPage<T>> {
    const cacheKey = artifact.sha256 + ':' + key;
    try {
      const cached = await this.local.get(kind, cacheKey, '');
      if (cached) {
        const data = JSON.parse(cached) as T;
        if (data.supported && valid(data)) return { data:data, stored:true };
      }
    } catch (_) { /* Fetch the immutable original when an old cache cannot be read. */ }
    let data: T;
    try { data=await this.gateway.request<T>(path,http.RequestMethod.GET,undefined,readTimeoutMs); }
    catch (error) {
      if(error instanceof GatewayError && error.status===0)
        throw new Error('琴房暂时没连上。已经收下的内容仍可离线阅读。');
      throw error as Error;
    }
    if (!data || !data.supported) throw new Error(data?.reason || '这一页暂时没能展开，原件仍可保存。');
    if (!valid(data)) throw new Error('这一页还没有完整收齐，请稍后再翻一次。');
    let stored = true;
    try { await this.local.put(kind, cacheKey, JSON.stringify(data)); }
    catch (_) { stored = false; }
    return { data:data, stored:stored };
  }

  async place(artifact: Artifact, kind: string): Promise<ReadingPlace> {
    const initial: ReadingPlace = { page:0, sheet:0, offset:0, zoom:1 };
    try {
      const value = JSON.parse(await this.local.get('artifact_reading_v1',artifact.sha256+':'+kind,'')) as ReadingPlace;
      if (Number.isSafeInteger(value.page) && value.page>=0 && Number.isSafeInteger(value.sheet) && value.sheet>=0 &&
          Number.isSafeInteger(value.offset) && value.offset>=0 && Number.isFinite(value.zoom) && value.zoom>=1 && value.zoom<=3)
        return value;
    } catch (_) { /* A missing reading place starts at the first page. */ }
    return initial;
  }
  async remember(artifact: Artifact, kind: string, value: ReadingPlace): Promise<void> {
    try { await this.local.put('artifact_reading_v1',artifact.sha256+':'+kind,JSON.stringify(value)); }
    catch (_) { throw new Error('这一页已展开，暂时还不能记住阅读位置。'); }
  }
}
