sub Main()
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)
    scene = screen.createScene("ReelScene")
    scene.observeField("closeRequested", port)
    screen.show()
    while true
        message = wait(0, port)
        if type(message) = "roSGNodeEvent" then screen.close()
        if type(message) = "roSGScreenEvent"
            if message.isScreenClosed() then return
        end if
    end while
end sub
