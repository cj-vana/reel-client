' Display text, artwork choice and remote focus routing. The Scene and the interpreter tests share these.
function RKRuntimeText(seconds as dynamic) as string
    total = int(RKNumber(seconds))
    if total <= 0 then return ""
    if total < 60 then return str(total).trim() + "s"
    minutes = int((total + 30) / 60)
    hours = int(minutes / 60)
    minutes = minutes - hours * 60
    if hours = 0 then return str(minutes).trim() + "m"
    if minutes = 0 then return str(hours).trim() + "h"
    return str(hours).trim() + "h " + str(minutes).trim() + "m"
end function

function RKDurationSeconds(item as object) as double
    return RKNumber(item.RunTimeTicks) / 10000000.0
end function

function RKProgress(item as object) as double
    if not RKObject(item.UserData) then return 0.0#
    if item.UserData.Played = true then return 0.0#
    duration = RKDurationSeconds(item)
    position = RKNumber(item.UserData.PlaybackPositionTicks) / 10000000.0
    fraction = 0.0#
    if duration > 0 and position > 0 then fraction = position / duration
    if fraction <= 0 then fraction = RKNumber(item.UserData.PlayedPercentage) / 100.0
    if fraction < 0 then return 0.0#
    if fraction > 1 then return 1.0#
    return fraction
end function

function RKTimeLeftText(item as object, resume as double) as string
    remaining = RKDurationSeconds(item) - resume
    if remaining <= 0 then return ""
    return RKRuntimeText(remaining) + " left"
end function

function RKEpisodeCode(item as object) as string
    episode = item.IndexNumber
    season = item.ParentIndexNumber
    if episode = invalid then return ""
    code = "E" + str(int(RKNumber(episode))).trim()
    if season <> invalid then code = "S" + str(int(RKNumber(season))).trim() + " " + code
    return code
end function

function RKDisplayTitle(item as object) as string
    if RKString(item.Type) = "Episode" then return RKString(item.SeriesName, RKString(item.Name, "Untitled"))
    return RKString(item.Name, "Untitled")
end function

' Real media badges only; nothing is shown when the server reports no stream details.
function RKMediaBadges(item as object) as object
    badges = []
    if not RKArray(item.MediaSources) then return badges
    if item.MediaSources.count() = 0 then return badges
    source = item.MediaSources[0]
    if not RKObject(source) then return badges
    if not RKArray(source.MediaStreams) then return badges
    video = invalid
    audio = invalid
    captions = false
    for each stream in source.MediaStreams
        if RKObject(stream)
            kind = RKString(stream.Type)
            if kind = "Video" and video = invalid then video = stream
            if kind = "Audio" and audio = invalid then audio = stream
            if kind = "Subtitle" then captions = true
        end if
    end for
    if video <> invalid
        if RKNumber(video.Width) >= 3800 or RKNumber(video.Height) >= 2100 then badges.push("4K")
        range = lcase(RKString(video.VideoRangeType))
        if left(range, 4) = "dovi"
            badges.push("Dolby Vision")
        else if left(range, 3) = "hdr" or lcase(RKString(video.VideoRange)) = "hdr"
            badges.push("HDR")
        end if
    end if
    if audio <> invalid
        channels = RKNumber(audio.Channels)
        if channels >= 8
            badges.push("7.1")
        else if channels >= 6
            badges.push("5.1")
        end if
        if instr(1, lcase(RKString(audio.DisplayTitle) + " " + RKString(audio.Profile)), "atmos") > 0 then badges.push("Atmos")
    end if
    if captions then badges.push("CC")
    return badges
end function

' The community score out of ten with one decimal ("7.6", "8.0"), or "" when the server sends none.
function RKStarRating(item as object) as string
    score = RKNumber(item.CommunityRating)
    if score <= 0 or score > 10 then return ""
    tenths = int(score * 10 + 0.5)
    return str(int(tenths / 10)).trim() + "." + str(tenths mod 10).trim()
end function

' A title's facts for the meta row, in the order every Reel client uses: year (an episode's code and
' name instead), the boxed rating, runtime or "Series", the star score, then boxed media badges.
' Each part is {kind: "text" | "badge" | "star", text}.
function RKMetaParts(item as object) as object
    parts = []
    kind = RKString(item.Type)
    if kind = "Episode"
        code = RKEpisodeCode(item)
        if code <> "" then parts.push({kind: "text", text: code})
        if RKString(item.SeriesName) <> "" and RKString(item.Name) <> "" then parts.push({kind: "text", text: item.Name})
    else if item.ProductionYear <> invalid
        parts.push({kind: "text", text: str(int(RKNumber(item.ProductionYear))).trim()})
    end if
    if RKString(item.OfficialRating) <> "" then parts.push({kind: "badge", text: item.OfficialRating})
    if kind = "Series"
        parts.push({kind: "text", text: "Series"})
    else
        runtime = RKRuntimeText(RKDurationSeconds(item))
        if runtime <> "" then parts.push({kind: "text", text: runtime})
    end if
    stars = RKStarRating(item)
    if stars <> "" then parts.push({kind: "star", text: stars})
    for each badge in RKMediaBadges(item)
        parts.push({kind: "badge", text: badge})
    end for
    return parts
end function

' The muted line under a card. Shelves name an episode by code and title ("S1 E2 Manifest"); an episode
' list gives its runtime or time left, then "Watched" once played. Movies show time left, else the year.
function RKCardDetail(item as object, showCode as boolean) as string
    timeLeft = ""
    if RKProgress(item) > 0 and RKObject(item.UserData)
        timeLeft = RKTimeLeftText(item, RKNumber(item.UserData.PlaybackPositionTicks) / 10000000.0)
    end if
    if RKString(item.Type) = "Episode"
        if showCode then return (RKEpisodeCode(item) + " " + RKString(item.Name)).trim()
        parts = []
        if timeLeft = "" then timeLeft = RKRuntimeText(RKDurationSeconds(item))
        if timeLeft <> "" then parts.push(timeLeft)
        if RKPlayed(item) then parts.push("Watched")
        return parts.join("   ")
    end if
    if timeLeft <> "" then return timeLeft
    if item.ProductionYear <> invalid then return str(int(RKNumber(item.ProductionYear))).trim()
    return ""
end function

function RKPlayed(item as object) as boolean
    if not RKObject(item.UserData) then return false
    return item.UserData.Played = true
end function

' The small genre line above a title: one genre, and none for episodes.
function RKEyebrow(item as object) as string
    if RKString(item.Type) = "Episode" or not RKArray(item.Genres) then return ""
    for each genre in item.Genres
        if RKString(genre) <> "" then return RKString(genre)
    end for
    return ""
end function

' The heading of a page that failed to load names the problem, not the screen.
function RKErrorTitle(kind as string, expired as boolean) as string
    if expired then return "Sign in again"
    if kind = "home" then return "Could not load Home"
    if kind = "library" then return "Could not load your library"
    if kind = "search" then return "Could not search"
    if kind = "details" then return "Could not load this title"
    if kind = "seasons" then return "Could not load seasons"
    if kind = "episodes" then return "Could not load episodes"
    return "Could not reach the server"
end function

' Streaming quality presets, named as on the other clients. The Roku profile accepts 2 to 20 Mbps, so
' there is no "Original / auto" choice here.
function RKQualityPresets() as object
    dot = chr(183)
    return [{bitrate: 20000000, label: "High " + dot + " 20 Mbps"}, {bitrate: 8000000, label: "Balanced " + dot + " 8 Mbps"}, {bitrate: 2000000, label: "Data saver " + dot + " 2 Mbps"}]
end function

' A saved bitrate from before the presets keeps its plain value.
function RKQualityLabel(bitrate as dynamic) as string
    value = RKNumber(bitrate)
    for each preset in RKQualityPresets()
        if preset.bitrate = value then return preset.label
    end for
    return str(int(value / 1000000)).trim() + " Mbps"
end function

function RKEpisodeCaption(item as object) as string
    label = RKString(item.Name, "Episode")
    if item.IndexNumber <> invalid then label = str(int(RKNumber(item.IndexNumber))).trim() + ". " + label
    return label
end function

' Artwork route for a card shape. Landscape cards prefer stills and backdrops; posters prefer Primary.
function RKArtworkRoute(item as object, shape as string, width as integer) as string
    if RKString(item.reelAction) <> "" or RKString(item.Id) = "" then return ""
    query = "?maxWidth=" + str(width).trim() + "&quality=85"
    kind = RKString(item.Type)
    hasPrimary = false
    if RKObject(item.ImageTags) then hasPrimary = RKString(item.ImageTags.Primary) <> ""
    hasBackdrop = false
    if RKArray(item.BackdropImageTags) then hasBackdrop = item.BackdropImageTags.count() > 0
    if shape = "poster"
        if kind = "Episode" and RKString(item.SeriesId) <> "" then return "Items/" + RKEncode(item.SeriesId) + "/Images/Primary" + query
        return "Items/" + RKEncode(item.Id) + "/Images/Primary" + query
    end if
    if kind = "Episode" and hasPrimary then return "Items/" + RKEncode(item.Id) + "/Images/Primary" + query
    if hasBackdrop then return "Items/" + RKEncode(item.Id) + "/Images/Backdrop" + query
    parent = RKString(item.ParentBackdropItemId)
    if parent <> "" and RKArray(item.ParentBackdropImageTags)
        if item.ParentBackdropImageTags.count() > 0 then return "Items/" + RKEncode(parent) + "/Images/Backdrop" + query
    end if
    return "Items/" + RKEncode(item.Id) + "/Images/Primary" + query
end function

' Full-screen backdrop behind Home and Details. Empty when the server has no wide artwork.
function RKBackdropRoute(item as object) as string
    if RKString(item.reelAction) <> "" or RKString(item.Id) = "" then return ""
    query = "?maxWidth=1920&quality=80"
    if RKArray(item.BackdropImageTags)
        if item.BackdropImageTags.count() > 0 then return "Items/" + RKEncode(item.Id) + "/Images/Backdrop" + query
    end if
    parent = RKString(item.ParentBackdropItemId, RKString(item.SeriesId))
    if parent <> "" and RKArray(item.ParentBackdropImageTags)
        if item.ParentBackdropImageTags.count() > 0 then return "Items/" + RKEncode(parent) + "/Images/Backdrop" + query
    end if
    return ""
end function

function RKLogoRoute(item as object) as string
    if not RKObject(item.ImageTags) or RKString(item.Id) = "" then return ""
    if RKString(item.ImageTags.Logo) = "" then return ""
    return "Items/" + RKEncode(item.Id) + "/Images/Logo?maxWidth=720&quality=90"
end function

' Where a remote key that the focused list did not use should move focus.
' Areas: nav (top tabs), buttons (Details actions), rows (RowList), actions (vertical list).
' An empty result leaves focus where it is.
function RKFocusRoute(key as string, focus as string, state as object) as string
    if key = "up"
        if focus = "rows" and state.rowIndex = 0
            if state.buttonsVisible then return "buttons"
            if state.navVisible then return "nav"
        else if focus = "actions" and state.actionIndex = 0
            if state.navVisible then return "nav"
        else if focus = "buttons"
            if state.navVisible then return "nav"
        end if
    else if key = "down"
        if focus = "nav"
            if state.buttonsVisible then return "buttons"
            if state.rowsVisible then return "rows"
            if state.actionsVisible then return "actions"
        else if focus = "buttons"
            if state.rowsVisible then return "rows"
        end if
    end if
    return ""
end function

' Which top tab a view belongs to: Home, Movies, Series, Search, Settings.
function RKTabIndex(view as string, filter as string, current as integer) as integer
    if view = "home" then return 0
    if view = "library"
        if filter = "Movies" then return 1
        if filter = "Series" then return 2
        return current
    end if
    if view = "search" then return 3
    if view = "settings" or view = "connections" then return 4
    return current
end function

' Card geometry at 1920x1080, close to the Apple TV and web TV clients: four wide cards or eight posters
' across the 1728 px safe width. Posters are 2:3, wide cards 16:9. "label" is the band above a titled
' row: the label line plus "labelGap", the space RowList leaves between label and cards, which keeps
' the focused card's ring (up to 18 px above a poster at the 1.08 scale) clear of the label. "after"
' holds the card's title and detail line (always shown under landscape cards, on focus under posters),
' which end about 85 px under a focused card, plus 8 px before the next row. maxWidth is the artwork
' request, wide enough for the scaled card.
function RKShapeSpec(shape as string) as object
    if shape = "wide" then return {width: 384, height: 216, gap: 32, label: 72, after: 96, labelGap: 32, maxWidth: 480}
    if shape = "season" then return {width: 160, height: 240, gap: 24, label: 72, after: 96, labelGap: 32, maxWidth: 320}
    return {width: 192, height: 288, gap: 24, label: 72, after: 96, labelGap: 32, maxWidth: 320}
end function

' Where the title block, rows, buttons and lists sit on each kind of screen, as y positions and heights
' on an 8 px grid. -1 hides a line. x is the 96 px title-safe edge, except on "message" screens, which
' centre a 1120 px column. hero: Home and episode lists, with Play and Details under the overview.
' details: a series, its buttons and seasons. feature: a movie or episode, its title block set low
' over the artwork with the buttons near the bottom safe edge. All three put the genre eyebrow above
' a one-line title. grid: a short title over unlabelled poster rows. list: servers, settings.
' message: search, empty and failed pages.
function RKScreenLayout(mode as string) as object
    if mode = "hero" then return {title: 208, titleHeight: 80, titleLines: 1, meta: 296, genres: 176, description: 344, descriptionHeight: 72, descriptionLines: 2, rows: 536, buttons: 440, actions: 392}
    if mode = "details" then return {title: 208, titleHeight: 80, titleLines: 1, meta: 296, genres: 176, description: 344, descriptionHeight: 108, descriptionLines: 3, rows: 568, buttons: 472, actions: 392}
    if mode = "feature" then return {title: 632, titleHeight: 80, titleLines: 1, meta: 720, genres: 600, description: 768, descriptionHeight: 108, descriptionLines: 3, rows: 568, buttons: 904, actions: 392}
    if mode = "grid" then return {title: 176, titleHeight: 80, titleLines: 1, meta: 264, genres: -1, description: -1, descriptionHeight: 72, descriptionLines: 2, rows: 328, buttons: 544, actions: 392}
    if mode = "message" then return {title: 392, titleHeight: 80, titleLines: 1, meta: -1, genres: -1, description: 488, descriptionHeight: 72, descriptionLines: 2, rows: 320, buttons: 592, actions: 392}
    return {title: 176, titleHeight: 80, titleLines: 1, meta: 264, genres: -1, description: 304, descriptionHeight: 72, descriptionLines: 2, rows: 320, buttons: 544, actions: 392}
end function

' The column to land on when focus moves to another row: the one the viewer last used there,
' otherwise the card nearest to where focus was horizontally.
function RKLandingColumn(fromColumn as integer, fromShape as string, toShape as string, toCount as integer, remembered as dynamic) as integer
    if toCount <= 0 then return 0
    if remembered <> invalid
        if remembered >= 0 and remembered < toCount then return remembered
    end if
    from = RKShapeSpec(fromShape)
    target = RKShapeSpec(toShape)
    x = fromColumn * (from.width + from.gap) + from.width / 2
    column = int(x / (target.width + target.gap))
    if column < 0 then column = 0
    if column > toCount - 1 then column = toCount - 1
    return column
end function

' Where remote focus goes when a panel closes and nothing else claims it.
function RKRestoreArea(state as object) as string
    if state.buttonsVisible = true then return "buttons"
    if state.rowsVisible = true then return "rows"
    if state.actionsVisible = true then return "actions"
    return "nav"
end function
