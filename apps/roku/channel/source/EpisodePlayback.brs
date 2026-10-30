' Shared episode rules; native SceneGraph and the off-device interpreter use these.
function RKEpisodeItem(item as dynamic, seriesId as string) as boolean
    if not RKObject(item) or seriesId = "" then return false
    if RKString(item.Type) <> "Episode" or RKString(item.Id) = "" then return false
    return RKString(item.SeriesId, seriesId) = seriesId and item.IsMissing <> true
end function

' The season a series page's Episodes button opens: the one holding the next-up episode, matched by
' id and then by season number, else the first season. Invalid while no seasons have loaded.
function RKNextUpSeason(seasons as dynamic, episode as dynamic) as dynamic
    if not RKArray(seasons) then return invalid
    if seasons.count() = 0 then return invalid
    if RKObject(episode)
        for each season in seasons
            if RKString(season.Id) <> "" and RKString(season.Id) = RKString(episode.SeasonId) then return season
        end for
        if episode.ParentIndexNumber <> invalid
            for each season in seasons
                if season.IndexNumber <> invalid
                    if RKNumber(season.IndexNumber) = RKNumber(episode.ParentIndexNumber) then return season
                end if
            end for
        end if
    end if
    return seasons[0]
end function

function RKEpisodeNeighbors(items as dynamic, current as object) as object
    result = {previous: invalid, next: invalid}
    if not RKArray(items) or RKString(current.Type) <> "Episode" then return result
    seriesId = RKString(current.SeriesId)
    index = -1
    seen = {}
    for i = 0 to items.count() - 1
        episode = items[i]
        if not RKEpisodeItem(episode, seriesId) then return result
        if seen.doesExist(episode.Id) then return result
        seen[episode.Id] = true
        if episode.Id = RKString(current.Id) then index = i
    end for
    if index > 0 then result.previous = items[index - 1]
    if index >= 0 and index + 1 < items.count() then result.next = items[index + 1]
    return result
end function

function RKIntroTarget(items as dynamic, item as object, position as dynamic, offset as dynamic, streamDuration = invalid as dynamic) as double
    if not RKArray(items) then return -1.0#
    clock = RKNumber(position, -1)
    if clock < 0 then return -1.0#
    actualDuration = RKNumber(streamDuration, -1)
    if actualDuration <= 0 or actualDuration > 9007199254740991.0# then return -1.0#
    duration = RKNumber(item.RunTimeTicks) / 10000000.0
    limit = items.count()
    if limit > 1000 then limit = 1000
    for i = 0 to limit - 1
        segment = items[i]
        if RKObject(segment)
            if RKString(segment.Type) = "Intro" and RKString(segment.ItemId, RKString(item.Id)) = RKString(item.Id)
                first = RKNumber(segment.StartTicks, -1)
                last = RKNumber(segment.EndTicks, -1)
                if first >= 0 and last > first and last <= 9007199254740991.0#
                    start = first / 10000000.0
                    finish = last / 10000000.0
                    if (duration <= 0 or finish <= duration) and clock >= start and clock < finish
                        target = finish - RKNumber(offset)
                        if target >= 0 and target <= actualDuration then return target
                    end if
                end if
            end if
        end if
    end for
    return -1.0#
end function

function RKPlayerRequestMatches(source as dynamic, accountKey as string, generation as integer, epoch as integer) as boolean
    if not RKObject(source) then return false
    return RKString(source.accountKey) = accountKey and source.generation = generation and source.playerEpoch = epoch
end function

function RKAutoNextAllowed(reason as string, stopped as boolean, enabled as boolean, current as object, nextItem as dynamic, accountKey as string, ownerKey as string, cancelled = false as boolean) as boolean
    if cancelled or reason <> "finished" or not stopped or not enabled or accountKey <> ownerKey then return false
    if not RKEpisodeItem(nextItem, RKString(current.SeriesId)) then return false
    return RKString(current.Type) = "Episode" and nextItem.Id <> RKString(current.Id)
end function

function RKPlayerEndReason(state as string, pendingEpisodeId as string) as string
    if (state = "finished" or state = "error") and pendingEpisodeId <> "" then return "episode"
    return state
end function
