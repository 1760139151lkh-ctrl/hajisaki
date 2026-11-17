/**
 * Incremental UTF-8 for the explicitly selected preview product. This class does
 * not select itself as a fallback and does not parse or normalize SSE framing.
 *
 * Replacement and continuation-byte rules follow the WHATWG Encoding Standard:
 * https://encoding.spec.whatwg.org/#utf-8-decoder
 * Leading-BOM handling follows TextDecoder's default ignoreBOM=false behavior:
 * https://encoding.spec.whatwg.org/#interface-textdecoder
 */
export class PreviewUtf8Decoder {
  private codePoint: number = 0;
  private bytesNeeded: number = 0;
  private bytesSeen: number = 0;
  private lowerBoundary: number = 0x80;
  private upperBoundary: number = 0xBF;
  private bomSeen: boolean = false;
  private newStream: boolean = true;
  private malformed: boolean = false;

  get hadError():boolean { return this.malformed; }

  /**
   * stream=true retains an incomplete scalar for the next call. stream=false
   * finishes this logical stream and replaces any remaining valid prefix once.
   * A subsequent call starts a new stream, including fresh initial-BOM handling.
   */
  decode(input: Uint8Array, stream: boolean = true): string {
    if (this.newStream) {
      this.resetSequence();
      this.bomSeen = false;
      this.newStream = false;
      this.malformed = false;
    }
    const output: string[] = [];
    let index = 0;
    while (index < input.length) {
      const byte = input[index];
      if (this.bytesNeeded === 0) {
        index++;
        if (byte <= 0x7F) {
          this.append(byte, output);
        } else if (byte >= 0xC2 && byte <= 0xDF) {
          this.bytesNeeded = 1;
          this.codePoint = byte & 0x1F;
        } else if (byte >= 0xE0 && byte <= 0xEF) {
          if (byte === 0xE0) this.lowerBoundary = 0xA0;
          if (byte === 0xED) this.upperBoundary = 0x9F;
          this.bytesNeeded = 2;
          this.codePoint = byte & 0x0F;
        } else if (byte >= 0xF0 && byte <= 0xF4) {
          if (byte === 0xF0) this.lowerBoundary = 0x90;
          if (byte === 0xF4) this.upperBoundary = 0x8F;
          this.bytesNeeded = 3;
          this.codePoint = byte & 0x07;
        } else {
          this.malformed = true;
          this.append(0xFFFD, output);
        }
        continue;
      }

      if (byte < this.lowerBoundary || byte > this.upperBoundary) {
        this.malformed = true;
        this.resetSequence();
        this.append(0xFFFD, output);
        // Do not consume this byte: it may be ASCII or the lead of another
        // valid scalar, and must be processed again in the initial state.
        continue;
      }

      index++;
      this.lowerBoundary = 0x80;
      this.upperBoundary = 0xBF;
      this.codePoint = (this.codePoint << 6) | (byte & 0x3F);
      this.bytesSeen++;
      if (this.bytesSeen === this.bytesNeeded) {
        const scalar = this.codePoint;
        this.resetSequence();
        this.append(scalar, output);
      }
    }

    if (!stream) {
      if (this.bytesNeeded !== 0) { this.malformed = true; this.append(0xFFFD, output); }
      this.resetSequence();
      this.newStream = true;
    }
    return output.join('');
  }

  private resetSequence(): void {
    this.codePoint = 0;
    this.bytesNeeded = 0;
    this.bytesSeen = 0;
    this.lowerBoundary = 0x80;
    this.upperBoundary = 0xBF;
  }

  private append(scalar: number, output: string[]): void {
    if (!this.bomSeen) {
      this.bomSeen = true;
      if (scalar === 0xFEFF) return;
    }
    if (scalar <= 0xFFFF) {
      output.push(String.fromCharCode(scalar));
    } else {
      const supplementary = scalar - 0x10000;
      output.push(String.fromCharCode(0xD800 + (supplementary >> 10), 0xDC00 + (supplementary & 0x3FF)));
    }
  }
}
