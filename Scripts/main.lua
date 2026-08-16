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

    -- The Approach child is pushed by the RecoverHungry root. The current
    -- PalAIActionComponent exposes this specifically for pushed actions.
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

-- -------------------------------------------------------------------------
-- Watchdog helpers. Debug telemetry is read-only; the starvation safety net
-- uses the same worker scan even when DebugLogging is disabled.
-- -------------------------------------------------------------------------

local starvationWatchSeenScans = {}

-- Safety-net state is keyed by the concrete runtime Pal actor path, not species.
-- This keeps multiple Pals of the same type independent.
local safetyNetState = {}

local function objectLabel(obj)
    local name = fullName(obj)
    local first = string.match(name, "^(%S+)")
    return first or "<unknown>"
end

local function actorInstanceLabel(actor)
    local name = fullName(actor)

    -- Full names look like:
    -- BP_Anubis_C /Game/...PersistentLevel.BP_Anubis_C_2147...
    -- The final object name is unique for this runtime actor instance.
    local last = string.match(name, "%.([^%.%s]+)$")
    if last ~= nil then
        return last
    end

    return name
end

local function getParameterComponent(character)
    if not valid(character) then
        return nil
    end

    local ok, parameterComponent = pcall(function()
        return character:GetCharacterParameterComponent()
    end)

    if ok and valid(parameterComponent) then
        return parameterComponent
    end

    return nil
end

local function getActionSnapshot(component)
    if not valid(component) then
        return nil, nil, "<unknown>", nil
    end

    local current = nil
    local top = nil
    local category = "<unknown>"
    local empty = nil

    pcall(function()
        current = component:GetCurrentAction_BP()
    end)

    pcall(function()
        top = component:GetCurrentTopParentAction_BP()
    end)

    pcall(function()
        category = tostring(component:GetCurrentAIActionCategory())
    end)

    pcall(function()
        empty = component:IsActionEmpty()
    end)

    return current, top, category, empty
end

local function getActorLocation(actor)
    if not valid(actor) then
        return nil
    end

    local location = nil

    local ok = pcall(function()
        location = actor:K2_GetActorLocation()
    end)

    if (not ok or location == nil) then
        ok = pcall(function()
            location = actor:GetActorLocation()
        end)
    end

    if not ok or location == nil then
        return nil
    end

    local x = nil
    local y = nil
    local z = nil

    pcall(function() x = toNumber(location.X) end)
    pcall(function() y = toNumber(location.Y) end)
    pcall(function() z = toNumber(location.Z) end)

    if x == nil or y == nil or z == nil then
        return nil
    end

    return { x = x, y = y, z = z }
end

local function collectPlayerLocations()
    if config.DebugPlayerDistance ~= true then
        return {}
    end

    local locations = {}

    local ok, players = pcall(function()
        return FindAllOf("PalPlayerCharacter")
    end)

    if not ok or players == nil then
        return locations
    end

    for _, player in ipairs(players) do
        local location = getActorLocation(player)
        if location ~= nil then
            table.insert(locations, location)
        end
    end

    return locations
end

local function nearestPlayerDistanceMeters(character, playerLocations)
    if config.DebugPlayerDistance ~= true then
        return nil
    end

    local location = getActorLocation(character)
    if location == nil or playerLocations == nil or #playerLocations == 0 then
        return nil
    end

    local nearestSq = nil

    for _, playerLocation in ipairs(playerLocations) do
        local dx = location.x - playerLocation.x
        local dy = location.y - playerLocation.y
        local dz = location.z - playerLocation.z
        local distanceSq = dx * dx + dy * dy + dz * dz

        if nearestSq == nil or distanceSq < nearestSq then
            nearestSq = distanceSq
        end
    end

    if nearestSq == nil then
        return nil
    end

    -- Unreal units are centimetres; convert to metres for readable logs.
    return math.sqrt(nearestSq) / 100.0
end

local function getBaseCampWorkerFromComponent(component)
    if not valid(component) then
        return nil, "invalid-component"
    end

    local current, top, category, empty = getActionSnapshot(component)

    local controller = nil
    local controllerSource = nil

    -- On this dedicated-server runtime PalAIActionComponent:GetOwner() and
    -- controller:GetPawn() are not reliable through UE4SS. The component Outer
    -- is nevertheless the BP_MonsterAIController_BaseCamp_C in the observed
    -- runtime paths, so keep it for controller/AI-state diagnostics.
    local okOwner = pcall(function()
        controller = component:GetOwner()
    end)

    if okOwner and valid(controller) then
        controllerSource = "owner"
    else
        controller = getOuter(component)
        if valid(controller) then
            controllerSource = "outer"
        end
    end

    if not valid(controller) then
        return nil, "no-controller"
    end

    -- Determine whether this is a base-camp worker before resolving its Pal.
    local identity = table.concat({
        fullName(controller),
        classFullName(controller),
        fullName(current),
        classFullName(current),
        fullName(top),
        classFullName(top)
    }, " ")

    if not string.find(identity, "BaseCamp", 1, true) and
       not string.find(identity, "MonsterFarm", 1, true) then
        return nil, "not-basecamp"
    end

    local character = nil
    local characterSource = nil

    -- Pal AI actions expose GetCharacter(), and this already works in the
    -- normal RemoteAutoFeed hook. Prefer it over Controller:GetPawn().
    for _, action in ipairs({ current, top }) do
        if valid(action) then
            local okCharacter, candidate = pcall(function()
                return action:GetCharacter()
            end)

            if okCharacter and valid(candidate) then
                character = candidate
                characterSource = "action"
                break
            end
        end
    end

    -- Keep GetPawn only as a fallback for actionless components.
    if not valid(character) then
        local okPawn, pawn = pcall(function()
            return controller:GetPawn()
        end)

        if okPawn and valid(pawn) then
            character = pawn
            characterSource = "pawn"
        end
    end

    if not valid(character) then
        return nil, "no-character"
    end

    return {
        component = component,
        controller = controller,
        controllerSource = controllerSource,
        character = character,
        characterSource = characterSource,
        current = current,
        top = top,
        category = category,
        empty = empty,
        identity = identity,
    }, nil
end

local function logRecoverRootDiagnostic(root)
    if not config.DebugLogging then
        return
    end

    local component = getOuter(root)
    local character = getCharacter(root, nil)
    local parameterComponent = getParameterComponent(character)
    local full = getFullStomach(parameterComponent)
    local maximum = getMaxFullStomach(parameterComponent)
    local percent = percentOf(full, maximum)
    local current, top, category, empty = getActionSnapshot(component)

    debugLog(string.format(
        "RECOVER_ROOT | Pal=%s | fullness=%s | current=%s | top=%s | category=%s | empty=%s",
        valid(character) and palLabel(character) or "<unknown-pal>",
        percent ~= nil and string.format("%.1f%%", percent) or "n/a",
        valid(current) and objectLabel(current) or "<none>",
        valid(top) and objectLabel(top) or "<none>",
        tostring(category),
        tostring(empty)
    ))
end

local function logApproachObjectDiagnostic(approach)
    if not config.DebugLogging then
        return
    end

    local component = getOuter(approach)
    local character = getCharacter(nil, approach)
    local parameterComponent = getParameterComponent(character)
    local full = getFullStomach(parameterComponent)
    local maximum = getMaxFullStomach(parameterComponent)
    local percent = percentOf(full, maximum)
    local current, top = getActionSnapshot(component)

    debugLog(string.format(
        "APPROACH_OBJECT | Pal=%s | fullness=%s | current=%s | top=%s",
        valid(character) and palLabel(character) or "<unknown-pal>",
        percent ~= nil and string.format("%.1f%%", percent) or "n/a",
        valid(current) and objectLabel(current) or "<none>",
        valid(top) and objectLabel(top) or "<none>"
    ))
end

local function safetyActionIsEligible(worker)
    local text = worker.identity or ""

    -- Never interrupt transient spawning/cage states. These showed up in the
    -- broad diagnostic scan but are not useful starvation-recovery targets.
    if string.find(text, "WanderingCage", 1, true) or
       string.find(text, "BaseCampSpawningForWorker", 1, true) then
        return false
    end

    local patterns = {
        "RecoverHungry",
        "SleepActively",
        "BaseCamp_Sleep",
        "Worker_Working",
        "BaseCampWorker_",
        "Work_WaitForWorkable",
        "BaseCamp_DodgeWork",
        "MonsterFarm",
    }

    for _, pattern in ipairs(patterns) do
        if string.find(text, pattern, 1, true) then
            return true
        end
    end

    return false
end

local function getRecoverHungryRoot(worker)
    for _, action in ipairs({ worker.current, worker.top }) do
        if valid(action) then
            local text = fullName(action) .. " " .. classFullName(action)
            if string.find(text, "BP_AIAction_BaseCampRecoverHungry_C", 1, true) then
                return action
            end
        end
    end

    return nil
end

local function hasActiveRemoteState(root)
    if not valid(root) then
        return false
    end

    local state = rootState[fullName(root)]
    if state == nil then
        return false
    end

    return state.status == "pending" or
           state.status == "queued" or
           state.status == "feeding"
end

local function stopWorkerMovement(worker)
    if not worker or not valid(worker.controller) then
        return
    end

    pcall(function()
        worker.controller:StopMovement()
    end)
end

local function nudgeStuckRecoverHungry(worker, root, percent, state)
    if not valid(root) then
        return false, "recover-root-invalid"
    end

    -- If our normal path is already resolving/feeding this exact root, do not
    -- interfere. The safety net only handles roots that never reached the
    -- ChangeActionApproach hook.
    if hasActiveRemoteState(root) then
        return false, "remote-path-active"
    end

    local ok, err = pcall(function()
        root:ChangeActionApproach()
    end)

    if not ok then
        return false, "ChangeActionApproach failed: " .. tostring(err)
    end

    stopWorkerMovement(worker)
    state.lastFix = "kick-recover-approach"

    log(string.format(
        "SAFETY | Pal=%s | actor=%s | fullness=%.1f%% | fix=kick-recover-approach | nudge=%d",
        palLabel(worker.character),
        actorInstanceLabel(worker.character),
        percent * 100.0,
        state.nudges
    ))

    return true, nil
end

local function nudgeMissingRecoverHungry(worker, percent, state)
    local action = worker.current
    if not valid(action) then
        action = worker.top
    end

    if not valid(action) then
        return false, "current-action-invalid"
    end

    local okClass, actionClass = pcall(function()
        return action:GetClass()
    end)

    if not okClass or not valid(actionClass) then
        return false, "current-action-class-invalid"
    end

    local ok, err = pcall(function()
        worker.component:TerminateCurrentActionByClass(actionClass)
    end)

    if not ok then
        return false, "TerminateCurrentActionByClass failed: " .. tostring(err)
    end

    stopWorkerMovement(worker)
    state.lastFix = "force-ai-reevaluate"

    log(string.format(
        "SAFETY | Pal=%s | actor=%s | fullness=%.1f%% | fix=force-ai-reevaluate | previous=%s | nudge=%d",
        palLabel(worker.character),
        actorInstanceLabel(worker.character),
        percent * 100.0,
        objectLabel(action),
        state.nudges
    ))

    return true, nil
end

local function applySafetyNet(worker, percent, recoverHungry, seenThisScan)
    if config.SafetyNetEnabled ~= true or percent == nil then
        return
    end

    local trigger = tonumber(config.SafetyNetTriggerPercent) or 0.30
    local graceScans = math.floor(tonumber(config.SafetyNetGraceScans) or 3)
    local cooldownScans = math.floor(tonumber(config.SafetyNetCooldownScans) or 3)
    local maxNudges = math.floor(tonumber(config.SafetyNetMaxNudgesPerEpisode) or 3)

    trigger = math.max(0.01, math.min(trigger, 1.0))
    graceScans = math.max(1, graceScans)
    cooldownScans = math.max(1, cooldownScans)
    maxNudges = math.max(1, maxNudges)

    local key = fullName(worker.character)

    if percent > trigger then
        safetyNetState[key] = nil
        return
    end

    seenThisScan[key] = true

    if not safetyActionIsEligible(worker) then
        -- Keep the episode but do not interrupt unknown/transient states.
        local currentState = safetyNetState[key] or {
            lowScans = 0,
            cooldown = 0,
            nudges = 0,
            gaveUpLogged = false,
        }
        currentState.lowScans = 0
        safetyNetState[key] = currentState
        return
    end

    local root = recoverHungry and getRecoverHungryRoot(worker) or nil
    local mode = recoverHungry and "recover-stuck" or "recover-missing"
    local actionKey = valid(root) and fullName(root) or
        (valid(worker.current) and fullName(worker.current) or fullName(worker.top))

    local state = safetyNetState[key]
    if state == nil then
        state = {
            lowScans = 0,
            cooldown = 0,
            nudges = 0,
            gaveUpLogged = false,
            mode = mode,
            actionKey = actionKey,
        }
        safetyNetState[key] = state
    end

    if state.mode ~= mode or state.actionKey ~= actionKey then
        local fastEscalation =
            state.lastFix == "force-ai-reevaluate" and
            mode == "recover-stuck"

        state.lowScans = 0
        state.mode = mode
        state.actionKey = actionKey
        state.gaveUpLogged = false

        -- A successful force-ai-reevaluate often moves the Pal into
        -- RecoverHungry/ApproachToFoodBox. Treat that as progress, but do not
        -- make it wait both the old cooldown and a fresh grace window. The new
        -- stuck-recovery mode gets only its normal grace scans (~30s).
        if fastEscalation then
            state.cooldown = 0
        end
    end

    if state.cooldown > 0 then
        state.cooldown = state.cooldown - 1
        return
    end

    -- If the normal RemoteAutoFeed path is already active for this RecoverHungry
    -- root, it is not stuck. Let the normal target retry/feeding logic finish.
    if recoverHungry and valid(root) and hasActiveRemoteState(root) then
        state.lowScans = 0
        return
    end

    state.lowScans = state.lowScans + 1
    if state.lowScans < graceScans then
        return
    end

    if state.nudges >= maxNudges then
        if not state.gaveUpLogged then
            state.gaveUpLogged = true
            log(string.format(
                "WARNING | SAFETY exhausted | Pal=%s | actor=%s | fullness=%.1f%% | mode=%s | nudges=%d",
                palLabel(worker.character),
                actorInstanceLabel(worker.character),
                percent * 100.0,
                mode,
                state.nudges
            ))
        end
        return
    end

    state.nudges = state.nudges + 1
    state.lowScans = 0
    state.cooldown = cooldownScans

    local ok = false
    local err = nil

    if recoverHungry then
        ok, err = nudgeStuckRecoverHungry(worker, root, percent, state)
    else
        ok, err = nudgeMissingRecoverHungry(worker, percent, state)
    end

    if not ok and err ~= "remote-path-active" then
        log(string.format(
            "WARNING | SAFETY nudge failed | Pal=%s | actor=%s | fullness=%.1f%% | mode=%s | reason=%s",
            palLabel(worker.character),
            actorInstanceLabel(worker.character),
            percent * 100.0,
            mode,
            tostring(err)
        ))
    end
end


local function getBaseCampWorkerDirector(baseCamp)
    if not valid(baseCamp) then
        return nil
    end

    local director = nil

    -- WorkerDirector is a replicated BlueprintReadWrite UPROPERTY on
    -- UPalBaseCampModel. UE4SS normally exposes it directly.
    pcall(function()
        director = baseCamp.WorkerDirector
    end)

    -- Keep a reflective fallback for runtimes where direct property access is
    -- not available through the generated wrapper.
    if not valid(director) then
        pcall(function()
            director = baseCamp:GetPropertyValue("WorkerDirector")
        end)
    end

    if valid(director) then
        return director
    end

    return nil
end

local function collectAuthoritativeBaseCampWorkers()
    if config.AuthoritativeWorkerFilter ~= true then
        return nil, {
            mode = "disabled",
            baseCamps = 0,
            directors = 0,
            nonEmptySlots = 0,
            workerActors = 0,
        }
    end

    local stats = {
        mode = "unavailable",
        baseCamps = 0,
        directors = 0,
        slotCalls = 0,
        nonEmptySlots = 0,
        workerActors = 0,
    }

    local okCamps, camps = pcall(function()
        return FindAllOf("PalBaseCampModel")
    end)

    if not okCamps or camps == nil then
        return nil, stats
    end

    local actors = {}

    for _, baseCamp in ipairs(camps) do
        if valid(baseCamp) then
            stats.baseCamps = stats.baseCamps + 1

            local director = getBaseCampWorkerDirector(baseCamp)
            if valid(director) then
                stats.directors = stats.directors + 1

                local outSlots = {}
                local okSlots = pcall(function()
                    director:GetCharacterHandleSlots(outSlots)
                end)

                if okSlots then
                    stats.slotCalls = stats.slotCalls + 1

                    local slots = nil
                    pcall(function()
                        slots = outSlots.OutSlots
                    end)

                    if slots == nil then
                        slots = outSlots
                    end

                    -- UE4SS exposes TArray out parameters as an iterable Lua
                    -- table/proxy. If this particular runtime does not, the
                    -- call fails closed and the scanner uses its broad fallback.
                    pcall(function()
                        for _, slot in ipairs(slots) do
                            if valid(slot) then
                                local isEmpty = nil
                                pcall(function()
                                    isEmpty = slot:IsEmpty()
                                end)

                                if isEmpty ~= true then
                                    stats.nonEmptySlots = stats.nonEmptySlots + 1

                                    local handle = nil
                                    pcall(function()
                                        handle = slot:GetHandle()
                                    end)

                                    if valid(handle) then
                                        local actor = nil
                                        pcall(function()
                                            actor = handle:TryGetIndividualActor()
                                        end)

                                        if valid(actor) then
                                            local key = fullName(actor)
                                            if actors[key] ~= true then
                                                actors[key] = true
                                                stats.workerActors = stats.workerActors + 1
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end)
                end
            end
        end
    end

    -- Only enable filtering when worker-slot enumeration produced a useful,
    -- mostly complete actor set. An incomplete authoritative set would be more
    -- dangerous than the validated BaseCamp-controller fallback because it
    -- could silently omit a genuinely starving worker.
    local completeness = 0.0
    if stats.nonEmptySlots > 0 then
        completeness = stats.workerActors / stats.nonEmptySlots
    end

    if stats.slotCalls > 0 and
       stats.workerActors > 0 and
       (stats.nonEmptySlots == 0 or completeness >= 0.80) then
        stats.mode = "authoritative"
        return actors, stats
    end

    stats.mode = "broad-fallback"
    return nil, stats
end

local function runStarvationWatch()
    local debugWatch = config.DebugLogging and config.DebugStarvationWatchEnabled == true
    local safetyEnabled = config.SafetyNetEnabled == true

    if not debugWatch and not safetyEnabled then
        return
    end

    local threshold = tonumber(config.DebugStarvationWatchThresholdPercent) or 0.50
    local safetyThreshold = tonumber(config.SafetyNetTriggerPercent) or 0.30
    local repeatScans = math.floor(tonumber(config.DebugStarvationWatchRepeatScans) or 3)

    if threshold < 0 then threshold = 0 end
    if threshold > 1 then threshold = 1 end
    if safetyThreshold < 0 then safetyThreshold = 0 end
    if safetyThreshold > 1 then safetyThreshold = 1 end
    if repeatScans < 1 then repeatScans = 1 end

    local scanThreshold = safetyThreshold
    if debugWatch then
        scanThreshold = math.max(threshold, safetyThreshold)
    end

    local playerLocations = {}
    if debugWatch and config.DebugPlayerDistance == true then
        playerLocations = collectPlayerLocations()
    end
    local authoritativeWorkers, workerFilterStats =
        collectAuthoritativeBaseCampWorkers()
    local seenThisScan = {}
    local safetySeenThisScan = {}
    local scannedComponents = 0
    local candidateBaseWorkers = 0
    local baseWorkers = 0
    local filteredOutWorkers = 0
    local lowWorkers = 0

    local noController = 0
    local noCharacter = 0
    local notBaseCamp = 0
    local noParameter = 0
    local noFullness = 0
    local ownerResolved = 0
    local outerResolved = 0
    local actionCharacterResolved = 0
    local pawnCharacterResolved = 0

    local ok, components = pcall(function()
        return FindAllOf("PalAIActionComponent")
    end)

    if ok and components ~= nil then
        for _, component in ipairs(components) do
            scannedComponents = scannedComponents + 1

            local worker, workerReason = getBaseCampWorkerFromComponent(component)

            if worker == nil then
                if workerReason == "no-controller" then
                    noController = noController + 1
                elseif workerReason == "no-character" then
                    noCharacter = noCharacter + 1
                elseif workerReason == "not-basecamp" then
                    notBaseCamp = notBaseCamp + 1
                end
            else
                candidateBaseWorkers = candidateBaseWorkers + 1

                local workerKey = fullName(worker.character)
                local isAuthoritativeWorker =
                    authoritativeWorkers == nil or
                    authoritativeWorkers[workerKey] == true

                if not isAuthoritativeWorker then
                    filteredOutWorkers = filteredOutWorkers + 1
                else
                    baseWorkers = baseWorkers + 1

                if worker.controllerSource == "owner" then
                    ownerResolved = ownerResolved + 1
                elseif worker.controllerSource == "outer" then
                    outerResolved = outerResolved + 1
                end

                if worker.characterSource == "action" then
                    actionCharacterResolved = actionCharacterResolved + 1
                elseif worker.characterSource == "pawn" then
                    pawnCharacterResolved = pawnCharacterResolved + 1
                end

                local parameterComponent = getParameterComponent(worker.character)

                if not valid(parameterComponent) then
                    noParameter = noParameter + 1
                else
                    local full = getFullStomach(parameterComponent)
                    local maximum = getMaxFullStomach(parameterComponent)
                    local percent = nil

                    if full ~= nil and maximum ~= nil and maximum > 0 then
                        percent = full / maximum
                    else
                        noFullness = noFullness + 1
                    end

                    if percent ~= nil and percent <= scanThreshold then
                        local currentName = valid(worker.current) and objectLabel(worker.current) or "<none>"
                        local topName = valid(worker.top) and objectLabel(worker.top) or "<none>"
                        local actionText = worker.identity or ""
                        local ranchHint = string.find(actionText, "MonsterFarm", 1, true) ~= nil
                        local recoverHungry = string.find(actionText, "RecoverHungry", 1, true) ~= nil

                        -- Safety handling is independent from debug WATCH output.
                        applySafetyNet(worker, percent, recoverHungry, safetySeenThisScan)

                        if debugWatch and percent <= threshold then
                            lowWorkers = lowWorkers + 1

                            local key = fullName(worker.character)
                            seenThisScan[key] = true
                            local seenCount = (starvationWatchSeenScans[key] or 0) + 1
                            starvationWatchSeenScans[key] = seenCount

                            if seenCount == 1 or seenCount % repeatScans == 0 then
                                local activeAI = nil

                                pcall(function()
                                    activeAI = worker.controller:IsActiveAI()
                                end)

                                local distance = nearestPlayerDistanceMeters(
                                    worker.character,
                                    playerLocations
                                )

                                debugLog(string.format(
                                    "WATCH | Pal=%s | actor=%s | fullness=%.1f%% | active_ai=%s | ranch_hint=%s | recover_hungry=%s | current=%s | top=%s | category=%s | empty=%s | controller_via=%s | nearest_player=%s",
                                    palLabel(worker.character),
                                    actorInstanceLabel(worker.character),
                                    percent * 100.0,
                                    tostring(activeAI),
                                    tostring(ranchHint),
                                    tostring(recoverHungry),
                                    currentName,
                                    topName,
                                    tostring(worker.category),
                                    tostring(worker.empty),
                                    tostring(worker.controllerSource) .. "/" .. tostring(worker.characterSource),
                                    distance ~= nil and string.format("%.1fm", distance) or "n/a"
                                ))
                            end
                        end
                    elseif percent ~= nil then
                        -- Above both scan thresholds: end any previous safety episode.
                        safetyNetState[fullName(worker.character)] = nil
                    end
                end
                end -- authoritative worker gate
            end
        end
    else
        debugLog("WATCH | PalAIActionComponent scan failed.")
    end

    for key, _ in pairs(starvationWatchSeenScans) do
        if seenThisScan[key] ~= true then
            starvationWatchSeenScans[key] = nil
        end
    end

    for key, _ in pairs(safetyNetState) do
        if safetySeenThisScan[key] ~= true then
            safetyNetState[key] = nil
        end
    end

    if debugWatch then
        debugLog(string.format(
            "WATCH_SUMMARY | components=%d | candidates=%d | base_workers=%d | filtered_out=%d | low_workers=%d | worker_filter=%s | camps=%d | worker_slots=%d | worker_actors=%d | owner=%d | outer=%d | char_action=%d | char_pawn=%d | no_controller=%d | no_character=%d | not_basecamp=%d | no_param=%d | no_fullness=%d | players_with_location=%d",
            scannedComponents,
            candidateBaseWorkers,
            baseWorkers,
            filteredOutWorkers,
            lowWorkers,
            tostring(workerFilterStats and workerFilterStats.mode or "unknown"),
            workerFilterStats and workerFilterStats.baseCamps or 0,
            workerFilterStats and workerFilterStats.nonEmptySlots or 0,
            workerFilterStats and workerFilterStats.workerActors or 0,
            ownerResolved,
            outerResolved,
            actionCharacterResolved,
            pawnCharacterResolved,
            noController,
            noCharacter,
            notBaseCamp,
            noParameter,
            noFullness,
            #playerLocations
        ))
    end
end

local function scheduleStarvationWatch()
    local debugWatch = config.DebugLogging and config.DebugStarvationWatchEnabled == true
    local safetyEnabled = config.SafetyNetEnabled == true

    if not debugWatch and not safetyEnabled then
        return
    end

    local interval = math.floor(
        tonumber(config.SafetyNetCheckIntervalMs) or
        tonumber(config.DebugStarvationWatchIntervalMs) or
        10000
    )

    if interval < 1000 then
        interval = 1000
    end

    local scheduled, err = schedule(interval, function()
        local ok, scanErr = pcall(function()
            runStarvationWatch()
        end)

        if not ok then
            log("WARNING | starvation watchdog failed | error=" .. tostring(scanErr))
        end

        scheduleStarvationWatch()
    end)

    if not scheduled then
        log("WARNING | starvation watchdog scheduling failed | error=" .. tostring(err))
    end
end

local function readHungryParameter(root, approach)
    -- Preferred path: the concrete RecoverHungry root owns HungeryParameter.
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

    -- Fallback through the child helper.
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

    -- Preserve vanilla feed-box ordering.
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
        -- Cleanup failure is non-fatal; the entry is tiny and keyed by a
        -- short-lived RecoverHungry root object.
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

    -- Free the feed-box serialization lock before ending the root so the next
    -- queued hungry Pal can begin immediately.
    releaseContainerLock(state)

    -- Final aggressive cleanup of any approach child that reappeared.
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

    -- If the parent tried to re-create Approach between bites, kill it again.
    cancelApproachMovement(state.root)

    local currentFull = getFullStomach(state.parameterComponent)

    -- Never declare a hunger action complete without at least MinRemoteBites.
    -- v0.10 showed that a stale/low RecoverSatietyTo can already be below the
    -- Pal's current absolute FullStomach when the action reaches us.
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

    if state.bites >= state.hardLimit then
        debugLog(string.format(
            "Remote meal hard cap reached before target | Pal=%s | items=%d | batches=%d | target=%.1f%%",
            state.palLabel or "<unknown-pal>",
            state.bites,
            state.batchNumber or 1,
            (state.configuredPercent or 0) * 100.0
        ))

        -- This is a safe partial meal, not an item-use failure. End the current
        -- hunger root cleanly and let Palworld schedule the next hunger cycle
        -- if more food is still required.
        state.completionReason = "partial"
        finishRemoteMeal(state)
        return
    end

    if state.batchBites >= state.batchLimit then
        state.batchNumber = (state.batchNumber or 1) + 1
        state.batchBites = 0

        debugLog(string.format(
            "Remote meal continuing with batch %d | Pal=%s | total_items=%d | batch_limit=%d",
            state.batchNumber,
            state.palLabel or "<unknown-pal>",
            state.bites,
            state.batchLimit
        ))

        local pause = math.floor(
            tonumber(config.RemoteMealBatchPauseMs) or 100
        )
        if pause < 0 then pause = 0 end

        local scheduledBatch, batchErr = schedule(pause, function()
            remoteFeedNext(state)
        end)

        if not scheduledBatch then
            log("WARNING | could not schedule next meal batch | error=" ..
                tostring(batchErr))
            state.completionReason = "schedule-failed"
            finishRemoteMeal(state)
        end
        return
    end

    local slot, beforeStack, slotErr =
        findUsableFoodSlot(state.container, state.individualId)

    if not valid(slot) then
        -- We already cancelled movement. End the current hunger root so it
        -- can be reevaluated later; do not fabricate satiety.
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
    state.batchBites = state.batchBites + 1
    local biteNumber = state.bites
    local batchBiteNumber = state.batchBites

    local beforePercent = nil
    if beforeFull ~= nil and state.maxFullStomach and state.maxFullStomach > 0 then
        beforePercent = (beforeFull / state.maxFullStomach) * 100.0
    end

    debugLog(string.format(
        "Remote bite total=%d/%d batch=%d bite=%d/%d | Pal=%s | stack=%s | full_stomach=%s/%s (%.1f%%) | target=%.3f",
        biteNumber,
        state.hardLimit,
        state.batchNumber or 1,
        batchBiteNumber,
        state.batchLimit,
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

        -- Fullness belongs to this exact Pal, so it is the authoritative
        -- success signal. A shared feed-box stack can be changed by another Pal
        -- and is therefore diagnostic only.
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

        -- Continue until the normalized target or total hard safety cap says stop.
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

    -- Keep any re-created approach/navigation child suppressed while waiting.
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
        -- Don't cancel the vanilla walk unless we know the vanilla floor.
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

    -- Preserve any higher special-case vanilla recovery target, but do not let
    -- a low/stale absolute RecoverSatietyTo result in an underfed Pal.
    local effectiveTarget = math.max(
        recoverSatietyTo,
        percentageTarget
    )

    -- Never request more than the Pal's physical capacity as our target.
    effectiveTarget = math.min(effectiveTarget, maxFullStomach)

    local minBites = math.max(
        1,
        math.floor(tonumber(config.MinRemoteBites) or 1)
    )

    local hardLimit = math.floor(
        tonumber(config.HardMaxRemoteBites) or 40
    )
    hardLimit = math.max(minBites, hardLimit)

    -- EatMaxNum is the vanilla meal-size guard. Keep it as a per-batch size,
    -- but allow another immediate batch when a low-nutrition food cannot reach
    -- the configured target in one batch. HardMaxRemoteBites remains the total
    -- safety ceiling for this remote meal.
    local batchLimit = hardLimit

    if eatMaxNum ~= nil and eatMaxNum > 0 then
        batchLimit = math.min(
            math.floor(eatMaxNum),
            hardLimit
        )
    end

    if batchLimit < minBites then
        batchLimit = minBites
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
        "  EatMaxNum=%s BatchLimit=%d HardLimit=%d MinRemoteBites=%d source=%s",
        tostring(eatMaxNum),
        batchLimit,
        hardLimit,
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
        batchLimit = batchLimit,
        hardLimit = hardLimit,
        batchNumber = 1,
        batchBites = 0,
        bites = 0,
    }

    -- Critical v0.10 change:
    -- cancel the concrete Approach child once its target has initialized.
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

-- /Game hook executes after ChangeActionApproach.
local function onBlueprintChangeActionApproach(Context)
    local root = unwrap(Context)

    if not valid(root) or not isDedicatedServer(root) then
        return
    end

    local key = fullName(root)
    local state = rootState[key]

    if state and
       (state.status == "feeding" or state.status == "queued") then
        -- Parent reasserted Approach while the remote meal is underway/queued.
        -- Kill the newly created child immediately.
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

    local character = getCharacter(root, getApproachForRoot(root))
    local parameterComponent = getParameterComponent(character)
    local full = getFullStomach(parameterComponent)
    local maximum = getMaxFullStomach(parameterComponent)
    local percent = percentOf(full, maximum)

    debugLog(string.format(
        "APPROACH_HOOK | Pal=%s | fullness=%s | root=%s",
        valid(character) and palLabel(character) or "<unknown-pal>",
        percent ~= nil and string.format("%.1f%%", percent) or "n/a",
        key
    ))
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

        logApproachObjectDiagnostic(obj)
        return
    end

    if string.find(
        cls,
        "BP_AIAction_BaseCampRecoverHungry_C",
        1,
        true
    ) then
        logRecoverRootDiagnostic(obj)
        registerBlueprintHooks()
    end
end

if not config.Enabled then
    log("Disabled in config.lua")
    return
end

log(string.format(
    "Starting v1.1.0 | target=%.0f%% | safety=%s | meal_logging=%s | debug=%s",
    (tonumber(config.TargetSatietyPercent) or 0.90) * 100.0,
    tostring(config.SafetyNetEnabled == true),
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

if (config.DebugLogging and config.DebugStarvationWatchEnabled == true) or
   config.SafetyNetEnabled == true then
    debugLog(string.format(
        "Starvation watchdog enabled | interval=%dms | threshold=%.0f%% | safety=%s | safety_trigger=%.0f%% | worker_filter=%s | hard_bites=%d",
        math.floor(
            tonumber(config.SafetyNetCheckIntervalMs) or
            tonumber(config.DebugStarvationWatchIntervalMs) or
            10000
        ),
        (tonumber(config.DebugStarvationWatchThresholdPercent) or 0.50) * 100.0,
        tostring(config.SafetyNetEnabled == true),
        (tonumber(config.SafetyNetTriggerPercent) or 0.30) * 100.0,
        tostring(config.AuthoritativeWorkerFilter == true),
        math.floor(tonumber(config.HardMaxRemoteBites) or 40)
    ))
    scheduleStarvationWatch()
end

debugLog("Loaded.")
