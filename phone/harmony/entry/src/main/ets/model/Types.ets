export interface Conversation {
  id: string;
  title: string;
  group: string;
  pinned: boolean;
  archived: boolean;
  updated_at: string;
  preview: string;
  branch_parent_id?:string;
  branch_kind?:string;
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
  attachments: Artifact[];
}
export interface ModelOption { id: string; name: string; efforts: string[] }
export interface Memory { id: string; content: string; created_at: string; updated_at: string }
export interface Personality { formality: number; detail: number; teasing: number }
export interface Settings { theme: string; transparency: string; personality: Personality; sound: boolean }
export interface ProviderStatus { name: string; available: boolean; authenticated: boolean | null; simulated?: boolean; detail: string }
export interface HostStatus { uptime_seconds?: number; memory_mb?: number; proxy?: string }
export interface Status { provider: ProviderStatus; host: HostStatus; capabilities: Record<string, boolean | number | string> }
export interface EventPayload {
  message_id?: string;
  assistant_message_id?: string;
  message?: string;
  text?: string;
  summary?: string;
  name?: string;
  status?: string;
  detail?: string;
  artifact?: Artifact;
  page?: number;
  source_sha256?: string;
  width?: number;
  height?: number;
  animated?: boolean;
}
export interface StreamEvent {
  seq: number;
  conversation_id: string;
  run_id: string;
  layer: string;
  kind: string;
  payload: EventPayload;
  created_at: string;
}
export interface EventPage { events: StreamEvent[]; cursor: number; has_more?: boolean }
export interface ConversationPage { conversations: Conversation[] }
export interface ActiveRun { id: string; status: string; assistant_message_id: string }
export interface MessagePage { messages: Message[]; active_run?: ActiveRun | null; cursor: number }
export interface MemoryPage { memories: Memory[] }
export interface TaskItem { index:number; text:string; initial_checked:boolean }
export interface TaskPage { tasks:Record<string,boolean>; items:TaskItem[]; editable:boolean }
export interface MessageTasks { message_id:string; page:TaskPage }
export interface PinSource { name?:string; content?:string }
export interface ContextPin { id:string; conversation_id:string; kind:string; target_id?:string; content:string; source?:PinSource }
export interface PinPage { pins:ContextPin[] }
export interface ArtifactPage { artifacts: Artifact[] }
export interface ModelPage { models: ModelOption[] }
export interface SendResult { message: Message; run_id: string }
export interface UploadSession { id: string; offset: number; complete: boolean; artifact?: Artifact }
export interface PendingMessage {
  client_id: string;
  conversation_id: string;
  content: string;
  model: string;
  effort: string;
  attachments: Artifact[];
  created_at: string;
  last_error?:string;
  tone_id?:string;
}
export interface Connection { primary: string; fallback: string; device: string }

export function defaultSettings(): Settings {
  return { theme: 'auto', transparency: 'balanced', personality: { formality: 60, detail: 50, teasing: 25 }, sound: false };
}
