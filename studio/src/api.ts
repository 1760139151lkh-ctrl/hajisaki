import { apiAddress } from './android';
let token = sessionStorage.getItem("haji-token") || "";
let device = localStorage.getItem("haji-device") || "";
export function credentials() {
  return { token, device };
}
export function pair(nextToken: string, nextDevice: string) {
  token = nextToken;
  device = nextDevice;
  sessionStorage.setItem("haji-token", token);
  localStorage.setItem("haji-device", device);
}
export function disconnect() {
  token = "";
  sessionStorage.removeItem("haji-token");
}
export async function request(path: string, init: RequestInit = {}) {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${token}`);
  headers.set("X-Haji-Device", device);
  if (typeof init.body === "string")
    headers.set("Content-Type", "application/json");
  let response: Response;
  try {
    response = await fetch(apiAddress(`/api${path}`), { ...init, headers });
  } catch (error) {
    if (init.signal?.aborted) throw error;
    throw new Error("琴房的连接暂时松开了。草稿还在，连上后可以重新送出。");
  }
  if (!response.ok) {
    let message = "这次没有接稳。请稍后再试。";
    try {
      const detail = await response.json();
      if (typeof detail.detail === "string") message = detail.detail;
      else if (typeof detail.message === "string") message = detail.message;
    } catch {}
    throw new Error(
      response.status === 401 || response.status === 403
        ? "琴房的钥匙没有对上，请重新配对。"
        : message,
    );
  }
  return response;
}
export async function api<T>(
  path: string,
  body?: unknown,
  method = body === undefined ? "GET" : "POST",
): Promise<T> {
  const response = await request(path, {
    method,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  try {
    return await response.json();
  } catch {
    throw new Error("这一页还没有完整展开。请稍后再试。");
  }
}
const database = new Promise<IDBDatabase>((resolve, reject) => {
  const open = indexedDB.open("hajisaki-studio", 1);
  open.onupgradeneeded = () => open.result.createObjectStore("cache");
  open.onsuccess = () => resolve(open.result);
  open.onerror = () => reject(open.error);
});
export async function save(key: string, value: unknown) {
  const db = await database;
  return new Promise<void>((resolve, reject) => {
    const t = db.transaction("cache", "readwrite");
    t.objectStore("cache").put(value, key);
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
  });
}
export async function cached<T>(key: string, fallback: T): Promise<T> {
  const db = await database;
  return new Promise<T>((resolve, reject) => {
    const r = db.transaction("cache").objectStore("cache").get(key);
    r.onsuccess = () => resolve(r.result ?? fallback);
    r.onerror = () => reject(r.error);
  });
}
export function cacheKey(key: string) {
  return `${device || "unpaired"}:${key}`;
}
