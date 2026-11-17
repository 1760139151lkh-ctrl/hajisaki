import { request } from "./api";
import type { StreamEvent } from "./types";

/** Consume the authenticated durable event stream. The caller owns seq deduplication. */
export async function consumeStream(
  path: string,
  onEvent: (event: StreamEvent) => void,
  signal: AbortSignal,
) {
  const response = await request(path, {
    signal,
    headers: { Accept: "text/event-stream" },
  });
  if (!response.body) throw new Error("这一段连接暂时没有声音。");
  const reader = response.body.getReader(),
    decoder = new TextDecoder();
  let pending = "";
  try {
    while (!signal.aborted) {
      const { value, done } = await reader.read();
      if (done) break;
      pending += decoder.decode(value, { stream: true });
      pending = pending.replace(/\r\n/g, "\n");
      let end: number;
      while ((end = pending.indexOf("\n\n")) >= 0) {
        const frame = pending.slice(0, end);
        pending = pending.slice(end + 2);
        const data = frame
          .split("\n")
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).trimStart())
          .join("\n");
        if (data) {
          const event = JSON.parse(data) as StreamEvent;
          if (Number.isSafeInteger(event.seq) && typeof event.kind === "string")
            onEvent(event);
        }
      }
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
