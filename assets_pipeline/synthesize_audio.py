"""Create original, quiet PCM cues for HajiSaki; no external audio services."""
from __future__ import annotations

from array import array
import json
import math
from pathlib import Path
import random
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'shared' / 'assets' / 'audio'
RATE = 48000


def note(frequency: float, seconds: float, volume: float = 0.22) -> list[float]:
    result = []
    for sample in range(int(seconds * RATE)):
        t = sample / RATE
        attack = 1 - math.exp(-t * 330)
        tone = sum((0.64 / harmonic ** 2.1) * math.sin(2 * math.pi * frequency * harmonic * t)
                   * math.exp(-t * (3.6 + harmonic * 1.2)) for harmonic in range(1, 7))
        result.append(tone * attack * volume)
    return result


def mix(tracks: list[list[float]]) -> list[float]:
    result = [0.0] * max(map(len, tracks))
    for track in tracks:
        for index, value in enumerate(track):
            result[index] += value
    return result


def save(name: str, samples: list[float]) -> dict:
    data = array('h', (round(max(-1, min(1, value)) * 32767) for value in samples))
    if sys.byteorder != 'little':
        data.byteswap()
    path = OUTPUT / (name + '.wav')
    with wave.open(str(path), 'wb') as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(data.tobytes())
    return {'id': name, 'file': 'audio/' + path.name, 'sample_rate': RATE,
            'channels': 1, 'frames': len(samples), 'seconds': len(samples) / RATE,
            'peak': max(abs(value) for value in samples), 'bytes': path.stat().st_size,
            'source': 'original procedural synthesis'}


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    cues = [save('send-felt-c6', note(1046.502, 0.7)),
            save('reply-major-nine', mix([note(frequency, 1.35, 0.095)
                                          for frequency in [261.626, 329.628, 391.995, 493.883, 587.33]])),
            save('bookmark-chime', mix([note(1567.982, 0.9, 0.16), note(2093.005, 1.05, 0.07)]))]
    source = random.Random(53821)
    click = [(source.random() * 2 - 1) * 0.08 * math.exp(-index / (RATE * 0.006))
             for index in range(int(RATE * 0.045))]
    cues.append(save('effort-watch-click', click))
    rain, low = [], 0.0
    for index in range(RATE * 30):
        low = low * 0.92 + (source.random() * 2 - 1) * 0.08
        t = index / RATE
        # Low background level and a continuous periodic envelope for a gentle loop.
        envelope = 0.7 + 0.3 * math.sin(math.pi * t / 30) ** 2
        rain.append(low * envelope * 0.11)
    crossfade = RATE
    for index in range(crossfade):
        phase = index / crossfade
        blend = rain[index] * phase + rain[-crossfade + index] * (1 - phase)
        rain[index] = blend
    for start, frequencies in [(6, [261.626, 391.995]), (16, [293.665, 440.0]), (25, [329.628, 493.883])]:
        distant = mix([note(frequency, 2.0, 0.012) for frequency in frequencies])
        for index, value in enumerate(distant):
            rain[start * RATE + index] += value
    cues.append(save('piano-room-rain', rain))
    (OUTPUT / 'manifest.json').write_text(json.dumps({'assets': cues, 'default_volume': 0.35,
        'default_enabled': False, 'notes': 'Original soft harmonic cues, not recordings of an acoustic felt piano. No device sound/haptic timing claim.'},
        ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Created {len(cues)} original PCM assets in {OUTPUT}')


if __name__ == '__main__':
    main()
