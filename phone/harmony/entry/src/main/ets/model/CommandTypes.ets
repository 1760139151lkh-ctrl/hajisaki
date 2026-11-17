import { Artifact } from './Types';

export interface ComposerTemplate { id:string; title:string; description:string; text:string }
export interface ToneOption { id:string; title:string; description:string }
export interface ComposerCatalog { templates:ComposerTemplate[]; tones:ToneOption[] }
export interface CompactionRecord {
  id:string;
  run_id:string;
  operation_id:string;
  summary:string;
  created_at:string;
  activated_at:string | null;
  status:string;
  failure?:string | null;
  assistant_message_id:string;
  archive?:Artifact | null;
  method?:string;
  tokens_before?:number | null;
  tokens_after?:number | null;
  verification_run_id?:string | null;
  generation_status?:string;
}
export interface ComposerState {
  tone_id:string;
  active_compaction:CompactionRecord | null;
  latest_compaction:CompactionRecord | null;
  busy:boolean;
  has_history:boolean;
}
