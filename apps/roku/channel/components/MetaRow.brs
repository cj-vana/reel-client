' Parts come from RKMetaParts: {kind: "text" | "badge" | "star", text}. Text is the muted 26 px meta
' style; badges are a thin outline around smaller regular text, so they read as labels beside the facts
' rather than outweigh them, like the rating boxes on Apple TV.
function metaSpec() as object
    return {height: 36, gap: 20, textSize: 26, textColor: "0xF4F4F6A3", badgeHeight: 28, badgePadding: 8, badgeFont: 20, badgeFontUri: "font:SystemFontFile", badgeTint: "0xF4F4F6A3", badgeTextColor: "0xF4F4F6A3", starSize: 22, starGap: 8, starTint: "0xF4F4F6A3"}
end function

sub rebuild()
    while m.top.getChildCount() > 0
        m.top.removeChildIndex(0)
    end while
    spec = metaSpec()
    parts = m.top.parts
    if parts = invalid then parts = []
    x = 0
    for each part in parts
        if x > 0 then x += spec.gap
        if part.kind = "badge"
            x += addBadge(part.text, x, spec)
        else if part.kind = "star"
            icon = m.top.createChild("Poster")
            icon.uri = "pkg:/images/star.png"
            icon.width = spec.starSize
            icon.height = spec.starSize
            icon.blendColor = spec.starTint
            icon.translation = [x, int((spec.height - spec.starSize) / 2)]
            x += spec.starSize + spec.starGap
            x += addLabel(m.top, part.text, x, spec.height, "font:SystemFontFile", spec.textSize, spec.textColor)
        else
            x += addLabel(m.top, part.text, x, spec.height, "font:SystemFontFile", spec.textSize, spec.textColor)
        end if
    end for
    m.top.rowWidth = x
end sub

' Adds a label sized to its text and returns its width.
function addLabel(parent as object, text as string, x as float, height as integer, uri as string, size as integer, color as string) as float
    label = parent.createChild("Label")
    font = CreateObject("roSGNode", "Font")
    font.uri = uri
    font.size = size
    label.font = font
    label.color = color
    label.vertAlign = "center"
    label.text = text
    width = label.boundingRect().width
    if width <= 0 then width = len(text) * size * 0.56
    width = int(width + 0.5)
    label.width = width
    label.height = height
    label.translation = [x, 0]
    return width
end function

function addBadge(text as string, x as float, spec as object) as float
    badge = m.top.createChild("Group")
    frame = badge.createChild("Poster")
    frame.uri = "pkg:/images/badge.9.png"
    frame.blendColor = spec.badgeTint
    width = addLabel(badge, text, spec.badgePadding, spec.badgeHeight, spec.badgeFontUri, spec.badgeFont, spec.badgeTextColor) + spec.badgePadding * 2
    frame.width = width
    frame.height = spec.badgeHeight
    badge.translation = [x, int((spec.height - spec.badgeHeight) / 2)]
    return width
end function
