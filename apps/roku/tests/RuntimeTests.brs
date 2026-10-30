sub main()
    cases = ParseJson(ReadAsciiFile("pkg:/cases.json"))
    output = []
    for each specimen in cases
        m.effects = []
        m.responses = specimen.responses
        m.storageEffects = []
        m.storage = {read: recordedStorageRead, write: recordedStorageWrite, effects: m.storageEffects, readResult: specimen.storageRead, reads: specimen.storageReads, writeResult: specimen.storageWrite}
        m.transport = {send: recordedTransfer, batch: recordedBatch, effects: m.effects, responses: m.responses}
        value = dispatch(specimen)
        output.push({id: specimen.id, result: value, effects: m.effects, storageEffects: m.storageEffects})
    end for
    print "REEL_RESULTS:"; FormatJson(escapedTree(output))
end sub

function recordedTransfer(envelope as object) as object
    if not envelope.ok then return envelope
    m.effects.push(envelope)
    if not RKArray(m.responses) then return RKError("No fixture response is provided.")
    if m.responses.count() = 0 then return RKError("Unexpected fixture request.")
    return m.responses.shift()
end function

function dispatch(specimen as object) as dynamic
    p = specimen.args
    op = specimen.op
    if op = "normalize" then return RKNormalizeServer(p.value)
    if op = "scope" then return RKScopedURL(p.server, p.path)
    if op = "encode" then return RKEncode(p.value)
    if op = "auth" then return RKAuthResponse(p.server, p.username, p.auth, p.info)
    if op = "metadata" then return RKMetadata(p.accounts, p.device)
    if op = "restore" then return RKRestore(p.value)
    if op = "items" then return RKItems(p.value)
    if op = "append" then return RKAppendItems(p.existing, p.page)
    if op = "query" then return RKLibraryQuery(p.account, p.options)
    if op = "resume" then return RKResume(p.item)
    if op = "episodeNeighbors" then return RKEpisodeNeighbors(p.items, p.item)
    if op = "introTarget" then return RKIntroTarget(p.items, p.item, p.position, p.offset, p.duration)
    if op = "playerMatches" then return RKPlayerRequestMatches(p.source, p.key, p.generation, p.epoch)
    if op = "playerEndReason" then return RKPlayerEndReason(p.state, p.pending)
    if op = "format" then return formatCase(p)
    if op = "autoNextAllowed" then return RKAutoNextAllowed(p.reason, p.stopped, p.enabled, p.item, p.nextItem, p.key, p.owner, p.cancelled = true)
    if op = "body" then return RKPlaybackBody(p.account, p.options)
    if op = "plan" then return RKPlaybackPlan(p.account, p.item, p.info, p.options, p.device)
    if op = "report" then return RKReport(p.account, p.plan, p.event, p.position, p.paused, p.device)
    if op = "request" then return RKRequest(p.account, p.device, p.route, p.query, p.method, p.body)
    if op = "matches" then return RKResultMatches(p.envelope, p.key, p.generation, p.nonce)
    if op = "historyAllowed" then return RKHistoryAllowed(p.accounts, p.key)
    if op = "acceptAuth" then return RKAcceptAuthentication(p.accounts, p.incoming)
    if op = "upsert" then return RKUpsertAccount(p.accounts, p.incoming)
    if op = "remove" then return RKRemoveAccount(p.accounts, p.index, p.active, p.remove)
    if op = "localPage" then return RKLocalPage(p.items, p.start)
    if op = "registryDecode" then return RKRegistryDecode(p.read)
    if op = "metadataScenario" then return metadataScenario(p)
    if op = "revokeNotice" then return RKRevocationNotice(p.source, p.result)
    if op = "canStart" then return RKCanStartPlayback(p.closing, p.visible)
    if op = "canRelease" then return RKCanReleasePlayer(p.closing, p.state)
    if op = "reconcileRecovery" then return RKReconcileRecovery(p.saved, p.current, p.activeKey)
    if op = "recoveryFlow" then return recoveryFlow(p)
    if op = "perform" then return perform(p)
    return RKError("Unknown test operation.")
end function

' brs 0.45's FormatJson does not escape embedded quotes. Encode only test output
' strings, then decode in Node; production Core/Operations are never rewritten.
function escapedTree(value as dynamic) as dynamic
    if type(value) = "String" or type(value) = "roString" then return value.escape()
    if RKArray(value)
        result = []
        for each child in value
            result.push(escapedTree(child))
        end for
        return result
    end if
    if RKObject(value)
        result = {}
        for each key in value
            result[key] = escapedTree(value[key])
        end for
        return result
    end if
    return value
end function

function recordedBatch(envelopes as object) as object
    results = []
    for each envelope in envelopes
        results.push(m.send(envelope))
    end for
    return results
end function

function recordedStorageRead() as object
    m.effects.push({operation: "read"})
    if RKArray(m.reads)
        if m.reads.count() > 0 then return m.reads.shift()
    end if
    return m.readResult
end function

function recordedStorageWrite(raw as string) as object
    m.effects.push({operation: "write", raw: raw})
    return m.writeResult
end function

function metadataScenario(p as object) as object
    queue = RKMetadataQueue()
    output = []
    for each action in p.actions
        if action.kind = "enqueue" then RKMetadataEnqueue(queue, action.accounts, "fixture-device", action.reset = true)
        if action.kind = "begin"
            begun = RKMetadataBegin(queue)
            output.push({begin: begun})
        end if
        if action.kind = "complete" then RKMetadataComplete(queue, action.revision, action.ok)
        if action.kind = "retry" then queue.failed = false
        if action.kind = "exit" then output.push({exit: RKMetadataExit(queue, action.canSave)})
        output.push({state: ParseJson(FormatJson(queue))})
    end for
    return {queue: queue, steps: output}
end function

' Drive the production load, merge, queue and guarded save functions in sequence.
function recoveryFlow(p as object) as object
    first = perform({kind: "loadMetadata"})
    queue = RKMetadataQueue()
    RKMetadataEnqueue(queue, p.current, "fixture-device")
    pendingBeforeRecovery = ParseJson(FormatJson(queue.desired))
    recovered = perform({kind: "loadMetadata"})
    merged = invalid
    write = invalid
    if recovered.canSave
        merged = RKReconcileRecovery(recovered.metadata.accounts, p.current, p.activeKey)
        if merged.ok
            RKMetadataEnqueue(queue, merged.accounts, "fixture-device")
            queue.failed = false
            begun = RKMetadataBegin(queue)
            write = perform({kind: "saveMetadata", accounts: begun.metadata.accounts, device: begun.metadata.device})
            RKMetadataComplete(queue, begun.revision, write.ok)
        end if
    end if
    persisted = invalid
    for each effect in m.storageEffects
        if effect.operation = "write" then persisted = RKRegistryDecode({ok: true, exists: true, raw: effect.raw})
    end for
    canSave = recovered.canSave
    if merged <> invalid
        if not merged.ok then canSave = false
    end if
    return {first: first, recovered: recovered, merged: merged, pendingBeforeRecovery: pendingBeforeRecovery, queue: queue, write: write, persisted: persisted, exitDecision: RKMetadataExit(queue, canSave)}
end function

' Display text, artwork routes and focus routing from Format.brs.
function formatCase(p as object) as dynamic
    fn = p.fn
    if fn = "runtime" then return RKRuntimeText(p.seconds)
    if fn = "metaLine" then return metaText(RKMetaParts(p.item))
    if fn = "metaParts" then return RKMetaParts(p.item)
    if fn = "nextUpSeason" then return RKNextUpSeason(p.seasons, p.episode)
    if fn = "tabIndex" then return RKTabIndex(p.view, p.filter, p.current)
    if fn = "focusRoute" then return RKFocusRoute(p.key, p.focus, p.state)
    if fn = "landingColumn" then return RKLandingColumn(p.column, p.fromShape, p.toShape, p.count, p.remembered)
    if fn = "restoreArea" then return RKRestoreArea(p.state)
    if fn = "cardDetail" then return RKCardDetail(p.item, p.showCode)
    if fn = "progress" then return RKProgress(p.item)
    if fn = "backdrop" then return RKBackdropRoute(p.item)
    if fn = "artwork" then return RKArtworkRoute(p.item, p.shape, p.width)
    if fn = "eyebrow" then return RKEyebrow(p.item)
    if fn = "qualityLabel" then return RKQualityLabel(p.bitrate)
    if fn = "errorTitle" then return RKErrorTitle(p.kind, p.expired)
    if fn = "shape" then return RKShapeSpec(p.shape)
    return invalid
end function

' The meta row's parts read left to right as one line, for the order and wording checks.
function metaText(parts as object) as string
    texts = []
    for each part in parts
        texts.push(part.text)
    end for
    return texts.join("   ")
end function
