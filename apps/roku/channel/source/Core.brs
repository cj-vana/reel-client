' Shared logic: used by the SceneGraph channel and the non-Roku interpreter tests.
function RKString(value as dynamic, fallback = "" as string) as string
    if type(value) = "String" or type(value) = "roString" then return value
    return fallback
end function

function RKObject(value as dynamic) as boolean
    return type(value) = "roAssociativeArray"
end function

function RKArray(value as dynamic) as boolean
    return type(value) = "roArray"
end function

function RKNumber(value as dynamic, fallback = 0 as double) as double
    t = type(value)
    if t = "Integer" or t = "roInt" or t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble" or t = "LongInteger" or t = "roLongInteger"
        if value = value then return value * 1.0#
    end if
    return fallback * 1.0#
end function

function RKError(description as string) as object
    return {ok: false, error: description}
end function

function RKLocalHost(host as string) as boolean
    if host = "localhost" or host = "[::1]" then return true
    if right(host, 6) = ".local" or right(host, 7) = ".ts.net" then return true
    parts = host.split(".")
    if parts.count() <> 4 then return false
    octets = []
    for each part in parts
        if not CreateObject("roRegex", "^[0-9]{1,3}$", "").isMatch(part) then return false
        n = val(part)
        if n > 255 then return false
        octets.push(n)
    end for
    if octets[0] = 10 or octets[0] = 127 then return true
    if octets[0] = 192 and octets[1] = 168 then return true
    if octets[0] = 172 and octets[1] >= 16 and octets[1] <= 31 then return true
    return octets[0] = 100 and octets[1] >= 64 and octets[1] <= 127
end function

function RKNormalizeServer(input as dynamic) as object
    value = RKString(input).trim()
    if len(value) > 512 then return RKError("The server address is too long.")
    match = CreateObject("roRegex", "^(https?)://([^/?#]+)(/[^?#]*)?$", "i").match(value)
    if match.count() = 0 then return RKError("Enter a complete Jellyfin address, including https://.")
    scheme = lcase(match[1])
    authority = lcase(match[2])
    path = ""
    if match.count() > 3 then path = match[3]
    if instr(1, authority, "@") > 0 or instr(1, authority, "\") > 0 then return RKError("Remove the username or password from the address.")
    host = authority
    port = ""
    if left(authority, 1) = "["
        close = instr(1, authority, "]")
        if close = 0 then return RKError("The IPv6 address needs closing brackets.")
        host = left(authority, close)
        if not CreateObject("roRegex", "^\[[0-9a-f:]+\]$", "i").isMatch(host) then return RKError("The server host is not valid.")
        suffix = mid(authority, close + 1)
        if suffix <> ""
            if left(suffix, 1) <> ":" then return RKError("The server port is not valid.")
            port = mid(suffix, 2)
        end if
    else
        if not CreateObject("roRegex", "^[a-z0-9.-]+(:[0-9]{1,5})?$", "").isMatch(authority) then return RKError("The server host is not valid.")
        colon = instr(1, authority, ":")
        if colon > 0
            host = left(authority, colon - 1)
            port = mid(authority, colon + 1)
        end if
        if left(host, 1) = "." or right(host, 1) = "." or instr(1, host, "..") > 0 then return RKError("The server host is not valid.")
    end if
    if port <> ""
        if not CreateObject("roRegex", "^[0-9]{1,5}$", "").isMatch(port) then return RKError("The server port is not valid.")
        if val(port) < 1 or val(port) > 65535 then return RKError("The server port is not valid.")
    else if right(authority, 1) = ":"
        return RKError("The server port is not valid.")
    end if
    if scheme = "http" and not RKLocalHost(host) then return RKError("Remote connections require HTTPS. Local HTTP needs a trusted network.")
    if not CreateObject("roRegex", "^[/a-zA-Z0-9._~-]*$", "").isMatch(path) then return RKError("Use a server base path without encoded characters, queries or fragments.")
    if instr(1, path, "..") > 0 or instr(1, path, "//") > 0 then return RKError("The server base path is not valid.")
    while right(path, 1) = "/" and len(path) > 0
        path = left(path, len(path) - 1)
    end while
    if port = "443" and scheme = "https" then authority = host
    if port = "80" and scheme = "http" then authority = host
    origin = scheme + "://" + authority
    return {ok: true, url: origin + path, origin: origin, path: path, host: host, insecure: scheme = "http"}
end function

function RKEncode(input as dynamic) as string
    value = RKString(input)
    return value.escape()
end function

function RKScopedURL(server as string, resource as dynamic) as object
    base = RKNormalizeServer(server)
    if not base.ok then return base
    path = RKString(resource)
    if path = "" or len(path) > 8192 then return RKError("The server returned an invalid resource.")
    if instr(1, path, "\") > 0 or instr(1, path, "#") > 0 or instr(1, path, chr(10)) > 0 or instr(1, path, chr(13)) > 0 then return RKError("The server returned an unsafe resource.")
    lower = lcase(path)
    if instr(1, lower, "%2e") > 0 or instr(1, lower, "%2f") > 0 or instr(1, lower, "%5c") > 0 or instr(1, lower, "%25") > 0 then return RKError("Encoded resource traversal was refused.")
    if left(path, 2) = "//" then return RKError("A resource outside this connection was refused.")
    absolute = instr(1, lower, "://") > 0
    if absolute
        prefix = base.origin
        if left(lcase(path), len(prefix) + 1) <> prefix + "/" then return RKError("A resource outside this connection was refused.")
        path = mid(path, len(prefix) + 1)
    else if CreateObject("roRegex", "^[a-z][a-z0-9+.-]*:", "i").isMatch(path)
        return RKError("Only this Jellyfin connection can provide resources.")
    end if
    q = instr(1, path, "?")
    pathname = path
    query = ""
    if q > 0
        pathname = left(path, q - 1)
        query = mid(path, q)
    end if
    for each part in pathname.split("/")
        if part = "." or part = ".." then return RKError("Resource traversal was refused.")
    end for
    if left(pathname, 1) <> "/" then pathname = "/" + pathname
    root = base.path
    if root <> "" and pathname <> root and left(pathname, len(root) + 1) <> root + "/"
        if absolute then return RKError("A resource outside the server base path was refused.")
        pathname = root + pathname
    end if
    return {ok: true, url: base.origin + pathname + query}
end function

function RKQuery(values as object) as string
    parts = []
    for each key in values
        value = values[key]
        if value <> invalid
            text = RKString(value)
            if type(value) = "Boolean" or type(value) = "roBoolean"
                if value then text = "true" else text = "false"
            else if text = ""
                text = str(value).trim()
            end if
            parts.push(RKEncode(key) + "=" + RKEncode(text))
        end if
    end for
    return parts.join("&")
end function

function RKHeader(input as dynamic) as string
    return CreateObject("roRegex", "[" + chr(34) + "\\\x00-\x1f\x7f]", "").replaceAll(RKString(input), "")
end function

function RKAuthorization(account as object, device as string) as string
    value = "MediaBrowser Client=" + chr(34) + "Reel Roku" + chr(34) + ", Device=" + chr(34) + "Roku" + chr(34) + ", DeviceId=" + chr(34) + RKHeader(device) + chr(34) + ", Version=" + chr(34) + "0.1.0" + chr(34)
    if RKString(account.token) <> "" then value += ", Token=" + chr(34) + RKHeader(account.token) + chr(34)
    return value
end function

function RKAccountKey(account as object) as string
    return RKString(account.server) + "|" + RKString(account.userId)
end function

function RKCanWrite(account as object, method as string, route as string) as boolean
    if method = "GET" or method = "HEAD" then return true
    path = lcase(route.split("?")[0])
    if path = "users/authenticatebyname" or path = "sessions/logout" then return method = "POST"
    if path = "videos/activeencodings" then return method = "DELETE"
    if CreateObject("roRegex", "^items/[a-zA-Z0-9_-]+/playbackinfo$", "").isMatch(path) then return method = "POST"
    if path = "sessions/playing" or path = "sessions/playing/progress" or path = "sessions/playing/stopped"
        return method = "POST" and account.history = true
    end if
    return false
end function

function RKRequest(account as object, device as string, route as string, query = invalid as dynamic, method = "GET" as string, body = invalid as dynamic) as object
    if not RKCanWrite(account, method, route) then return RKError("Private playback prevents this server change.")
    if lcase(route) = "videos/activeencodings"
        if not RKObject(query) then return RKError("Cleanup requires its playback session.")
        if RKString(query.playSessionId) = "" or RKString(query.deviceId) = "" then return RKError("Cleanup requires its playback session.")
    end if
    url = RKScopedURL(RKString(account.server), route)
    if not url.ok then return url
    if query <> invalid
        encoded = RKQuery(query)
        if encoded <> ""
            separator = "?"
            if instr(1, url.url, "?") > 0 then separator = "&"
            url.url += separator + encoded
        end if
    end if
    return {ok: true, url: url.url, method: method, body: body, headers: {Authorization: RKAuthorization(account, device), Accept: "application/json"}, accountKey: RKAccountKey(account)}
end function

function RKAuthResponse(server as string, username as string, auth as dynamic, info as dynamic) as object
    if not RKObject(auth) then return RKError("Jellyfin returned an invalid sign-in.")
    if RKString(auth.AccessToken) = "" or not RKObject(auth.User) then return RKError("Jellyfin returned an invalid sign-in.")
    if RKString(auth.User.Id) = "" or RKString(auth.User.Name) = "" then return RKError("Jellyfin returned an invalid account.")
    name = "Jellyfin"
    if RKObject(info) then name = RKString(info.ServerName, name)
    ' A new account sends watch progress until Private viewing is turned on; a saved account keeps its own choice.
    return {ok: true, account: {server: server, username: username, userId: auth.User.Id, name: auth.User.Name, serverName: name, token: auth.AccessToken, history: true}}
end function

function RKMetadata(accounts as object, device as string) as object
    result = []
    for each account in accounts
        base = RKNormalizeServer(account.server)
        if base.ok
            result.push({server: base.url, username: RKString(account.username), name: RKString(account.name), serverName: RKString(account.serverName), userId: RKString(account.userId), history: account.history = true, autoNext: account.autoNext <> false, bitrate: RKNumber(account.bitrate, 20000000)})
        end if
    end for
    return {version: 1, device: device, accounts: result}
end function

function RKRestore(input as dynamic) as object
    result = {accounts: [], device: ""}
    if not RKObject(input) then return result
    result.device = RKString(input.device)
    if not RKArray(input.accounts) then return result
    seen = {}
    for each account in input.accounts
        if RKObject(account)
            if result.accounts.count() < 8
                base = RKNormalizeServer(account.server)
                if base.ok and RKString(account.userId) <> ""
                    key = base.url + "|" + account.userId
                    if not seen.doesExist(key)
                        seen[key] = true
                        result.accounts.push({server: base.url, username: RKString(account.username), name: RKString(account.name), serverName: RKString(account.serverName), userId: account.userId, token: "", history: account.history = true, autoNext: account.autoNext <> false, bitrate: RKNumber(account.bitrate, 20000000)})
                    end if
                end if
            end if
        end if
    end for
    return result
end function

function RKItems(input as dynamic) as object
    source = input
    if RKObject(input) then source = input.Items
    result = []
    if not RKArray(source) then return result
    seen = {}
    for each item in source
        if RKObject(item)
            if RKString(item.Id) <> "" and not seen.doesExist(item.Id)
                seen[item.Id] = true
                result.push(item)
            end if
        end if
    end for
    return result
end function

function RKAppendItems(existing as object, pageItems as object) as object
    all = []
    for each item in existing
        all.push(item)
    end for
    for each item in pageItems
        all.push(item)
    end for
    return RKItems(all)
end function

function RKLibraryQuery(account as object, options as object) as object
    kind = "Movie,Series"
    if RKString(options.filter) = "Movies" then kind = "Movie"
    if RKString(options.filter) = "Series" then kind = "Series"
    if RKString(options.filter) = "Episodes" then kind = "Episode"
    sort = "SortName"
    order = "Ascending"
    if RKString(options.sort) = "Recently added"
        sort = "DateCreated"
        order = "Descending"
    else if RKString(options.sort) = "Year"
        sort = "ProductionYear"
        order = "Descending"
    end if
    start = int(RKNumber(options.start))
    if start < 0 then start = 0
    if start > 1000000 then start = 1000000
    query = {userId: account.userId, recursive: true, includeItemTypes: kind, fields: "Overview,Genres", enableUserData: true, startIndex: start, limit: 60, sortBy: sort, sortOrder: order}
    search = RKString(options.search).trim()
    if search <> ""
        query["searchTerm"] = search
        query["includeItemTypes"] = "Movie,Series,Episode"
    end if
    return query
end function

function RKResume(item as object) as double
    seconds = 0.0
    if RKObject(item.UserData) then seconds = RKNumber(item.UserData.PlaybackPositionTicks) / 10000000.0
    duration = RKNumber(item.RunTimeTicks) / 10000000.0
    if seconds < 0 then seconds = 0
    if duration > 0 and seconds >= duration - 10 then seconds = 0
    if seconds > 604800 then seconds = 0
    return seconds * 1.0#
end function

function RKSafeStart(value as dynamic) as double
    seconds = RKNumber(value)
    if seconds < 0 or seconds > 604800 then return 0.0#
    return seconds
end function

function RKTickString(value as dynamic) as string
    seconds = RKSafeStart(value)
    whole = int(seconds)
    fraction = int((seconds - whole) * 10000000.0)
    return str(whole).trim() + right("0000000" + str(fraction).trim(), 7)
end function

function RKPlaybackRoute(resource as string, start as dynamic, sessionId as string) as string
    route = RKStripCredentials(resource)
    q = instr(1, route, "?")
    pathname = route
    parts = []
    if q > 0
        pathname = left(route, q - 1)
        for each part in mid(route, q + 1).split("&")
            key = lcase(part.split("=")[0].unescape())
            if key <> "starttimeticks" and key <> "playsessionid" then parts.push(part)
        end for
    end if
    parts.push("StartTimeTicks=" + RKTickString(start))
    parts.push("PlaySessionId=" + RKEncode(sessionId))
    return pathname + "?" + parts.join("&")
end function

function RKPlaybackBody(account as object, options as object) as object
    bitrate = RKNumber(options.bitrate, 20000000)
    if bitrate < 1000000 or bitrate > 40000000 then bitrate = 20000000
    force = options.forceHLS = true
    body = {UserId: account.userId, MaxStreamingBitrate: bitrate, StartTimeTicks: RKSafeStart(options.start) * 10000000.0, EnableDirectPlay: not force, EnableDirectStream: false, EnableTranscoding: true, AllowVideoStreamCopy: false, AllowAudioStreamCopy: false, AutoOpenLiveStream: false}
    body["DeviceProfile"] = {Name: "Reel Roku conservative", MaxStreamingBitrate: bitrate, DirectPlayProfiles: [{Type: "Video", Container: "mp4,m4v", VideoCodec: "h264", AudioCodec: "aac"}], TranscodingProfiles: [{Type: "Video", Context: "Streaming", Protocol: "hls", Container: "ts", VideoCodec: "h264", AudioCodec: "aac", MaxAudioChannels: "2", MinSegments: 2, SegmentLength: 4, EnableSubtitlesInManifest: true}], SubtitleProfiles: [{Format: "vtt", Method: "Hls"}, {Format: "srt", Method: "Encode"}, {Format: "ass", Method: "Encode"}, {Format: "pgssub", Method: "Encode"}]}
    if RKString(options.source) <> "" then body["MediaSourceId"] = options.source
    if options.audio <> invalid
        body["AudioStreamIndex"] = options.audio
        body["EnableDirectPlay"] = false
    end if
    if options.subtitle <> invalid
        body["SubtitleStreamIndex"] = options.subtitle
        body["EnableDirectPlay"] = false
    end if
    return body
end function

function RKStripCredentials(resource as string) as string
    q = instr(1, resource, "?")
    if q = 0 then return resource
    parts = []
    for each part in mid(resource, q + 1).split("&")
        key = lcase(part.split("=")[0].unescape())
        if key <> "api_key" and key <> "apikey" and key <> "token" and key <> "access_token" then parts.push(part)
    end for
    result = left(resource, q - 1)
    if parts.count() > 0 then result += "?" + parts.join("&")
    return result
end function

function RKPlaybackPlan(account as object, item as object, info as dynamic, options as object, device as string) as object
    if not RKObject(info) then return RKError("Jellyfin did not prepare this video.")
    if RKString(info.PlaySessionId) = "" then return RKError("The server did not return a playback session.")
    if not RKArray(info.MediaSources) then return RKError("The server did not return a playable source.")
    for each source in info.MediaSources
        if RKObject(source)
            selectedSource = RKString(options.source)
            if RKString(source.Id) <> "" and (selectedSource = "" or selectedSource = source.Id)
                route = ""
                format = "hls"
                method = "Transcode"
                offset = RKSafeStart(options.start)
                playStart = 0.0
                if source.SupportsDirectPlay = true and options.forceHLS <> true and options.audio = invalid and options.subtitle = invalid
                    route = "Videos/" + RKEncode(item.Id) + "/stream?" + RKQuery({static: true, mediaSourceId: source.Id, playSessionId: info.PlaySessionId, deviceId: device})
                    format = "mp4"
                    method = "DirectPlay"
                    playStart = offset
                    offset = 0
                else if RKString(source.TranscodingUrl) <> ""
                    route = RKPlaybackRoute(source.TranscodingUrl, offset, info.PlaySessionId)
                end if
                if route <> ""
                    url = RKScopedURL(account.server, route)
                    if not url.ok then return url
                    return {ok: true, url: url.url, format: format, method: method, sourceId: source.Id, sessionId: info.PlaySessionId, accountKey: RKAccountKey(account), itemId: item.Id, playStart: playStart, offset: offset, title: RKString(item.Name, "Video"), history: account.history = true}
                end if
            end if
        end if
    end for
    return RKError("No compatible MP4 or HLS stream was available.")
end function

function RKReport(account as object, plan as object, event as string, position as dynamic, paused as boolean, device as string) as object
    if account.history <> true or RKAccountKey(account) <> RKString(plan.accountKey) then return RKError("Private playback does not report history.")
    route = "Sessions/Playing"
    if event = "progress" then route += "/Progress"
    if event = "stopped" then route += "/Stopped"
    if event <> "start" and event <> "progress" and event <> "stopped" then return RKError("Unknown playback event.")
    seconds = RKNumber(position) + RKNumber(plan.offset)
    if seconds < 0 then seconds = 0
    return RKRequest(account, device, route, invalid, "POST", {ItemId: plan.itemId, MediaSourceId: plan.sourceId, PlaySessionId: plan.sessionId, PositionTicks: seconds * 10000000.0, IsPaused: paused, CanSeek: true, PlayMethod: plan.method})
end function

function RKResultMatches(envelope as object, currentKey as string, generation as integer, nonce as integer) as boolean
    return RKString(envelope.accountKey) = currentKey and envelope.generation = generation and envelope.nonce = nonce
end function

function RKCopyAccount(account as object) as object
    return {server: RKString(account.server), userId: RKString(account.userId), username: RKString(account.username), name: RKString(account.name), serverName: RKString(account.serverName), token: RKString(account.token), history: account.history = true, autoNext: account.autoNext <> false, bitrate: RKNumber(account.bitrate, 20000000)}
end function

function RKUpsertAccount(accounts as object, incoming as object) as object
    copied = []
    selected = -1
    for each old in accounts
        nextAccount = RKCopyAccount(old)
        if RKAccountKey(old) = RKAccountKey(incoming)
            selected = copied.count()
            nextAccount = RKCopyAccount(incoming)
            nextAccount.history = old.history = true
            nextAccount["autoNext"] = old.autoNext <> false
            nextAccount.bitrate = RKNumber(old.bitrate, 20000000)
        end if
        copied.push(nextAccount)
    end for
    if selected < 0
        if copied.count() >= 8 then return RKError("Remove a connection before adding another.")
        selected = copied.count()
        copied.push(RKCopyAccount(incoming))
    end if
    return {ok: true, accounts: copied, selected: selected}
end function

function RKRemoveAccount(accounts as object, index as integer, active as integer, removeLabel as boolean) as object
    if index < 0 or index >= accounts.count() then return RKError("This connection is no longer available.")
    copied = []
    target = RKCopyAccount(accounts[index])
    selected = active
    for i = 0 to accounts.count() - 1
        nextAccount = RKCopyAccount(accounts[i])
        if i = index then nextAccount.token = ""
        if not (removeLabel and i = index) then copied.push(nextAccount)
    end for
    if active = index
        selected = -1
        for i = 0 to copied.count() - 1
            if selected < 0 and RKString(copied[i].token) <> "" then selected = i
        end for
    else if removeLabel and index < active
        selected -= 1
    end if
    return {ok: true, accounts: copied, selected: selected, revoke: target}
end function

function RKHistoryAllowed(accounts as object, key as string) as boolean
    for each account in accounts
        if RKAccountKey(account) = key then return account.history = true and RKString(account.token) <> ""
    end for
    return false
end function

' Seasons is an unpaged Jellyfin API. Keep the complete response and page only in memory.
function RKLocalPage(items as object, start as dynamic, limit = 60 as integer) as object
    offset = int(RKNumber(start))
    if offset < 0 then offset = 0
    if limit < 1 then limit = 60
    if items.count() = 0 then offset = 0
    if items.count() > 0 and offset >= items.count() then offset = int((items.count() - 1) / limit) * limit
    result = []
    for i = offset to offset + limit - 1
        if i < items.count() then result.push(items[i])
    end for
    return {items: result, start: offset, total: items.count()}
end function

function RKRegistryDecode(read as object) as object
    empty = {accounts: [], device: ""}
    if read.ok <> true then return {ok: true, state: "read-failed", canSave: false, metadata: empty, error: "Saved connection labels could not be read. Existing storage has not been replaced."}
    if read.exists <> true then return {ok: true, state: "absent", canSave: true, metadata: empty}
    raw = RKString(read.raw)
    input = ParseJson(raw)
    if not RKObject(input) then return {ok: true, state: "corrupt", canSave: false, metadata: empty, error: "Saved connection labels are unreadable. Existing storage has not been replaced."}
    if RKNumber(input.version, -1) <> 1 then return {ok: true, state: "unsupported-version", canSave: false, metadata: empty, error: "Saved connection labels use an unsupported version. Existing storage has not been replaced."}
    valid = RKArray(input.accounts) and (type(input.device) = "String" or type(input.device) = "roString")
    for each key in input
        if lcase(key) <> "version" and lcase(key) <> "accounts" and lcase(key) <> "device" then valid = false
    end for
    if valid
        if input.accounts.count() > 8 then valid = false
        seen = {}
        for each account in input.accounts
            if not RKObject(account)
                valid = false
            else
                for each key in account
                    field = lcase(key)
                    if field <> "server" and field <> "username" and field <> "name" and field <> "servername" and field <> "userid" and field <> "history" and field <> "bitrate" and field <> "autonext" then valid = false
                end for
                base = RKNormalizeServer(RKString(account.server))
                if not base.ok or RKString(account.userId) = "" then valid = false
                for each key in ["server", "username", "name", "serverName", "userId"]
                    if type(account[key]) <> "String" and type(account[key]) <> "roString" then valid = false
                end for
                if type(account.history) <> "Boolean" and type(account.history) <> "roBoolean" then valid = false
                if account.autoNext <> invalid
                    if type(account.autoNext) <> "Boolean" and type(account.autoNext) <> "roBoolean" then valid = false
                end if
                bitrate = RKNumber(account.bitrate, -1)
                if bitrate < 2000000 or bitrate > 20000000 then valid = false
                key = RKAccountKey(account)
                if seen.doesExist(key) then valid = false
                seen[key] = true
            end if
        end for
    end if
    if not valid then return {ok: true, state: "invalid-schema", canSave: false, metadata: empty, error: "Saved connection labels have an unrecognized format. Existing storage has not been replaced."}
    return {ok: true, state: "valid", canSave: true, metadata: RKRestore(input)}
end function

function RKMetadataQueue() as object
    return {revision: 0, durable: 0, inFlight: 0, desired: invalid, failed: false}
end function

sub RKMetadataEnqueue(queue as object, accounts as object, device as string, reset = false as boolean)
    queue.revision += 1
    queue.desired = {revision: queue.revision, metadata: RKMetadata(accounts, device), reset: reset}
end sub

function RKMetadataBegin(queue as object) as dynamic
    if queue.inFlight <> 0 or queue.failed or queue.desired = invalid then return invalid
    queue.inFlight = queue.desired.revision
    return queue.desired
end function

sub RKMetadataComplete(queue as object, revision as integer, success as boolean)
    if queue.inFlight <> revision or revision = 0 then return
    queue.inFlight = 0
    if success
        queue.durable = revision
        queue.failed = false
        if queue.desired <> invalid
            if queue.desired.revision = revision then queue.desired = invalid
        end if
    else
        queue.failed = true
    end if
end sub

function RKMetadataExit(queue as object, canSave as boolean) as string
    if queue.inFlight <> 0 then return "wait"
    if queue.desired = invalid then return "close"
    if queue.failed or not canSave then return "confirm"
    return "save"
end function

function RKRevocationNotice(source as object, result as object) as dynamic
    if result.ok then return invalid
    if not RKObject(source.account) then return invalid
    target = RKCopyAccount(source.account)
    if RKString(target.token) = "" then return invalid
    id = RKString(source.revocationId, RKString(source.job))
    return {id: id, account: target, accountKey: RKAccountKey(target), label: RKString(target.name, RKString(target.username, "Connection")) + " on " + RKString(target.serverName, "Jellyfin")}
end function

function RKCanStartPlayback(closing as boolean, visible as boolean) as boolean
    return not closing and not visible
end function

function RKCanReleasePlayer(closing as boolean, state as string) as boolean
    return closing and state = "stopped"
end function

function RKAcceptAuthentication(accounts as object, incoming as object) as object
    accepted = RKUpsertAccount(accounts, incoming)
    if not accepted.ok then accepted.revoke = RKCopyAccount(incoming)
    return accepted
end function

' A read failure does not authorize replacing labels recovered by a later read.
' Recovered labels keep their order; current session values win by normalized key.
' An over-capacity union is rejected intact, never trimmed or automatically saved.
function RKReconcileRecovery(saved as object, current as object, activeKey as string) as object
    merged = []
    indices = {}
    for each group in [saved, current]
        for each original in group
            account = RKCopyAccount(original)
            base = RKNormalizeServer(account.server)
            if not base.ok or account.userId = "" then return RKError("Connection labels could not be reconciled. Existing saved labels are preserved.")
            account.server = base.url
            key = RKAccountKey(account)
            if indices.doesExist(key)
                merged[indices[key]] = account
            else
                indices[key] = merged.count()
                merged.push(account)
            end if
        end for
    end for
    if merged.count() > 8 then return {ok: false, capacity: true, count: merged.count(), error: "Recovered and current connections exceed eight saved labels. Existing saved labels are preserved; this session remains usable without saving. Remove session connections and retry reading, or explicitly replace saved labels in Storage options."}
    selected = -1
    if indices.doesExist(activeKey) then selected = indices[activeKey]
    return {ok: true, accounts: merged, selected: selected}
end function
