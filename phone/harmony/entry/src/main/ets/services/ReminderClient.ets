import { http } from '@kit.NetworkKit';
import { Gateway } from './Gateway';
import { Reminder, ReminderInput, ReminderPage, ReminderUpdate, InboxPage } from '../model/ReminderTypes';

export class ReminderClient {
  private gateway:Gateway;
  constructor(gateway:Gateway) { this.gateway=gateway; }
  list():Promise<ReminderPage> { return this.gateway.request<ReminderPage>('/api/reminders'); }
  create(input:ReminderInput):Promise<Reminder> {
    return this.gateway.request<Reminder>('/api/reminders',http.RequestMethod.POST,JSON.stringify(input));
  }
  update(id:string,changes:ReminderUpdate):Promise<Reminder> {
    return this.gateway.request<Reminder>('/api/reminders/'+encodeURIComponent(id)+'/update',http.RequestMethod.POST,JSON.stringify(changes));
  }
  inbox():Promise<InboxPage> { return this.gateway.request<InboxPage>('/api/inbox'); }
  read(id:string):Promise<Record<string,string>> {
    return this.gateway.request<Record<string,string>>('/api/inbox/'+encodeURIComponent(id)+'/read',http.RequestMethod.POST,'{}');
  }
}
