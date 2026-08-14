local config = {
    Enabled = true,
    RequireDedicatedServer = true,

    -- Normal production logging: one compact line per completed remote meal.
    -- Example:
    -- MEAL | Pal=BP_Serpent_C | items=5 | fullness=50.0%->99.9% |
    -- target=90.0% | status=complete
    MealLogging = true,

    -- Set true for target-resolution, per-bite, queue and hook diagnostics.
    DebugLogging = false,

    -- Feed hungry Pals to at least this percentage of their own maximum
    -- FullStomach capacity. 0.90 = 90%.
    TargetSatietyPercent = 0.90,

    -- Target selection currently becomes available shortly after the concrete
    -- ApproachToFoodBox action is created.
    TargetResolveRetryMs = 50,
    TargetResolveMaxAttempts = 20,

    -- Verify each Palworld item-use operation before issuing another bite.
    VerifyDelayMs = 150,
    BetweenBitesDelayMs = 50,

    -- Only one complete remote meal at a time per physical feed-box container.
    -- Different feed boxes may still serve Pals concurrently.
    ContainerQueueRetryMs = 50,

    -- If Palworld entered RecoverHungry, consume at least one valid food item.
    MinRemoteBites = 1,

    -- Respect vanilla EatMaxNum when lower while retaining an absolute guard.
    HardMaxRemoteBites = 20,

    -- Keep a finished root state briefly so immediate Blueprint re-entry cannot
    -- start the same meal twice, then discard it to avoid long-running buildup.
    CompletedStateRetentionMs = 5000,

    SatietyEpsilon = 0.001,
}

return config
