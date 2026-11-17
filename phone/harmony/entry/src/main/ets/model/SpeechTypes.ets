import { Artifact } from './Types';

export interface SpeechStatus {
  available: boolean;
  state: string;
  detail: string;
  limits: SpeechLimits;
  active_jobs?: string[];
  queued_jobs?: string[];
}
export interface SpeechLimits { max_bytes: number; max_seconds: number }
export interface SpeechSegment { start: number | null; end: number | null; text: string }
export interface UncertainSpeech {
  char_start: number | null;
  char_end: number | null;
  start_seconds: number | null;
  end_seconds: number | null;
  text: string;
  probability: number | null;
}
export interface SpeechSuggestion { start: number; end: number; text: string; replacement: string; source: string }
export interface SpeechProgress { segments: number; through_seconds: number | null }
export interface SpeechJob {
  id: string;
  status: string;
  artifact_id: string;
  original_text: string;
  text: string;
  segments: SpeechSegment[];
  uncertain_spans: UncertainSpeech[];
  dictionary_suggestions: SpeechSuggestion[];
  progress: SpeechProgress;
  detail?: string;
}
export interface SpeechHotword { term: string; aliases: string[] }
export interface SpeechHotwords { hotwords: SpeechHotword[] }
export interface SpeechCleanEdit { start: number; end: number; original: string; replacement: string }
export interface SpeechCleanResult { original: string; text: string; edits: SpeechCleanEdit[]; method: string }
export interface SpeechDraft { text: string; edited: boolean }

@Observed
export class SpeechState {
  status?: SpeechStatus;
  artifact?: Artifact;
  job?: SpeechJob;
  artifacts: Artifact[] = [];
  text: string = '';
  edited: boolean = false;
  notice: string = '';
  busy: string = '';
  loadingStatus: boolean = false;
  recordedPath: string = '';
  recording: string = 'idle';
  recordSeconds: number = 0;
  transferDone: number = 0;
  transferTotal: number = 0;
  playing: boolean = false;
  playbackSeconds: number = 0;
  playbackDuration: number = 0;
  hotwordText: string = '';
  hotwordsLoaded: boolean = false;
  hotwordsLoading: boolean = false;
  libraryLoading: boolean = false;
  submissionUncertain: boolean = false;
  beforeClean: string = '';
  cleanedText: string = '';
}

export function speechTime(seconds: number | null): string {
  const value = seconds === null || !Number.isFinite(seconds) ? 0 : Math.max(0, Math.floor(seconds));
  return Math.floor(value / 60).toString().padStart(2, '0') + ':' + (value % 60).toString().padStart(2, '0');
}

export function speechOngoing(job?: SpeechJob): boolean {
  return job !== undefined && (job.status === 'queued' || job.status === 'running');
}
