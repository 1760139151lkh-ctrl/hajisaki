export interface Reminder {
  id:string; content:string; due_at:string; timezone:string; repeat:string;
  enabled:boolean; conversation_id:string|null; created_at:string; updated_at:string;
  last_delivered_at?:string|null;
}
export interface ReminderScheduler { running:boolean; last_tick:string|null; attention_needed:boolean; delivery:string; remote_push_verified:boolean }
export interface ReminderPage { reminders:Reminder[]; scheduler:ReminderScheduler }
export interface ReminderInput { content:string; due_at:string; timezone:string; repeat:string; conversation_id?:string }
export interface ReminderUpdate { content?:string; due_at?:string; timezone?:string; repeat?:string; enabled?:boolean }
export interface ReminderLetter {
  id:string; reminder_id:string; due_at:string; delivered_at:string; content:string;
  read_at:string|null; conversation_id:string|null;
}
export interface InboxPage { items:ReminderLetter[] }
