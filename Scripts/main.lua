local config = require("config")
local UEHelpers = require("UEHelpers")

local MOD_NAME = "RemoteAutoFeed"

local ROOT_CLASS =
    "/Game/Pal/Blueprint/Controller/AIAction/BaseCamp/RecoverHungry/" ..
    "BP_AIAction_BaseCampRecoverHungry.BP_AIAction_BaseCampRecoverHungry_C"

local ROOT_APPROACH_FUNCTION =
    ROOT_CLASS .. ":ChangeActionApproach"

local hooksRegistered = false
local hookRegistrationAttempted = false

-- Latest concrete ApproachToFoodBox action per PalAIActionComponent.
local approachByComponent = {}

-- Root state:
--   pending  = waiting for target initialization
--   feeding  = remote meal in progress
--   done     = completed/abandoned
local rootState = {}

-- One complete remote meal at a time per physical feed-box container.
-- Different feed boxes can still feed concurrently.
local containerLocks = {}

local KismetSystemLibrary = UEHelpers.GetKismetSystemLibrary()

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function debugLog(message)
    if config.DebugLogging then
        log("DEBUG | " .. tostring(message))
    end
end

local function unwrap(value)
    if value == nil then
        return nil
    end

    local ok, result = pcall(function()
        return value:get()
    end)

    if ok and result ~= nil then
        return result
    end

    return value
end

local function valid(obj)
    if obj == nil then
        return false
    end

    local ok, result = pcall(function()
        return obj:IsValid()
    end)

    return ok and result == true
end

local function fullName(obj)
    obj = unwrap(obj)

    if not valid(obj) then
        return "<invalid>"
    end

    local ok, result = pcall(function()
        return obj:GetFullName()
    end)

    if ok and result then
        return tostring(result)
    end

    return "<name-error>"
end

local function palLabel(character)
    local name = fullName(character)
    local first = string.match(name, "^(%S+)")
    return first or "<unknown-pal>"
end

local function percentOf(value, maximum)
    if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then
        return nil
    end

    return (value / maximum) * 100.0
end

local function classFullName(obj)
    obj = unwrap(obj)

    if not valid(obj) then
        return "<invalid-class>"
    end

    local ok, cls = pcall(function()
        return obj:GetClass()
    end)

    if not ok or not valid(cls) then
        return "<class-error>"
    end

    return fullName(cls)
end

local function getOuter(obj)
    obj = unwrap(obj)

    if not valid(obj) then
        return nil
    end

    local ok, outer = pcall(function()
        return obj:GetOuter()
    end)

    if ok and valid(outer) then
        return outer
    end

    return nil
end

local function toNumber(value)
    value = unwrap(value)

    if type(value) == "number" then
        return value
    end

    local n = tonumber(value)
    return n
end

local function isDedicatedServer(worldContext)
    if not config.RequireDedicatedServer then
        return true
    end

    if not KismetSystemLibrary or not valid(KismetSystemLibrary) then
        return false
    end

    local ok, result = pcall(function()
        return KismetSystemLibrary:IsDedicatedServer(worldContext)
    end)

    return ok and result == true
end

local function schedule(delayMs, callback)
    local ok, handleOrErr = pcall(function()
        return ExecuteInGameThreadWithDelay(delayMs, callback)
    end)

    if not ok then
        return false, tostring(handleOrErr)
    end

    return true, handleOrErr
end

local function getApproachForRoot(root)
    local component = getOuter(root)

    if not valid(component) then
        return nil
    end

    return approachByComponent[fullName(component)]
end

local function getCharacter(root, approach)
    for _, action in ipairs({ approach, root }) do
        if valid(action) then
            local ok, character = pcall(function()
                return action:GetCharacter()
            end)

            if ok and valid(character) then
                return character
            end
        end
    end

    local component = getOuter(root)

    if valid(component) then
        local okOwner, controller = pcall(function()
            return component:GetOwner()
        end)

        if okOwner and valid(controller) then
            local okPawn, pawn = pcall(function()
                return controller:GetPawn()
            end)

            if okPawn and valid(pawn) then
                return pawn
            end
        end
    end

    return nil
end

local function stopMovement(root)
    local component = getOuter(root)

    if not valid(component) then
        return false
    end

    local okOwner, controller = pcall(function()
        return component:GetOwner()
    end)

    if not okOwner or not valid(controller) then
        return false
    end

    return pcall(function()
        controller:StopMovement()
    end)
end

-- Kill the concrete feed-box walking child, not merely the parent.
local function cancelApproachMovement(root)
    if not valid(root) then
        return false
    end

    local component = getOuter(root)
    if not valid(component) then
        return false
    end

    local cancelledSomething = false
    local approach = getApproachForRoot(root)

    if valid(approach) then
        local okClass, approachClass = pcall(function()
            return approach:GetClass()
        end)

        if okClass and valid(approachClass) then
            local okTerminate = pcall(function()
                component:TerminateCurrentActionByClass(approachClass)
            end)

            if okTerminate then
                cancelledSomething = true
            end
        end
    end

    local okCancelPushed = pcall(function()
        component:AllCancelPushedAction(root)
    end)

    if okCancelPushed then
        cancelledSomething = true
    end

    if stopMovement(root) then
        cancelledSomething = true
    end

    return cancelledSomething
end

local function terminateRoot(root)
    if not valid(root) then
        return false, "root invalid"
    end

    local component = getOuter(root)

    if not valid(component) then
        return false, "AI action component invalid"
    end

    local okClass, rootClass = pcall(function()
        return root:GetClass()
    end)

    if okClass and valid(rootClass) then
        local okTerminate, err = pcall(function()
            component:TerminateCurrentActionByClass(rootClass)
        end)

        if okTerminate then
            stopMovement(root)
            return true, "TerminateCurrentActionByClass"
        end

        if config.DebugLogging then
            log("Root TerminateCurrentActionByClass error: " .. tostring(err))
        end
    end

    local okWorker, workerErr = pcall(function()
        root:ChangeActionToWorker()
    end)

    if okWorker then
        stopMovement(root)
        return true, "ChangeActionToWorker"
    end

    return false, tostring(workerErr)
end

local function tryGetSelectedFeedBox(approach)
    if not valid(approach) then
        return nil, "approach unavailable"
    end

    local outTarget = {}

    local ok, success = pcall(function()
        return approach:TryGetTargetMapObjectConcreteModel(outTarget)
    end)

    if not ok then
        return nil, "TryGetTargetMapObjectConcreteModel call failed: " ..
            tostring(success)
    end

    if success ~= true then
        return nil, "target-not-ready"
    end

    local target = outTarget.OutTargetModel

    if not valid(target) then
        return nil, "target-invalid"
    end

    return target, nil
end

local function getFeedContainer(target)
    local okModule, module = pcall(function()
        return target:GetItemContainerModule()
    end)

    if not okModule or not valid(module) then
        return nil, "item container module invalid"
    end

    local okContainer, container = pcall(function()
        return module:GetContainer()
    end)

    if not okContainer or not valid(container) then
        return nil, "feed container invalid"
    end

    return container, nil
end

local function getPalUseContext(character)
    local okParam, parameterComponent = pcall(function()
        return character:GetCharacterParameterComponent()
    end)

    if not okParam or not valid(parameterComponent) then
        return nil, nil, "parameter component invalid"
    end

    local okHandle, handle = pcall(function()
        return parameterComponent.IndividualHandle
    end)

    if not okHandle or not valid(handle) then
        return nil, nil, "IndividualHandle invalid"
    end

    local okId, individualId = pcall(function()
        return handle:GetIndividualID()
    end)

    if not okId or individualId == nil then
        return nil, nil, "GetIndividualID failed"
    end

    return parameterComponent, individualId, nil
end

local function getFullStomach(parameterComponent)
    local ok, value = pcall(function()
        return parameterComponent:GetFullStomach()
    end)

    if ok then
        return toNumber(value)
    end

    return nil
end

local function getMaxFullStomach(parameterComponent)
    local ok, value = pcall(function()
        return parameterComponent:GetMaxFullStomach()
    end)

    if ok then
        local n = toNumber(value)
        if n ~= nil and n > 0 then
            return n
        end
    end

    return nil
end

local function readHungryParameter(root, approach)
    local okRoot, p = pcall(function()
        return root.HungeryParameter
    end)

    if okRoot and p ~= nil then
        local recover = nil
        local maxEat = nil

        pcall(function()
            recover = toNumber(p.RecoverSatietyTo)
        end)

        pcall(function()
            maxEat = toNumber(p.EatMaxNum)
        end)

        if recover ~= nil then
            return recover, maxEat, "root.HungeryParameter"
        end
    end

    if valid(approach) then
        local out = {}

        local ok = pcall(function()
            approach:GetHungryParameter(out)
        end)

        if ok then
            local p2 = out.HungeryParameter or out
            local recover = nil
            local maxEat = nil

            pcall(function()
                recover = toNumber(p2.RecoverSatietyTo)
            end)

            pcall(function()
                maxEat = toNumber(p2.EatMaxNum)
            end)

            if recover ~= nil then
                return recover, maxEat, "approach:GetHungryParameter"
            end
        end
    end

    return nil, nil, "unavailable"
end

local function findUsableFoodSlot(container, individualId)
    local okNum, num = pcall(function()
        return container:Num()
    end)

    if not okNum or type(num) ~= "number" then
        return nil, nil, "container Num failed"
    end

    for i = 0, num - 1 do
        local okGet, slot = pcall(function()
            return container:Get(i)
        end)

        if okGet and valid(slot) then
            local okEmpty, empty = pcall(function()
                return slot:IsEmpty()
            end)

            if okEmpty and not empty then
                local okCan, canUse = pcall(function()
                    return slot:CanUseItemToCharacter(individualId)
                end)

                if okCan and canUse == true then
                    local stack = nil
                    pcall(function()
                        stack = slot:GetStackCount()
                    end)

                    return slot, toNumber(stack), nil
                end
            end
        end
    end

    return nil, nil, "no usable food slot"
end

local function scheduleRootStateCleanup(key)
    local delayMs = tonumber(config.CompletedStateRetentionMs) or 5000

    if delayMs < 0 then
        delayMs = 0
    end

    local ok = pcall(function()
        ExecuteInGameThreadWithDelay(delayMs, function()
            local state = rootState[key]
            if state and state.status == "done" then
                rootState[key] = nil
            end
        end)
    end)

    if not ok then
        debugLog("Could not schedule completed root-state cleanup.")
    end
end

local function releaseContainerLock(state)
    if not state or not state.containerKey then
        return
    end

    if containerLocks[state.containerKey] == state.key then
        containerLocks[state.containerKey] = nil
        debugLog("Released feed-box container lock.")
    end
end

local function acquireContainerLock(state)
    local owner = containerLocks[state.containerKey]

    if owner == nil or owner == state.key then
        containerLocks[state.containerKey] = state.key
        return true
    end

    return false
end

local function abandon(root, reason)
    local key = fullName(root)

    rootState[key] = {
        status = "done",
        result = "vanilla"
    }

    log("WARNING | remote feeding abandoned | reason=" .. tostring(reason))
    debugLog("Vanilla feeding remains available for root=" .. key)
    scheduleRootStateCleanup(key)
end

local function finishRemoteMeal(state)
    local root = state.root

    releaseContainerLock(state)
    cancelApproachMovement(root)

    local endFull = getFullStomach(state.parameterComponent)
    local startPct = percentOf(state.startFull, state.maxFullStomach)
    local endPct = percentOf(endFull, state.maxFullStomach)
    local targetPct = percentOf(state.effectiveTarget, state.maxFullStomach)

    local ok, method = terminateRoot(root)

    state.status = "done"
    state.result = "remote"
    rootState[state.key] = state

    if config.MealLogging and state.bites > 0 then
        local status = state.completionReason or "complete"

        log(string.format(
            "MEAL | Pal=%s | items=%d | fullness=%.1f%%->%.1f%% | target=%.1f%% | status=%s",
            state.palLabel or "<unknown-pal>",
            state.bites,
            startPct or -1,
            endPct or -1,
            targetPct or (state.configuredPercent * 100.0),
            tostring(status)
        ))
    end

    if not ok then
        log("WARNING | meal completed but hunger action termination failed | method=" ..
            tostring(method))
    else
        debugLog("Hunger action ended via " .. tostring(method))
    end

    scheduleRootStateCleanup(state.key)
end

local function remoteFeedNext(state)
    if not valid(state.root) then
        releaseContainerLock(state)
        rootState[state.key] = nil
        return
    end

    cancelApproachMovement(state.root)

    local currentFull = getFullStomach(state.parameterComponent)

    if state.bites >= state.minBites and
       currentFull ~= nil and
       state.effectiveTarget ~= nil and
       currentFull + config.SatietyEpsilon >= state.effectiveTarget then

        local percent = nil
        if state.maxFullStomach and state.maxFullStomach > 0 then
            percent = (currentFull / state.maxFullStomach) * 100.0
        end

        debugLog(string.format(
            "Satiety target reached: %.3f / %.3f (%.1f%%) >= %.3f",
            currentFull,
            state.maxFullStomach or -1,
            percent or -1,
            state.effectiveTarget
        ))

        state.completionReason = "complete"
        finishRemoteMeal(state)
        return
    end

    if state.bites >= state.eatLimit then
        log(string.format(
            "WARNING | meal bite limit reached | Pal=%s | items=%d | target=%.1f%%",
            state.palLabel or "<unknown-pal>",
            state.bites,
            (state.configuredPercent or 0) * 100.0
        ))

        state.completionReason = "bite-limit"
        finishRemoteMeal(state)
        return
    end

    local slot, beforeStack, slotErr =
        findUsableFoodSlot(state.container, state.individualId)

    if not valid(slot) then
        log("WARNING | no usable food before target | Pal=" ..
            tostring(state.palLabel) .. " | reason=" .. tostring(slotErr))
        state.completionReason = "no-food"
        finishRemoteMeal(state)
        return
    end

    local beforeFull = currentFull

    if beforeFull == nil then
        beforeFull = getFullStomach(state.parameterComponent)
    end

    state.bites = state.bites + 1
    local biteNumber = state.bites

    local beforePercent = nil
    if beforeFull ~= nil and state.maxFullStomach and state.maxFullStomach > 0 then
        beforePercent = (beforeFull / state.maxFullStomach) * 100.0
    end

    debugLog(string.format(
        "Remote bite %d/%d | Pal=%s | stack=%s | full_stomach=%s/%s (%.1f%%) | target=%.3f",
        biteNumber,
        state.eatLimit,
        state.palLabel or "<unknown-pal>",
        tostring(beforeStack),
        tostring(beforeFull),
        tostring(state.maxFullStomach),
        beforePercent or -1,
        state.effectiveTarget
    ))

    local okUse, useErr = pcall(function()
        slot:RequestUseToCharacter(state.individualId, 1)
    end)

    if not okUse then
        log("WARNING | RequestUseToCharacter failed | Pal=" ..
            tostring(state.palLabel) .. " | error=" .. tostring(useErr))
        state.completionReason = "item-use-failed"
        finishRemoteMeal(state)
        return
    end

    local scheduled, err = schedule(config.VerifyDelayMs, function()
        if not valid(state.root) then
            releaseContainerLock(state)
            rootState[state.key] = nil
            return
        end

        local afterStack = nil
        if valid(slot) then
            pcall(function()
                afterStack = toNumber(slot:GetStackCount())
            end)
        end

        local afterFull = getFullStomach(state.parameterComponent)

        local stackDecreased =
            beforeStack ~= nil and afterStack ~= nil and
            afterStack < beforeStack

        local fullnessIncreased =
            beforeFull ~= nil and afterFull ~= nil and
            afterFull > beforeFull + config.SatietyEpsilon

        debugLog(string.format(
            "Bite %d verification | Pal=%s | stack %s -> %s | full_stomach %s -> %s",
            biteNumber,
            state.palLabel or "<unknown-pal>",
            tostring(beforeStack),
            tostring(afterStack),
            tostring(beforeFull),
            tostring(afterFull)
        ))

        if not fullnessIncreased then
            log(string.format(
                "WARNING | bite did not increase FullStomach | Pal=%s | stack_changed=%s",
                state.palLabel or "<unknown-pal>",
                tostring(stackDecreased)
            ))
            state.completionReason = "verification-failed"
            finishRemoteMeal(state)
            return
        end

        local scheduledNext, nextErr =
            schedule(config.BetweenBitesDelayMs, function()
                remoteFeedNext(state)
            end)

        if not scheduledNext then
            log("WARNING | could not schedule next bite | error=" ..
                tostring(nextErr))
            state.completionReason = "schedule-failed"
            finishRemoteMeal(state)
        end
    end)

    if not scheduled then
        log("WARNING | could not schedule bite verification | error=" .. tostring(err))
        state.completionReason = "schedule-failed"
        finishRemoteMeal(state)
    end
end

local function startWhenContainerAvailable(state)
    if not valid(state.root) then
        rootState[state.key] = nil
        return
    end

    cancelApproachMovement(state.root)

    if acquireContainerLock(state) then
        state.status = "feeding"

        debugLog("Acquired feed-box container lock; starting remote meal.")
        remoteFeedNext(state)
        return
    end

    if not state.queueLogged then
        state.queueLogged = true
        debugLog("Feed box is already serving another Pal; remote meal queued.")
    end

    local scheduled, err = schedule(config.ContainerQueueRetryMs, function()
        startWhenContainerAvailable(state)
    end)

    if not scheduled then
        log("WARNING | could not schedule feed-box queue retry | error=" .. tostring(err))
        state.completionReason = "queue-schedule-failed"
        finishRemoteMeal(state)
    end
end

local function beginRemoteMeal(root, approach, target, attempt)
    local key = fullName(root)

    local character = getCharacter(root, approach)
    if not valid(character) then
        abandon(root, "could not resolve Pal character")
        return
    end

    local container, containerErr = getFeedContainer(target)
    if not valid(container) then
        abandon(root, containerErr)
        return
    end

    local parameterComponent, individualId, idErr =
        getPalUseContext(character)

    if not valid(parameterComponent) or individualId == nil then
        abandon(root, idErr)
        return
    end

    local recoverSatietyTo, eatMaxNum, paramSource =
        readHungryParameter(root, approach)

    if recoverSatietyTo == nil then
        abandon(root, "could not read RecoverSatietyTo")
        return
    end

    local maxFullStomach = getMaxFullStomach(parameterComponent)

    if maxFullStomach == nil then
        abandon(root, "could not read GetMaxFullStomach()")
        return
    end

    local configuredPercent = tonumber(config.TargetSatietyPercent) or 0.80
    configuredPercent = math.max(0.01, math.min(configuredPercent, 1.0))

    local percentageTarget = maxFullStomach * configuredPercent

    local effectiveTarget = math.max(
        recoverSatietyTo,
        percentageTarget
    )

    effectiveTarget = math.min(effectiveTarget, maxFullStomach)

    local minBites = math.max(
        1,
        math.floor(tonumber(config.MinRemoteBites) or 1)
    )

    local eatLimit = config.HardMaxRemoteBites

    if eatMaxNum ~= nil and eatMaxNum > 0 then
        eatLimit = math.min(
            math.floor(eatMaxNum),
            config.HardMaxRemoteBites
        )
    end

    if eatLimit < minBites then
        eatLimit = minBites
    end

    debugLog(string.format(
        "Feed-box target ready on attempt %d.",
        attempt
    ))
    debugLog("Remote meal initialized:")
    debugLog("  Pal:    " .. fullName(character))
    debugLog("  Target: " .. fullName(target))
    local currentFull = getFullStomach(parameterComponent)
    local currentPercent = nil
    if currentFull ~= nil and maxFullStomach > 0 then
        currentPercent = (currentFull / maxFullStomach) * 100.0
    end

    debugLog(string.format(
        "  Current=%s Max=%s CurrentPct=%.1f%%",
        tostring(currentFull),
        tostring(maxFullStomach),
        currentPercent or -1
    ))
    debugLog(string.format(
        "  VanillaRecover=%s PercentTarget=%.1f%% => %.3f EffectiveTarget=%.3f",
        tostring(recoverSatietyTo),
        configuredPercent * 100.0,
        percentageTarget,
        effectiveTarget
    ))
    debugLog(string.format(
        "  EatMaxNum=%s MinRemoteBites=%d source=%s",
        tostring(eatMaxNum),
        minBites,
        tostring(paramSource)
    ))

    local containerKey = fullName(container)

    rootState[key] = {
        status = "queued",
        key = key,
        root = root,
        character = character,
        approach = approach,
        target = target,
        container = container,
        containerKey = containerKey,
        parameterComponent = parameterComponent,
        individualId = individualId,
        palLabel = palLabel(character),
        startFull = currentFull,
        recoverSatietyTo = recoverSatietyTo,
        maxFullStomach = maxFullStomach,
        configuredPercent = configuredPercent,
        percentageTarget = percentageTarget,
        effectiveTarget = effectiveTarget,
        minBites = minBites,
        eatLimit = eatLimit,
        bites = 0,
    }

    cancelApproachMovement(root)

    debugLog("Concrete ApproachToFoodBox movement cancelled.")

    startWhenContainerAvailable(rootState[key])
end

local function resolveTarget(root, attempt)
    if not valid(root) then
        return
    end

    local key = fullName(root)
    local state = rootState[key]

    if not state or state.status ~= "pending" then
        return
    end

    local approach = getApproachForRoot(root)

    if valid(approach) then
        local target, targetErr = tryGetSelectedFeedBox(approach)

        if valid(target) then
            beginRemoteMeal(root, approach, target, attempt)
            return
        end

        if targetErr ~= "target-not-ready" and
           targetErr ~= "target-invalid" then
            abandon(root, targetErr)
            return
        end
    end

    if attempt >= config.TargetResolveMaxAttempts then
        abandon(
            root,
            string.format(
                "feed-box target unavailable after %d attempts",
                attempt
            )
        )
        return
    end

    if config.DebugLogging and
       (attempt == 0 or attempt == 1 or attempt % 5 == 0) then
        debugLog(string.format(
            "Feed-box target not ready yet; retry %d/%d.",
            attempt,
            config.TargetResolveMaxAttempts
        ))
    end

    local scheduled, err =
        schedule(config.TargetResolveRetryMs, function()
            resolveTarget(root, attempt + 1)
        end)

    if not scheduled then
        abandon(root, "target retry scheduling failed: " .. tostring(err))
    end
end

local function onBlueprintChangeActionApproach(Context)
    local root = unwrap(Context)

    if not valid(root) or not isDedicatedServer(root) then
        return
    end

    local key = fullName(root)
    local state = rootState[key]

    if state and
       (state.status == "feeding" or state.status == "queued") then
        cancelApproachMovement(root)

        if not state.reentryLogged then
            state.reentryLogged = true
            debugLog("Approach re-entry suppressed during remote meal.")
        end

        return
    end

    if state ~= nil then
        return
    end

    rootState[key] = {
        status = "pending"
    }

    debugLog("Hungry Pal entered concrete ApproachToFoodBox path: " .. key)
    debugLog("Waiting for vanilla feed-box target initialization.")

    resolveTarget(root, 0)
end

local function registerBlueprintHooks()
    if hooksRegistered or hookRegistrationAttempted then
        return hooksRegistered
    end

    hookRegistrationAttempted = true

    local ok, id1, id2 = pcall(function()
        return RegisterHook(
            ROOT_APPROACH_FUNCTION,
            onBlueprintChangeActionApproach
        )
    end)

    if not ok then
        log("ERROR | failed to hook concrete ChangeActionApproach")
        log("ERROR | " .. tostring(id1))
        return false
    end

    hooksRegistered = true

    debugLog(string.format(
        "Hooked concrete BP ChangeActionApproach (%s, %s)",
        tostring(id1),
        tostring(id2)
    ))

    return true
end

local function inspectActionObject(obj)
    if not valid(obj) then
        return
    end

    local cls = classFullName(obj)

    if string.find(
        cls,
        "BP_AIAction_BaseCampRecoverHungry_ApproachToFoodBox_C",
        1,
        true
    ) then
        local outer = getOuter(obj)

        if valid(outer) then
            approachByComponent[fullName(outer)] = obj
        end

        return
    end

    if string.find(
        cls,
        "BP_AIAction_BaseCampRecoverHungry_C",
        1,
        true
    ) then
        registerBlueprintHooks()
    end
end

if not config.Enabled then
    log("Disabled in config.lua")
    return
end

log(string.format(
    "Starting v1.0 | target=%.0f%% | meal_logging=%s | debug=%s",
    (tonumber(config.TargetSatietyPercent) or 0.90) * 100.0,
    tostring(config.MealLogging == true),
    tostring(config.DebugLogging == true)
))

if type(ExecuteInGameThreadWithDelay) ~= "function" then
    log("ERROR | delayed game-thread API unavailable.")
    return
end

local notifyOK, notifyErr = pcall(function()
    NotifyOnNewObject("/Script/Pal.PalAIActionBase", function(obj)
        local ok, err = pcall(function()
            inspectActionObject(obj)
        end)

        if not ok then
            log("WARNING | action watcher callback failed | error=" .. tostring(err))
        end
    end)
end)

if not notifyOK then
    log("ERROR | action watcher registration failed | error=" .. tostring(notifyErr))
    return
end

pcall(function()
    local actions = FindAllOf("PalAIActionBase")

    if actions then
        for _, action in ipairs(actions) do
            inspectActionObject(action)
        end
    end
end)

debugLog("Loaded.")
