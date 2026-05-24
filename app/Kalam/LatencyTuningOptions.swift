enum LatencyTuningOptions {
    static let postRollMinMsKey = "internal.latency.postRollMinMs"
    static let postRollMaxMsKey = "internal.latency.postRollMaxMs"
    static let pasteDelayShortMsKey = "internal.latency.pasteDelayShortMs"
    static let pasteDelayLongMsKey = "internal.latency.pasteDelayLongMs"
    static let pasteFallbackTotalMsKey = "internal.latency.pasteFallbackTotalMs"
    static let enableStageTimingKey = "internal.latency.enableStageTiming"

    static let defaultPostRollMinMs = 100
    static let defaultPostRollMaxMs = 150
    static let defaultPasteDelayShortMs = 50
    static let defaultPasteDelayLongMs = 80
    static let defaultPasteFallbackTotalMs = 120
    static let defaultEnableStageTiming = true
}
