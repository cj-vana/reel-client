sub init()
    m.poster = m.top.findNode("poster")
    m.ring = m.top.findNode("ring")
    m.shadow = m.top.findNode("shadow")
    m.caption = m.top.findNode("caption")
    m.subtitle = m.top.findNode("subtitle")
    m.progress = 0.0
    m.played = false
end sub

sub onContent()
    item = m.top.itemContent
    if item = invalid then return
    m.caption.text = item.title
    m.top.findNode("fallback").text = item.title
    m.subtitle.text = ""
    if item.hasField("subtitle") then m.subtitle.text = item.subtitle
    m.progress = 0.0
    if item.hasField("progress") then m.progress = item.progress
    m.played = false
    if item.hasField("played") then m.played = item.played = true
    m.poster.uri = ""
    if item.hasField("imageAuthorization")
        agent = CreateObject("roHttpAgent")
        if not agent.setCertificatesFile("common:/certs/ca-bundle.crt") then return
        agent.addHeader("Authorization", item.imageAuthorization)
        m.poster.setHttpAgent(agent)
    end if
    m.poster.uri = item.hdPosterUrl
    layout()
end sub

sub layout()
    w = m.top.width
    h = m.top.height
    if w <= 0 or h <= 0 then return
    m.top.findNode("base").width = w
    m.top.findNode("base").height = h
    fallback = m.top.findNode("fallback")
    fallback.translation = [12, 12]
    fallback.width = w - 24
    fallback.height = h - 24
    m.poster.width = w
    m.poster.height = h
    m.shadow.translation = [-40, -32]
    m.shadow.width = w + 80
    m.shadow.height = h + 80
    m.ring.translation = [-6, -6]
    m.ring.width = w + 12
    m.ring.height = h + 12
    ' Two 24 px lines under the art, ending 68 px below it; RKShapeSpec "after" leaves room at the focus scale.
    ' Landscape cards always show them, so each caption stays inside its own card's width.
    m.caption.translation = [0, h + 12]
    m.caption.width = w
    m.caption.height = 28
    m.subtitle.translation = [0, h + 40]
    m.subtitle.width = w
    m.subtitle.height = 28
    ' A played title carries a small mint check in the art's top right corner.
    watched = m.top.findNode("watched")
    watched.translation = [w - 48, 12]
    watched.visible = m.played
    if w > h
        m.caption.opacity = 1
        m.subtitle.opacity = 1
    end if
    ' The progress bar sits inside the art, 12 px from the sides and bottom, like the other TV clients.
    track = m.top.findNode("progressTrack")
    fill = m.top.findNode("progressFill")
    track.translation = [12, h - 18]
    track.width = w - 24
    track.height = 6
    fill.translation = [12, h - 18]
    fill.height = 6
    fill.width = int((w - 24) * m.progress)
    track.visible = m.progress > 0
    fill.visible = m.progress > 0
    m.top.scaleRotateCenter = [w / 2, h / 2]
end sub

sub onFocus()
    percent = m.top.focusPercent * m.top.rowFocusPercent
    if not m.top.rowListHasFocus then percent = 0
    m.ring.opacity = percent
    m.shadow.opacity = percent
    ' Landscape cards (Continue watching, Up next, episodes) keep their captions; posters show them on focus.
    captions = percent
    if m.top.width > m.top.height then captions = 1
    m.caption.opacity = captions
    m.subtitle.opacity = captions
    scale = 1 + 0.08 * percent
    m.top.scale = [scale, scale]
end sub
