-- Bar Guard: keeps a snapshot of your action bars per spec and puts the icons
-- back when a dual-spec bug wipes them (checked after login and after every
-- spec switch). It only ever fills EMPTY slots, never overwrites anything.
-- Options: Esc > Options > AddOns > Bar Guard, or /barguard.
local ADDON = ...

local MAX_SLOT     = 180  -- 1-120 classic bars (73-120 = stance/form bars), 121-180 extra bars
local LOGIN_DELAY  = 4    -- seconds after login before checking (server may fill bars late)
local SPEC_DELAY   = 4    -- seconds after the last spec event before checking
local DEBOUNCE     = 1.5  -- seconds of quiet after a bar change before snapshotting
local WIPE_RATIO   = 0.5  -- fewer than half the remembered icons left = wiped
local MIN_FOR_WIPE = 3    -- need at least this many remembered icons to call it a wipe

local defaults = { autoRestore = true, ask = false, announce = true }
local db, cdb -- account options, per-character snapshots

local ready = false       -- login check done; snapshots allowed
local specBusy = false    -- a spec switch is settling
local restoring = false   -- we are placing icons ourselves
local specSeq, snapToken = 0, 0
local pendingKey = nil    -- spec key when the current burst of bar changes started
local pendingCombat = nil
local warnedEmpty = false
local specApi = "?"
local settleUntil = 0     -- a wipe before this time (login / spec switch) is restored, not just warned about

local function say(msg)
	print("|cff66ff99Bar Guard|r: " .. msg)
end

-- Diagnostic log (last LOG_MAX lines, kept in the character's saved file). /barguard log
local LOG_MAX = 80
local earlyLog = {} -- lines written before the saved variables are loaded
local function log(msg)
	local line = date("%m-%d %H:%M:%S") .. " " .. msg
	local t = cdb and cdb.log or earlyLog
	t[#t + 1] = line
	while #t > LOG_MAX do table.remove(t, 1) end
end

-- API shims: classic-style globals first, namespaced versions if a global is gone.
local function api(ns, name)
	return _G[name] or (_G[ns] and _G[ns][name])
end
local GetInfo     = api("C_ActionBar", "GetActionInfo")
local GetText     = api("C_ActionBar", "GetActionText")
local Place       = api("C_ActionBar", "PlaceAction")
local PickSpell   = api("C_Spell", "PickupSpell")
local PickItem    = api("C_Item", "PickupItem")
local SpellName   = (C_Spell and C_Spell.GetSpellName) or function(id)
	return GetSpellInfo and (GetSpellInfo(id))
end

-- ---- which spec / talent group is active -----------------------------------
local specTries = {
	{ "C_SpecializationInfo.GetActiveSpecGroup", function()
		return C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup
			and C_SpecializationInfo.GetActiveSpecGroup(false, false)
	end },
	{ "GetActiveTalentGroup", function() return GetActiveTalentGroup and GetActiveTalentGroup(false, false) end },
	{ "GetActiveSpecGroup", function() return GetActiveSpecGroup and GetActiveSpecGroup(false) end },
	{ "GetSpecialization", function() return GetSpecialization and GetSpecialization() end },
}

local function specKey()
	for _, t in ipairs(specTries) do
		local ok, v = pcall(t[2])
		if ok and type(v) == "number" and v > 0 then
			specApi = t[1]
			return "spec" .. v
		end
	end
	specApi = "none found (treating as one set)"
	return "spec1"
end

-- ---- reading the bars --------------------------------------------------------
local function readSlot(slot)
	local kind, id, sub = GetInfo(slot)
	if not kind then return nil end
	if sub == "pet" and id == 0 then return nil end -- pet-bar placeholder, can't be placed
	local e = { t = kind, id = id, sub = sub }
	if kind == "macro" then
		-- The action text is the macro name; indexes shift, names don't.
		local name = GetText and GetText(slot)
		local idx = name and GetMacroIndexByName(name) or 0
		if (not idx or idx == 0) and type(id) == "number" then
			idx = id
			name = name or (GetMacroInfo(id))
		end
		if idx and idx > 0 then
			local mName, icon, body = GetMacroInfo(idx)
			e.name, e.icon, e.body = name or mName, icon, body
			e.char = idx > (MAX_ACCOUNT_MACROS or 120) or nil
		else
			e.name = name
		end
	elseif kind == "spell" then
		local ok, name = pcall(SpellName, id)
		if ok then e.name = name end
	end
	return e
end

local function scan()
	local slots, n = {}, 0
	for s = 1, MAX_SLOT do
		local ok, e = pcall(readSlot, s)
		if ok and e then
			slots[s] = e
			n = n + 1
		end
	end
	return slots, n
end

local function same(a, b)
	if not a or not b or a.t ~= b.t then return false end
	if a.t == "macro" then return a.name == b.name end
	return a.id == b.id
end

-- Share of the remembered slots that now hold something else (or nothing).
local function changedShare(old, new)
	local total, diff = 0, 0
	for s, e in pairs(old) do
		total = total + 1
		if not same(e, new[s]) then diff = diff + 1 end
	end
	return total > 0 and diff / total or 0
end

local function isWipe(set, n)
	return set and set.count >= MIN_FOR_WIPE and n < set.count * WIPE_RATIO
end

-- How many remembered slots are empty now.
local function emptyCount(set, slots)
	local e = 0
	for s in pairs(set.slots) do if not slots[s] then e = e + 1 end end
	return e
end

-- Right after login / a spec switch, losing even part of the bars (one bar is
-- enough) counts: the bug can clear a single bar and leave the rest.
local function isSettleWipe(set, slots)
	return set and emptyCount(set, slots) >= MIN_FOR_WIPE
end

local function store(key, slots, n)
	cdb.sets[key] = { slots = slots, count = n, time = time() }
	warnedEmpty = false
end

-- ---- putting icons back ------------------------------------------------------
local function cursorHolds()
	return GetCursorInfo() ~= nil
end

local function pickup(e)
	ClearCursor()
	if e.t == "spell" then
		local known = false
		pcall(function() known = (IsPlayerSpell and IsPlayerSpell(e.id)) or (IsSpellKnown and IsSpellKnown(e.id)) end)
		if known then pcall(PickSpell, e.id) end
		if not cursorHolds() and e.name then pcall(PickSpell, e.name) end
	elseif e.t == "macro" then
		local idx = e.name and GetMacroIndexByName(e.name) or 0
		if (not idx or idx == 0) and e.name and e.body then
			-- The macro itself is gone too: recreate it (fails quietly if macro slots are full).
			local ok, newIdx = pcall(CreateMacro, e.name, e.icon or "INV_MISC_QUESTIONMARK", e.body, e.char)
			idx = ok and newIdx or 0
		end
		if idx and idx > 0 then PickupMacro(idx) end
	elseif e.t == "item" then
		pcall(PickItem, e.id)
	elseif e.t == "equipmentset" then
		pcall(function()
			local id = e.id
			if type(id) == "string" and C_EquipmentSet.GetEquipmentSetID then id = C_EquipmentSet.GetEquipmentSetID(id) end
			C_EquipmentSet.PickupEquipmentSet(id)
		end)
	elseif e.t == "summonpet" then
		pcall(C_PetJournal.PickupPet, e.id)
	end
	-- flyouts/mounts/companions have no reliable pick-up-by-id; they count as "couldn't place".
	return cursorHolds()
end

local function label(e)
	return e.name or (e.t .. " " .. tostring(e.id))
end

local function restore(key, why)
	if InCombatLockdown() then
		log("restore " .. key .. " (" .. why .. "): in combat, deferred")
		pendingCombat = why
		say("in combat; I'll put your bars back when combat ends.")
		return
	end
	local set = cdb.sets[key]
	if not set then
		say("no snapshot yet for this spec, nothing to restore.")
		return
	end
	restoring = true
	local put, missed = 0, {}
	for slot, e in pairs(set.slots) do
		if not GetInfo(slot) then
			local ok, picked = pcall(pickup, e)
			if ok and picked then
				pcall(Place, slot)
				if GetInfo(slot) then put = put + 1 else missed[#missed + 1] = label(e) end
			else
				missed[#missed + 1] = label(e)
			end
			ClearCursor()
		end
	end
	cdb.last = string.format("%s, %s: put back %d, missed %d", date("%Y-%m-%d %H:%M"), why, put, #missed)
	log(string.format("restore %s (%s): put %d, missed %d%s", key, why, put, #missed,
		#missed > 0 and (" [" .. table.concat(missed, ", ", 1, math.min(#missed, 8)) .. "]") or ""))
	if put > 0 or #missed > 0 then
		if db.announce or #missed > 0 then
			say(string.format("put %d icon%s back on your bars.", put, put == 1 and "" or "s"))
		end
		if #missed > 0 then
			say("couldn't place: " .. table.concat(missed, ", ", 1, math.min(#missed, 12)) .. (#missed > 12 and ", ..." or ""))
		end
	end
	-- Let the slot-changed events from our own placing go by, then snapshot.
	C_Timer.After(DEBOUNCE + 0.5, function()
		restoring = false
		if ready and not specBusy then
			local slots, n = scan()
			local cur = cdb.sets[key]
			if specKey() == key and not isWipe(cur, n) then store(key, slots, n) end
		end
	end)
end

-- Compare the bars with the snapshot for the active spec; restore if wiped.
local function check(why)
	local key = specKey()
	local set = cdb.sets[key]
	local slots, n = scan()
	if not set then
		log(string.format("check %s (%s): no snapshot, %d icons -> first snapshot", key, why, n))
		if n > 0 then store(key, slots, n) end
		return
	end
	local empty = emptyCount(set, slots)
	local wiped = isSettleWipe(set, slots) -- check() only runs after login / spec switch / a late wipe
	log(string.format("check %s (%s): %d icons now, snapshot %d, %d snapshot slots empty, %.0f%% changed -> %s",
		key, why, n, set.count, empty, changedShare(set.slots, slots) * 100,
		not wiped and "ok" or (not db.autoRestore and "warn") or (db.ask and "popup") or "restore"))
	if not wiped then return end
	if not db.autoRestore then
		say(string.format("%d icons are missing from your bars. Type /barguard restore to put them back.", empty))
	elseif db.ask then
		StaticPopup_Show("BARGUARD_RESTORE", empty)
	else
		restore(key, why)
	end
end

StaticPopupDialogs["BARGUARD_RESTORE"] = {
	text = "Bar Guard: %d icons are missing from your action bars.\nPut them back?",
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function() restore(specKey(), "popup") end,
	OnCancel = function() log("popup: answered No / closed") end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- ---- snapshotting while you play --------------------------------------------
local function doSnapshot(token, deferred)
	if token ~= snapToken then return end
	if not ready or specBusy or restoring then return end
	local key = specKey()
	if key ~= pendingKey then
		log("snapshot skipped: spec changed " .. tostring(pendingKey) .. " -> " .. key .. " during the burst")
		pendingKey = nil
		return
	end
	local slots, n = scan()
	local set = cdb.sets[key]
	local share = set and changedShare(set.slots, slots) or 0
	if set and share > 0.2 then
		log(string.format("bar burst %s: %d icons now, snapshot %d, %.0f%% changed%s", key, n, set.count, share * 100,
			GetTime() < settleUntil and " (settle window)" or ""))
	end
	if GetTime() < settleUntil and isSettleWipe(set, slots) then
		-- Late wipe shortly after login / spec switch (e.g. a slow server sync).
		pendingKey = nil
		check("late wipe")
		return
	end
	if set and isWipe(set, n) then
		-- Mostly empty mid-session: keep the old snapshot, don't fight the player.
		pendingKey = nil
		log("  -> mostly empty mid-session, kept old snapshot")
		if not warnedEmpty then
			warnedEmpty = true
			say("your bars are mostly empty, so I'm keeping the old snapshot. /barguard restore brings it back, /barguard snap saves the bars as they are now.")
		end
		return
	end
	if set and not deferred and set.count >= 6 and changedShare(set.slots, slots) > 0.5 then
		-- Big change in one go: could be a spec swap whose event is late. Look again shortly.
		log("  -> big change, looking again in 5 s")
		C_Timer.After(5, function() doSnapshot(token, true) end)
		return
	end
	pendingKey = nil
	if deferred or share > 0.2 then log(string.format("  -> saved as %s snapshot (%d icons)", key, n)) end
	store(key, slots, n)
end

local function scheduleSnapshot()
	snapToken = snapToken + 1
	if not pendingKey then pendingKey = specKey() end
	local token = snapToken
	C_Timer.After(DEBOUNCE, function() doSnapshot(token) end)
end

local function onSpecEvent(event)
	log("event " .. event .. " (active set reads " .. specKey() .. ")")
	snapToken = snapToken + 1 -- cancels any pending snapshot
	pendingKey = nil
	specBusy = true
	specSeq = specSeq + 1
	local seq = specSeq
	C_Timer.After(SPEC_DELAY, function()
		if seq ~= specSeq then return end
		specBusy = false
		settleUntil = GetTime() + 30
		if ready then check("spec switch") end
	end)
end

-- ---- status ---------------------------------------------------------------------
local function age(t)
	if not t then return "?" end
	local s = time() - t
	if s < 120 then return s .. " s ago" end
	if s < 7200 then return math.floor(s / 60) .. " min ago" end
	if s < 172800 then return math.floor(s / 3600) .. " h ago" end
	return math.floor(s / 86400) .. " days ago"
end

local function status()
	local key = specKey()
	local _, n = scan()
	say("active set: " .. key .. " (via " .. specApi .. "), " .. n .. " icons on your bars now.")
	local parts = {}
	for _, t in ipairs(specTries) do
		local ok, v = pcall(t[2])
		parts[#parts + 1] = t[1] .. "=" .. (ok and tostring(v) or "error")
	end
	say("spec APIs: " .. table.concat(parts, ", "))
	local any = false
	for k, set in pairs(cdb.sets) do
		any = true
		say(string.format("  snapshot %s: %d icons, saved %s", k, set.count or 0, age(set.time)))
	end
	if not any then say("  no snapshots yet.") end
	say("last restore: " .. (cdb.last or "none yet") .. ". Auto-restore " .. (db.autoRestore and "on" or "off") .. (db.ask and " (asks first)" or "") .. ".")
	if not ready or specBusy or restoring then
		say(string.format("busy: ready=%s specBusy=%s restoring=%s", tostring(ready), tostring(specBusy), tostring(restoring)))
	end
end

-- ---- options panel ---------------------------------------------------------------
local panel = CreateFrame("Frame", "BarGuardOptions")
panel.name = "Bar Guard"
local checks, statusText = {}, nil

local function refreshPanel()
	if not db or not cdb then return end
	for key, cb in pairs(checks) do cb:SetChecked(db[key]) end
	if statusText then
		local key = specKey()
		local set = cdb.sets[key]
		local _, n = scan()
		statusText:SetText(set
			and string.format("Active set: %s. Snapshot holds %d icons (saved %s); %d on your bars now.", key, set.count, age(set.time), n)
			or string.format("Active set: %s. No snapshot yet; one is taken a few seconds after you change your bars.", key))
	end
end

local function makeCheck(key, label, hint, anchor)
	local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
	cb:SetSize(26, 26)
	local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
	text:SetText(label)
	local sub = cb:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	sub:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -2)
	sub:SetText(hint)
	cb:SetScript("OnClick", function(self)
		db[key] = self:GetChecked() and true or false
		refreshPanel()
	end)
	checks[key] = cb
	local spacer = CreateFrame("Frame", nil, panel)
	spacer:SetSize(1, 14)
	spacer:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, 0)
	return spacer
end

local function makeButton(text, anchor, x, onClick)
	local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b:SetSize(150, 24)
	b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x, -14)
	b:SetText(text)
	b:SetScript("OnClick", function() onClick() refreshPanel() end)
	return b
end

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Bar Guard")

local blurb = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
blurb:SetWidth(560)
blurb:SetJustifyH("LEFT")
blurb:SetText("Remembers the icons on your action bars, separately for each spec, and puts them back if they get wiped (checked after login and after every spec switch). It only fills empty slots; it never overwrites an icon. Chat: /barguard status, /barguard snap, /barguard restore.")

statusText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
statusText:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -12)
statusText:SetWidth(560)
statusText:SetJustifyH("LEFT")

local a = statusText
a = makeCheck("autoRestore", "Put wiped bars back automatically", "Off: you only get a chat message and can type /barguard restore yourself.", a)
a = makeCheck("ask", "Ask first", "Shows a Yes/No box before putting the icons back.", a)
a = makeCheck("announce", "Say so in chat", "One line in chat when icons were put back.", a)

makeButton("Snapshot now", a, 0, function()
	local key = specKey()
	store(key, scan())
	say("saved your bars for " .. key .. ".")
end)
makeButton("Restore now", a, 160, function() restore(specKey(), "manual") end)

panel:SetScript("OnShow", refreshPanel)

local function registerPanel()
	if Settings and Settings.RegisterCanvasLayoutCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
		Settings.RegisterAddOnCategory(category)
		panel.category = category
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
end

-- ---- events ---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
local specEvents = {
	ACTIVE_TALENT_GROUP_CHANGED = true,
	PLAYER_SPECIALIZATION_CHANGED = true,
	ACTIVE_PLAYER_SPECIALIZATION_CHANGED = true,
	PLAYER_TALENT_UPDATE = true,
}
local specEventsOk = {}
for ev in pairs(specEvents) do
	-- unknown events throw on modern engines
	specEventsOk[#specEventsOk + 1] = ev .. (pcall(f.RegisterEvent, f, ev) and "" or " (unknown)")
end

f:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		BarGuardDB = BarGuardDB or {}
		db = BarGuardDB
		for k, v in pairs(defaults) do
			if db[k] == nil then db[k] = v end
		end
		BarGuardCharDB = BarGuardCharDB or {}
		cdb = BarGuardCharDB
		cdb.sets = cdb.sets or {}
		cdb.log = cdb.log or {}
		for _, line in ipairs(earlyLog) do log(line) end
		log("loaded; spec events: " .. table.concat(specEventsOk, ", "))
		registerPanel()
	elseif not cdb then
		return
	elseif event == "PLAYER_ENTERING_WORLD" then
		if not ready and not f.loginTimer then
			f.loginTimer = true
			log("entering world, active set " .. specKey() .. " via " .. specApi)
			C_Timer.After(LOGIN_DELAY, function()
				if not specBusy then check("login") end
				ready = true
				settleUntil = GetTime() + 30
				scheduleSnapshot()
			end)
		end
	elseif event == "ACTIONBAR_SLOT_CHANGED" then
		if ready and not specBusy and not restoring then scheduleSnapshot() end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingCombat then
			local why = pendingCombat
			pendingCombat = nil
			check(why .. " (after combat)")
		end
	elseif specEvents[event] then
		onSpecEvent(event)
	end
end)

-- ---- /barguard -----------------------------------------------------------------------
SLASH_BARGUARD1 = "/barguard"
SLASH_BARGUARD2 = "/bguard"
SlashCmdList["BARGUARD"] = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if not cdb then return end
	if msg == "status" then
		status()
	elseif msg == "snap" or msg == "save" then
		local key = specKey()
		store(key, scan())
		say("saved your bars for " .. key .. " (" .. cdb.sets[key].count .. " icons).")
	elseif msg == "log" then
		local t = cdb.log or {}
		say("last " .. math.min(#t, 25) .. " of " .. #t .. " log lines (all of them are in the saved file):")
		for i = math.max(1, #t - 24), #t do print("  " .. t[i]) end
	elseif msg == "restore" then
		restore(specKey(), "manual")
	elseif msg == "" and panel.category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(panel.category:GetID())
	else
		say("/barguard (options), /barguard status, /barguard snap (save bars now), /barguard restore (fill empty slots from the snapshot), /barguard log.")
	end
	refreshPanel()
end
