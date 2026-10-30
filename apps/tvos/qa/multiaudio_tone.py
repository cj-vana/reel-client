"""Measure a continuous decoded fixture tone, excluding codec edge priming."""
import math


def decoded_frequency(samples):
    sample_rate = 48_000
    if len(samples) < 95_000:
        raise ValueError("The actual decoded tone must cover nearly two seconds")
    trim = sample_rate // 4
    interior = samples[trim:-trim]
    crossings = [index for index, (left, right) in enumerate(zip(interior, interior[1:])) if left <= 0 < right]
    if len(crossings) < 3 or crossings[-1] - crossings[0] < sample_rate * 1.3:
        raise ValueError("Decoded signal does not contain a continuous interior tone")
    span = crossings[-1] - crossings[0]
    frequency = (len(crossings) - 1) * sample_rate / span
    intervals = [right - left for left, right in zip(crossings, crossings[1:])]
    period = sample_rate / frequency
    rms = math.sqrt(sum(float(sample) ** 2 for sample in interior) / len(interior))
    if rms < 100 or min(intervals) < period * 0.75 or max(intervals) > period * 1.25:
        raise ValueError("Decoded interior is silent, discontinuous or not the authored single tone")
    return {"decodedZeroCrossingHz": frequency, "decodedSamples": len(samples), "trimmedEdgeSamplesEach": trim,
            "interiorCrossings": len(crossings), "crossingSpanSamples": span,
            "minimumPeriodSamples": min(intervals), "maximumPeriodSamples": max(intervals), "interiorRMS": rms}
