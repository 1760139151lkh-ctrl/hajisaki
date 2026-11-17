export interface StudioPoint { x: number; y: number }
export interface StudioOperation {
  kind: string;
  points: StudioPoint[];
  color: string;
  width: number;
  number: number;
}
export interface StudioStep { key: string; operation: StudioOperation }
export interface StudioDraft { version: number; steps: StudioStep[]; cursor: number; exportId: string }
export interface StudioPreview { supported: boolean; width: number; height: number; mime: string; image_base64: string }
export interface StudioRequest { source_id: string; operations: StudioOperation[] }
export interface StudioExport extends StudioRequest { operation_id: string }

export function studioTransform(kind: string): boolean {
  return kind === 'rotate' || kind === 'perspective' || kind === 'paper';
}
export function studioCheckpoint(kind: string): boolean { return kind === 'mosaic' || studioTransform(kind); }
export function studioPreviewValid(value: StudioPreview): boolean {
  return value.supported === true && Number.isSafeInteger(value.width) && value.width > 0 && value.width <= 4096 &&
    Number.isSafeInteger(value.height) && value.height > 0 && value.height <= 4096 &&
    (value.mime === 'image/png' || value.mime === 'image/jpeg') && typeof value.image_base64 === 'string' &&
    value.image_base64.length > 0 && value.image_base64.length <= 4*1024*1024 && /^[A-Za-z0-9+/]+={0,2}$/.test(value.image_base64);
}

/** Validate restored edits before passing them to the canvas or gateway. */
export function studioDraftValid(value: StudioDraft): boolean {
  if (value.version !== 1 || !Array.isArray(value.steps) || value.steps.length > 400 ||
      !Number.isSafeInteger(value.cursor) || value.cursor < 0 || value.cursor > value.steps.length ||
      typeof value.exportId !== 'string' || value.exportId.length > 100) return false;
  let points = 0;
  let transforms = 0;
  for (const step of value.steps) {
    if (!step || typeof step.key !== 'string' || !/^[A-Za-z0-9_-]{1,100}$/.test(step.key)) return false;
    const op = step.operation;
    if (!op || !['pen','number','mosaic','rotate','perspective','paper'].includes(op.kind) ||
        !Array.isArray(op.points) || op.points.length > 2048 || !/^#[0-9a-fA-F]{6}[fF]{2}$/.test(op.color) ||
        !Number.isFinite(op.width) || op.width < 0.001 || op.width > 0.08 ||
        !Number.isInteger(op.number) || op.number < 1 || op.number > 999) return false;
    if ((op.kind === 'pen' && op.points.length < 1) || (op.kind === 'number' && op.points.length !== 1) ||
        (op.kind === 'mosaic' && op.points.length !== 2) || (op.kind === 'perspective' && op.points.length !== 4) ||
        (studioTransform(op.kind) && op.kind !== 'perspective' && op.points.length !== 0)) return false;
    points += op.points.length;
    if (studioTransform(op.kind)) transforms++;
    for (const p of op.points) if (!p || !Number.isFinite(p.x) || !Number.isFinite(p.y) || p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return false;
  }
  return points <= 32000 && transforms <= 12;
}
