import { Artifact, Message } from './Types';

export interface SelectionSource { message_id:string; conversation_id:string; text:string; source_sha256:string; status:string }
export interface ThreadRecord { id:string; parent_id:string; source_message_id:string; quote:string; title?:string; client_id?:string; created_at?:string }
export interface ThreadPage { threads:ThreadRecord[] }
export interface ArenaOrigin { arena_id:string; side:string; parent_id:string }
export interface BranchOrigin { thread:ThreadRecord | null; arena:ArenaOrigin | null }
export interface ArenaChoice { model:string; effort:string }
export interface ArenaDraft { content:string; choices:ArenaChoice[]; client_id:string; attachments:string[] }
export interface ArenaSide { side:string; conversation_id:string; run_id:string | null; status:string; cursor:number;
  question_message_id:string; question_created_at:string; messages:Message[]; model?:string; effort?:string }
export interface ArenaRecord { id:string; parent_id:string; client_id:string; content:string; created_at:string; revealed:boolean; choice:string | null }
export interface ArenaPage { arenas:ArenaRecord[] }
export interface ArenaResult { id:string; parent_id:string; client_id:string; content:string; created_at:string; revealed:boolean;
  choice:string | null; stopped_at:string | null; attachments:Artifact[]; sides:ArenaSide[] }
export interface ThreadIntent { message_id:string; quote:string; source_sha256:string; client_id:string }
