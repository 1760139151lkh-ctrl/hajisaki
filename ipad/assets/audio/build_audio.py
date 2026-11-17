"""Produce the iPad's original stereo room ambience and package shared cue masters.

This is an asset production entry point, not a test or playback utility.
Uses only Python's standard library; never opens an audio device.
"""
from __future__ import annotations

from array import array
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import sys
import wave

OUTPUT = Path(__file__).resolve().parent
ROOT = OUTPUT.parents[2]
RATE = 48_000
SECONDS = 30
FRAMES = RATE * SECONDS


def periodic_rain(seed: int) -> array:
    source = random.Random(seed)
    noise = array('f', (source.uniform(-1, 1) for _ in range(FRAMES)))
    filtered = array('f', [0]) * FRAMES
    previous = 0.0
    # The second pass starts with the first pass's terminal filter state,
    # so the repeated source has a continuous circular filter state.
    for pass_index in range(2):
        for index, sample in enumerate(noise):
            previous = 0.94 * previous + 0.06 * sample
            if pass_index:
                filtered[index] = previous
    return filtered


def add_note(target: array, start: float, frequency: float, gain: float) -> None:
    for sample in range(RATE * 5):
        t = sample / RATE
        attack = 1 - math.exp(-t * 100)
        envelope = math.exp(-t * 1.65) * (1 - t / 5) ** 2
        value = gain * attack * envelope * sum(
            math.sin(math.tau * frequency * partial * t) / partial ** 2.4
            for partial in range(1, 5)
        )
        target[(round(start * RATE) + sample) % FRAMES] += value


def describe(path: Path, source: str) -> dict:
    with wave.open(str(path), 'rb') as stream:
        count = stream.getnchannels()
        samples = array('h', stream.readframes(stream.getnframes()))
        if sys.byteorder != 'little':
            samples.byteswap()
        channels = [samples[channel::count] for channel in range(count)]
        return {
            'file': path.name, 'source': source,
            'sample_rate': stream.getframerate(), 'channels': count,
            'sample_width_bits': stream.getsampwidth() * 8,
            'frames': stream.getnframes(),
            'seconds': stream.getnframes() / stream.getframerate(),
            'channel_peak': [max(abs(value) for value in values) / 32768 for values in channels],
            'channel_rms': [math.sqrt(sum((value / 32768) ** 2 for value in values) / len(values)) for values in channels],
            'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        }


def main() -> None:
    assets = []
    for filename in ['send-felt-c6.wav', 'reply-major-nine.wav', 'effort-watch-click.wav']:
        source = ROOT / 'shared/assets/audio' / filename
        destination = OUTPUT / filename
        shutil.copyfile(source, destination)
        entry = describe(destination, 'byte-for-byte copy of shared/assets/audio/' + filename)
        entry['source_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
        assets.append(entry)

    left_rain = periodic_rain(711_049)
    right_rain = periodic_rain(711_053)
    piano = array('f', [0]) * FRAMES
    for start, notes in [(4.5, [261.626, 391.995]), (15.0, [293.665, 440.0]), (24.5, [329.628, 493.883])]:
        for frequency in notes:
            add_note(piano, start, frequency, 0.006)
            add_note(piano, start + 0.11, frequency, 0.0014)
            add_note(piano, start + 0.29, frequency, 0.0007)

    interleaved = array('h')
    reflection = round(RATE * 0.023)
    for index in range(FRAMES):
        # Fixed stereo placement: rain has greater left-channel energy;
        # damped harmonic notes have greater right-channel energy.
        left = 0.075 * left_rain[index] + 0.013 * right_rain[(index - reflection) % FRAMES] + 0.18 * piano[index]
        right = 0.018 * left_rain[(index - reflection) % FRAMES] + 0.031 * right_rain[index] + piano[index]
        interleaved.extend([round(max(-1, min(1, left)) * 32767), round(max(-1, min(1, right)) * 32767)])
    if sys.byteorder != 'little':
        interleaved.byteswap()
    ambience = OUTPUT / 'room-stereo.wav'
    with wave.open(str(ambience), 'wb') as stream:
        stream.setnchannels(2); stream.setsampwidth(2); stream.setframerate(RATE)
        stream.writeframes(interleaved.tobytes())
    assets.append(describe(ambience, 'original seeded filtered-noise and damped-harmonic synthesis by build_audio.py'))
    manifest = {
        'assets': assets, 'effects_default_enabled': False, 'ambience_default_enabled': False,
        'ambience': {'file': ambience.name, 'left': 'predominantly filtered rain',
                     'right': 'quieter rain with distant damped harmonic notes',
                     'loop': '30 second periodic synthesis', 'runtime_volume': 0.30},
        'limits': ['Stereo placement only; no head tracking or spatial-audio certification.',
                   'Synthesized harmonic voices, not a recording of an acoustic felt piano.',
                   'WAV structure and numeric levels are measured; listening and iPad latency remain unverified.'],
    }
    (OUTPUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'assets': len(assets), 'ambience_bytes': ambience.stat().st_size,
                      'ambience_channels': 2, 'ambience_seconds': SECONDS}, ensure_ascii=False))


if __name__ == '__main__':
    main()
