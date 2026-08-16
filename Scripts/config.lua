local config = {
    Enabled = true,
    RequireDedicatedServer = true,

    MealLogging = true,

    -- Detailed troubleshooting output. Leave false for normal servers.
    DebugLogging = false,

    DebugStarvationWatchEnabled = true,
    DebugStarvationWatchIntervalMs = 10000,
    DebugStarvationWatchThresholdPercent = 0.50,
    DebugStarvationWatchRepeatScans = 3,
    DebugPlayerDistance = true,

    -- Emergency fallback for Pals whose vanilla base AI fails to begin feeding
    -- or gets stuck inside RecoverHungry before ChangeActionApproach.
    --
    -- The safety net DOES NOT edit FullStomach or food stacks. It only nudges
    -- Palworld's AI state so the existing vanilla-driven RemoteAutoFeed path can
    -- take over and consume real feed-box items.
    SafetyNetEnabled = true,

    -- Server-wide safety scan interval. The safety net remains active even
    -- when DebugLogging is false.
    SafetyNetCheckIntervalMs = 10000,

    -- 30% is intentionally conservative. Normal feeding should happen well
    -- before this; below it we treat a missing/stalled hunger transition as an
    -- emergency rather than interrupting normal work/sleep too aggressively.
    SafetyNetTriggerPercent = 0.30,

    -- With the 10s watchdog interval, 3 scans = about 30 seconds continuously
    -- below the emergency threshold in the same AI state before intervention.
    SafetyNetGraceScans = 3,

    -- Wait about 30 seconds after a nudge before considering the same
    -- recovery mode again. If force-ai-reevaluate successfully transitions
    -- into RecoverHungry, that new mode gets its own 3-scan grace immediately
    -- instead of waiting a second cooldown first.
    SafetyNetCooldownScans = 3,

    -- Do not endlessly fight a pathological AI state. A new episode begins
    -- after the Pal rises above SafetyNetTriggerPercent.
    SafetyNetMaxNudgesPerEpisode = 3,

    -- Normal remote-meal target.
    TargetSatietyPercent = 0.90,

    TargetResolveRetryMs = 50,

    -- Complex/multi-level bases can take several seconds before Palworld
    -- exposes its selected feed box. 200 gives a generous retry window while
    -- still abandoning safely if no vanilla target appears.
    TargetResolveMaxAttempts = 200,

    VerifyDelayMs = 150,
    BetweenBitesDelayMs = 50,
    ContainerQueueRetryMs = 50,
    MinRemoteBites = 1,

    -- Palworld's EatMaxNum is treated as a per-batch size. If a low-nutrition
    -- food cannot reach the 90% target in one vanilla-sized batch, feeding
    -- continues immediately in another batch while keeping the same real
    -- feed-box item flow. This total hard cap prevents pathological overuse.
    RemoteMealBatchPauseMs = 100,
    HardMaxRemoteBites = 40,

    -- Experimental worker-slot enumeration did not expose usable slots in
    -- the tested UE4SS runtime. Keep the validated BaseCamp-controller scan as
    -- the production worker discovery path.
    AuthoritativeWorkerFilter = false,

    CompletedStateRetentionMs = 5000,
    SatietyEpsilon = 0.001,
}

return config
