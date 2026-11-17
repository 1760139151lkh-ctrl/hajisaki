import { Artifact, Connection, ContextPin, Conversation, Memory, Message, MessageTasks, ModelOption, PendingMessage, Settings, Status, StreamEvent, defaultSettings } from './Types';
import { MessagePart, manuscriptParts } from './MessageParts';
import { BranchOrigin } from './BranchTypes';

@Observed
export class ClientState {
  previewStorage: boolean = false;
  ready: boolean = false;
  page: string = 'hub';
  notice: string = '';
  pendingRelayId: string = '';
  relayConfigured: boolean = false;
  relayActive: boolean = false;
  relayOrigin: string = '';
  relayNotice: string = '';
  online: boolean = false;
  connecting: boolean = false;
  conversations: Conversation[] = [];
  messages: Message[] = [];
  taskPages:MessageTasks[]=[];
  pins:ContextPin[]=[];
  memories: Memory[] = [];
  artifacts: Artifact[] = [];
  events: StreamEvent[] = [];
  models: ModelOption[] = [];
  activeId: string = '';
  activeTitle: string = '二人琴房';
  group: string = '全部';
  query: string = '';
  searchConversationIds: string[] = [];
  draft: string = '';
  draftEpoch:number=0;
  draftLoading:boolean=false;
  queued: number = 0;
  pending: PendingMessage[] = [];
  runId: string = '';
  stopping: boolean = false;
  sending: boolean = false;
  model: string = 'default';
  effort: string = 'medium';
  toneId:string='inherit';
  branchOrigin:BranchOrigin={thread:null,arena:null};
  settings: Settings = defaultSettings();
  connection: Connection = { primary: '', fallback: '', device: '' };
  status?: Status;
  selectedAttachments: Artifact[] = [];
  readingText: string = '';
  readingMessageId: string = '';
  readingTitle: string = '';
  showProcess: boolean = false;
  uploadProgress: string = '';
  recordingState: string = 'idle';
  recordingPath: string = '';
}

interface ParsedMessage { content: string; parts: string[] }

export class MessageSource implements IDataSource {
  private items: MessagePart[] = [];
  private cache: Map<string, MessagePart> = new Map();
  private parsed: Map<string, ParsedMessage> = new Map();
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.items.length; }
  getData(index: number): MessagePart { return this.items[index]; }
  indexOfMessage(id:string):number {return this.items.findIndex((part:MessagePart)=>part.message.id===id);}
  registerDataChangeListener(listener: DataChangeListener): void { this.listeners.push(listener); }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener) => item !== listener);
  }
  replace(items: Message[]): void {
    const next: MessagePart[] = [];
    const cache: Map<string, MessagePart> = new Map();
    const parsed: Map<string, ParsedMessage> = new Map();
    for (const message of items) {
      const old=this.parsed.get(message.id);
      const parts=old && old.content===message.content ? old.parts : manuscriptParts(message.content);
      parsed.set(message.id,{content:message.content,parts:parts});
      for (let index=0; index<parts.length; index++) {
        const id = message.id + ':' + index;
        let part = this.cache.get(id);
        if (part) {
          if(part.message!==message) part.message=message;
          if(part.text!==parts[index]) part.text=parts[index];
          if(part.first!==(index===0)) part.first=index===0;
          if(part.last!==(index===parts.length-1)) part.last=index===parts.length-1;
        } else part=new MessagePart(id,message,parts[index],index===0,index===parts.length-1);
        next.push(part); cache.set(id,part);
      }
    }
    this.items=next; this.cache=cache; this.parsed=parsed;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}
