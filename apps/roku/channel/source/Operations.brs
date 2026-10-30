function fetch(r as object, route as string, query = invalid as dynamic, method = "GET" as string, body = invalid as dynamic) as object
    return m.transport.send(RKRequest(r.account, r.device, route, query, method, body))
end function

function page(r as object, route as string, query as object) as object
    result = fetch(r, route, query)
    if not result.ok then return result
    if not RKObject(result.data) then return RKError("The server returned an invalid collection.")
    if not RKArray(result.data.Items) then return RKError("The server returned an invalid collection.")
    return {ok: true, items: RKItems(result.data), total: RKNumber(result.data.TotalRecordCount), received: result.data.Items.count()}
end function

function perform(r as object) as object
    kind = r.kind
    if kind = "loadMetadata"
        return RKRegistryDecode(m.storage.read())
    else if kind = "saveMetadata"
        current = RKRegistryDecode(m.storage.read())
        if current.state = "read-failed" then return RKError(current.error)
        if not current.canSave and r.reset <> true then return RKError(current.error + " Open Servers for storage recovery.")
        return m.storage.write(FormatJson(RKMetadata(r.accounts, r.device)))
    else if kind = "auth"
        info = fetch(r, "System/Info/Public")
        if not info.ok then return info
        auth = fetch(r, "Users/AuthenticateByName", invalid, "POST", {Username: r.username, Pw: r.password})
        r.password = ""
        if not auth.ok then return auth
        return RKAuthResponse(r.account.server, r.username, auth.data, info.data)
    else if kind = "home"
        rows = []
        failures = []
        endpoints = [
            {title: "Continue watching", shape: "wide", route: "UserItems/Resume", query: {userId: r.account.userId, limit: 18, mediaTypes: "Video", fields: "Overview,Genres", enableUserData: true}},
            {title: "Up next", shape: "wide", route: "Shows/NextUp", query: {userId: r.account.userId, limit: 18, fields: "Overview,Genres", enableUserData: true}},
            {title: "Recently added movies", browse: "Movies", route: "Items/Latest", query: {userId: r.account.userId, limit: 18, includeItemTypes: "Movie", fields: "Overview,Genres", enableUserData: true}},
            {title: "New episodes", shape: "wide", browse: "Episodes", route: "Items/Latest", query: {userId: r.account.userId, limit: 18, includeItemTypes: "Episode", groupItems: false, fields: "Overview,Genres", enableUserData: true}},
            {title: "Recently added series", browse: "Series", route: "Items/Latest", query: {userId: r.account.userId, limit: 18, includeItemTypes: "Series", fields: "Overview,Genres", enableUserData: true}}
        ]
        envelopes = []
        for each endpoint in endpoints
            envelopes.push(RKRequest(r.account, r.device, endpoint.route, endpoint.query))
        end for
        responses = m.transport.batch(envelopes)
        for i = 0 to endpoints.count() - 1
            endpoint = endpoints[i]
            response = responses[i]
            if response.ok
                valid = RKArray(response.data)
                if RKObject(response.data) then valid = RKArray(response.data.Items)
                if not valid then return RKError("The server returned an invalid Home collection.")
                items = RKItems(response.data)
                if items.count() > 0
                    if RKString(endpoint.browse) <> "" then items.push({Id: "__browse_" + endpoint.browse, Name: "See all " + lcase(endpoint.browse), reelAction: "browse", filter: endpoint.browse})
                    rows.push({title: endpoint.title, shape: RKString(endpoint.shape, "poster"), items: items})
                end if
            else
                if response.expired = true then return response
                failures.push(endpoint.title)
            end if
        end for
        if rows.count() = 0 and failures.count() = endpoints.count() then return RKError("Check your connection, then choose Retry.")
        return {ok: true, rows: rows, failures: failures}
    else if kind = "library" or kind = "search"
        return page(r, "Items", RKLibraryQuery(r.account, r.options))
    else if kind = "details" or kind = "playerDetail"
        response = fetch(r, "Items/" + RKEncode(r.itemId), {userId: r.account.userId, fields: "Overview,Genres,MediaSources", enableUserData: true})
        if not response.ok then return response
        if not RKObject(response.data) then return RKError("The server returned invalid details.")
        if RKString(response.data.Id) <> r.itemId then return RKError("The server returned a different title.")
        if kind = "playerDetail" or RKString(response.data.Type) <> "Series" then return {ok: true, item: response.data}
        ' A series leads with its next-up episode. Some servers ignore seriesId, so the episode must belong
        ' to this series; without one, or if the request fails, the series page leads with Seasons.
        nextUp = invalid
        upcoming = fetch(r, "Shows/NextUp", {userId: r.account.userId, seriesId: r.itemId, limit: 1, fields: "Overview,Genres,MediaSources", enableUserData: true})
        if upcoming.ok and RKObject(upcoming.data)
            if RKArray(upcoming.data.Items)
                for each episode in upcoming.data.Items
                    if nextUp = invalid and RKEpisodeItem(episode, r.itemId) then nextUp = episode
                end for
            end if
        end if
        return {ok: true, item: response.data, nextUp: nextUp}
    else if kind = "seasons" or kind = "playerSeasons"
        return page(r, "Shows/" + RKEncode(r.itemId) + "/Seasons", {userId: r.account.userId, fields: "Overview", enableUserData: true})
    else if kind = "episodes" or kind = "playerEpisodes"
        return page(r, "Shows/" + RKEncode(r.seriesId) + "/Episodes", {userId: r.account.userId, seasonId: r.itemId, fields: "Overview", enableUserData: true, isMissing: false, startIndex: int(RKNumber(r.start)), limit: 60})
    else if kind = "playerContext"
        response = fetch(r, "Shows/" + RKEncode(r.item.SeriesId) + "/Episodes", {userId: r.account.userId, adjacentTo: r.item.Id, isMissing: false, fields: "Overview", enableUserData: true})
        if not response.ok then return response
        if not RKObject(response.data) then return RKError("The episode order could not be read.")
        neighbors = RKEpisodeNeighbors(response.data.Items, r.item)
        return {ok: true, previous: neighbors.previous, next: neighbors.next}
    else if kind = "playerIntro"
        response = fetch(r, "MediaSegments/" + RKEncode(r.itemId), {includeSegmentTypes: "Intro"})
        if not response.ok then return response
        if not RKObject(response.data) then return RKError("Intro timing is unavailable.")
        if not RKArray(response.data.Items) then return RKError("Intro timing is unavailable.")
        return {ok: true, segments: response.data.Items}
    else if kind = "playback"
        response = fetch(r, "Items/" + RKEncode(r.item.Id) + "/PlaybackInfo", invalid, "POST", RKPlaybackBody(r.account, r.options))
        if not response.ok then return response
        return RKPlaybackPlan(r.account, r.item, response.data, r.options, r.device)
    else if kind = "report"
        return m.transport.send(RKReport(r.account, r.plan, r.event, r.position, r.paused, r.device))
    else if kind = "cleanup"
        if RKAccountKey(r.account) <> r.plan.accountKey then return RKError("Cleanup connection mismatch.")
        if RKString(r.plan.sessionId) = "" then return RKError("Cleanup requires its playback session.")
        return fetch(r, "Videos/ActiveEncodings", {deviceId: r.device, playSessionId: r.plan.sessionId}, "DELETE")
    else if kind = "logout"
        return fetch(r, "Sessions/Logout", invalid, "POST")
    end if
    return RKError("This operation is not supported.")
end function
