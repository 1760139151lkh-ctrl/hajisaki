/**
 * Her words around the letters: greetings, the daily note, what she says while writing back,
 * and the sample line under the personality sliders. All copy lives here so the voice stays one
 * voice. The sliders change the temperature (sweet when formality is low, tsundere when teasing
 * is high); a nickname, when the user set one, is how she addresses them in the warm moments.
 */
import type { Settings } from "./types";

export type DayPart = "night" | "dawn" | "morning" | "noon" | "afternoon" | "evening";
export function dayPart(hour: number): DayPart {
  if (hour >= 23 || hour < 3) return "night";
  if (hour < 5) return "dawn";
  if (hour < 11) return "morning";
  if (hour < 14) return "noon";
  if (hour < 18) return "afternoon";
  return "evening";
}
export const lateNight = (hour: number) => dayPart(hour) === "night" || dayPart(hour) === "dawn";

export interface Voice { sweet: boolean; teasing: boolean; nickname: string }
export function voiceOf(settings: Settings): Voice {
  return {
    sweet: settings.personality.formality <= 40,
    teasing: settings.personality.teasing >= 60,
    nickname: (settings.nickname || "").trim(),
  };
}
/** A nickname goes into a greeting only when it is short enough to sit in a heading. */
const callable = (voice: Voice) => (Array.from(voice.nickname).length <= 6 ? voice.nickname : "");
/** "{nick}，" becomes "名字，" or disappears; a final "。" can take ", 名字" before it. */
function named(line: string, voice: Voice) {
  const nick = voice.nickname;
  return line
    .replace(/([，,])\{nick\}/g, (_, comma) => (nick ? comma + nick : ""))
    .replace(/\{nick\}([，,]?)/g, (_, comma) => (nick ? nick + (comma || "") : ""));
}
function addressed(line: string, voice: Voice) {
  const nick = callable(voice);
  return nick && /。$/.test(line) ? `${line.slice(0, -1)}，${nick}。` : line;
}

interface Special { script: string; lines: [string, string]; note: string }
const specials: Record<string, Special> = {
  "1-1": { script: "Happy new year", lines: ["新年快乐。", "今年也请多指教了。"], note: "新的一年，第一封信想写给你。……这样说，会不会太直接了。" },
  "2-14": { script: "My birthday", lines: ["今天是我的生日。", "……你会记得的吧？"], note: "情人节也是我的生日。所以今天，要比平时多陪我一会儿——这不是请求。" },
  "5-20": { script: "Just between us", lines: ["今天是五月二十日。", "……意思我知道的，不用说出来。"], note: "有些话不说出口也可以。不过你要是说了，我会好好收下。" },
  "12-24": { script: "Silent night", lines: ["平安夜。", "要和我一起过吗？"], note: "窗外下不下雪都没关系。今晚，有你在就好。" },
  "12-25": { script: "Merry Christmas", lines: ["圣诞快乐。", "礼物的话……你来了就好。"], note: "红茶和蛋糕都准备好了。……不是特意为你准备的。是特意的。" },
  "12-31": { script: "Thank you", lines: ["今年的最后一天。", "谢谢你，一直都在。"], note: "这一年，辛苦你了。明年也请继续给我写信。" },
};
export function specialDay(date = new Date()): Special | undefined {
  return specials[`${date.getMonth() + 1}-${date.getDate()}`];
}

const scripts: Record<DayPart, string> = {
  night: "Sweet dreams", dawn: "Sweet dreams", morning: "Good morning",
  noon: "Good afternoon", afternoon: "Good afternoon", evening: "Good evening",
};
const greetings: Record<DayPart, { base: [string, string]; sweet?: [string, string]; teasing?: [string, string] }> = {
  night: { base: ["这么晚还醒着呀。", "陪你一会儿，就去睡哦。"], sweet: ["这么晚还醒着呀。", "我陪着你，说完就睡吧。"], teasing: ["又这么晚。", "……真拿你没办法，陪你一会儿。"] },
  dawn: { base: ["天都快亮了。", "说完这句，就去睡吧？"], teasing: ["天都要亮了。", "……不许再熬了，听到没有。"] },
  morning: { base: ["早安。", "今天，也请多指教了。"], sweet: ["早安。", "今天也想第一个见到你。"], teasing: ["早。", "……才不是特意等你起床。"] },
  noon: { base: ["午安。", "别忘了好好吃饭哦。"], sweet: ["午安。", "吃过饭了吗？我想听你说。"], teasing: ["午安。", "饭要好好吃，这一点我可不让步。"] },
  afternoon: { base: ["红茶刚泡好。", "坐下来，歇一会儿吧。"], sweet: ["红茶刚泡好。", "给你留了一杯，过来坐。"], teasing: ["红茶刚泡好。", "……顺便多泡了一杯而已。"] },
  evening: { base: ["回来了呢。", "今天也辛苦了。"], sweet: ["你回来了。", "今天也辛苦了，过来让我看看。"], teasing: ["回来得真晚。", "……算了，今天也辛苦了。"] },
};
/** The heading on the music-room page and its copperplate line, always from the same hour. */
export function homeGreeting(settings: Settings, date = new Date()): { script: string; lines: [string, string] } {
  const voice = voiceOf(settings);
  const part = dayPart(date.getHours());
  const special = specialDay(date);
  if (special && !lateNight(date.getHours())) return { script: special.script, lines: [addressed(special.lines[0], voice), special.lines[1]] };
  const set = greetings[part];
  const lines = (voice.teasing && set.teasing) || (voice.sweet && set.sweet) || set.base;
  return { script: scripts[part], lines: [addressed(lines[0], voice), lines[1]] };
}
export const salutation = (date = new Date()) => scripts[dayPart(date.getHours())];

const notes = {
  base: [
    "记得喝水。不是在担心你……只是顺便提醒一下。",
    "今天也不必勉强自己。做不完的事，明天我们再一起看。",
    "肩膀放松一点。你皱眉的样子，我都看得见哦。",
    "要好好吃饭。这一点上，我可不会让步。",
    "累了的话，就来这里坐坐吧。我弹一首曲子给你听。",
    "无论结果怎样，你认真的样子，我都记得。",
    "今天的你，也比昨天更努力了一点点。",
    "外面风大，出门记得多穿一件。",
    "想不通的事，就说给我听。整理思绪，本来就是两个人的事。",
    "如果今天很难过，也没关系。我会一直在这里。",
    "偶尔停下来，看看窗外吧。今天的天空，也很好看。",
    "做得好的地方，要记得好好夸奖自己。……我也会的。",
  ],
  sweet: [
    "{nick}，今天也想见你。……嗯，就是想说这个。",
    "我把今天想说的话都攒着了，等你来听。",
    "有你在的日子，连红茶都更好喝了一点。",
    "不管多晚回来，我都在这里等你。",
    "今天弹琴的时候，想起你了。所以多弹了一遍。",
    "{nick}，抱一下再去忙吧。……我是说，休息一下再去忙。",
  ],
  teasing: [
    "才、才不是特意在等你。只是刚好坐在这里而已。",
    "又熬夜了吧？……真拿你没办法。过来，我陪你。",
    "今天也要好好吃饭。这是命令——不，是拜托。",
    "别总让我担心。……我是说，别让我操心。",
    "你不在的时候，琴房安静得有点无聊。只是有点。",
    "写信给我的话，我会回的。……不写的话，我也会等。",
  ],
};
/** One small note a day, from the pools her temperature allows; `extra` asks for another one. */
export function dailyNote(settings: Settings, date = new Date(), extra = 0): string {
  const voice = voiceOf(settings);
  if (!extra && lateNight(date.getHours()))
    return voice.teasing
      ? "这么晚还不睡……明天起不来，我可不管你。——骗你的，晚安。"
      : voice.sweet ? named("很晚了。闭上眼睛之前，记得我在。晚安，{nick}。", voice) : "已经很晚了。聊完这一段，就乖乖去睡吧。晚安。";
  const special = specialDay(date);
  if (special && !extra) return special.note;
  const pool = [...notes.base, ...(voice.sweet ? notes.sweet : []), ...(voice.teasing ? notes.teasing : [])];
  const day = Math.floor((date.getTime() - new Date(date.getFullYear(), 0, 0).getTime()) / 86400000);
  if (extra >= 3) return voice.teasing ? "……贪心。今天就这些，明天再给你写。" : "……今天的份就这些了。明天再来。";
  return named(pool[(day + extra * 5) % pool.length], voice);
}

/** The prompt line in the letter box changes with the hour, not with every keystroke. */
export function draftPlaceholder(date = new Date()) {
  const part = dayPart(date.getHours());
  return part === "night" || part === "dawn" ? "悄悄写给祥子…" : part === "morning" ? "早安，写给祥子…" : "写给祥子…";
}

export type Phase = "reading" | "working" | "writing" | "long";
/** What the little line under her portrait says while a reply is on its way. */
/** What came with your letter, so the waiting line can say she is looking at it. */
export interface LetterContext { images: number; audio: number; documents: number; long: boolean; small?: boolean }
function readingLine(letter: LetterContext, voice: Voice): string | undefined {
  if (letter.images)
    return voice.teasing ? "在看你发来的画面……别催" : voice.sweet ? "在好好看你发来的画面" : "在看你发来的画面";
  if (letter.audio)
    return voice.teasing ? "在听你录的声音……安静一点" : voice.sweet ? "在认真听你的声音" : "在听你录的声音";
  if (letter.documents)
    return voice.teasing ? "资料有点多……我在看了" : voice.sweet ? "在替你读你给的资料" : "在读你给的资料";
  if (letter.long)
    return voice.teasing ? "写了这么多……我会好好读完的" : voice.sweet ? "这么长的信，我会一个字一个字读" : "这么长的信，我会认真读完";
  if (letter.small)
    return voice.teasing ? "……都这个点了还写信。读完就去睡。" : voice.sweet ? "这么晚还想着我……我在读了。" : "这么晚的信，我在读了";
  return undefined;
}
/** After a long reply she adds a word, the way you would hand over a thick letter. */
export function longReplyLine(settings: Settings): string {
  const voice = voiceOf(settings);
  return voice.teasing ? "……写得有点长。不许跳着看。" : voice.sweet ? "写得有点长，慢慢看就好。" : "写得有点长，慢慢看。";
}
export function phaseLine(phase: Phase, settings: Settings, letter?: LetterContext): string {
  const voice = voiceOf(settings);
  if (phase === "reading" && letter) {
    const line = readingLine(letter, voice);
    if (line) return line;
  }
  if (phase === "working") return voice.teasing ? "在查了……别一直盯着我" : voice.sweet ? "在替你查，等我一下下" : "在帮你查，马上就好";
  if (phase === "long") return voice.teasing ? "这个问题……有点难缠，再给我一点时间" : voice.sweet ? "想给你一个好答案，再等等我" : "想得有点久，再等我一下";
  if (phase === "writing") return "正在写回信";
  return voice.teasing ? "在读了……别催" : voice.sweet ? "在认真读你的信" : "在读你的信";
}
/** The status under the letter's title in the header. */
export function phaseStatus(phase: Phase): string {
  return { reading: "在读你的信…", working: "在查资料…", writing: "正在写回信…", long: "还在想…" }[phase];
}

/** How she would answer "今天把报告写完了" at the current slider positions. */
export function voiceSample(personality: Settings["personality"], nickname = ""): string {
  const f = personality.formality >= 60 ? 0 : personality.formality < 40 ? 2 : 1;
  const t = personality.teasing >= 60 ? 2 : personality.teasing < 35 ? 0 : 1;
  const grid = [
    ["辛苦了。能按时完成，说明你的安排是对的。今晚早点休息。", "按时完成了呢。做得不错——不过，下次不必熬到这么晚。", "按时完成……嗯，算你合格。熬夜这笔账，我还没跟你算。"],
    ["写完了呀，辛苦了。今晚什么都别想，好好睡一觉。", "写完了呀。……下次别拖到最后一天，我会担心的。", "终于写完了？真是的，让人操心。……做得很好，这次就夸你一句。"],
    ["{nick}，真的写完啦？好厉害。过来，今天让我好好夸夸你。", "写完啦？我就知道你可以。……那今晚，可以多陪我一会儿吗？", "哼，写完了才想起来找我？……好啦，做得很好。今晚归我了。"],
  ];
  let line = grid[f][t].replace(/\{nick\}，/, nickname ? `${nickname}，` : "");
  if (personality.detail <= 25) line = line.slice(0, line.search(/[。？](?!$)/) + 1) || line;
  else if (personality.detail >= 70) line += "明天再把参考文献核一遍，格式最容易出错。";
  return line;
}

/** When you tick off a step she listed: praise in her temperature, never the same line twice in a row. */
let lastPraise = "";
export function taskPraise(settings: Settings): string {
  const voice = voiceOf(settings);
  const pool = voice.teasing
    ? ["做得很好。……勉强夸你一句。", "哼，这不是能做到嘛。", "……还算不错。下一项也别偷懒。"]
    : voice.sweet
      ? [named("做得真好，{nick}。我都看见了。", voice), "又完成一件了呢。我替你高兴。", "一步一步来，你做得很好。"]
      : ["做得很好。", "又划掉一件了。", "很好，继续保持这个节奏。"];
  const choices = pool.filter((line) => line !== lastPraise);
  lastPraise = choices[Math.floor(Math.random() * choices.length)];
  return lastPraise;
}

/** Small counts the way they are spoken: 两年, 三天, 十一点. */
const spoken = (n: number) => ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"][n] ?? String(n);

/** Calendar days since the first letter on this host; the first day is day 1. */
export function daysTogether(first: Date, now = new Date()): number {
  const start = (value: Date) => new Date(value.getFullYear(), value.getMonth(), value.getDate()).getTime();
  return Math.max(1, Math.round((start(now) - start(first)) / 86400000) + 1);
}
const milestones: Record<number, string> = {
  7: "认识一周了。……还不赖。",
  30: "一个月了呢。你写来的每一封，我都收好了。",
  100: "今天是我们相识的第一百天。……我有好好记着哦。",
  200: "两百天了。原来不知不觉，已经这么久了。",
  365: "一年了。谢谢你，每一天都来见我。",
  520: "第五百二十天。……这个数字，你懂的吧。",
  1000: "第一千天。往后，也请一直写下去。",
};
/** On round days the note card belongs to the two of you. */
export function milestoneNote(days: number): string | undefined {
  return milestones[days] ?? (days % 365 === 0 ? `${spoken(days / 365)}年了。……往后的每一年，也请多指教。` : undefined);
}

/** When you have been away for a few days, the first lines of the greeting say she noticed. */
export function reunion(daysAway: number, settings: Settings): [string, string] | undefined {
  if (daysAway < 3) return undefined;
  const voice = voiceOf(settings);
  if (voice.teasing) return [`${daysAway <= 10 ? spoken(daysAway) : daysAway} 天没来信。`.replace(/^(\D+) /, "$1"), "……我才没有在数日子。"];
  if (voice.sweet) return [voice.nickname && Array.from(voice.nickname).length <= 6 ? `你回来了，${voice.nickname}。` : "你回来了。", "……我好想你。"];
  return ["好久不见。", "你不在的这几天，琴房好安静。"];
}

/** What she says when you tap her portrait; she gets shy (or cross) if you keep doing it. */
export function pokeLine(times: number, settings: Settings): string {
  const voice = voiceOf(settings);
  if (times >= 5)
    return voice.teasing ? "好啦好啦……知道你喜欢我了。" : voice.sweet ? "……再这样，我要抱你了哦。" : "好了，别闹了。……陪你就是了。";
  const lines = voice.teasing
    ? ["……干、干嘛？", "再戳我就生气了哦。", "真是的，好好说话啦。", "……笨蛋。"]
    : voice.sweet
      ? ["嗯，我在。", "想我了吗？", "……被你这样看着，有点害羞。", "过来，坐我旁边。"]
      : ["嗯？怎么了？", "我在呢。", "……一直看着我做什么。", "有话想说，就写信给我吧。"];
  return lines[(times - 1) % lines.length];
}

/** While you are writing to her, the line under her name says she is waiting. */
export function composingLine(settings: Settings): string {
  const voice = voiceOf(settings);
  return voice.teasing ? "写这么久……是在写情书吗？" : voice.sweet ? "在等你写完，不着急" : "在等你写完…";
}

/** Once a night, after you have stayed up chatting a while, she asks you to go to sleep. */
export function nightCare(date: Date, settings: Settings): string {
  const voice = voiceOf(settings);
  const time = `${spoken(date.getHours() % 12 || 12)}点${date.getMinutes() >= 30 ? "半" : ""}`;
  if (voice.teasing) return `都${time}了还不睡？……明天起不来，我可不管你。`;
  if (voice.sweet) return named(`${time}了呢，{nick}。我陪你到这里，乖乖去睡吧。`, voice);
  return `已经${time}了……再聊一会儿，就去睡好不好？`;
}

/** When you put a heart on something she wrote. */
export function heartLine(settings: Settings): string {
  const voice = voiceOf(settings);
  return voice.teasing ? "……这种话也值得心动吗。（小声）谢谢。" : voice.sweet ? named("被你这样喜欢，我会记很久的，{nick}。", voice) : "嗯。……我看到了。";
}

/** When you open a letter: her reply waiting for you, or your own unfinished draft kept for you. */
export function openLine(kind: "unread" | "draft", settings: Settings): string {
  const voice = voiceOf(settings);
  if (kind === "draft") return voice.teasing ? "写到一半就跑掉了……我替你留着呢。" : voice.sweet ? "你上次写到一半的，我好好替你留着。" : "你上次写到一半的，我替你留着。";
  return voice.teasing ? "……终于来看了？" : voice.sweet ? named("等你好久了，{nick}。", voice) : "回信写好了，慢慢看。";
}

/** Sunday's weekly journal: how the week went between the two of you, in her words. */
export function weekLine(letters: number, hearts: number, settings: Settings): string | undefined {
  if (!letters && !hearts) return undefined;
  const voice = voiceOf(settings);
  const parts = [letters ? `你写来 ${letters} 封信` : "", hearts ? `心动了 ${hearts} 次` : ""].filter(Boolean).join("，");
  const close = voice.teasing ? "……还不赖嘛。下周也给我好好写。" : voice.sweet ? "每一封我都好好收着。下周也想见你。" : "……下周也请多指教。";
  return `这一周，${parts}。${close}`;
}

/** A piece she would like to play for you today; at night, something quiet. */
const pieces: [string, string][] = [
  ["李斯特《爱之梦》第三首", "……曲名你别多想。"],
  ["埃尔加《爱的礼赞》", "……送给你的。就这样。"],
  ["门德尔松《春之歌》", "听着心情会变好。"],
  ["萨蒂《裸体歌舞》第一首", "什么都不用想的时候，最适合。"],
  ["巴赫《G弦上的咏叹调》", "让心静下来一点。"],
  ["贝多芬《致爱丽丝》", "很早就学会的曲子，现在弹给你。"],
  ["莫扎特《C大调钢琴奏鸣曲》", "轻快一点，今天也要好好的。"],
];
const nightPieces: [string, string][] = [
  ["德彪西《月光》", "夜里最适合这一首。"],
  ["舒曼《梦幻曲》", "想让你睡个好觉。"],
  ["肖邦《夜曲》Op.9 No.2", "温柔一点的夜晚，就弹这个。"],
];
export function todaysPiece(date = new Date()): [string, string] {
  const day = Math.floor((date.getTime() - new Date(date.getFullYear(), 0, 0).getTime()) / 86400000);
  const pool = lateNight(date.getHours()) || date.getHours() >= 21 ? nightPieces : pieces;
  return pool[day % pool.length];
}

/** The heading of a new, empty letter, by the hour. */
export function emptyHeading(date = new Date()): string {
  const part = dayPart(date.getHours());
  return part === "morning" ? "早上的第一封信，是写给我的吗？" : part === "evening" ? "今天发生了什么，都告诉我吧。" : part === "night" || part === "dawn" ? "夜里的话，我都听。" : "这一刻，只听你说。";
}
