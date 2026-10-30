"""Describe the generated TV sample's actual tagged AAC audio, not a product fallback."""
import copy

def native_audio_metadata(value):
    if isinstance(value, list):
        return [native_audio_metadata(item) for item in value]
    if not isinstance(value, dict):
        return value
    result = copy.deepcopy(value)
    if isinstance(result.get("Items"), list):
        result["Items"] = native_audio_metadata(result["Items"])
    for source in result.get("MediaSources", []):
        if not isinstance(source, dict):
            continue
        if "MediaStreams" not in source:
            index = 4 if str(source.get("Id", "")).endswith("-alternate") else 1
            source["MediaStreams"] = [{"Index": 0, "Type": "Video", "Codec": "h264"},
                {"Index": index, "Type": "Audio", "Codec": "aac", "Language": "eng", "DisplayTitle": "English · AAC synthetic tone", "Channels": 1, "SampleRate": 48000}]
            source["DefaultAudioStreamIndex"] = index
        else:
            for stream in source["MediaStreams"]:
                if isinstance(stream, dict) and stream.get("Type") == "Audio":
                    stream.update(Language="eng", Codec="aac", DisplayTitle="English · AAC synthetic tone", Channels=1, SampleRate=48000)
    return result
