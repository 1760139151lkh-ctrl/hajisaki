type Effect = "send" | "reply" | "effort" | "bookmark";
const files: Record<Effect, string> = {
  send: "send-felt-c6.wav",
  reply: "reply-major-nine.wav",
  effort: "effort-watch-click.wav",
  bookmark: "bookmark-chime.wav",
};
let enabled = false,
  rain: HTMLAudioElement | undefined;
const voices = new Map<Effect, HTMLAudioElement>();
export function setSound(value: boolean) {
  enabled = value;
  if (!value) voices.forEach((audio) => audio.pause());
}
export function playEffect(effect: Effect) {
  if (!enabled) return;
  let audio = voices.get(effect);
  if (!audio) {
    audio = new Audio(`/artwork/audio/${files[effect]}`);
    audio.volume = 0.35;
    voices.set(effect, audio);
  }
  audio.currentTime = 0;
  void audio.play().catch(() => {});
}
export function rainPlaying() {
  return !!rain && !rain.paused;
}
export async function toggleRain() {
  if (rain && !rain.paused) {
    rain.pause();
    return false;
  }
  if (!rain) {
    rain = new Audio("/artwork/audio/piano-room-rain.wav");
    rain.loop = true;
    rain.volume = 0.24;
  }
  await rain.play();
  return true;
}
