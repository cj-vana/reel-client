"""Pure controls for the fixed, owned multi-audible provider only."""
CONTROLS = frozenset({'failNextMaster', 'failNextVideo', 'unresolvableAudio', 'changedSource', 'detailsSubtitleDefault', 'negotiatedSubtitleEnabled', 'encodedSubtitlePlan', 'omittedSubtitleDefault', 'conflictingSubtitlePlan'})


def controls(body):
    if not isinstance(body, dict) or not set(body).issubset(CONTROLS) or any(type(v) is not bool for v in body.values()):
        raise ValueError('Invalid owned audio control')
    return dict(body)


def apply(response, settings, sequence, failed_masters, failed_videos):
    if settings.pop('failNextMaster', False):
        failed_masters.append(sequence)
    if settings.pop('failNextVideo', False):
        failed_videos.append(sequence)
    if settings.get('unresolvableAudio', False):
        for stream in response['MediaSources'][0]['MediaStreams']:
            if stream['Type'] == 'Audio':
                stream.update(Language='eng', DisplayTitle='Ambiguous synthetic audio', Title='Ambiguous synthetic audio')

    if settings.pop('changedSource', False):
        response['MediaSources'][0]['Id'] = 'movie-1-different-version'
    if settings.pop('negotiatedSubtitleEnabled', False):
        response['MediaSources'][0]['DefaultSubtitleStreamIndex'] = 2

    if settings.pop('encodedSubtitlePlan', False):
        response['MediaSources'][0]['TranscodingUrl'] += '?SubtitleStreamIndex=2&SubtitleMethod=Encode'
    if settings.pop('conflictingSubtitlePlan', False):
        path = response['MediaSources'][0]['TranscodingUrl'].split('?', 1)[0]
        response['MediaSources'][0]['TranscodingUrl'] = path + '?SubtitleStreamIndex=-1&subtitlestreamindex=2&SubtitleMethod=Hls'
    if settings.pop('omittedSubtitleDefault', False):
        response['MediaSources'][0].pop('DefaultSubtitleStreamIndex', None)
