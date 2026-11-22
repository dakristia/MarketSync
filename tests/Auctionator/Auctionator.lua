-- Minimal Auctionator v351 stand-in: the price database, the event bus and the scan event names.
Auctionator = {}

Auctionator.Database = { db = {} }

-- Same entry shape and write rules as v351: { l = {}, h = { [day] = price }, a = { [day] = qty }, m = price }.
function Auctionator.Database.SetPrice(self, dbKey, buyoutPrice, available)
    local day = tostring(math.floor(time() / 86400))
    local entry = self.db[dbKey]
    if entry == nil then
        entry = { l = {}, h = {}, a = {}, m = buyoutPrice }
        self.db[dbKey] = entry
    end
    if entry.h[day] == nil or buyoutPrice < entry.h[day] then
        entry.h[day] = buyoutPrice
    end
    entry.a[day] = available
    entry.m = buyoutPrice
end

Auctionator.EventBus = { listeners = {} }

function Auctionator.EventBus.Register(self, listener, events)
    for _, event in ipairs(events) do
        self.listeners[event] = self.listeners[event] or {}
        table.insert(self.listeners[event], listener)
    end
    return self
end

function Auctionator.EventBus.Fire(self, source, event, ...)
    for _, listener in ipairs(self.listeners[event] or {}) do
        listener:ReceiveEvent(event, ...)
    end
end

Auctionator.FullScan = {
    Events = {
        ScanStart = "replicate_scan_start",
        ScanComplete = "replicate_scan_complete",
        ScanFailed = "replicate_scan_failed",
    },
}
