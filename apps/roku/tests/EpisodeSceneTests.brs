' These tests execute verbatim Scene handlers with fields in place of native nodes.
' They deliberately control callback order; they are not SceneGraph emulation.
sub main()
    m.checks = []

    resetEpisodeScene()
    source = ownedRequest("playerContext")
    closePlayer("finished")
    onPlayerResult(source, contextResult())
    expectScene("late-context-during-stop-retained", RKObject(m.playerNext), true)
    stoppedCallback()
    expectScene("late-context-during-stop-countdown", m.episodePanelMode, "countdown")

    resetEpisodeScene()
    source = ownedRequest("playerContext")
    closePlayer("finished")
    stoppedCallback()
    onPlayerResult(source, contextResult())
    expectScene("late-context-after-stop-countdown", m.episodePanelMode, "countdown")
    expectScene("late-context-full-countdown", m.autoNextRemaining, 8)
    closeEpisodePanel()
    onPlayerResult(source, contextResult())
    expectScene("cancelled-eof-does-not-restart", m.episodePanel.visible, false)
    expectScene("cancelled-eof-timer-stopped", m.nextEpisodeTimer.control, "stop")

    resetEpisodeScene()
    source = ownedRequest("playerContext")
    closePlayer("back")
    stoppedCallback()
    onPlayerResult(source, contextResult())
    expectScene("back-rejects-late-autoplay", m.episodePanel.visible, false)

    resetEpisodeScene()
    queueEpisode(testEpisode("chosen"))
    source = m.requests[m.requests.count() - 1]
    m.video.state = "finished"
    onVideoState()
    onPlayerResult(source, {ok: true, item: testEpisode("chosen")})
    expectScene("selected-detail-waits-for-stopped", m.starts.count(), 0)
    stoppedCallback()
    expectScene("selected-detail-before-stopped-kept", m.starts.join("|"), "chosen")
    stoppedCallback()
    expectScene("repeated-stopped-does-not-restart", m.starts.count(), 1)

    resetEpisodeScene()
    queueEpisode(testEpisode("chosen"))
    source = m.requests[m.requests.count() - 1]
    m.video.state = "finished"
    onVideoState()
    stoppedCallback()
    expectScene("selected-detail-after-stopped-waits", m.starts.count(), 0)
    onPlayerResult(source, {ok: true, item: testEpisode("chosen")})
    expectScene("selected-detail-after-stopped-kept", m.starts.join("|"), "chosen")

    resetEpisodeScene()
    queueEpisode(testEpisode("chosen"))
    source = m.requests[m.requests.count() - 1]
    closeEpisodePanel()
    onPlayerResult(source, {ok: true, item: testEpisode("chosen")})
    expectScene("cancel-selection-discards-late-detail", m.starts.count(), 0)
    expectScene("cancel-selection-keeps-current-video", m.video.visible, true)

    resetEpisodeScene()
    queueEpisode(testEpisode("chosen"))
    source = m.requests[m.requests.count() - 1]
    m.video.state = "finished"
    onVideoState()
    onPlayerResult(source, {ok: false, error: "Fixture unavailable"})
    expectScene("detail-error-during-stop-does-not-start", m.starts.count(), 0)
    stoppedCallback()
    expectScene("detail-error-after-stop-offers-retry", m.episodePanelMode, "transition-error")
    requestEpisodeDetail()
    source = m.requests[m.requests.count() - 1]
    onPlayerResult(source, {ok: true, item: testEpisode("chosen")})
    expectScene("detail-retry-starts-selected-episode", m.starts.join("|"), "chosen")

    for each stale in ["accountKey", "generation", "playerEpoch"]
        resetEpisodeScene()
        source = ownedRequest("playerContext")
        if stale = "accountKey" then source.accountKey = "other" else source[stale] = 99
        onPlayerResult(source, contextResult())
        expectScene("stale-" + stale + "-cannot-change-neighbors", RKObject(m.playerNext), false)
    end for

    resetEpisodeScene()
    m.playerNext = testEpisode("next")
    closePlayer("finished")
    stoppedCallback()
    for i = 1 to 10
        onNextEpisodeTimer()
    end for
    detailRequests = 0
    for each item in m.requests
        if item.kind = "playerDetail" then detailRequests += 1
    end for
    expectScene("countdown-requests-next-exactly-once", detailRequests, 1)
    expectScene("countdown-awaits-detail-before-start", m.starts.count(), 0)
    expectScene("countdown-selects-expected-next", m.pendingEpisodeId, "next")

    resetEpisodeScene()
    m.playerNext = testEpisode("next")
    closePlayer("finished")
    stoppedCallback()
    m.top.dialog = {visible: true}
    onNextEpisodeTimer()
    expectScene("dialog-cancels-countdown", m.episodePanel.visible, false)
    expectScene("dialog-does-not-start-playback", m.starts.count(), 0)

    resetEpisodeScene()
    m.playerNext = testEpisode("next")
    showPlayerSeasons()
    source = m.requests[m.requests.count() - 1]
    m.video.state = "finished"
    onVideoState()
    expectScene("picker-remains-visible-during-eof-stop", m.episodePanel.visible, true)
    onPlayerResult(source, {ok: true, items: [{Id: "season-1", Name: "Season 1", Type: "Season", SeriesId: "series"}]})
    expectScene("picker-result-can-complete-during-stop", m.episodePanelMode, "seasons")
    stoppedCallback()
    expectScene("picker-not-replaced-by-autoplay", m.episodePanelMode, "seasons")
    expectScene("picker-eof-cancels-auto-next", m.autoNextCancelled, true)
    closeEpisodePanel()
    onPlayerResult(source, {ok: true, items: []})
    expectScene("cancelled-picker-rejects-late-results", m.episodePanel.visible, false)
    onPlayerResult(ownedRequest("playerContext"), contextResult())
    expectScene("cancelled-picker-rejects-late-countdown", m.episodePanel.visible, false)

    resetEpisodeScene()
    m.introSegments = [{Id: "intro", Type: "Intro", StartTicks: 0, EndTicks: 100000000}]
    m.lastAbsolutePosition = 2
    updatePlayerActions()
    expectScene("intro-action-visible-inside-valid-range", m.playerActionNames.join("|"), "episodes|intro")
    m.video.playbackActionButtonSelected = 1
    onPlayerAction()
    expectScene("intro-action-seeks-valid-boundary", m.video.seek, 10)
    m.video.seek = -1
    m.video.duration = 5
    onPlayerAction()
    expectScene("stale-intro-action-rechecks-real-duration", m.video.seek, -1)
    updatePlayerActions()
    expectScene("over-end-intro-action-hidden", m.playerActionNames.join("|"), "episodes")
    m.video.duration = 0
    updatePlayerActions()
    expectScene("unknown-duration-intro-hidden", m.playerActionNames.join("|"), "episodes")

    ' Focus lands on something visible when the player or a panel closes.
    resetEpisodeScene()
    m.video.visible = false
    m.episodePanel.visible = true
    m.buttons.visible = true
    m.rows.visible = true
    m.actions.visible = true
    closeEpisodePanel()
    expectScene("panel-close-details-focuses-buttons", m.buttons.focused, true)
    expectScene("panel-close-details-leaves-other-areas", m.rows.focused or m.actions.focused, false)

    resetEpisodeScene()
    m.video.visible = false
    m.rows.visible = true
    closeEpisodePanel()
    expectScene("panel-close-home-focuses-rows", m.rows.focused, true)

    resetEpisodeScene()
    m.video.visible = false
    m.actions.visible = true
    closeEpisodePanel()
    expectScene("panel-close-list-focuses-actions", m.actions.focused, true)

    resetEpisodeScene()
    m.video.visible = false
    m.nav.focused = false
    closeEpisodePanel()
    expectScene("panel-close-empty-screen-focuses-tabs", m.nav.focused, true)

    resetEpisodeScene()
    m.rows.visible = true
    claimFocus("rows")
    expectScene("loaded-rows-do-not-steal-focus-from-tabs", m.rows.focused, false)
    m.nav.focused = false
    claimFocus("rows")
    expectScene("loaded-rows-take-focus-from-content", m.rows.focused, true)

    resetEpisodeScene()
    m.video.visible = true
    closeEpisodePanel()
    expectScene("panel-close-during-playback-returns-to-video", m.video.focused, true)

    ' Back returns focus to the button that opened the page: Episodes on a series page.
    resetBackScene()
    m.buttons.focused = true
    m.buttons.focusIndex = 1
    pushPage()
    leavePage("episodes")
    backPage()
    expectScene("back-details-focuses-opening-button", m.buttons.focused, true)
    expectScene("back-details-keeps-opening-index", m.buttons.focusIndex, 1)
    expectScene("back-details-leaves-rows", m.rows.focused, false)

    ' The same from the Home hero: Details opened the page, so Details has focus again.
    resetBackScene()
    m.view = "home"
    m.layoutMode = "hero"
    m.buttonNames = ["heroPlay", "heroDetails"]
    m.buttons.focused = true
    m.buttons.focusIndex = 1
    pushPage()
    leavePage("details")
    backPage()
    expectScene("back-hero-focuses-opening-button", m.buttons.focused, true)
    expectScene("back-hero-keeps-opening-index", m.buttons.focusIndex, 1)
    expectScene("back-hero-leaves-rows", m.rows.focused, false)

    ' A hero showing a "See all" tile has no buttons, so the rows take focus.
    resetBackScene()
    m.view = "home"
    m.layoutMode = "hero"
    m.buttons.focused = true
    pushPage()
    leavePage("details")
    m.heroButtons = false
    backPage()
    expectScene("back-hero-without-buttons-focuses-rows", m.rows.focused, true)

    ' After reported playback the episode list reloads and its focus returns to the episode left from.
    resetBackScene()
    m.view = "episodes"
    m.layoutMode = "hero"
    m.episodeSeason = {Id: "season-1", SeriesId: "series"}
    m.rows.focused = true
    m.rows.rowItemFocused = [0, 2]
    pushPage()
    leavePage("details")
    m.historyDirty = true
    backPage()
    reload = m.requests[m.requests.count() - 1]
    expectScene("back-after-playback-reloads-episodes", reload.kind, "episodes")
    expectScene("back-after-playback-reloads-same-season", reload.itemId, "season-1")
    expectScene("back-after-playback-clears-history-flag", m.historyDirty, false)
    showRows(m.pageRows)
    restoreReloadFocus()
    expectScene("episode-reload-jumps-to-left-episode", FormatJson(m.rows.jumpToRowItem), "[0,2]")
    expectScene("episode-reload-shows-left-episode", FormatJson(m.followed), "[0,2]")
    expectScene("episode-reload-focus-used-once", m.reloadFocus, invalid)

    ' A reloaded series page puts focus back on the button pressed, or the last one it still has.
    for each names in [["nextUp", "seasonEpisodes"], ["seasonEpisodes"]]
        resetBackScene()
        m.buttons.focused = true
        m.buttons.focusIndex = 1
        pushPage()
        leavePage("episodes")
        m.historyDirty = true
        backPage()
        expectScene("back-after-playback-reloads-details-" + str(names.count()).trim(), m.requests[m.requests.count() - 1].kind, "details")
        m.buttonNames = names
        m.buttons.focusIndex = 0
        restoreReloadFocus()
        expectScene("details-reload-focus-index-" + str(names.count()).trim(), m.buttons.focusIndex, names.count() - 1)
        expectScene("details-reload-focuses-buttons-" + str(names.count()).trim(), m.buttons.focused, true)
    end for

    ' A remembered position belongs to the page it was taken on.
    resetBackScene()
    m.reloadFocus = {view: "episodes", rows: [0, 2], button: 1}
    m.buttons.focusIndex = 0
    restoreReloadFocus()
    expectScene("reload-focus-ignored-on-other-page", m.buttons.focusIndex, 0)
    expectScene("reload-focus-cleared-on-other-page", m.reloadFocus, invalid)

    print "REEL_SCENE_RESULTS:"; FormatJson(m.checks)
end sub

sub expectScene(id as string, actual as dynamic, expected as dynamic)
    m.checks.push({id: id, actual: actual, expected: expected, passed: actual = expected})
end sub

function testEpisode(id as string) as object
    return {Id: id, Type: "Episode", SeriesId: "series", Name: id, UserData: {}, RunTimeTicks: 300000000}
end function

function contextResult() as object
    return {ok: true, previous: invalid, next: testEpisode("next")}
end function

sub resetEpisodeScene()
    m.account = {server: "https://fixture.example", userId: "viewer", autoNext: true}
    m.playAccount = m.account
    m.generation = 1
    m.playerEpoch = 1
    m.pickerNonce = 0
    m.transitionNonce = 0
    m.playerItem = testEpisode("current")
    m.detail = testEpisode("current")
    m.playerNext = invalid
    m.playerPrevious = invalid
    m.plan = {offset: 0}
    m.video = {visible: true, state: "playing", duration: 30, seek: -1, playbackActionButtons: [], setFocus: fakeFocus}
    m.reportTimer = {}
    m.stopTimer = {}
    m.nextEpisodeTimer = {}
    m.episodePanel = {visible: false}
    m.episodeChoices = {setFocus: fakeFocus}
    m.nav = fakeFocusNode(true)
    m.buttons = fakeFocusNode(false)
    m.rows = fakeFocusNode(false)
    m.actions = fakeFocusNode(false)
    m.top = {dialog: invalid}
    m.pendingEpisode = invalid
    m.pendingEpisodeId = ""
    m.pendingEpisodeError = ""
    m.autoNextCancelled = false
    m.finishedNaturally = false
    m.keepEpisodePanel = false
    m.autoNextRemaining = 0
    m.episodePanelMode = ""
    m.closing = false
    m.closeReason = ""
    m.introSegments = []
    m.playerActionNames = []
    m.requests = []
    m.starts = []
    m.lastPosition = 29
    m.lastAbsolutePosition = 29
    m.reported = true
end sub

sub stoppedCallback()
    m.video.state = "stopped"
    onVideoState()
end sub

sub fakeFocus(value as boolean)
    m.focused = value
end sub

function fakeHasFocus() as boolean
    return m.focused = true
end function

function fakeFocusNode(focused as boolean) as object
    return {visible: false, focused: focused, setFocus: fakeFocus, hasFocus: fakeHasFocus}
end function

sub setText(id as string, value as string)
end sub

function textContent(labels as object) as object
    return labels
end function

function ownedRequest(kind as string) as object
    return {kind: kind, accountKey: RKAccountKey(m.account), generation: m.generation, playerEpoch: m.playerEpoch}
end function

sub request(kind as string, extra as object, auxiliary = false as boolean)
    data = ownedRequest(kind)
    for each key in extra
        data[key] = extra[key]
    end for
    m.requests.push(data)
end sub

sub sendReport(kind as string)
end sub

sub showDetails()
end sub

sub message(title as string, body as string, buttons as object, purpose as string)
end sub

sub beginPlayback(start as double, forceHLS as boolean)
    m.starts.push(m.detail.Id)
end sub

' A series page with its two buttons and one seasons row, ready for pushPage and backPage.
sub resetBackScene()
    resetEpisodeScene()
    m.video.visible = false
    m.top = {dialog: invalid, findNode: fakeFindNode}
    m.stack = []
    m.view = "details"
    m.layoutMode = "details"
    m.pageRows = [{title: "Seasons", items: [{Id: "season-1"}, {Id: "season-2"}, {Id: "season-3"}]}]
    m.options = {filter: "All", sort: "Name", start: 0, search: ""}
    m.detail = {Id: "series", Type: "Series"}
    m.requestedItemId = "series"
    m.episodeSeason = invalid
    m.collectionStart = 0
    m.seasonItemsFull = []
    m.actionLabels = []
    m.actionNames = []
    m.trackAudio = invalid
    m.trackSubtitle = invalid
    m.historyDirty = false
    m.reloadFocus = invalid
    m.nonce = 0
    m.busy = false
    m.playWhenLoaded = -1
    m.buttonNames = ["nextUp", "seasonEpisodes"]
    m.heroButtons = true
    m.followed = invalid
    m.nav.focused = false
    m.buttons.visible = true
    m.buttons.focusIndex = 0
    m.rows.visible = true
    m.rows.content = fakeRowsContent([3])
    m.rows.rowItemFocused = [0, 0]
    m.rows.jumpToRowItem = invalid
end sub

' Stands in for opening the next page: the view changes and focus moves off this page's controls.
sub leavePage(view as string)
    m.view = view
    m.buttons.focused = false
    m.rows.focused = false
    m.actions.focused = false
end sub

function fakeFindNode(id as string) as object
    return {text: "", visible: true}
end function

function fakeRowsContent(counts as object) as object
    return {counts: counts, getChild: fakeContentRow}
end function

function fakeContentRow(index as integer) as dynamic
    if index < 0 or index >= m.counts.count() then return invalid
    return {size: m.counts[index], getChildCount: fakeRowItemCount}
end function

function fakeRowItemCount() as integer
    return m.size
end function

' Mirrors the real showRows focus rule: populated rows take focus unless told not to.
sub showRows(rows as object, takeFocus = true as boolean, emptyMessage = "" as string)
    m.rows.visible = rows.count() > 0
    if m.rows.visible and takeFocus then claimFocus("rows")
end sub

' The hero shows Play and Details for a title, and no buttons for a "See all" tile.
sub followFocus(position as object)
    m.followed = position
    m.buttons.visible = m.heroButtons
end sub

sub applyLayout(mode as string)
    m.layoutMode = mode
end sub

sub header(meta as string, title as string, description as string, eyebrow = "" as string)
end sub

sub setStatus(text as string, warning = false as boolean)
end sub

sub syncTabs()
end sub

sub updateAccountLabel()
end sub

sub showBackdrop(route as string, immediate as boolean)
end sub

sub showActions(labels as object, names as object)
    m.actions.visible = true
end sub

sub loadLibrary()
    request("library", {})
end sub

sub showConnections()
end sub
