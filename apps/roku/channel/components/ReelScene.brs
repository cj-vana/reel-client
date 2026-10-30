sub init()
    m.top.backgroundColor = "0x0C0C0EFF"
    m.nav = m.top.findNode("nav")
    m.buttons = m.top.findNode("buttons")
    m.rows = m.top.findNode("rows")
    m.actions = m.top.findNode("actions")
    m.backdropFront = m.top.findNode("backdropFront")
    m.backdropBack = m.top.findNode("backdropBack")
    m.backdropFade = m.top.findNode("backdropFade")
    m.backdropTimer = m.top.findNode("backdropTimer")
    m.backdropRoute = ""
    m.pendingBackdrop = ""
    m.rowMemory = {}
    m.lastRow = -1
    m.lastColumn = 0
    m.rowAdjusting = false
    m.rowShapes = []
    m.buttonNames = []
    m.layoutMode = "list"
    m.video = m.top.findNode("video")
    m.video.asyncStopSemantics = true
    m.reportTimer = m.top.findNode("reportTimer")
    m.stopTimer = m.top.findNode("stopTimer")
    m.nextEpisodeTimer = m.top.findNode("nextEpisodeTimer")
    m.episodePanel = m.top.findNode("episodePanel")
    m.episodeChoices = m.top.findNode("episodeChoices")
    m.playerEpoch = 0
    m.pickerNonce = 0
    m.transitionNonce = 0
    m.playerItem = invalid
    m.playerPrevious = invalid
    m.playerNext = invalid
    m.introSegments = []
    m.playerActionNames = []
    m.episodeChoiceActions = []
    m.episodePanelMode = ""
    m.pendingEpisode = invalid
    m.pendingEpisodeId = ""
    m.autoNextRemaining = 0
    m.autoNextCancelled = true
    m.keepEpisodePanel = false
    m.pendingEpisodeError = ""
    m.jobs = {}
    m.initializing = true
    m.metadata = RKMetadataQueue()
    m.storageCanSave = false
    m.storageState = "loading"
    m.recoveringStorage = false
    m.revocationWarnings = []
    m.nextJob = 0
    m.frontBusy = false
    m.pendingFront = invalid
    m.exitAfterSave = false
    m.generation = 0
    m.nonce = 0
    m.accounts = []
    m.active = -1
    m.account = {server: "", token: "", userId: "", history: false}
    m.device = ""
    m.view = "connections"
    m.stack = []
    m.pageRows = []
    m.collectionStart = 0
    m.seasonItemsFull = []
    m.actionNames = []
    m.options = {filter: "All", sort: "Name", start: 0, search: ""}
    m.trackAudio = invalid
    m.trackSubtitle = invalid
    m.bitrate = 20000000
    m.heroItem = invalid
    m.playWhenLoaded = -1
    m.busy = false
    m.closing = false
    m.plan = invalid
    m.reported = false
    m.reportBusy = false
    m.reportQueue = []
    m.historyDirty = false
    m.reloadFocus = invalid
    m.lastPosition = 0.0
    m.nav.labels = ["Home", "Movies", "Series", "Search", "Settings"]
    m.nav.selectedIndex = 0
    m.nav.observeField("itemSelected", "onNavigation")
    m.nav.observeField("focused", "onNavFocus")
    m.nav.observeField("rowWidth", "onNavWidth")
    m.buttons.observeField("itemSelected", "onButton")
    m.buttons.observeField("rowWidth", "placeButtons")
    m.backdropTimer.observeField("fire", "onBackdropTimer")
    m.rows.observeField("rowItemSelected", "onRowSelected")
    m.rows.observeField("rowItemFocused", "onRowFocused")
    m.actions.observeField("itemSelected", "onAction")
    m.video.observeField("state", "onVideoState")
    m.video.observeField("position", "onVideoPosition")
    m.reportTimer.observeField("fire", "onReportTimer")
    m.stopTimer.observeField("fire", "onStopTimeout")
    m.nextEpisodeTimer.observeField("fire", "onNextEpisodeTimer")
    m.episodeChoices.observeField("itemSelected", "onEpisodeChoice")
    m.video.observeField("playbackActionButtonSelected", "onPlayerAction")
    m.nav.setFocus(true)
    showConnections()
    request("loadMetadata", {})
end sub

function textContent(labels as object) as object
    root = CreateObject("roSGNode", "ContentNode")
    for each text in labels
        child = root.createChild("ContentNode")
        child.title = text
    end for
    return root
end function

sub setText(id as string, text as string)
    m.top.findNode(id).text = text
end sub

' eyebrow is the small genre line above the title (the "genres" label).
sub header(meta as string, title as string, description as string, eyebrow = "" as string)
    setText("meta", meta)
    setText("title", title)
    setText("description", description)
    setText("genres", eyebrow)
    m.top.findNode("metaRow").visible = false
    updateAccountLabel()
end sub

' A title's header: its facts go in the meta row (text, boxed rating, star score, media badges)
' instead of the plain meta line, which stays for screen notes such as "Sorted by name".
sub itemHeader(item as object, description as string)
    header("", RKDisplayTitle(item), description, RKEyebrow(item))
    showMetaParts(RKMetaParts(item))
end sub

sub showMetaParts(parts as object)
    row = m.top.findNode("metaRow")
    row.parts = parts
    row.visible = m.top.findNode("meta").visible
end sub

' Moves the title block, rows, buttons and lists for one kind of screen (see RKScreenLayout).
sub applyLayout(mode as string)
    m.layoutMode = mode
    m.top.findNode("searchIcon").visible = false
    spec = RKScreenLayout(mode)
    x = 96
    align = "left"
    if mode = "message"
        x = 400
        align = "center"
    end if
    title = m.top.findNode("title")
    title.translation = [x, spec.title]
    title.height = spec.titleHeight
    title.numLines = spec.titleLines
    title.horizAlign = align
    meta = m.top.findNode("meta")
    meta.translation = [96, spec.meta]
    meta.visible = spec.meta >= 0
    m.top.findNode("metaRow").translation = [96, spec.meta]
    genres = m.top.findNode("genres")
    genres.translation = [96, spec.genres]
    genres.visible = spec.genres >= 0
    description = m.top.findNode("description")
    description.translation = [x, spec.description]
    description.height = spec.descriptionHeight
    description.numLines = spec.descriptionLines
    description.horizAlign = align
    description.width = 960
    description.color = "0xF4F4F6C8"
    if mode = "message"
        description.width = 1120
        description.color = "0xF4F4F6A3"
    end if
    description.visible = spec.description >= 0
    m.rows.translation = [96, spec.rows]
    m.buttons.translation = [96, spec.buttons]
    m.actions.translation = [96, spec.actions]
    placeButtons()
end sub

' Message screens centre their buttons under the message; elsewhere buttons start at the safe edge.
sub placeButtons()
    if m.layoutMode <> "message" or m.buttons.rowWidth <= 0 then return
    m.buttons.translation = [int((1920 - m.buttons.rowWidth) / 2), RKScreenLayout("message").buttons]
end sub

' The line above the title. Failures use the warning colour; loading and hints stay muted.
sub setStatus(text as string, warning = false as boolean)
    status = m.top.findNode("status")
    status.text = text
    if warning then status.color = "0xF2C98AFF" else status.color = "0xF4F4F6A3"
end sub

' A page with nothing to browse: its title, one message and a short row of buttons, centred.
' The first button is the primary action.
sub showMessage(title as string, body as string, labels as object, names as object)
    applyLayout("message")
    header("", title, body)
    m.buttonNames = names
    m.buttons.labels = labels
    m.buttons.focusIndex = 0
    m.buttons.visible = true
    m.actions.visible = false
    m.rows.visible = false
    placeButtons()
    claimFocus("buttons")
end sub

' The viewer and server on one line beside the tab bar. Pages with an Options menu show it as a quiet
' capsule at the right edge, and the account line moves left to make room.
sub updateAccountLabel()
    account = m.top.findNode("accountLabel")
    if m.active >= 0
        account.text = RKString(m.account.name, RKString(m.account.username)) + " on " + RKString(m.account.serverName, "Jellyfin")
    else
        account.text = "Signed out"
    end if
    hasOptions = m.view = "home" or m.view = "library" or m.view = "search"
    m.top.findNode("options").visible = hasOptions
    setText("hint", "* Options")
    if hasOptions then account.width = 248 else account.width = 424
end sub

sub onNavFocus()
    if m.nav.focused then m.nav.opacity = 1.0 else m.nav.opacity = 0.62
end sub

' The tab bar sits centred, like the Apple TV app.
sub onNavWidth()
    if m.nav.rowWidth > 0 then m.nav.translation = [int((1920 - m.nav.rowWidth) / 2), 56]
end sub

sub syncTabs()
    m.nav.selectedIndex = RKTabIndex(m.view, RKString(m.options.filter), m.nav.selectedIndex)
end sub

sub focusArea(area as string)
    if area = "nav"
        m.nav.setFocus(true)
    else if area = "buttons"
        m.buttons.setFocus(true)
    else if area = "rows"
        m.rows.setFocus(true)
    else
        m.actions.setFocus(true)
    end if
end sub

' Loaded content takes focus, except from the tab bar: someone paging through tabs stays on them.
sub claimFocus(area as string)
    if m.nav.hasFocus() then return
    focusArea(area)
end sub

sub restoreFocus()
    state = {buttonsVisible: m.buttons.visible, rowsVisible: m.rows.visible, actionsVisible: m.actions.visible}
    focusArea(RKRestoreArea(state))
end sub

sub request(kind as string, extra as object, auxiliary = false as boolean)
    m.nextJob += 1
    if not auxiliary
        m.nonce += 1
        m.busy = true
        setStatus("Loading…")
    end if
    data = {kind: kind, account: ParseJson(FormatJson(m.account)), accountKey: RKAccountKey(m.account), device: m.device, generation: m.generation, nonce: m.nonce, job: str(m.nextJob).trim(), auxiliary: auxiliary}
    for each key in extra
        data[key] = extra[key]
    end for
    if not auxiliary
        if m.frontBusy
            m.pendingFront = data
            return
        end if
        m.frontBusy = true
    end if
    launchTask(data)
end sub

sub launchTask(data as object)
    task = CreateObject("roSGNode", "ApiTask")
    task.request = data
    task.historyAllowed = RKHistoryAllowed(m.accounts, RKAccountKey(data.account))
    task.observeField("result", "onResult")
    m.jobs[data.job] = task
    task.control = "RUN"
end sub

sub saveMetadata(reset = false as boolean)
    RKMetadataEnqueue(m.metadata, m.accounts, m.device, reset)
    pumpMetadata()
    refreshStorageNotice()
end sub

sub pumpMetadata()
    if not m.storageCanSave then return
    snapshot = RKMetadataBegin(m.metadata)
    if snapshot = invalid then return
    request("saveMetadata", {accounts: snapshot.metadata.accounts, device: snapshot.metadata.device, revision: snapshot.revision, reset: snapshot.reset, account: {server: "", token: "", userId: "", history: false}}, true)
end sub

sub refreshStorageNotice()
    text = ""
    if not m.storageCanSave then text = "Labels: session only"
    if m.metadata.failed then text = "Labels not saved"
    if m.revocationWarnings.count() > 0 then text = "Sign-out not confirmed"
    setText("storageNotice", text)
end sub

sub confirmUnsavedExit()
    m.exitAfterSave = false
    message("Connection labels were not saved", "Your latest connection labels remain in memory. Retry saving, or explicitly leave without saving. Existing unreadable storage is preserved until you choose Reset in Connections.", ["Try again", "Leave without saving", "Stay"], "exitSaveFailure")
end sub

sub showStorageRecovery()
    message("Connection label storage", "Reel preserves unreadable or unsupported saved data. You can retry reading, keep using this session without saving, or explicitly replace saved labels with this session's labels.", ["Retry reading", "Use this session only", "Reset saved labels…", "Cancel"], "storageRecovery")
end sub

sub recordRevocation(source as object, result as object)
    id = RKString(source.revocationId, RKString(source.job))
    remaining = []
    for each warning in m.revocationWarnings
        if warning.id <> id then remaining.push(warning)
    end for
    notice = RKRevocationNotice(source, result)
    if notice <> invalid then remaining.push(notice)
    m.revocationWarnings = remaining
    refreshStorageNotice()
    if m.view = "connections" and not m.busy then showConnections()
end sub

sub onResult(event as object)
    packet = event.getData()
    r = packet.request
    sourceRequest = invalid
    if m.jobs.doesExist(RKString(r.job))
        sourceRequest = m.jobs[r.job].request
        m.jobs.delete(r.job)
    end if
    if sourceRequest <> invalid
        if not sourceRequest.auxiliary
            m.frontBusy = false
            if m.pendingFront <> invalid
                queued = m.pendingFront
                m.pendingFront = invalid
                m.frontBusy = true
                launchTask(queued)
            end if
        end if
    end if
    result = packet.result
    kind = r.kind
    if kind = "report"
        m.reportBusy = false
        if result.ok and r.generation = m.generation and r.accountKey = RKAccountKey(m.account)
            m.historyDirty = true
            if not m.video.visible and (m.view = "home" or m.view = "library" or m.view = "search")
                m.historyDirty = false
                retryPage()
            end if
        end if
        pumpReport()
        return
    end if
    if kind = "saveMetadata"
        if sourceRequest = invalid then return
        RKMetadataComplete(m.metadata, sourceRequest.revision, result.ok)
        if not result.ok then setStatus(result.error, true)
        refreshStorageNotice()
        if result.ok then pumpMetadata()
        if m.exitAfterSave
            decision = RKMetadataExit(m.metadata, m.storageCanSave)
            if decision = "close" then m.top.closeRequested = true
            if decision = "confirm" then confirmUnsavedExit()
        end if
        if m.view = "connections" and not m.busy then showConnections()
        return
    end if
    if kind = "logout"
        if sourceRequest <> invalid then recordRevocation(sourceRequest, result)
        return
    end if
    if kind = "cleanup"
        if not result.ok and r.generation = m.generation and r.accountKey = RKAccountKey(m.account) then setStatus(result.error, true)
        return
    end if
    if left(kind, 6) = "player"
        onPlayerResult(sourceRequest, result)
        return
    end if
    if not RKResultMatches(r, RKAccountKey(m.account), m.generation, m.nonce)
        if kind = "auth" and result.ok then request("logout", {account: result.account}, true)
        if kind = "playback" and result.ok and sourceRequest <> invalid then request("cleanup", {account: sourceRequest.account, plan: result}, true)
        return
    end if
    m.busy = false
    setStatus("")
    if not result.ok
        if result.expired = true
            if m.active >= 0
                m.account.token = ""
                m.accounts[m.active] = m.account
            end if
        end if
        if kind = "playback"
            setStatus(result.error, true)
            message("Could not play", result.error, ["Retry", "Cancel"], "playbackError")
        else if kind = "auth"
            setStatus(result.error, true)
            message("Could not sign in", result.error, ["Try again", "Cancel"], "authError")
        else
            m.playWhenLoaded = -1
            showMessage(RKErrorTitle(kind, result.expired = true), result.error, ["Retry", "Manage servers"], ["retry", "connections"])
        end if
        return
    end if
    if kind = "loadMetadata"
        m.initializing = false
        m.storageCanSave = result.canSave
        m.storageState = result.state
        recoveryError = ""
        if not m.recoveringStorage
            m.accounts = result.metadata.accounts
            m.device = result.metadata.device
        else if result.canSave
            reconciled = RKReconcileRecovery(result.metadata.accounts, m.accounts, RKAccountKey(m.account))
            if reconciled.ok
                m.accounts = reconciled.accounts
                m.active = reconciled.selected
                if m.active >= 0 then m.account = m.accounts[m.active]
                if m.device = "" then m.device = result.metadata.device
                RKMetadataEnqueue(m.metadata, m.accounts, m.device)
            else
                m.storageCanSave = false
                m.storageState = "capacity-or-reconciliation-failed"
                recoveryError = reconciled.error
            end if
        end if
        m.recoveringStorage = false
        if m.device = "" then m.device = CreateObject("roDeviceInfo").getRandomUUID()
        if m.device = "" then m.device = "reel-session-" + str(rnd(2147483647)).trim()
        if m.storageCanSave
            m.metadata.failed = false
            pumpMetadata()
        end if
        showConnections()
        if not result.canSave then setStatus(result.error + " Select Storage options.", true)
        if recoveryError <> ""
            setStatus("Saved labels preserved. This session is not being saved.", true)
            message("Saved labels preserved", recoveryError, ["Storage options", "Keep this session"], "recoveryConflict")
        end if
        refreshStorageNotice()
    else if kind = "auth"
        updated = RKAcceptAuthentication(m.accounts, result.account)
        if not updated.ok
            request("logout", {account: updated.revoke}, true)
            showConnections()
            setStatus(updated.error, true)
            return
        end if
        m.accounts = updated.accounts
        index = updated.selected
        m.draft = invalid
        activate(index)
        saveMetadata()
    else if kind = "home"
        m.pageRows = result.rows
        applyLayout("hero")
        m.buttons.visible = false
        ' Home opens on the hero's Play button, one press from resuming.
        showRows(result.rows, false)
        if m.rows.visible then claimFocus(RKRestoreArea({buttonsVisible: m.buttons.visible, rowsVisible: true}))
        if result.failures.count() > 0 then setStatus("Some shelves could not load. Press * to refresh.", true)
    else if kind = "library" or kind = "search"
        m.items = result.items
        m.total = result.total
        ' The page title already names the grid, so its first row carries no label.
        rows = collectionRows(m.items, "", m.options.start, result.total)
        m.pageRows = rows
        applyLayout("grid")
        m.buttons.visible = false
        showRows(rows, true, "No titles found. Press * to change your search or filters.")
    else if kind = "details"
        m.detail = result.item
        m.detail.reelNextUp = result.nextUp
        m.pageRows = []
        m.trackAudio = invalid
        m.trackSubtitle = invalid
        showDetails()
        restoreReloadFocus()
        playFrom = m.playWhenLoaded
        m.playWhenLoaded = -1
        if RKString(m.detail.Type) = "Series"
            request("seasons", {itemId: m.detail.Id, start: 0})
        else if playFrom >= 0
            beginPlayback(playFrom, false)
        end if
    else if kind = "seasons" or kind = "episodes"
        if kind = "seasons"
            m.seasonItemsFull = result.items
            showSeasonPage()
        else
            m.pageRows = collectionRows(result.items, "Episodes", m.collectionStart, result.total, "wide", false)
            applyLayout("hero")
            m.buttons.visible = false
            showRows(m.pageRows)
            restoreReloadFocus()
        end if
    else if kind = "playback"
        playNative(result)
    end if
end sub

sub activate(index as integer)
    closeEpisodePanel()
    m.playerEpoch += 1
    m.seasonItemsFull = []
    m.generation += 1
    m.active = index
    m.account = m.accounts[index]
    m.bitrate = RKNumber(m.account.bitrate, 20000000)
    m.stack = []
    m.pageRows = []
    m.rows.content = invalid
    updateAccountLabel()
    if RKString(m.account.token) = "" then beginSignIn(m.account) else navigate("home")
end sub

sub onNavigation()
    m.autoNextCancelled = true
    if m.initializing then return
    index = m.nav.itemSelected
    if index = 1
        navigate("library", "Movies")
    else if index = 2
        navigate("library", "Series")
    else
        choices = ["home", "", "", "search", "settings"]
        navigate(choices[index])
    end if
end sub

sub navigate(view as string, filter = "All" as string)
    m.seasonItemsFull = []
    m.nonce += 1
    m.busy = false
    m.stack = []
    m.reloadFocus = invalid
    m.view = view
    m.pendingFront = invalid
    m.playWhenLoaded = -1
    m.pageRows = []
    m.rows.content = invalid
    m.rows.visible = false
    m.actions.visible = false
    m.buttons.visible = false
    setStatus("")
    showBackdrop("", true)
    updateAccountLabel()
    if view = "connections"
        showConnections()
        return
    end if
    if m.active < 0 or RKString(m.account.token) = ""
        showConnections()
        setStatus("Sign in to open your library. Only the server name and your choices are saved, never your password.")
        return
    end if
    if view = "home"
        syncTabs()
        applyLayout("hero")
        header("", "Home", "")
        request("home", {})
    else if view = "library"
        m.options = {filter: filter, sort: "Name", start: 0, search: ""}
        syncTabs()
        loadLibrary()
    else if view = "search"
        m.options = {filter: "All", sort: "Name", start: 0, search: ""}
        syncTabs()
        showMessage("A title in mind?", "Search movies, series and episodes.", ["Search"], ["search"])
        m.top.findNode("searchIcon").visible = true
        keyboard("Search", "", "search")
    else if view = "settings"
        syncTabs()
        showSettings()
    end if
    updateAccountLabel()
end sub

' Rows for a paged collection. Posters wrap eight to a row; a single row (episodes) keeps its cards together.
function collectionRows(items as object, title as string, startIndex as integer, total as double, shape = "poster" as string, wrapRows = true as boolean) as object
    rows = []
    perRow = 8
    if not wrapRows then perRow = 60
    for start = 0 to items.count() - 1 step perRow
        batch = []
        for i = start to start + perRow - 1
            if i < items.count() then batch.push(items[i])
        end for
        rowTitle = ""
        if start = 0 then rowTitle = title
        rows.push({title: rowTitle, shape: shape, items: batch})
    end for
    more = items.count() = 60
    if total > 0 then more = startIndex + items.count() < total
    paging = []
    if startIndex > 0 then paging.push({Id: "__previous__", Name: "Previous page", reelAction: "previous"})
    if more then paging.push({Id: "__more__", Name: "Next page", reelAction: "more"})
    if paging.count() > 0 then rows.push({title: "More", shape: "wide", items: paging})
    return rows
end function

sub showRows(rows as object, takeFocus = true as boolean, emptyMessage = "Nothing here yet. Choose Refresh after adding titles to this library." as string)
    content = CreateObject("roSGNode", "ContentNode")
    authorization = RKAuthorization(m.account, m.device)
    populated = false
    sizes = []
    spacings = []
    heights = []
    gaps = []
    labels = []
    offsets = []
    m.rowShapes = []
    for each row in rows
        if row.items.count() > 0
            populated = true
            shape = RKString(row.shape, "poster")
            spec = RKShapeSpec(shape)
            node = content.createChild("ContentNode")
            node.title = RKString(row.title)
            m.rowShapes.push(shape)
            sizes.push([spec.width, spec.height])
            gaps.push([spec.gap, 0])
            labelled = RKString(row.title) <> ""
            labels.push(labelled)
            offsets.push([0, spec.labelGap])
            labelHeight = 0
            if labelled then labelHeight = spec.label
            heights.push(labelHeight + spec.height)
            spacings.push(spec.after)
            for each item in row.items
                card = node.createChild("ContentNode")
                card.title = RKDisplayTitle(item)
                if m.view = "episodes" then card.title = RKEpisodeCaption(item)
                if RKString(item.reelAction) <> "" then card.title = RKString(item.Name)
                detail = ""
                if RKString(item.reelAction) = "" then detail = RKCardDetail(item, m.view <> "episodes")
                card.addFields({reelItem: item, imageAuthorization: authorization, subtitle: detail, progress: RKProgress(item), played: RKPlayed(item)})
                url = ""
                route = RKArtworkRoute(item, shape, spec.maxWidth)
                if route <> ""
                    scoped = RKScopedURL(m.account.server, route)
                    if scoped.ok then url = scoped.url
                end if
                card.hdPosterUrl = url
            end for
        end if
    end for
    m.rowMemory = {}
    m.lastRow = -1
    m.lastColumn = 0
    if populated
        m.rows.rowItemSize = sizes
        m.rows.rowItemSpacing = gaps
        m.rows.showRowLabel = labels
        m.rows.rowLabelOffset = offsets
        m.rows.rowHeights = heights
        m.rows.rowSpacings = spacings
    end if
    m.rows.content = content
    m.rows.visible = populated
    m.actions.visible = false
    if populated
        if takeFocus then claimFocus("rows")
        followFocus([0, 0])
    else
        showMessage(m.top.findNode("title").text, emptyMessage, ["Refresh", "Manage servers"], ["retry", "connections"])
    end if
end sub

sub showActions(labels as object, names as object)
    m.actionNames = names
    m.actionLabels = labels
    applyLayout("list")
    m.actions.content = textContent(labels)
    m.actions.visible = true
    m.rows.visible = false
    m.buttons.visible = false
    m.actions.jumpToItem = 0
    claimFocus("actions")
end sub

sub showConnections()
    m.view = "connections"
    m.rows.content = invalid
    showBackdrop("", true)
    header("", "Servers", "Sign in for this session. Reel saves server names and your choices only, so you sign in again after closing the app.")
    labels = []
    names = []
    for i = 0 to m.accounts.count() - 1
        account = m.accounts[i]
        suffix = "   Sign in"
        if RKString(account.token) <> "" then suffix = "   Open"
        labels.push(RKString(account.name, account.username) + " on " + RKString(account.serverName, "Jellyfin") + suffix)
        names.push("account:" + str(i).trim())
    end for
    if m.metadata.failed
        labels.push("Retry saving connection labels")
        names.push("retrySave")
    end if
    labels.push("Storage options")
    names.push("storageRecovery")
    for i = 0 to m.revocationWarnings.count() - 1
        labels.push("Review sign-out: " + m.revocationWarnings[i].label)
        names.push("revoke:" + str(i).trim())
    end for
    labels.push("Add a server")
    names.push("add")
    showActions(labels, names)
    updateAccountLabel()
    refreshStorageNotice()
end sub

' Private viewing is the inverse of the stored history flag: on means no progress reports.
sub showSettings()
    header("", "Settings", "With private viewing on, watch progress stays on this device.")
    privateViewing = "Private viewing: On"
    if m.account.history = true then privateViewing = "Private viewing: Off"
    automatic = "Play next episode automatically: On"
    if m.account.autoNext = false then automatic = "Play next episode automatically: Off"
    showActions([privateViewing, automatic, "Streaming quality: " + RKQualityLabel(m.bitrate), "Manage servers", "Sign out or remove this server"], ["history", "autoNext", "quality", "connections", "connectionOptions"])
end sub

sub loadLibrary()
    if m.view = "search"
        header("", "Results for " + chr(34) + m.options.search + chr(34), "")
        request("search", {options: m.options})
    else
        title = "Library"
        if m.options.filter = "Movies" then title = "Movies"
        if m.options.filter = "Series" then title = "Series"
        if m.options.filter = "Episodes" then title = "Episodes"
        header("Sorted by " + lcase(m.options.sort), title, "")
        request("library", {options: m.options})
    end if
end sub

sub pushPage()
    focus = [0, 0]
    if m.rows.content <> invalid then focus = m.rows.rowItemFocused
    ' The button that opened the next page (Play S1 E2, Episodes) takes focus again on Back.
    buttonFocus = -1
    if m.buttons.visible and m.buttons.hasFocus() then buttonFocus = m.buttons.focusIndex
    m.reloadFocus = invalid
    m.stack.push({buttonFocus: buttonFocus, view: m.view, pageRows: m.pageRows, options: ParseJson(FormatJson(m.options)), detail: m.detail, title: m.top.findNode("title").text, meta: m.top.findNode("meta").text, genres: m.top.findNode("genres").text, description: m.top.findNode("description").text, layout: m.layoutMode, focus: focus, actionLabels: m.actionLabels, actionNames: m.actionNames, actionsVisible: m.actions.visible, audio: m.trackAudio, subtitle: m.trackSubtitle, requestedItemId: m.requestedItemId, episodeSeason: m.episodeSeason, collectionStart: m.collectionStart, seasonItemsFull: m.seasonItemsFull})
end sub

sub backPage()
    if m.stack.count() = 0
        m.nav.setFocus(true)
        return
    end if
    showBackdrop("", true)
    m.nonce += 1
    m.busy = false
    m.playWhenLoaded = -1
    state = m.stack.pop()
    m.view = state.view
    m.pageRows = state.pageRows
    m.options = state.options
    m.detail = state.detail
    m.trackAudio = state.audio
    m.trackSubtitle = state.subtitle
    m.requestedItemId = state.requestedItemId
    m.episodeSeason = state.episodeSeason
    m.collectionStart = state.collectionStart
    m.seasonItemsFull = state.seasonItemsFull
    header(state.meta, state.title, state.description, state.genres)
    setStatus("")
    syncTabs()
    updateAccountLabel()
    ' After reported playback, progress, watched marks and a series' next-up episode may have moved:
    ' reload, and put focus back on the episode or button the viewer left from once the page returns.
    if m.historyDirty and (m.view = "home" or m.view = "library" or m.view = "search" or m.view = "details" or m.view = "episodes")
        m.historyDirty = false
        if m.view = "details" or m.view = "episodes" then m.reloadFocus = {view: m.view, rows: state.focus, button: state.buttonFocus}
        retryPage()
        return
    end if
    if m.view = "details"
        showDetails()
        if m.pageRows.count() > 0
            showRows(m.pageRows, false)
            m.rows.jumpToRowItem = state.focus
            if state.buttonFocus < 0 then m.rows.setFocus(true)
        end if
        if state.buttonFocus >= 0 then focusButtonAt(state.buttonFocus)
    else if state.actionsVisible
        showActions(state.actionLabels, state.actionNames)
    else
        applyLayout(state.layout)
        m.buttons.visible = false
        showRows(m.pageRows, state.buttonFocus < 0)
        m.rows.jumpToRowItem = state.focus
        if m.layoutMode = "hero" then followFocus(state.focus)
        if state.buttonFocus >= 0 and m.rows.visible then focusButtonAt(state.buttonFocus)
    end if
end sub

' Focus goes to the button at index, or the last one when the page now has fewer (a finished movie
' loses Resume and Restart). Without buttons, as on a "See all" tile, the rows take focus.
sub focusButtonAt(index as integer)
    count = 0
    if m.buttonNames <> invalid then count = m.buttonNames.count()
    if m.buttons.visible and count > 0
        if index >= count then index = count - 1
        m.buttons.focusIndex = index
        claimFocus("buttons")
    else if m.rows.visible
        claimFocus("rows")
    end if
end sub

' Runs when a page reloaded by backPage arrives: the episode list jumps back to the episode the viewer
' left from, and focus returns to the button that opened the next page.
sub restoreReloadFocus()
    remembered = m.reloadFocus
    m.reloadFocus = invalid
    if remembered = invalid then return
    if remembered.view <> m.view then return
    if m.view = "episodes" and m.rows.visible and m.rows.content <> invalid
        row = m.rows.content.getChild(remembered.rows[0])
        if row <> invalid
            if remembered.rows[1] < row.getChildCount()
                m.rows.jumpToRowItem = remembered.rows
                followFocus(remembered.rows)
            end if
        end if
    end if
    if remembered.button >= 0 then focusButtonAt(remembered.button)
end sub

sub onRowSelected()
    m.autoNextCancelled = true
    if m.busy then return
    selectedPosition = m.rows.rowItemSelected
    node = m.rows.content.getChild(selectedPosition[0]).getChild(selectedPosition[1])
    item = node.reelItem
    if RKString(item.reelAction) = "browse"
        pushPage()
        m.view = "library"
        m.options = {filter: item.filter, sort: "Recently added", start: 0, search: ""}
        loadLibrary()
        return
    end if
    if RKString(item.reelAction) = "more" or RKString(item.reelAction) = "previous"
        delta = 60
        if item.reelAction = "previous" then delta = -60
        if m.view = "seasons"
            m.collectionStart += delta
            showSeasonPage()
        else if m.view = "episodes"
            m.collectionStart += delta
            retryPage()
        else
            m.options.start += delta
            loadLibrary()
        end if
        return
    end if
    if RKString(item.Type) = "Season"
        openSeason(item)
        return
    end if
    pushPage()
    openDetails(item, -1.0#)
end sub

' Opens a season's episode list from the series page, from its row or its Episodes button.
sub openSeason(season as object)
    pushPage()
    m.episodeSeason = season
    if RKString(m.episodeSeason.SeriesId) = "" then m.episodeSeason.SeriesId = m.detail.Id
    m.view = "episodes"
    m.collectionStart = 0
    header("", RKString(season.Name, "Episodes"), "")
    m.buttons.visible = false
    m.rows.visible = false
    request("episodes", {itemId: m.episodeSeason.Id, seriesId: m.episodeSeason.SeriesId, start: m.collectionStart})
end sub

sub onRowFocused()
    if m.rows.content = invalid or not m.rows.visible then return
    position = m.rows.rowItemFocused
    row = position[0]
    column = position[1]
    if row < 0 or row >= m.rowShapes.count() then return
    if m.lastRow >= 0 and row <> m.lastRow
        key = str(row).trim()
        remembered = invalid
        if m.rowMemory.doesExist(key) then remembered = m.rowMemory[key]
        count = m.rows.content.getChild(row).getChildCount()
        target = RKLandingColumn(m.lastColumn, m.rowShapes[m.lastRow], m.rowShapes[row], count, remembered)
        if target <> column
            m.lastRow = row
            m.lastColumn = target
            m.rowMemory[key] = target
            m.rows.jumpToRowItem = [row, target]
            followFocus([row, target])
            return
        end if
    end if
    m.lastRow = row
    m.lastColumn = column
    m.rowMemory[str(row).trim()] = column
    followFocus(position)
end sub

' Home and episode lists show the focused title above the rows and put its artwork behind them.
sub followFocus(position as object)
    if m.view <> "home" and m.view <> "episodes" then return
    if m.rows.content = invalid then return
    row = m.rows.content.getChild(position[0])
    if row = invalid then return
    node = row.getChild(position[1])
    if node = invalid then return
    item = node.reelItem
    if RKString(item.reelAction) <> ""
        header("", RKString(item.Name), "")
        showBackdrop("", false)
        showHeroButtons(invalid)
        return
    end if
    itemHeader(item, RKString(item.Overview))
    showBackdrop(RKBackdropRoute(item), false)
    showHeroButtons(item)
end sub

' Play and Details for the title the hero shows. A series has nothing to play from here, so it offers
' Details alone; paging and "See all" tiles offer neither.
sub showHeroButtons(item as dynamic)
    m.heroItem = item
    if not RKObject(item)
        m.buttons.visible = false
        return
    end if
    labels = ["Details"]
    names = ["heroDetails"]
    if RKString(item.Type) <> "Series"
        play = "Play"
        if RKResume(item) > 0 then play = "Resume"
        labels = [play, "Details"]
        names = ["heroPlay", "heroDetails"]
    end if
    current = m.buttons.labels
    if current = invalid then current = []
    if current.join("|") <> labels.join("|") then m.buttons.labels = labels
    m.buttonNames = names
    m.buttons.visible = true
end sub

sub showBackdrop(route as string, immediate as boolean)
    m.backdropTimer.control = "stop"
    m.pendingBackdrop = route
    if immediate
        applyBackdrop(route)
    else if route <> m.backdropRoute
        m.backdropTimer.control = "start"
    end if
end sub

sub onBackdropTimer()
    applyBackdrop(m.pendingBackdrop)
end sub

sub applyBackdrop(route as string)
    if route = m.backdropRoute then return
    m.backdropRoute = route
    url = ""
    if route <> "" and m.active >= 0
        scoped = RKScopedURL(m.account.server, route)
        if scoped.ok then url = scoped.url
    end if
    if url = ""
        m.backdropFront.uri = ""
        m.backdropBack.uri = ""
        m.backdropFront.opacity = 0
        return
    end if
    agent = CreateObject("roHttpAgent")
    if not agent.setCertificatesFile("common:/certs/ca-bundle.crt") then return
    agent.addHeader("Authorization", RKAuthorization(m.account, m.device))
    m.backdropBack.setHttpAgent(agent)
    m.backdropFront.setHttpAgent(agent)
    m.backdropBack.uri = m.backdropFront.uri
    m.backdropFront.opacity = 0
    m.backdropFront.uri = url
    m.backdropFade.control = "start"
end sub

' A movie or episode sets its title block low over the artwork, as the other TV clients do. A series
' keeps it high, leaving room for the seasons row under its buttons.
sub showDetails()
    item = m.detail
    isSeries = RKString(item.Type) = "Series"
    if isSeries then applyLayout("details") else applyLayout("feature")
    itemHeader(item, RKString(item.Overview, "No description available."))
    showBackdrop(RKBackdropRoute(item), true)
    labels = []
    names = []
    if isSeries
        ' A series leads with its next-up episode ("Resume S1 E2"). Episodes follows, or leads without
        ' one, and opens the episode list of the season to watch next.
        upNext = item.reelNextUp
        if RKObject(upNext)
            verb = "Play"
            if RKResume(upNext) > 0 then verb = "Resume"
            labels.push((verb + " " + RKEpisodeCode(upNext)).trim())
            names.push("nextUp")
        end if
        labels.push("Episodes")
        names.push("seasonEpisodes")
    else
        resume = RKResume(item)
        if resume > 0
            labels.push(("Resume " + RKTimeLeftText(item, resume)).trim())
            names.push("resume")
            labels.push("Restart")
            names.push("play")
        else
            labels.push("Play")
            names.push("play")
        end if
        labels.push("Audio and subtitles")
        names.push("tracks")
    end if
    m.buttonNames = names
    m.buttons.labels = labels
    m.buttons.focusIndex = 0
    m.buttons.visible = true
    m.actions.visible = false
    m.rows.visible = false
    claimFocus("buttons")
end sub

sub onButton()
    if not m.video.visible then m.autoNextCancelled = true
    if m.busy then return
    index = m.buttons.itemSelected
    if index < 0 or index >= m.buttonNames.count() then return
    runAction(m.buttonNames[index])
end sub

sub onAction()
    if not m.video.visible then m.autoNextCancelled = true
    if m.busy then return
    runAction(m.actionNames[m.actions.itemSelected])
end sub

sub runAction(name as string)
    if left(name, 8) = "account:"
        m.connectionIndex = val(mid(name, 9))
        message("Connection", "Choose what to do with this account.", connectionChoices(m.connectionIndex), "connectionChoice")
    else if name = "retrySave"
        if m.storageCanSave
            m.metadata.failed = false
            pumpMetadata()
        else
            showStorageRecovery()
        end if
    else if name = "storageRecovery"
        showStorageRecovery()
    else if left(name, 7) = "revoke:"
        m.revocationReview = m.revocationWarnings[val(mid(name, 8))]
        message("Sign-out not confirmed", "Reel no longer uses this session for " + m.revocationReview.label + ". The server did not confirm token revocation. Retry this exact session or dismiss this warning. Your current connection is unaffected.", ["Retry sign-out", "Dismiss", "Cancel"], "revocationReview")
    else if name = "add"
        if m.accounts.count() >= 8
            message("Connections", "Remove a connection before adding another. Reel supports eight saved connection labels.", ["OK"], "info")
        else
            beginSignIn({server: "", username: ""})
        end if
    else if name = "retry"
        retryPage()
    else if name = "connections"
        navigate("connections")
    else if name = "search"
        keyboard("Search", m.options.search, "search")
    else if name = "seasonEpisodes"
        season = RKNextUpSeason(m.seasonItemsFull, m.detail.reelNextUp)
        if season <> invalid then openSeason(season)
    else if name = "nextUp"
        episode = m.detail.reelNextUp
        if not RKObject(episode) then return
        ' Play the episode from its own page, so Back after playback returns to the series.
        pushPage()
        m.detail = episode
        m.requestedItemId = episode.Id
        m.trackAudio = invalid
        m.trackSubtitle = invalid
        showDetails()
        beginPlayback(RKResume(episode), false)
    else if name = "heroPlay" or name = "heroDetails"
        if not RKObject(m.heroItem) then return
        playFrom = -1.0#
        if name = "heroPlay" then playFrom = RKResume(m.heroItem)
        pushPage()
        openDetails(m.heroItem, playFrom)
    else if name = "play"
        beginPlayback(0, false)
    else if name = "resume"
        beginPlayback(RKResume(m.detail), false)
    else if name = "tracks"
        message("Audio and subtitles", "Choose what to change for this title.", ["Audio", "Subtitles", "Cancel"], "tracks")
    else if name = "audio" or name = "subtitles"
        trackDialog(name)
    else if name = "history"
        ' Turning private viewing on stops reports at once; turning it off asks first.
        if m.account.history = true
            m.account.history = false
            m.accounts[m.active] = m.account
            for each job in m.jobs
                task = m.jobs[job]
                if task.request.kind = "report" and RKAccountKey(task.request.account) = RKAccountKey(m.account) then task.historyAllowed = false
            end for
            saveMetadata()
            showSettings()
        else
            message("Turn off private viewing?", "Reel will send watch progress to Jellyfin for this account. That updates Continue watching and what shows as watched.", ["Turn off", "Keep on"], "history")
        end if
    else if name = "autoNext"
        m.account.autoNext = m.account.autoNext = false
        m.accounts[m.active] = m.account
        saveMetadata()
        showSettings()
    else if name = "quality"
        labels = []
        for each preset in RKQualityPresets()
            labels.push(preset.label)
        end for
        message("Streaming quality", "Choose a maximum bitrate. Jellyfin may transcode to fit the connection.", labels, "quality")
    else if name = "connectionOptions"
        m.connectionIndex = m.active
        message("Connection", "Sign out ends the session. Remove also deletes this saved connection label.", connectionChoices(m.connectionIndex), "connectionChoice")
    end if
end sub

' The first choice opens a signed-in account and reads "Sign in" for one that needs it.
function connectionChoices(index as integer) as object
    first = "Sign in"
    if index >= 0 and index < m.accounts.count()
        if RKString(m.accounts[index].token) <> "" then first = "Open"
    end if
    return [first, "Sign out", "Remove connection", "Cancel"]
end function

' Opens a title's details page; playFrom >= 0 starts playback from there once the details arrive.
sub openDetails(item as object, playFrom as double)
    m.requestedItemId = item.Id
    m.view = "details"
    m.playWhenLoaded = playFrom
    request("details", {itemId: item.Id})
end sub

sub showSeasonPage()
    page = RKLocalPage(m.seasonItemsFull, m.collectionStart)
    m.collectionStart = page.start
    m.pageRows = collectionRows(page.items, "Seasons", page.start, page.total, "season")
    showRows(m.pageRows, false, "No seasons are available for this series.")
end sub

sub retryPage()
    if m.view = "home"
        request("home", {})
    else if m.view = "library" or m.view = "search"
        loadLibrary()
    else if m.view = "details"
        request("details", {itemId: m.requestedItemId})
    else if m.view = "seasons"
        request("seasons", {itemId: m.detail.Id, start: m.collectionStart})
    else if m.view = "episodes"
        request("episodes", {itemId: m.episodeSeason.Id, seriesId: m.episodeSeason.SeriesId, start: m.collectionStart})
    else
        showConnections()
    end if
end sub

sub beginSignIn(metadata as object)
    m.draft = {server: RKString(metadata.server), username: RKString(metadata.username)}
    keyboard("Jellyfin server", m.draft.server, "server")
end sub

sub keyboard(title as string, value as string, purpose as string)
    d = CreateObject("roSGNode", "StandardKeyboardDialog")
    d.title = title
    d.text = value
    d.textEditBox.maxTextLength = 512
    if purpose = "search"
        d.buttons = ["Search", "Cancel"]
        d.textEditBox.hintText = "Movies, series and episodes"
    else
        d.buttons = ["Continue", "Cancel"]
        d.message = ["Passwords and sign-in tokens stay in memory for this app session."]
    end if
    if purpose = "password"
        d.buttons = ["Sign in", "Cancel"]
        d.keyboardDomain = "password"
        d.textEditBox.secureMode = true
    end if
    m.dialogPurpose = purpose
    d.observeField("buttonSelected", "onKeyboard")
    m.top.dialog = d
end sub

sub onKeyboard(event as object)
    d = m.top.dialog
    if d = invalid then return
    value = d.text
    selected = event.getData()
    d.text = ""
    d.close = true
    if selected <> 0 then return
    purpose = m.dialogPurpose
    if purpose = "server"
        base = RKNormalizeServer(value)
        if not base.ok
            message("Check the server address", base.error, ["Edit", "Cancel"], "serverError")
            return
        end if
        m.draft.server = base.url
        if base.insecure
            message("Trust this local network?", "HTTP sends sign-in details and video without encryption. Continue only on a local network you trust. HTTPS is recommended.", ["Continue on this network", "Cancel"], "trustHTTP")
        else
            keyboard("Username", m.draft.username, "username")
        end if
    else if purpose = "username"
        if value.trim() = ""
            keyboard("Enter your username", "", "username")
            return
        end if
        m.draft.username = value.trim()
        keyboard("Password", "", "password")
    else if purpose = "password"
        header("Connecting", "Making room for your library.", "Sign-in is for this app session. No password or token is saved to the registry.")
        request("auth", {account: {server: m.draft.server, token: "", userId: "", history: false}, username: m.draft.username, password: value})
        value = ""
    else if purpose = "search"
        if value.trim() = ""
            setStatus("Enter a title to search.")
            return
        end if
        m.options.search = value.trim()
        m.options.start = 0
        loadLibrary()
    end if
end sub

sub message(title as string, body as string, buttons as object, purpose as string)
    d = CreateObject("roSGNode", "StandardMessageDialog")
    d.title = title
    d.message = [body]
    d.buttons = buttons
    m.messagePurpose = purpose
    d.observeField("buttonSelected", "onMessage")
    m.top.dialog = d
end sub

sub onMessage(event as object)
    index = event.getData()
    purpose = m.messagePurpose
    if m.top.dialog <> invalid then m.top.dialog.close = true
    if purpose = "trustHTTP" and index = 0
        keyboard("Username", m.draft.username, "username")
    else if purpose = "serverError" and index = 0
        keyboard("Jellyfin server", m.draft.server, "server")
    else if purpose = "authError"
        if index = 0 then keyboard("Username", m.draft.username, "username") else showConnections()
    else if purpose = "connectionChoice"
        if index = 0 then activate(m.connectionIndex)
        if index = 1 then removeConnection(false)
        if index = 2 then removeConnection(true)
    else if purpose = "history" and index = 0
        m.account.history = true
        m.accounts[m.active] = m.account
        saveMetadata()
        showSettings()
    else if purpose = "quality"
        presets = RKQualityPresets()
        if index >= 0 and index < presets.count()
            m.bitrate = presets[index].bitrate
            m.account.bitrate = m.bitrate
            m.accounts[m.active] = m.account
            saveMetadata()
            showSettings()
        end if
    else if purpose = "pageOptions"
        if m.view = "home"
            if index = 0 then retryPage()
        else if m.view = "search"
            if index = 0 then keyboard("Search", m.options.search, "search")
            if index = 1 then retryPage()
        else if m.view = "library"
            if index = 0 then message("Filter", "Choose the titles to show.", ["All", "Movies", "Series", "Episodes"], "filter")
            if index = 1 then message("Sort", "Choose the order for this library.", ["Name", "Recently added", "Year"], "sort")
            if index = 2
                m.options.start = 0
                retryPage()
            end if
        end if
    else if purpose = "filter"
        values = ["All", "Movies", "Series", "Episodes"]
        m.options.filter = values[index]
        m.options.start = 0
        loadLibrary()
    else if purpose = "sort"
        values = ["Name", "Recently added", "Year"]
        m.options.sort = values[index]
        m.options.start = 0
        loadLibrary()
    else if purpose = "tracks"
        if index = 0 then trackDialog("audio")
        if index = 1 then trackDialog("subtitles")
    else if purpose = "audio" or purpose = "subtitles"
        if index < m.trackChoices.count()
            if purpose = "audio" then m.trackAudio = m.trackChoices[index] else m.trackSubtitle = m.trackChoices[index]
            setStatus("Track choice applies when you play this title.")
        end if
    else if purpose = "playbackError"
        if index = 0 then beginPlayback(m.playOptions.start, true) else showDetails()
    else if purpose = "nativePlaybackError"
        if index = 0 then beginPlayback(m.lastAbsolutePosition, true) else showDetails()
    else if purpose = "exit" and index = 0
        requestExit()
    else if purpose = "exitSaveFailure"
        if index = 0
            if m.storageCanSave
                m.metadata.failed = false
                requestExit()
            else
                showStorageRecovery()
            end if
        else if index = 1
            m.top.closeRequested = true
        end if
    else if purpose = "recoveryConflict"
        if index = 0 then showStorageRecovery()
    else if purpose = "storageRecovery"
        if index = 0
            if m.metadata.inFlight <> 0
                message("Connection labels are saving", "Wait for the current save to finish before retrying a read. This keeps recovery and pending saves in order.", ["OK"], "info")
            else
                m.storageCanSave = false
                m.recoveringStorage = true
                request("loadMetadata", {})
            end if
        else if index = 1
            m.storageCanSave = false
            showConnections()
        else if index = 2
            message("Replace saved labels?", "This replaces only Reel's saved connection labels and preferences with this session's labels. Passwords and tokens are never saved. Any existing saved labels not present in this session will be removed. Existing unreadable labels cannot be recovered by Reel after replacement.", ["Replace saved labels", "Cancel"], "storageReset")
        end if
    else if purpose = "storageReset" and index = 0
        m.storageCanSave = true
        m.metadata.failed = false
        saveMetadata(true)
        showConnections()
    else if purpose = "revocationReview"
        if index = 0
            request("logout", {account: m.revocationReview.account, revocationId: m.revocationReview.id}, true)
        else if index = 1
            remaining = []
            for each warning in m.revocationWarnings
                if warning.id <> m.revocationReview.id then remaining.push(warning)
            end for
            m.revocationWarnings = remaining
            showConnections()
        end if
    end if
end sub

sub requestExit()
    decision = RKMetadataExit(m.metadata, m.storageCanSave)
    if decision = "close"
        m.top.closeRequested = true
    else if decision = "confirm"
        confirmUnsavedExit()
    else
        m.exitAfterSave = true
        setStatus("Saving connection labels…")
        pumpMetadata()
    end if
end sub

sub removeConnection(removeLabel as boolean)
    updated = RKRemoveAccount(m.accounts, m.connectionIndex, m.active, removeLabel)
    if not updated.ok then return
    if RKString(updated.revoke.token) <> "" then request("logout", {account: updated.revoke}, true)
    m.accounts = updated.accounts
    m.active = updated.selected
    m.generation += 1
    m.nonce += 1
    m.busy = false
    m.stack = []
    if m.active >= 0
        m.account = m.accounts[m.active]
    else
        m.account = {server: "", token: "", userId: "", history: false}
    end if
    saveMetadata()
    showConnections()
end sub

sub trackDialog(kind as string)
    labels = ["Use device / server default"]
    choices = [invalid]
    if kind = "subtitles"
        labels.push("Off")
        choices.push(-1)
    end if
    if RKArray(m.detail.MediaSources)
        if m.detail.MediaSources.count() > 0
            source = m.detail.MediaSources[0]
            if RKArray(source.MediaStreams)
                for each stream in source.MediaStreams
                    target = "Audio"
                    if kind = "subtitles" then target = "Subtitle"
                    if RKString(stream.Type) = target and stream.Index <> invalid
                        labels.push(RKString(stream.DisplayTitle, RKString(stream.Language, target)))
                        choices.push(stream.Index)
                    end if
                end for
            end if
        end if
    end if
    m.trackChoices = choices
    message("Choose " + kind, "Your choice applies the next time you play this title.", labels, kind)
end sub

sub beginPlayback(start as double, forceHLS as boolean)
    if not RKCanStartPlayback(m.closing, m.video.visible) then return
    m.playerEpoch += 1
    m.autoNextCancelled = true
    m.playOptions = {start: RKSafeStart(start), forceHLS: forceHLS, bitrate: m.bitrate, audio: m.trackAudio, subtitle: m.trackSubtitle}
    if RKArray(m.detail.MediaSources)
        if m.detail.MediaSources.count() > 0 then m.playOptions.source = RKString(m.detail.MediaSources[0].Id)
    end if
    request("playback", {item: m.detail, options: m.playOptions})
end sub

sub playNative(plan as object)
    if not RKCanStartPlayback(m.closing, m.video.visible) then return
    m.autoNextCancelled = false
    m.finishedNaturally = false
    m.keepEpisodePanel = false
    m.playerItem = ParseJson(FormatJson(m.detail))
    m.playerPrevious = invalid
    m.playerNext = invalid
    m.introSegments = []
    m.playerActionNames = []
    m.video.playbackActionButtons = []
    m.plan = plan
    m.playAccount = ParseJson(FormatJson(m.account))
    m.reported = false
    m.lastPosition = plan.playStart
    m.lastAbsolutePosition = m.playOptions.start
    content = CreateObject("roSGNode", "ContentNode")
    content.url = plan.url
    content.title = plan.title
    content.streamFormat = plan.format
    content.playStart = plan.playStart
    content.HttpCertificatesFile = "common:/certs/ca-bundle.crt"
    content.HttpHeaders = ["Authorization:" + RKAuthorization(m.playAccount, m.device)]
    content.HttpCookies = []
    content.HttpSendClientCertificate = false
    m.video.content = content
    m.video.visible = true
    m.video.setFocus(true)
    m.video.control = "play"
    if RKString(m.playerItem.Type) = "Episode" and RKString(m.playerItem.SeriesId) <> ""
        request("playerContext", {item: m.playerItem, playerEpoch: m.playerEpoch}, true)
    end if
    if RKString(m.playerItem.Type) = "Episode" or RKString(m.playerItem.Type) = "Movie"
        request("playerIntro", {itemId: m.playerItem.Id, playerEpoch: m.playerEpoch}, true)
    end if
    updatePlayerActions()
end sub

sub onVideoPosition()
    if m.closing then return
    m.lastPosition = m.video.position
    if m.plan <> invalid then m.lastAbsolutePosition = m.lastPosition + m.plan.offset
    updatePlayerActions()
end sub

sub onVideoState()
    state = m.video.state
    if state = "finished" then m.finishedNaturally = true
    if m.closing
        if state = "stopped" then stoppedPlayer()
        return
    end if
    if state = "playing"
        if not m.reported
            m.reported = true
            sendReport("start")
        end if
        m.reportTimer.control = "start"
    else if state = "paused"
        sendReport("progress")
    else if state = "error" or state = "finished"
        closePlayer(RKPlayerEndReason(state, m.pendingEpisodeId))
    else if state = "stopped" and m.closing
        stoppedPlayer()
    end if
end sub

sub onReportTimer()
    if m.video.state = "playing" or m.video.state = "paused" then sendReport("progress")
end sub

sub sendReport(event as string)
    if m.plan = invalid or not m.reported then return
    if m.playAccount.history <> true then return
    if m.reportBusy and event = "progress" then return
    m.reportQueue.push({account: ParseJson(FormatJson(m.playAccount)), plan: ParseJson(FormatJson(m.plan)), event: event, position: m.lastPosition, paused: m.video.state = "paused"})
    pumpReport()
end sub

sub pumpReport()
    if m.reportBusy or m.reportQueue.count() = 0 then return
    m.reportBusy = true
    entry = m.reportQueue.shift()
    if not RKHistoryAllowed(m.accounts, RKAccountKey(entry.account))
        m.reportBusy = false
        pumpReport()
        return
    end if
    request("report", entry, true)
end sub

sub closePlayer(reason as string)
    if m.closing then return
    m.nextEpisodeTimer.control = "stop"
    m.autoNextRemaining = 0
    m.keepEpisodePanel = reason = "finished" and m.episodePanel.visible and m.episodePanelMode <> "countdown" and m.pendingEpisodeId = ""
    if m.keepEpisodePanel then m.autoNextCancelled = true else m.episodePanel.visible = false
    if reason <> "episode"
        m.pendingEpisode = invalid
        m.pendingEpisodeId = ""
        m.transitionNonce += 1
    end if
    if reason <> "finished" then m.autoNextCancelled = true
    m.closing = true
    m.closeReason = reason
    m.reportTimer.control = "stop"
    m.stopTimer.control = "start"
    m.video.control = "stop"
    if m.video.state = "stopped" then stoppedPlayer()
end sub

sub stoppedPlayer()
    if not RKCanReleasePlayer(m.closing, m.video.state) then return
    m.stopTimer.control = "stop"
    sendReport("stopped")
    request("cleanup", {account: m.playAccount, plan: m.plan}, true)
    m.video.visible = false
    m.video.playbackActionButtons = []
    m.video.content = invalid
    m.plan = invalid
    m.closing = false
    m.reported = false
    if not RKObject(m.detail.UserData) then m.detail.UserData = {}
    m.detail.UserData.PlaybackPositionTicks = m.lastAbsolutePosition * 10000000.0
    if m.finishedNaturally = true then m.detail.UserData.PlaybackPositionTicks = 0
    showDetails()
    if m.keepEpisodePanel and m.episodePanel.visible then m.episodeChoices.setFocus(true)
    if m.closeReason = "episode" and m.pendingEpisodeId <> ""
        if RKObject(m.pendingEpisode)
            startPendingEpisode()
        else if m.pendingEpisodeError <> ""
            showEpisodeTransitionError()
        else
            showEpisodePanel("Opening episode", "Preparing the selected episode…", ["Cancel"], [{kind: "cancel"}], "transition")
        end if
    else
        maybeShowNextEpisode()
    end if
    if m.closeReason = "error"
        message("Playback interrupted", "Try a compatible HLS stream from this position, or return to the title.", ["Try compatible playback", "Return to title"], "nativePlaybackError")
    end if
end sub

sub onStopTimeout()
    if not m.closing then return
    message("The player is still stopping", "Press the Roku Home button before starting another video. Reel will not replace a player while its stop is unresolved.", ["OK"], "info")
    ' Never replace a Video node while its asynchronous stop is unresolved.
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if not m.video.visible and not m.episodePanel.visible then m.autoNextCancelled = true
    if m.top.dialog <> invalid
        if m.top.dialog.visible then return false
    end if
    if m.episodePanel.visible
        if key = "back"
            if m.episodePanelMode = "episodes"
                showPlayerSeasons()
            else
                closeEpisodePanel()
            end if
            return true
        end if
        return false
    end if
    if m.video.visible
        if key = "back"
            closePlayer("back")
            return true
        end if
        return false
    end if
    if key = "up" or key = "down"
        area = "actions"
        rowIndex = 0
        if m.nav.hasFocus()
            area = "nav"
        else if m.buttons.hasFocus()
            area = "buttons"
        else if m.rows.hasFocus()
            area = "rows"
            rowIndex = m.rows.rowItemFocused[0]
        end if
        route = RKFocusRoute(key, area, {rowIndex: rowIndex, actionIndex: m.actions.itemFocused, navVisible: true, buttonsVisible: m.buttons.visible, rowsVisible: m.rows.visible, actionsVisible: m.actions.visible})
        if route <> ""
            focusArea(route)
            return true
        end if
        return false
    end if
    if key = "back"
        if m.stack.count() > 0
            backPage()
        else if m.nav.hasFocus()
            if m.nav.selectedIndex > 0 and m.active >= 0 and m.view <> "connections"
                m.nav.selectedIndex = 0
                m.nav.focusIndex = 0
                navigate("home")
            else
                message("Leave Reel?", "Sign-in tokens will be removed from memory when the app closes.", ["Leave Reel", "Stay"], "exit")
            end if
        else
            m.nav.setFocus(true)
        end if
        return true
    end if
    if key = "options" and not m.busy
        if m.view = "home" then message("Home", "Refresh the shelves from your server.", ["Refresh", "Cancel"], "pageOptions")
        if m.view = "library" then message("Library", "Shape your collection.", ["Filter", "Sort", "Refresh", "Cancel"], "pageOptions")
        if m.view = "search" then message("Search", "Find another title or refresh these results.", ["New search", "Refresh", "Cancel"], "pageOptions")
        return true
    end if
    return false
end function

sub updatePlayerActions()
    if not m.video.visible or m.closing or not RKObject(m.playerItem) then return
    names = []
    buttons = []
    if RKObject(m.playerPrevious)
        names.push("previous")
        buttons.push({text: "Previous episode"})
    end if
    if RKObject(m.playerNext)
        names.push("next")
        buttons.push({text: "Next episode"})
    end if
    if RKString(m.playerItem.Type) = "Episode" and RKString(m.playerItem.SeriesId) <> ""
        names.push("episodes")
        buttons.push({text: "Episodes"})
    end if
    if m.plan <> invalid
        if RKIntroTarget(m.introSegments, m.playerItem, m.lastAbsolutePosition, m.plan.offset, m.video.duration) >= 0
            names.push("intro")
            buttons.push({text: "Skip intro"})
        end if
    end if
    if names.join("|") <> m.playerActionNames.join("|")
        m.playerActionNames = names
        m.video.playbackActionButtons = buttons
    end if
end sub

sub onPlayerAction()
    if not m.video.visible or m.closing then return
    index = m.video.playbackActionButtonSelected
    if index < 0 or index >= m.playerActionNames.count() then return
    action = m.playerActionNames[index]
    if action = "previous" then queueEpisode(m.playerPrevious)
    if action = "next" then queueEpisode(m.playerNext)
    if action = "episodes" then showPlayerSeasons()
    if action = "intro" and m.plan <> invalid
        target = RKIntroTarget(m.introSegments, m.playerItem, m.lastAbsolutePosition, m.plan.offset, m.video.duration)
        if target >= 0 then m.video.seek = target
    end if
end sub

sub showEpisodePanel(title as string, description as string, labels as object, actions as object, mode as string)
    m.episodePanelMode = mode
    m.episodeChoiceActions = actions
    setText("episodePanelTitle", title)
    setText("episodePanelMessage", description)
    m.episodeChoices.content = textContent(labels)
    m.episodeChoices.jumpToItem = 0
    m.episodePanel.visible = true
    m.episodeChoices.setFocus(true)
end sub

sub closeEpisodePanel()
    if not m.video.visible or m.episodePanelMode = "countdown" then m.autoNextCancelled = true
    m.nextEpisodeTimer.control = "stop"
    m.autoNextRemaining = 0
    m.pickerNonce += 1
    m.transitionNonce += 1
    m.pendingEpisodeId = ""
    m.pendingEpisode = invalid
    m.pendingEpisodeError = ""
    m.keepEpisodePanel = false
    m.episodePanel.visible = false
    m.episodePanelMode = ""
    if m.video.visible then m.video.setFocus(true) else restoreFocus()
end sub

sub showPlayerSeasons()
    if not RKObject(m.playerItem) or m.closing then return
    if m.video.state = "playing" then m.video.control = "pause"
    m.pickerNonce += 1
    showEpisodePanel("Choose a season", "Loading seasons…", ["Cancel"], [{kind: "cancel"}], "loading-seasons")
    request("playerSeasons", {itemId: m.playerItem.SeriesId, playerEpoch: m.playerEpoch, pickerNonce: m.pickerNonce}, true)
end sub

sub showPlayerEpisodes(season as object, start as integer)
    m.pickerNonce += 1
    m.pickerSeason = season
    m.pickerStart = start
    showEpisodePanel(RKString(season.Name, "Episodes"), "Loading episodes…", ["Cancel"], [{kind: "cancel"}], "loading-episodes")
    request("playerEpisodes", {itemId: season.Id, seriesId: m.playerItem.SeriesId, start: start, playerEpoch: m.playerEpoch, pickerNonce: m.pickerNonce}, true)
end sub

sub onPlayerResult(source as dynamic, result as object)
    if not RKPlayerRequestMatches(source, RKAccountKey(m.account), m.generation, m.playerEpoch) then return
    if not RKObject(m.playerItem) then return
    kind = source.kind
    if kind = "playerContext"
        if result.ok
            m.playerPrevious = result.previous
            m.playerNext = result.next
        end if
        updatePlayerActions()
        maybeShowNextEpisode()
        return
    end if
    if kind = "playerIntro"
        if m.closing or not m.video.visible then return
        if result.ok then m.introSegments = result.segments
        updatePlayerActions()
        return
    end if
    if kind = "playerDetail"
        if source.transitionNonce <> m.transitionNonce or source.itemId <> m.pendingEpisodeId then return
        if not result.ok
            m.pendingEpisodeError = result.error
            if not m.closing then showEpisodeTransitionError()
            return
        end if
        if not RKEpisodeItem(result.item, RKString(m.playerItem.SeriesId)) or result.item.Id <> m.pendingEpisodeId
            m.pendingEpisodeError = "The server returned a different episode. Return and choose again."
            if not m.closing then showEpisodeTransitionError()
            return
        end if
        m.pendingEpisode = result.item
        m.pendingEpisodeError = ""
        if m.closing then return
        if m.video.visible then closePlayer("episode") else startPendingEpisode()
        return
    end if
    if m.closing and not m.keepEpisodePanel then return
    if source.pickerNonce <> m.pickerNonce or not m.episodePanel.visible then return
    if not result.ok
        retry = "retry-seasons"
        if kind = "playerEpisodes" then retry = "retry-episodes"
        showEpisodePanel("Episodes unavailable", result.error, ["Retry", "Cancel"], [{kind: retry}, {kind: "cancel"}], "picker-error")
        return
    end if
    labels = []
    actions = []
    if kind = "playerSeasons"
        for each season in result.items
            if RKString(season.Type) = "Season" and RKString(season.SeriesId, m.playerItem.SeriesId) = m.playerItem.SeriesId
                labels.push(RKString(season.Name, "Season"))
                actions.push({kind: "season", item: season})
            end if
        end for
        description = "Choose a season, then an episode. Playback stays paused."
        if labels.count() = 0 then description = "No seasons are available."
        labels.push("Cancel")
        actions.push({kind: "cancel"})
        showEpisodePanel("Seasons", description, labels, actions, "seasons")
    else if kind = "playerEpisodes"
        for each episode in result.items
            if RKEpisodeItem(episode, m.playerItem.SeriesId)
                label = RKString(episode.Name, "Episode")
                if episode.IndexNumber <> invalid then label = str(int(RKNumber(episode.IndexNumber))).trim() + ". " + label
                if episode.Id = m.playerItem.Id then label += " · Playing"
                labels.push(label)
                actions.push({kind: "episode", item: episode})
            end if
        end for
        description = "Choose an episode to start from the beginning."
        if labels.count() = 0 then description = "No episodes are available in this season."
        if m.pickerStart > 0
            labels.push("Previous page")
            actions.push({kind: "page", start: m.pickerStart - 60})
        end if
        if m.pickerStart + result.received < result.total and result.received > 0
            labels.push("Next page")
            actions.push({kind: "page", start: m.pickerStart + result.received})
        end if
        labels.push("Choose another season")
        actions.push({kind: "seasons"})
        labels.push("Cancel")
        actions.push({kind: "cancel"})
        showEpisodePanel(RKString(m.pickerSeason.Name, "Episodes"), description, labels, actions, "episodes")
    end if
end sub

sub onEpisodeChoice()
    index = m.episodeChoices.itemSelected
    if index < 0 or index >= m.episodeChoiceActions.count() then return
    choice = m.episodeChoiceActions[index]
    if choice.kind = "cancel" then closeEpisodePanel()
    if choice.kind = "season" then showPlayerEpisodes(choice.item, 0)
    if choice.kind = "seasons" or choice.kind = "retry-seasons" then showPlayerSeasons()
    if choice.kind = "page" then showPlayerEpisodes(m.pickerSeason, choice.start)
    if choice.kind = "retry-episodes" then showPlayerEpisodes(m.pickerSeason, m.pickerStart)
    if choice.kind = "episode"
        if choice.item.Id = m.playerItem.Id then closeEpisodePanel() else queueEpisode(choice.item)
    end if
    if choice.kind = "play-next" then queueEpisode(m.playerNext)
    if choice.kind = "retry-detail" then requestEpisodeDetail()
end sub

sub queueEpisode(item as dynamic)
    if m.closing or not RKObject(m.playerItem) then return
    if not RKEpisodeItem(item, RKString(m.playerItem.SeriesId)) then return
    if item.Id = m.playerItem.Id then return
    if m.video.state = "playing" then m.video.control = "pause"
    m.nextEpisodeTimer.control = "stop"
    m.autoNextRemaining = 0
    m.transitionNonce += 1
    m.pickerNonce += 1
    m.pendingEpisodeId = item.Id
    m.pendingEpisode = invalid
    m.pendingEpisodeError = ""
    m.autoNextCancelled = true
    requestEpisodeDetail()
end sub

sub requestEpisodeDetail()
    if m.pendingEpisodeId = "" or m.closing then return
    m.pendingEpisodeError = ""
    showEpisodePanel("Opening episode", "Preparing the selected episode…", ["Cancel"], [{kind: "cancel"}], "transition")
    request("playerDetail", {itemId: m.pendingEpisodeId, playerEpoch: m.playerEpoch, transitionNonce: m.transitionNonce}, true)
end sub

sub startPendingEpisode()
    if not RKObject(m.pendingEpisode) or not RKCanStartPlayback(m.closing, m.video.visible) then return
    nextItem = m.pendingEpisode
    closeEpisodePanel()
    m.detail = nextItem
    m.requestedItemId = nextItem.Id
    m.trackAudio = invalid
    m.trackSubtitle = invalid
    showDetails()
    beginPlayback(0, false)
end sub

sub showEpisodeTransitionError()
    showEpisodePanel("Could not open this episode", m.pendingEpisodeError, ["Retry", "Cancel"], [{kind: "retry-detail"}, {kind: "cancel"}], "transition-error")
end sub

sub maybeShowNextEpisode()
    if m.closing or m.video.visible or m.episodePanel.visible or m.pendingEpisodeId <> "" then return
    if not RKObject(m.playerItem) or not RKObject(m.playAccount) then return
    if RKAutoNextAllowed(RKString(m.closeReason), true, m.account.autoNext <> false, m.playerItem, m.playerNext, RKAccountKey(m.account), RKAccountKey(m.playAccount), m.autoNextCancelled) then showNextEpisode()
end sub

sub showNextEpisode()
    if m.top.dialog <> invalid
        if m.top.dialog.visible
            m.autoNextCancelled = true
            return
        end if
    end if
    m.autoNextRemaining = 8
    showEpisodePanel("Up next", RKString(m.playerNext.Name, "Next episode") + " starts in 8 seconds.", ["Play now", "Cancel"], [{kind: "play-next"}, {kind: "cancel"}], "countdown")
    m.episodeChoices.jumpToItem = 1
    m.nextEpisodeTimer.control = "start"
end sub

sub onNextEpisodeTimer()
    if m.top.dialog <> invalid
        if m.top.dialog.visible
            closeEpisodePanel()
            return
        end if
    end if
    if m.episodePanelMode <> "countdown" or not m.episodePanel.visible or m.autoNextRemaining <= 0 then return
    if not RKAutoNextAllowed(m.closeReason, not m.closing and not m.video.visible, m.account.autoNext <> false, m.playerItem, m.playerNext, RKAccountKey(m.account), RKAccountKey(m.playAccount), m.autoNextCancelled)
        closeEpisodePanel()
        return
    end if
    m.autoNextRemaining -= 1
    if m.autoNextRemaining = 0
        queueEpisode(m.playerNext)
    else
        setText("episodePanelMessage", RKString(m.playerNext.Name, "Next episode") + " starts in " + str(m.autoNextRemaining).trim() + " seconds.")
    end if
end sub
