-- Runs inside wowless at PLAYER_LOGIN, prints PASS/FAIL lines and quits with the result.
-- The AH is driven through MarketSync's own handlers (HandleAuctionHouseShown and
-- HandleAuctionHouseClosed), because the event frame in Core.lua is local. The neutral
-- AH is detected through the GetAuctionHouseCut rate, the same signal the real code reads.
local passed, failed = 0, 0

local function check(cond, reason)
    if not cond then error(reason or "assertion failed", 0) end
end

local function run(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        __wowless.printf("PASS %s\n", name)
    else
        failed = failed + 1
        __wowless.printf("FAIL %s: %s\n", name, tostring(err))
    end
end

local FACTION_KEY, NEUTRAL_KEY_A, NEUTRAL_KEY_B = "2589", "2592", "4306"
local events = Auctionator.FullScan.Events

local timers
local function captureTimers()
    timers = {}
    C_Timer.After = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn } end
end

local function fire(event, ...) Auctionator.EventBus:Fire(nil, event, ...) end

local function openNeutralAH()
    GetAuctionHouseCut = function() return 0.15 end
    MarketSync.IsAuctionHouseOpen = true
    MarketSync.IsNeutralAHOpen = MarketSync.HandleAuctionHouseShown() and true or false
    check(MarketSync.IsNeutralAHOpen, "neutral AH was not detected")
end

-- The same steps Core.lua runs on AUCTION_HOUSE_CLOSED.
local function closeAH()
    MarketSync.IsAuctionHouseOpen = false
    MarketSync.IsNeutralAHOpen = false
    check(MarketSync.HandleAuctionHouseClosed(), "close handler did not report a neutral session")
end

local function snapshot(entry)
    return { m = entry.m, h = entry.h[next(entry.h)], a = entry.a[next(entry.a)], n = #entry.l }
end

local function freshFactionEntry()
    local day = tostring(math.floor(time() / 86400))
    local entry = { l = {}, h = { [day] = 1000 }, a = { [day] = 4 }, m = 1000 }
    Auctionator.Database.db[FACTION_KEY] = entry
    return entry, snapshot(entry)
end

local function sameEntry(entry, before)
    local now = snapshot(entry)
    return now.m == before.m and now.h == before.h and now.a == before.a and now.n == before.n
end

local function runAll()
    MarketSyncDB = MarketSyncDB or {}
    MarketSyncDB.UseAuctionatorScanner = true
    MarketSync.RegisterAuctionatorHooks()
    local realTimerAfter = C_Timer.After

    run("closing the neutral AH mid-processing keeps the scan neutral and verified", function()
        captureTimers()
        local entry, before = freshFactionEntry()
        openNeutralAH()
        fire(events.ScanStart)
        Auctionator.Database:SetPrice(NEUTRAL_KEY_A, 5000, 3)
        closeAH()
        -- Auctionator is still processing after the close.
        Auctionator.Database:SetPrice(NEUTRAL_KEY_B, 7000, 2)
        Auctionator.Database:SetPrice(FACTION_KEY, 9999, 1)
        fire(events.ScanComplete, {})

        check(Auctionator.Database.db[FACTION_KEY] == entry, "faction entry was replaced")
        check(sameEntry(entry, before), "faction entry was changed by the neutral price")
        check(Auctionator.Database.db[NEUTRAL_KEY_B] == nil, "neutral price leaked into the faction DB")
        local neutral = MarketSync.GetRealmDB().NeutralData
        check(neutral[NEUTRAL_KEY_B] and neutral[NEUTRAL_KEY_B].m == 7000, "late neutral price is missing from NeutralData")
        check(neutral[FACTION_KEY] and neutral[FACTION_KEY].m == 9999, "late price for the faction key is missing from NeutralData")
        check(neutral[NEUTRAL_KEY_B].vm == 7000, "scan was not verified (vm missing)")
        check(not MarketSync.IsNeutralAHSession(), "neutral session is still active after ScanComplete")
    end)

    run("ScanFailed after the close ends the deferred session", function()
        captureTimers()
        openNeutralAH()
        fire(events.ScanStart)
        closeAH()
        check(MarketSync.IsNeutralAHSession(), "session ended before the scan finished")
        fire(events.ScanFailed)
        check(not MarketSync.IsNeutralAHSession(), "neutral session is still active after ScanFailed")
    end)

    run("reopening the neutral AH cancels the pending end", function()
        captureTimers()
        openNeutralAH()
        fire(events.ScanStart)
        closeAH()
        openNeutralAH()
        for _, timer in ipairs(timers) do
            if timer.delay == 60 then timer.fn() end
        end
        check(MarketSync.IsNeutralAHSession(), "stale timeout ended the reopened session")
        fire(events.ScanFailed)
        MarketSync.EndNeutralSession()
    end)

    run("the 60 second timeout ends a deferred session", function()
        captureTimers()
        openNeutralAH()
        fire(events.ScanStart)
        closeAH()
        check(MarketSync.IsNeutralAHSession(), "session ended before the timeout")
        local ran = false
        for _, timer in ipairs(timers) do
            if timer.delay == 60 then ran = true; timer.fn() end
        end
        check(ran, "no 60 second timer was scheduled")
        check(not MarketSync.IsNeutralAHSession(), "neutral session is still active after the timeout")
    end)

    C_Timer.After = realTimerAfter
    __wowless.printf("RESULT %d passed, %d failed\n", passed, failed)
    __wowless.quit(failed == 0 and 0 or 1)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", runAll)
