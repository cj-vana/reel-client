sub init()
    m.top.functionName = "execute"
end sub

sub execute()
    r = m.top.request
    m.transport = {send: transfer, batch: transferMany}
    m.storage = {read: readMetadataStorage, write: writeMetadataStorage}
    if r.kind = "report" and not m.top.historyAllowed
        result = RKError("Playback history is off for this account.")
    else
        result = perform(r)
    end if
    m.top.result = {request: {kind: r.kind, accountKey: r.accountKey, generation: r.generation, nonce: r.nonce, job: r.job}, result: result}
end sub

function startTransfer(envelope as object, port as object) as object
    if not envelope.ok then return envelope
    xfer = CreateObject("roUrlTransfer")
    xfer.setMessagePort(port)
    if not xfer.setCertificatesFile("common:/certs/ca-bundle.crt") then return RKError("The platform certificate bundle is unavailable.")
    if not xfer.enablePeerVerification(true) then return RKError("The platform could not enable certificate verification.")
    if not xfer.enableHostVerification(true) then return RKError("The platform could not enable host verification.")
    xfer.retainBodyOnError(true)
    xfer.setUrl(envelope.url)
    for each key in envelope.headers
        xfer.addHeader(key, envelope.headers[key])
    end for
    if envelope.method = "GET"
        started = xfer.asyncGetToString()
    else
        xfer.addHeader("Content-Type", "application/json")
        xfer.setRequest(envelope.method)
        body = ""
        if envelope.body <> invalid then body = FormatJson(envelope.body)
        started = xfer.asyncPostFromString(body)
    end if
    if not started then return RKError("The request could not start. Check the server address and connection.")
    return {ok: true, xfer: xfer}
end function

function transferResponse(event as object) as object
    code = event.getResponseCode()
    if code = 401 or code = 403 then return {ok: false, error: "Your sign-in expired or this account lacks permission. Sign in again from Manage servers.", expired: true}
    if code < 200 or code >= 300 then return RKError("The server could not complete this request. Check the connection and try again.")
    text = event.getString()
    if len(text) > 2097152 then return RKError("The server response was too large.")
    if text = "" or code = 204 then return {ok: true, data: invalid}
    data = ParseJson(text)
    if data = invalid then return RKError("The server returned an unreadable response.")
    return {ok: true, data: data}
end function

function transferMany(envelopes as object) as object
    port = CreateObject("roMessagePort")
    pending = {}
    results = []
    clock = CreateObject("roTimespan")
    clock.mark()
    for each envelope in envelopes
        index = results.count()
        results.push(invalid)
        started = startTransfer(envelope, port)
        if started.ok
            pending[started.xfer.getIdentity().toStr()] = {xfer: started.xfer, index: index}
        else
            results[index] = started
        end if
    end for
    while pending.count() > 0 and clock.totalMilliseconds() < 15000
        event = wait(250, port)
        if type(event) = "roUrlEvent"
            key = event.getSourceIdentity().toStr()
            if pending.doesExist(key)
                results[pending[key].index] = transferResponse(event)
                pending.delete(key)
            end if
        end if
    end while
    for each key in pending
        pending[key].xfer.asyncCancel()
        results[pending[key].index] = RKError("The server took too long. Check your connection and try again.")
    end for
    return results
end function

function transfer(envelope as object) as object
    results = transferMany([envelope])
    return results[0]
end function

' Native registry exceptions stay at this adapter; the shared decoder never assumes
' a missing key when a read failed. No load operation writes or deletes a key.
function readMetadataStorage() as object
    try
        section = CreateObject("roRegistrySection", "ReelClient")
        if section = invalid then return {ok: false}
        exists = section.exists("connections-v1")
        if not exists then return {ok: true, exists: false}
        return {ok: true, exists: true, raw: section.read("connections-v1")}
    catch error
        return {ok: false}
    end try
end function

function writeMetadataStorage(raw as string) as object
    try
        section = CreateObject("roRegistrySection", "ReelClient")
        if section <> invalid
            if section.write("connections-v1", raw)
                if section.flush() then return {ok: true}
            end if
        end if
    catch error
        ' Keep the desired snapshot dirty in the Scene, including Flush failures.
    end try
    return RKError("Connection labels could not be saved. Your session still works until the app closes. Retry saving in Connections, or leave without saving.")
end function
