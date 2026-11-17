import { createSHA256 } from "hash-wasm";
self.onmessage = async (event: MessageEvent<File>) => {
  try {
    const file = event.data;
    const hash = await createSHA256();
    hash.init();
    for (let offset = 0; offset < file.size; offset += 4 * 1024 * 1024) {
      hash.update(
        new Uint8Array(
          await file.slice(offset, offset + 4 * 1024 * 1024).arrayBuffer(),
        ),
      );
      self.postMessage({
        progress: Math.min(file.size, offset + 4 * 1024 * 1024),
        total: file.size,
      });
    }
    self.postMessage({ hash: hash.digest() });
  } catch (error) {
    self.postMessage({ error: String(error) });
  }
};
