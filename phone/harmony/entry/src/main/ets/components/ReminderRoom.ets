import { i18n } from '@kit.LocalizationKit';
import { Palette } from '../design/Theme';
import { Gateway, GatewayError } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { ReminderClient } from '../services/ReminderClient';
import { Reminder, ReminderInput, ReminderUpdate, ReminderPage, ReminderLetter, InboxPage } from '../model/ReminderTypes';

@Component
export struct ReminderRoom {
  gateway:Gateway=new Gateway();
  local:LocalStore=new LocalStore();
  @Prop colors:Palette=new Palette();
  conversationId:string='';
  onClose:()=>void=()=>{};
  onOpenConversation:(id:string)=>void=()=>{};
  @State tab:string='plans';
  @State content:string='';
  @State when:Date=new Date(Date.now()+3600000);
  @State zone:string='America/Los_Angeles';
  @State repeat:string='once';
  @State editing:string='';
  @State reminders:Reminder[]=[];
  @State letters:ReminderLetter[]=[];
  @State schedulerRunning:boolean=false;
  @State busy:boolean=false;
  @State note:string='';
  private service?:ReminderClient;
  private timer:number=-1;
  private revision:number=0;
  private alive:boolean=false;

  aboutToAppear():void {
    this.alive=true; this.service=new ReminderClient(this.gateway);
    try {
      const zone=i18n.getTimeZone().getID();
      if(zone==='UTC'||/^[A-Za-z_+-]+\/[A-Za-z0-9_+/-]+$/.test(zone)) this.zone=zone;
    } catch(_) {}
    this.restore();
    this.timer=setInterval(()=>this.refresh(),10000);
  }
  aboutToDisappear():void {
    this.alive=false; this.revision++;
    if(this.timer>=0) clearInterval(this.timer); this.timer=-1;
  }
  private async restore():Promise<void> {
    try {
      const plans=JSON.parse(await this.local.get('reminder_cache','plans','[]')) as Reminder[];
      const letters=JSON.parse(await this.local.get('reminder_cache','letters','[]')) as ReminderLetter[];
      if(this.alive) { this.reminders=plans; this.letters=letters; }
    } catch(_) {}
    if(this.alive) await this.refresh();
  }
  private async refresh():Promise<void> {
    if(!this.alive||!this.gateway.isConfigured()||!this.service) return;
    const revision=++this.revision;
    try {
      const plans:ReminderPage=await this.service.list();
      const inbox:InboxPage=await this.service.inbox();
      if(!this.alive||revision!==this.revision) return;
      this.reminders=plans.reminders; this.letters=inbox.items;
      this.schedulerRunning=plans.scheduler.running&&!plans.scheduler.attention_needed;
      await this.local.put('reminder_cache','plans',JSON.stringify(plans.reminders));
      await this.local.put('reminder_cache','letters',JSON.stringify(inbox.items));
    } catch(error) {
      if(this.alive&&revision===this.revision) {
        this.schedulerRunning=false;
        this.note=error instanceof GatewayError?error.message:'琴房还没送回最新的约定，原来的信仍在。';
      }
    }
  }
  private dateChanged(date:Date):void {
    this.when=new Date(date.getFullYear(),date.getMonth(),date.getDate(),this.when.getHours(),this.when.getMinutes(),0);
  }
  private timeChanged(value:TimePickerResult):void {
    const hour=value.hour===undefined?this.when.getHours():Number(value.hour);
    const minute=value.minute===undefined?this.when.getMinutes():Number(value.minute);
    this.when=new Date(this.when.getFullYear(),this.when.getMonth(),this.when.getDate(),hour,minute,0);
  }
  private async save():Promise<void> {
    if(this.busy||!this.service||!this.content.trim()) return;
    this.busy=true; this.revision++;
    try {
      const input:ReminderInput={content:this.content.trim(),due_at:this.when.toISOString(),timezone:this.zone,repeat:this.repeat};
      if(this.editing) {
        const changes:ReminderUpdate={content:input.content,due_at:input.due_at,timezone:input.timezone,repeat:input.repeat};
        await this.service.update(this.editing,changes);
      }
      else {
        if(this.conversationId) input.conversation_id=this.conversationId;
        await this.service.create(input);
      }
      if(!this.alive) return;
      this.content=''; this.editing=''; this.note='';
      await this.refresh();
    } catch(error) { if(this.alive) this.note=error instanceof GatewayError?error.message:'这条约定还没收好，内容已经替你留着。'; }
    finally { if(this.alive) this.busy=false; }
  }
  private edit(item:Reminder):void {
    if(this.busy) return;
    this.content=item.content; this.when=new Date(item.due_at); this.zone=item.timezone;
    this.repeat=item.repeat; this.editing=item.id; this.tab='plans';
  }
  private async toggle(item:Reminder):Promise<void> {
    if(this.busy||!this.service) return;
    this.busy=true; this.revision++;
    try { await this.service.update(item.id,{enabled:!item.enabled}); if(this.alive) await this.refresh(); }
    catch(error) { if(this.alive) this.note=error instanceof GatewayError?error.message:'这条约定暂时没有改好，请稍后再试。'; }
    finally { if(this.alive) this.busy=false; }
  }
  private async read(item:ReminderLetter):Promise<void> {
    if(this.busy||!this.service||item.read_at) return;
    this.busy=true; this.revision++;
    try { await this.service.read(item.id); if(this.alive) await this.refresh(); }
    catch(error) { if(this.alive) this.note=error instanceof GatewayError?error.message:'这封信先留在这里，稍后再替你收好。'; }
    finally { if(this.alive) this.busy=false; }
  }
  private time(value:string):string { return new Date(value).toLocaleString(); }
  private cadence(value:string):string { return value==='daily'?'每天':value==='weekly'?'每周':'仅一次'; }

  @Builder private Choice(title:string,value:string) {
    Button(title).fontSize(13).height(36).layoutWeight(1)
      .backgroundColor(this.repeat===value?this.colors.accent:this.colors.surface)
      .fontColor(this.repeat===value?this.colors.background:this.colors.secondary)
      .enabled(!this.busy).onClick(()=>{this.repeat=value;})
  }
  build() {
    Column() {
      Row({space:12}) {
        Button('返回').backgroundColor(Color.Transparent).fontColor(this.colors.accent).onClick(()=>this.onClose())
        Text('约定与来信').fontSize(22).fontColor(this.colors.text).layoutWeight(1)
        if(this.schedulerRunning) Text('主机守约中').fontSize(11).fontColor(this.colors.gold)
      }.padding({left:14,right:22,top:16,bottom:12}).width('100%')
      Row({space:12}) {
        Button('约定').fontColor(this.tab==='plans'?this.colors.background:this.colors.accent)
          .backgroundColor(this.tab==='plans'?this.colors.accent:this.colors.surface).onClick(()=>{this.tab='plans';})
        Button('来信 '+this.letters.filter((item:ReminderLetter)=>!item.read_at).length)
          .fontColor(this.tab==='inbox'?this.colors.background:this.colors.accent)
          .backgroundColor(this.tab==='inbox'?this.colors.accent:this.colors.surface).onClick(()=>{this.tab='inbox';this.refresh();})
        Blank()
        Button('刷新').fontSize(12).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).onClick(()=>this.refresh())
      }.padding({left:24,right:24,bottom:14}).width('100%')
      if(this.note) Text(this.note).fontSize(13).fontColor(this.colors.secondary).padding({left:24,right:24,bottom:12}).width('100%')
      Scroll() {
        Column({space:20}) {
          if(this.tab==='plans') {
            TextArea({text:this.content,placeholder:'希望我到时提醒你的事'}).height(84).fontColor(this.colors.text)
              .placeholderColor(this.colors.secondary).backgroundColor(this.colors.surface).enabled(!this.busy)
              .onChange((value:string)=>{this.content=value;})
            Text('提醒时间 · 手机时区').fontSize(13).fontColor(this.colors.secondary).width('100%')
            DatePicker({start:new Date(2020,0,1),end:new Date(2045,11,31),selected:this.when})
              .height(150).width('100%').backgroundColor(this.colors.surface).borderRadius(16)
              .selectedTextStyle({color:this.colors.text,font:{size:17}}).textStyle({color:this.colors.secondary,font:{size:13}})
              .enabled(!this.busy).onDateChange((date:Date)=>this.dateChanged(date))
            TimePicker({selected:this.when}).useMilitaryTime(true).height(110).width('100%')
              .selectedTextStyle({color:this.colors.text,font:{size:17}}).textStyle({color:this.colors.secondary,font:{size:13}})
              .backgroundColor(this.colors.surface).borderRadius(16).enabled(!this.busy).onChange((value:TimePickerResult)=>this.timeChanged(value))
            Row({space:8}) { this.Choice('仅一次','once');this.Choice('每天','daily');this.Choice('每周','weekly') }.width('100%')
            if(this.repeat!=='once') Text('重复计划时区：'+this.zone).fontSize(12).fontColor(this.colors.secondary).width('100%')
            Row({space:12}) {
              if(this.editing) Button('取消修改').fontColor(this.colors.secondary).backgroundColor(Color.Transparent).enabled(!this.busy)
                .onClick(()=>{this.editing='';this.content='';})
              Blank()
              Button(this.busy?'正在收好…':this.editing?'改好约定':'约好了').fontColor(this.colors.background).backgroundColor(this.colors.accent)
                .enabled(!this.busy&&this.content.trim().length>0).onClick(()=>this.save())
            }.width('100%')
            Text('到时会送到来信箱，也会写回约定所在的乐章。').fontSize(12).lineHeight(21).fontColor(this.colors.secondary).width('100%')
            ForEach(this.reminders,(item:Reminder)=>{
              Column({space:12}) {
                Text(item.content).fontSize(16).lineHeight(26).fontColor(this.colors.text).width('100%')
                Text(this.time(item.due_at)+' · '+this.cadence(item.repeat)).fontSize(12).fontColor(this.colors.secondary).width('100%')
                Row({space:10}) {
                  Text(item.enabled?'等待约定的时间':item.last_delivered_at?'已送到来信箱':'已停下').fontSize(11).fontColor(this.colors.gold).layoutWeight(1)
                  Button('修改').fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent).enabled(!this.busy).onClick(()=>this.edit(item))
                  Button(item.enabled?'停下':'启用').fontSize(12).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).enabled(!this.busy).onClick(()=>this.toggle(item))
                }.width('100%')
              }.padding(18).backgroundColor(this.colors.surface).borderRadius(18).width('100%')
            },(item:Reminder)=>item.id)
          } else {
            if(this.letters.length===0) Text('还没有新的来信。').fontSize(16).fontColor(this.colors.secondary).padding(30)
            ForEach(this.letters,(item:ReminderLetter)=>{
              Column({space:12}) {
                Text(item.content).fontSize(17).lineHeight(28).fontColor(this.colors.text).width('100%').copyOption(CopyOptions.InApp)
                Text(this.time(item.delivered_at)).fontSize(12).fontColor(this.colors.secondary).width('100%')
                Row({space:10}) {
                  if(!item.read_at) Button('收好这封信').fontSize(12).fontColor(this.colors.gold).backgroundColor(Color.Transparent).enabled(!this.busy).onClick(()=>this.read(item))
                  else Text('已读').fontSize(11).fontColor(this.colors.secondary)
                  Blank()
                  if(item.conversation_id) Button('回到乐章').fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
                    .onClick(()=>{if(item.conversation_id)this.onOpenConversation(item.conversation_id);})
                }.width('100%')
              }.padding(18).backgroundColor(this.colors.surface).borderRadius(18).width('100%')
            },(item:ReminderLetter)=>item.id)
          }
        }.padding(24).width('100%').constraintSize({maxWidth:760})
      }.align(Alignment.Top).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
