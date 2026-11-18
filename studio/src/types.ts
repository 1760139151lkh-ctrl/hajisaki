export interface Conversation {
  id: string;
  title: string;
  group: string;
  pinned: boolean;
  archived: boolean;
  updated_at: string;
  created_at?: string;
  preview?: string;
  /** Who wrote the latest words in this letter, and whether she is writing right now. */
  preview_role?: string | null;
  writing?: boolean;
}
export interface Artifact {
  id: string;
  name: string;
  size: number;
  mime: string;
  sha256: string;
  url: string;
}
export interface Message {
  id: string;
  conversation_id: string;
  role: string;
  content: string;
  status: string;
  created_at: string;
  attachments: (Artifact | string)[];
  provider_diagnostics_available?: boolean;
}
export interface StreamEvent {
  seq: number;
  conversation_id: string;
  run_id: string;
  layer: string;
  kind: string;
  payload: Record<string, unknown>;
  created_at: string;
}
export interface Memory {
  id: string;
  content: string;
  created_at: string;
  updated_at: string;
}
export interface Settings {
  theme: string;
  transparency: string;
  personality: { formality: number; detail: number; teasing: number };
  sound: boolean;
  /** What she calls you when she is being sweet; empty means just “你”. */
  nickname?: string;
}
export interface Model {
  id: string;
  name: string;
  efforts: string[];
}
export interface HostStatus {
  provider: {
    name: string;
    available: boolean;
    authenticated: boolean;
    detail?: string;
  };
  host: Record<string, unknown>;
  capabilities: Record<string, unknown>;
}
