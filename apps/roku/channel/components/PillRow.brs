' Styles: "tabs" (top navigation), "buttons" (Details actions), "pill" (Skip Intro).
sub init()
    m.items = m.top.findNode("items")
    m.track = m.top.findNode("track")
    m.indicator = m.top.findNode("indicator")
    m.cells = []
    m.top.observeField("focusedChild", "onFocusChange")
end sub

function styleSpec() as object
    style = m.top.style
    if style = "tabs" then return {height: 60, padding: 30, gap: 6, minWidth: 0, inset: 6, fill: "pkg:/images/fill-pill.9.png"}
    if style = "pill" then return {height: 66, padding: 36, gap: 0, minWidth: 0, inset: 0, fill: "pkg:/images/fill-pill.9.png"}
    return {height: 64, padding: 36, gap: 16, minWidth: 180, inset: 0, fill: "pkg:/images/fill-pill.9.png"}
end function

sub rebuild()
    while m.items.getChildCount() > 0
        m.items.removeChildIndex(0)
    end while
    m.cells = []
    spec = styleSpec()
    x = spec.inset
    labels = m.top.labels
    if labels = invalid then labels = []
    for each text in labels
        cell = m.items.createChild("Group")
        fill = cell.createChild("Poster")
        fill.uri = spec.fill
        label = cell.createChild("Label")
        label.font = "font:SmallerBoldSystemFont"
        label.text = text
        label.horizAlign = "center"
        label.vertAlign = "center"
        measured = label.boundingRect().width
        if measured <= 0 then measured = len(text) * 17
        width = int(measured + spec.padding * 2)
        if width < spec.minWidth then width = spec.minWidth
        width = int((width + 2) / 3) * 3
        cell.translation = [x, spec.inset]
        cell.scaleRotateCenter = [width / 2, spec.height / 2]
        fill.width = width
        fill.height = spec.height
        label.width = width
        label.height = spec.height
        m.cells.push({group: cell, fill: fill, label: label, x: x, width: width})
        x += width + spec.gap
    end for
    if m.cells.count() > 0 then x -= spec.gap
    x += spec.inset
    m.top.rowWidth = x
    m.top.rowHeight = spec.height + spec.inset * 2
    m.track.visible = m.top.style = "tabs" and m.cells.count() > 0
    m.track.width = x
    m.track.height = spec.height + spec.inset * 2
    m.track.blendColor = "0x17171AC7"
    if m.top.focusIndex >= m.cells.count() then m.top.focusIndex = 0
    render()
end sub

sub render()
    style = m.top.style
    active = m.top.focused
    for i = 0 to m.cells.count() - 1
        cell = m.cells[i]
        isFocus = active and i = m.top.focusIndex
        cell.group.scale = [1, 1]
        if style = "tabs"
            cell.fill.visible = isFocus
            cell.fill.blendColor = "0xF4F4F6FF"
            if isFocus
                cell.label.color = "0x0C0C0EFF"
            else if i = m.top.selectedIndex
                cell.label.color = "0xF4F4F6FF"
            else
                cell.label.color = "0xF4F4F6A3"
            end if
        else if style = "pill"
            cell.fill.visible = true
            if isFocus
                cell.fill.blendColor = "0xF4F4F6FF"
                cell.label.color = "0x0C0C0EFF"
            else
                cell.fill.blendColor = "0x222226F2"
                cell.label.color = "0xF4F4F6FF"
            end if
        else
            ' Capsules: only the focused button turns white. While focus is on a card every button
            ' stays grey, as on the other TV clients, so one thing is lit at a time. Rings belong to cards.
            cell.fill.visible = true
            if isFocus
                cell.fill.blendColor = "0xF4F4F6FF"
                cell.label.color = "0x0C0C0EFF"
            else
                cell.fill.blendColor = "0xFFFFFF26"
                cell.label.color = "0xF4F4F6FF"
            end if
            if isFocus then cell.group.scale = [1.05, 1.05]
        end if
    end for
    showIndicator = style = "tabs" and m.top.selectedIndex >= 0 and m.top.selectedIndex < m.cells.count()
    if showIndicator and active then showIndicator = m.top.focusIndex <> m.top.selectedIndex
    m.indicator.visible = showIndicator
    if showIndicator
        cell = m.cells[m.top.selectedIndex]
        m.indicator.translation = [cell.x + int((cell.width - 30) / 2), 54]
    end if
end sub

sub onFocusChange()
    m.top.focused = m.top.hasFocus()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press or m.cells.count() = 0 then return false
    if key = "left" and m.top.focusIndex > 0
        m.top.focusIndex -= 1
        return true
    end if
    if key = "right" and m.top.focusIndex < m.cells.count() - 1
        m.top.focusIndex += 1
        return true
    end if
    if key = "OK"
        m.top.itemSelected = m.top.focusIndex
        return true
    end if
    return false
end function
