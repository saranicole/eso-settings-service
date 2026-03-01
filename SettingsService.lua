-- ============================================================
--  LibSettingsService.lua  (Console / Gamepad)
--  Drop-in settings framework for Elder Scrolls Online addons
--  targeting the CONSOLE / GAMEPAD UI layer.
--
--  NO XML FILE REQUIRED - all controls are created programmatically
--  via WINDOW_MANAGER. Uses the native GAMEPAD_TEXT_INPUT dialog.
--
--  UI system:  ZO_Gamepad parametric scroll list
--  SavedVars:  caller passes in their own pre-loaded SV table
--  Activation: caller calls addon:Show() / :Hide() / :Toggle()
--
--  SUPPORTED CONTROL TYPES:
--    checkbox     – on/off boolean toggle
--    slider       – numeric value between min and max
--    dropdown     – pick one value from a list
--    colorpicker  – RGBA color stored as { r, g, b, a }
--    textbox      – freeform string via native gamepad keyboard dialog
--    iconchooser  – pick one texture path from a list
--    button       – fire a callback (no saved value)
--    header       – non-interactive section label
--    divider      – visual separator
--
--  ── QUICK START ──────────────────────────────────────────────
--
--  1. Add this file BEFORE your main addon file in your .txt manifest.
--
--  2. In EVENT_ADD_ON_LOADED, after your SV table is ready:
--
--        MySettings = LibSettingsService:AddAddon("My Addon", {
--            savedVars     = MySavedVarsTable,
--            allowDefaults = true,   -- auto-adds a Reset to Defaults button
--            allowRefresh  = true,   -- auto-refreshes rows on write; enables
--                                    -- RefreshSetting() / RefreshAll()
--        })
--
--        MySettings:AddSetting({ type="header",   name="General" })
--
--        local enabledSetting = MySettings:AddSetting({
--            type="checkbox", name="Enabled", key="enabled", default=true
--        })
--
--  3. When a value changes externally, trigger a refresh of that row:
--
--        enabledSetting:Refresh()
--        -- or by name:
--        MySettings:RefreshSetting("Enabled")
--
--  4. Open the menu:
--        MySettings:Show()
--
--  ── API SUMMARY ──────────────────────────────────────────────
--
--  LibSettingsService:AddAddon(addonName, config)  →  addon
--
--    addon:AddSetting(def [, afterName])  →  settingHandle
--        Add a setting. Returns a handle with:
--            handle:Refresh()   – sync this row's display on demand
--            handle.def         – the underlying definition table
--
--        Each setting stores its value via ONE of two approaches:
--
--        Key-based (standard savedVars storage):
--            key         = "some.path"   dot-path into savedVars
--            default     = <value>       written once if key is absent
--
--        Function-based (custom / computed storage):
--            getFunction = function() return MyAddon.someValue end
--            setFunction = function(v) MyAddon.someValue = v end
--            Both must be supplied together. When present, key and
--            default are ignored for read/write. allowRefresh still
--            works correctly – getFunction is called on each SyncDisplay.
--
--    addon:RefreshSetting(nameOrDef)
--        Trigger a display refresh for a specific setting by name
--        or def reference (same as calling handle:Refresh()).
--
--    addon:RefreshAll()
--        Trigger a display refresh for every setting at once.
--
--    addon:RemoveSetting(nameOrDef)
--    addon:UpdateSetting(nameOrDef, changes)
--    addon:GetSetting(name)  →  def
--    addon:ResetToDefaults()
--    addon:Show() / :Hide() / :Toggle()
--
-- ============================================================

LibSettingsService = LibSettingsService or {}

-- ─────────────────────────────────────────────────────────────
--  CONSTANTS
-- ─────────────────────────────────────────────────────────────

local SCENE_NAME_PREFIX  = "LibSettingsService_Scene_"
local LIST_TEMPLATE      = "ZO_GamepadMenuEntryTemplate"
local HEADER_TEMPLATE    = "ZO_GamepadMenuEntryHeaderTemplate"
local DIVIDER_TEMPLATE   = "ZO_GamepadMenuEntryFullWidthHeaderTemplate"
local ZOS_TEXT_INPUT_DLG = "GAMEPAD_TEXT_INPUT"

-- ─────────────────────────────────────────────────────────────
--  INTERNAL HELPERS
-- ─────────────────────────────────────────────────────────────

local function ApplyDefaults(sv, defaults)
    for k, v in pairs(defaults) do
        if sv[k] == nil then
            if type(v) == "table" then
                sv[k] = {}
                ApplyDefaults(sv[k], v)
            else
                sv[k] = v
            end
        end
    end
end

local function GetNested(tbl, path)
    local cur = tbl
    for part in string.gmatch(path, "[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

local function SetNested(tbl, path, value)
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end
    local cur = tbl
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(cur[part]) ~= "table" then cur[part] = {} end
        cur = cur[part]
    end
    cur[parts[#parts]] = value
end

local function SnapToStep(value, min, max, step)
    local snapped = math.floor((value - min) / step + 0.5) * step + min
    return math.max(min, math.min(max, snapped))
end

local function FmtNum(n)
    if n == math.floor(n) then return tostring(math.floor(n)) end
    return tostring(n)
end

local function ApplySettingDefault(sv, ctrl)
    if ctrl.key ~= nil and ctrl.default ~= nil and ctrl.getFunction == nil then
        if GetNested(sv, ctrl.key) == nil then
            SetNested(sv, ctrl.key, ctrl.default)
        end
    end
end

-- ─────────────────────────────────────────────────────────────
--  VALUE RESOLVER HELPERS
-- ─────────────────────────────────────────────────────────────

local function ResolveGet(def, sv)
    if def.getFunction then return def.getFunction() end
    if def.key then
        local v = GetNested(sv, def.key)
        return (v == nil) and def.default or v
    end
    return def.default
end

local function ResolveSet(def, sv, value)
    if def.setFunction then
        def.setFunction(value)
    elseif def.key then
        SetNested(sv, def.key, value)
    end
end

local function FindSetting(controls, nameOrDef)
    if type(nameOrDef) == "table" then
        for i, ctrl in ipairs(controls) do
            if ctrl == nameOrDef then return i, ctrl end
        end
    elseif type(nameOrDef) == "string" then
        for i, ctrl in ipairs(controls) do
            if ctrl.name == nameOrDef then return i, ctrl end
        end
    end
    return nil, nil
end

-- ─────────────────────────────────────────────────────────────
--  NATIVE TEXT INPUT HELPER
-- ─────────────────────────────────────────────────────────────

local function ShowTextInput(title, currentText, maxChars, onAccept, onCancel)
    ZO_Dialogs_ShowGamepadDialog(ZOS_TEXT_INPUT_DLG, {
        title             = { text = title or "" },
        defaultText       = currentText or "",
        maxInputChars     = maxChars or 256,
        keyboardTitle     = title or "",
        finishedCallback  = function(text) if onAccept then onAccept(text) end end,
        cancelCallback    = function()     if onCancel then onCancel()     end end,
    })
end

-- ─────────────────────────────────────────────────────────────
--  COLOR INPUT HELPER
-- ─────────────────────────────────────────────────────────────

local function ShowColorInput(title, currentColor, onAccept)
    local c = currentColor or { r = 1, g = 1, b = 1, a = 1 }
    if COLOR_PICKER then
        local fn = COLOR_PICKER.ShowGamepad or COLOR_PICKER.Show
        if fn then
            fn(COLOR_PICKER, function(r, g, b, a)
                onAccept({ r = r, g = g, b = b, a = a or 1 })
            end, c.r, c.g, c.b, c.a, title)
            return
        end
    end
    local r, g, b = c.r, c.g, c.b
    local function AskB()
        ShowTextInput((title or "Color") .. " – Blue (0-255)",
            tostring(math.floor(b * 255)), 3, function(t)
                b = math.max(0, math.min(255, tonumber(t) or 0)) / 255
                onAccept({ r = r, g = g, b = b, a = c.a or 1 })
            end)
    end
    local function AskG()
        ShowTextInput((title or "Color") .. " – Green (0-255)",
            tostring(math.floor(g * 255)), 3, function(t)
                g = math.max(0, math.min(255, tonumber(t) or 0)) / 255
                AskB()
            end)
    end
    ShowTextInput((title or "Color") .. " – Red (0-255)",
        tostring(math.floor(r * 255)), 3, function(t)
            r = math.max(0, math.min(255, tonumber(t) or 0)) / 255
            AskG()
        end)
end

-- ─────────────────────────────────────────────────────────────
--  ENTRY BUILDERS
--
--  Each builder returns a list of ZO_GamepadEntryData objects.
--  Every entry that holds a value also exposes:
--
--    entry.SyncDisplay()
--        Re-reads the current value via ResolveGet, updates the
--        entry's subLabel in-place, and returns true if the
--        displayed value actually changed (so the caller knows
--        whether RefreshVisible() is needed).
--
--  SyncDisplay is used by the trigger-based RefreshSetting / RefreshAll
--  paths AND by the automatic write-triggered refresh when
--  allowRefresh = true.
--
--  When allowRefresh = true every builder's write path calls
--  addon:_OnSettingWritten(entry) instead of addon:_RefreshList().
--  _OnSettingWritten calls SyncDisplay on just that entry and then
--  RefreshVisible if the label changed — a cheap targeted repaint with
--  no full repopulate and no timers.
-- ─────────────────────────────────────────────────────────────

local EntryBuilders = {}

-- ── header ───────────────────────────────────────────────────
EntryBuilders["header"] = function(def, _sv, _addon)
    local entry = ZO_GamepadEntryData:New(def.name or "", nil)
    entry:SetHeader(def.name or "")
    entry.isInteractive = false
    entry.templateName  = HEADER_TEMPLATE
    entry.SyncDisplay   = function() return false end
    return { entry }
end

-- ── divider ──────────────────────────────────────────────────
EntryBuilders["divider"] = function(_def, _sv, _addon)
    local entry = ZO_GamepadEntryData:New("", nil)
    entry.isInteractive = false
    entry.templateName  = DIVIDER_TEMPLATE
    entry.SyncDisplay   = function() return false end
    return { entry }
end

-- ── checkbox ─────────────────────────────────────────────────
EntryBuilders["checkbox"] = function(def, sv, addon)
    local function GetVal()   return ResolveGet(def, sv) end
    local function SubLabel()
        return GetVal() and GetString(SI_CHECK_BUTTON_ON) or GetString(SI_CHECK_BUTTON_OFF)
    end

    local entry = ZO_GamepadEntryData:New(def.name or "", nil)
    entry.subLabel            = SubLabel()
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = LIST_TEMPLATE
    entry._lastDisplayedValue = GetVal()

    entry.Activate = function()
        local newVal = not GetVal()
        ResolveSet(def, sv, newVal)
        entry.subLabel            = SubLabel()
        entry._lastDisplayedValue = newVal
        addon:_OnSettingWritten(entry)
        if def.onChange then def.onChange(newVal) end
    end
    entry.OnDirectionalInput = function(_) entry.Activate() end

    entry.SyncDisplay = function()
        local cur = GetVal()
        if cur ~= entry._lastDisplayedValue then
            entry.subLabel            = SubLabel()
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── slider ───────────────────────────────────────────────────
EntryBuilders["slider"] = function(def, sv, addon)
    local min  = def.min  or 0
    local max  = def.max  or 100
    local step = def.step or 1

    local function GetVal()
        local v = ResolveGet(def, sv)
        return SnapToStep(v ~= nil and v or min, min, max, step)
    end
    local function SubLabel() return FmtNum(GetVal()) .. " / " .. FmtNum(max) end

    local entry = ZO_GamepadEntryData:New(def.name or "", nil)
    entry.subLabel            = SubLabel()
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = LIST_TEMPLATE
    entry._lastDisplayedValue = GetVal()

    local function ChangeBy(delta)
        local newVal = SnapToStep(GetVal() + delta, min, max, step)
        ResolveSet(def, sv, newVal)
        entry.subLabel            = SubLabel()
        entry._lastDisplayedValue = newVal
        addon:_OnSettingWritten(entry)
        if def.onChange then def.onChange(newVal) end
    end

    entry.Activate           = function() ChangeBy(step) end
    entry.OnDirectionalInput = function(direction)
        ChangeBy(direction == MOVEMENT_CONTROLLER_DIRECTION_NEGATIVE and -step or step)
    end

    entry.SyncDisplay = function()
        local cur = GetVal()
        if cur ~= entry._lastDisplayedValue then
            entry.subLabel            = SubLabel()
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── dropdown ─────────────────────────────────────────────────
EntryBuilders["dropdown"] = function(def, sv, addon)
    local choices = def.choices or {}

    local function GetVal()
        local v = ResolveGet(def, sv)
        return v ~= nil and v or choices[1]
    end
    local function GetIndex()
        local cur = GetVal()
        for i, c in ipairs(choices) do if c == cur then return i end end
        return 1
    end

    local entry = ZO_GamepadEntryData:New(def.name or "", nil)
    entry.subLabel            = tostring(GetVal())
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = LIST_TEMPLATE
    entry._lastDisplayedValue = GetVal()

    local function CycleBy(delta)
        if #choices == 0 then return end
        local newVal = choices[((GetIndex() - 1 + delta) % #choices) + 1]
        ResolveSet(def, sv, newVal)
        entry.subLabel            = tostring(newVal)
        entry._lastDisplayedValue = newVal
        addon:_OnSettingWritten(entry)
        if def.onChange then def.onChange(newVal) end
    end

    entry.Activate           = function() CycleBy(1) end
    entry.OnDirectionalInput = function(direction)
        CycleBy(direction == MOVEMENT_CONTROLLER_DIRECTION_NEGATIVE and -1 or 1)
    end

    entry.SyncDisplay = function()
        local cur = GetVal()
        if cur ~= entry._lastDisplayedValue then
            entry.subLabel            = tostring(cur)
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── colorpicker ───────────────────────────────────────────────
EntryBuilders["colorpicker"] = function(def, sv, addon)
    local function GetVal()
        local v = ResolveGet(def, sv)
        if v == nil then
            v = def.default or { r = 1, g = 1, b = 1, a = 1 }
            if not def.getFunction and def.key then SetNested(sv, def.key, v) end
        end
        return v
    end
    local function ColorKey(c)
        return string.format("%.4f:%.4f:%.4f:%.4f", c.r, c.g, c.b, c.a or 1)
    end
    local function SubLabel()
        local c = GetVal()
        return string.format("R:%.0f G:%.0f B:%.0f", c.r*255, c.g*255, c.b*255)
    end

    local entry = ZO_GamepadEntryData:New(def.name or "", nil)
    entry.subLabel            = SubLabel()
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = LIST_TEMPLATE
    entry._lastDisplayedValue = ColorKey(GetVal())

    entry.Activate = function()
        ShowColorInput(def.name, GetVal(), function(col)
            ResolveSet(def, sv, col)
            entry.subLabel            = SubLabel()
            entry._lastDisplayedValue = ColorKey(col)
            addon:_OnSettingWritten(entry)
            if def.onChange then def.onChange(col) end
        end)
    end

    entry.SyncDisplay = function()
        local cur = ColorKey(GetVal())
        if cur ~= entry._lastDisplayedValue then
            entry.subLabel            = SubLabel()
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── textbox ───────────────────────────────────────────────────
EntryBuilders["textbox"] = function(def, sv, addon)
    local function GetVal()
        local v = ResolveGet(def, sv)
        return v ~= nil and v or (def.default or "")
    end

    local entry = ZO_GamepadEntryData:New(def.name or "", nil)
    entry.subLabel            = tostring(GetVal())
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = LIST_TEMPLATE
    entry._lastDisplayedValue = tostring(GetVal())

    entry.Activate = function()
        ShowTextInput(def.name, tostring(GetVal()), def.maxChars or 256,
            function(text)
                ResolveSet(def, sv, text)
                entry.subLabel            = text
                entry._lastDisplayedValue = text
                addon:_OnSettingWritten(entry)
                if def.onChange then def.onChange(text) end
            end)
    end

    entry.SyncDisplay = function()
        local cur = tostring(GetVal())
        if cur ~= entry._lastDisplayedValue then
            entry.subLabel            = cur
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── iconchooser ───────────────────────────────────────────────
EntryBuilders["iconchooser"] = function(def, sv, addon)
    local icons = def.icons or {}

    local function GetVal()
        local v = ResolveGet(def, sv)
        return v ~= nil and v or (icons[1] or "")
    end
    local function GetIndex()
        local cur = GetVal()
        for i, p in ipairs(icons) do if p == cur then return i end end
        return 1
    end
    local function ShortPath(p) return (p and p:match("([^/]+)%.%a+$")) or p or "" end

    local entry = ZO_GamepadEntryData:New(def.name or "", nil)
    entry.subLabel            = ShortPath(GetVal())
    entry.icon                = GetVal()
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = LIST_TEMPLATE
    entry._lastDisplayedValue = GetVal()

    local function CycleBy(delta)
        if #icons == 0 then return end
        local newVal = icons[((GetIndex() - 1 + delta) % #icons) + 1]
        ResolveSet(def, sv, newVal)
        entry.subLabel            = ShortPath(newVal)
        entry.icon                = newVal
        entry._lastDisplayedValue = newVal
        addon:_OnSettingWritten(entry)
        if def.onChange then def.onChange(newVal) end
    end

    entry.Activate           = function() CycleBy(1) end
    entry.OnDirectionalInput = function(direction)
        CycleBy(direction == MOVEMENT_CONTROLLER_DIRECTION_NEGATIVE and -1 or 1)
    end

    entry.SyncDisplay = function()
        local cur = GetVal()
        if cur ~= entry._lastDisplayedValue then
            entry.subLabel            = ShortPath(cur)
            entry.icon                = cur
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── button ────────────────────────────────────────────────────
EntryBuilders["button"] = function(def, _sv, _addon)
    local entry = ZO_GamepadEntryData:New(def.name or "Button", nil)
    entry.subLabel      = def.subLabel or ""
    entry.tooltip       = def.tooltip
    entry.isInteractive = true
    entry.templateName  = LIST_TEMPLATE
    entry.Activate      = function() if def.onClick then def.onClick() end end
    entry.SyncDisplay   = function() return false end
    return { entry }
end

-- ─────────────────────────────────────────────────────────────
--  SETTINGS SCREEN CLASS
-- ─────────────────────────────────────────────────────────────

local SettingsScreen = ZO_Object:Subclass()

function SettingsScreen:New(addon)
    local obj = ZO_Object.New(self)
    obj:Initialize(addon)
    return obj
end

function SettingsScreen:Initialize(addon)
    self.addon     = addon
    self.sceneName = SCENE_NAME_PREFIX .. tostring(addon.name):gsub("[%s%p]", "_")

    -- Maps def → built entry (or list of entries for multi-entry types).
    -- Populated fresh on every _PopulateList call.
    -- Used by RefreshSetting to find the right entry without rescanning
    -- the whole list.
    self._entryByDef = {}

    -- Build the root control manually. ZO_GamepadParametricScrollScreen
    -- is an internal ZOS base class, not an instantiable virtual template.
    -- We create a plain full-screen backdrop and attach the parametric
    -- scroll list to it ourselves.
    self.control = WINDOW_MANAGER:CreateControl(
        self.sceneName .. "_Control", GuiRoot, CT_CONTROL)
    self.control:SetAnchorFill(GuiRoot)
    self.control:SetHidden(true)

    -- Background — matches the standard gamepad menu backdrop colour.
    local bg = WINDOW_MANAGER:CreateControl(
        self.sceneName .. "_BG", self.control, CT_BACKDROP)
    bg:SetAnchorFill(self.control)
    bg:SetCenterColor(0, 0, 0, 0.9)
    bg:SetEdgeColor(0, 0, 0, 0)
    bg:SetEdgeSize(0)

    -- Parametric scroll list — this is the real workhorse.
    self.list = ZO_GamepadVerticalParametricScrollList:New(self.control)
    self.list:SetAnchor(TOPLEFT,  self.control, TOPLEFT,  60, 120)
    self.list:SetAnchor(BOTTOMRIGHT, self.control, BOTTOMRIGHT, -60, -60)

    self:_SetupTemplates()
    self:_SetupScene()
    self:_SetupKeybinds()
end

function SettingsScreen:_SetupTemplates()
    self.list:AddDataTemplate(LIST_TEMPLATE,
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction)
    self.list:AddDataTemplateWithHeader(LIST_TEMPLATE,
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction,
        nil, HEADER_TEMPLATE)
    self.list:AddDataTemplate(HEADER_TEMPLATE,
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction)
    self.list:AddDataTemplate(DIVIDER_TEMPLATE,
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction)
end

function SettingsScreen:_SetupScene()
    self.scene = ZO_Scene:New(self.sceneName, SCENE_MANAGER)
    local screen = self
    self.scene:RegisterCallback("StateChange", function(_, newState)
        if newState == SCENE_SHOWING then
            screen.control:SetHidden(false)
            KEYBIND_STRIP:AddKeybindButtonGroup(screen.keybindStripDescriptor)
            screen.list:Activate()
            screen:_PopulateList()
        elseif newState == SCENE_HIDDEN then
            KEYBIND_STRIP:RemoveKeybindButtonGroup(screen.keybindStripDescriptor)
            screen.list:Deactivate()
            screen.control:SetHidden(true)
        end
    end)
end

function SettingsScreen:_SetupKeybinds()
    local screen = self
    self.keybindStripDescriptor = {
        alignment = KEYBIND_STRIP_ALIGN_LEFT,
        {
            name     = GetString(SI_GAMEPAD_BACK_OPTION),
            keybind  = "UI_SHORTCUT_NEGATIVE",
            callback = function() screen:Hide() end,
            sound    = SOUNDS.GAMEPAD_MENU_BACK,
        },
        {
            name     = GetString(SI_GAMEPAD_SELECT_OPTION),
            keybind  = "UI_SHORTCUT_PRIMARY",
            callback = function()
                local entry = screen.list:GetTargetData()
                if entry and entry.isInteractive and entry.Activate then
                    entry.Activate()
                end
            end,
            sound = SOUNDS.GAMEPAD_MENU_FORWARD,
        },
    }
end

function SettingsScreen:_PopulateList()
    self.list:Clear()
    self._entryByDef = {}

    local sv   = self.addon.savedVars
    local defs = self.addon.controls

    for _, def in ipairs(defs) do
        local builder = EntryBuilders[def.type]
        if builder then
            local entries = builder(def, sv, self.addon)
            self._entryByDef[def] = entries   -- store all entries for this def
            for _, entry in ipairs(entries) do
                self.list:AddEntry(entry.templateName or LIST_TEMPLATE, entry)
            end
        else
            d(string.format("[LibSettingsService] Unknown control type '%s' in '%s'",
                tostring(def.type), tostring(self.addon.name)))
        end
    end

    self.list:Commit()
end

-- Full repopulate – used when the controls list changes structurally
-- (add, remove, update).  Resets scroll position.
function SettingsScreen:RefreshList()
    if SCENE_MANAGER:IsShowing(self.sceneName) then
        self:_PopulateList()
    end
end

-- Targeted refresh – sync the display of entries that belong to a
-- specific def, then repaint only the visible rows.  Scroll position
-- is preserved.  No-op when the scene is not showing.
function SettingsScreen:RefreshSetting(def)
    if not SCENE_MANAGER:IsShowing(self.sceneName) then return end
    local entries = self._entryByDef[def]
    if not entries then return end
    local dirty = false
    for _, entry in ipairs(entries) do
        if entry.SyncDisplay and entry.SyncDisplay() then dirty = true end
    end
    if dirty then
        self.list:RefreshVisible()
    end
end

-- Targeted refresh of every setting at once.  Preferred over a full
-- _PopulateList because it preserves scroll position.
function SettingsScreen:RefreshAll()
    if not SCENE_MANAGER:IsShowing(self.sceneName) then return end
    local dirty = false
    for _, entries in pairs(self._entryByDef) do
        for _, entry in ipairs(entries) do
            if entry.SyncDisplay and entry.SyncDisplay() then dirty = true end
        end
    end
    if dirty then
        self.list:RefreshVisible()
    end
end

function SettingsScreen:Show()
    self.control:SetHidden(false)
    SCENE_MANAGER:Push(self.sceneName)
end

function SettingsScreen:Hide()
    SCENE_MANAGER:HideCurrentScene()
end

function SettingsScreen:Toggle()
    if SCENE_MANAGER:IsShowing(self.sceneName) then self:Hide() else self:Show() end
end

-- ─────────────────────────────────────────────────────────────
--  PUBLIC API  –  LibSettingsService:AddAddon(addonName, config)
-- ─────────────────────────────────────────────────────────────

--[[
  ════════════════════════════════════════════════════════════
  LibSettingsService:AddAddon(addonName, config)  →  addon

  addonName  (string)   Scopes all scene/control names.  Used as
                        the panel title.  Multiple addons never
                        collide as long as their names differ.

  config fields:
    savedVars     (table)    Required. Your pre-loaded ZO_SavedVars table.
    controls      (table)    Optional seed list of setting definitions.
    defaults      (table)    Optional top-level { key=value } defaults
                             applied non-destructively to savedVars.
    allowDefaults (boolean)  Auto-appends a "Reset to Defaults" button.
    allowRefresh  (boolean)  When true, every write made through the menu
                             automatically triggers a targeted display
                             refresh of just that setting's row — no
                             polling, no timers, no external calls needed.
                             Also enables :RefreshSetting() and
                             :RefreshAll() for syncing values that were
                             changed outside the menu.

  ════════════════════════════════════════════════════════════
  addon methods:

  ── Display ──────────────────────────────────────────────────
    :Show()     Push settings scene onto the gamepad scene stack.
    :Hide()     Pop / hide the current scene.
    :Toggle()   Show if hidden, hide if showing.

  ── Setting management ───────────────────────────────────────
    :AddSetting(def [, afterName])  →  settingHandle
        Add a new setting control and return a handle for it.

        settingHandle fields:
            .def          The definition table passed to AddSetting.
            :Refresh()    Sync this setting's row display to the current
                          value immediately.  Safe to call at any time,
                          including when the menu is not open (no-op).

        This is the primary way to trigger a display update when your
        addon changes a value externally:

            local scaleSetting = MySettings:AddSetting({
                type = "slider", name = "Scale",
                key = "scale", min = 50, max = 200, step = 5, default = 100,
            })

            -- Somewhere else in your addon when the value changes:
            MyAddon_SV.scale = 75
            scaleSetting:Refresh()

    :RefreshSetting(nameOrDef)
        Trigger a display refresh for a specific setting by name
        string or def/handle reference.  Equivalent to
        handle:Refresh() but usable when you only have the name.

    :RefreshAll()
        Trigger a display refresh for every setting at once.
        Useful after a bulk external update (e.g. profile switch).
        Only available when allowRefresh = true.

    :RemoveSetting(nameOrDef)
        Remove a setting by name string or handle/def reference.

    :UpdateSetting(nameOrDef, changes)
        Merge a changes table into an existing def and refresh.

    :GetSetting(name)  →  def
        Return the def for the first setting whose .name matches.

    :ResetToDefaults()
        Write every setting's .default back through ResolveSet and
        refresh the list.  Also fired by the auto "Reset to Defaults"
        button when allowDefaults = true.

  ── Internal ─────────────────────────────────────────────────
    :_RefreshList()   Full repopulate.  Called internally by entry
                      builders after a structural change or user
                      interaction.  Not normally needed by addon authors.

  ════════════════════════════════════════════════════════════
  Setting definition reference:

  Shared fields (all types):
    type         (string)    Required.
    name         (string)    Row label.
    tooltip      (string)    Shown in the gamepad tooltip area.
    onChange     (function)  Called with the new value after each change.

  Value storage – choose ONE approach:

  ── Approach 1: key-based (standard saved-variable storage) ────────
    key          (string)    Dot-path into savedVars, e.g. "ui.scale".
                             Supports nested paths: "display.hud.scale"
    default      (any)       Written once to savedVars when the key is
                             absent on first load. Ignored when
                             getFunction is present.

    Example:
      { type="slider", name="Opacity",
        key="display.opacity", default=80, min=0, max=100, step=5 }

  ── Approach 2: function-based (custom / computed storage) ─────────
    getFunction  (function)  Called with no arguments. Must return the
                             current value of the setting. Used instead
                             of reading from savedVars.
    setFunction  (function)  Called with (newValue) when the user
                             changes the setting. Responsible for
                             storing the value wherever needed. Use a
                             no-op -- function(_) end -- for read-only
                             or computed display-only controls.

    Rules:
      - Both getFunction and setFunction must be supplied together.
      - When both are present, key and default are ignored for
        read/write (key may still appear as documentation).
      - allowRefresh works correctly with function-based controls:
        getFunction is called on each SyncDisplay / Refresh call so
        the row always reflects whatever your getter returns.

    Examples:

      -- Value lives in your own table, not in savedVars:
      { type = "checkbox", name = "Debug Mode",
        getFunction = function() return MyAddon.debugMode end,
        setFunction = function(v) MyAddon.debugMode = v end }

      -- Read-only computed display (no-op setter):
      { type = "slider", name = "Current Latency (ms)",
        min = 0, max = 1000, step = 1,
        getFunction = function() return GetLatency() end,
        setFunction = function(_) end }

      -- Wraps another system's API:
      { type = "dropdown", name = "Difficulty",
        choices = { "Easy", "Normal", "Hard" },
        getFunction = function() return MyAddon:GetDifficulty() end,
        setFunction = function(v) MyAddon:SetDifficulty(v) end }

  Per-type extras:
    checkbox    – (none)
    slider      – min, max, step  (numbers)
    dropdown    – choices = { "A", "B", "C" }
    colorpicker – default = { r, g, b, a }  (channels 0–1)
    textbox     – maxChars (number, default 256)
    iconchooser – icons = { "/path/to/icon.dds", ... }
    button      – onClick (function), subLabel (string, optional)
    header      – (no key / default / onChange)
    divider     – (no fields needed)

  ════════════════════════════════════════════════════════════
  Example:

    EVENT_MANAGER:RegisterForEvent("MyAddon_Loaded", EVENT_ADD_ON_LOADED,
        function(_, addonName)
            if addonName ~= "MyAddon" then return end

            MyAddon_SV = ZO_SavedVars:NewAccountWide("MyAddon_SV", 1, nil, {})

            MySettings = LibSettingsService:AddAddon("My Addon", {
                savedVars     = MyAddon_SV,
                allowDefaults = true,
                allowRefresh  = true,
            })

            MySettings:AddSetting({ type = "header", name = "Display" })

            local scaleSetting = MySettings:AddSetting({
                type = "slider", name = "Scale",
                key = "scale", min = 50, max = 200, step = 5, default = 100,
                onChange = function(v) MyAddon:SetScale(v) end,
            })

            local modeSetting = MySettings:AddSetting({
                type = "dropdown", name = "Mode",
                key = "mode", choices = { "Fast", "Balanced", "Quality" },
                default = "Balanced",
            })

            -- When your addon changes these values externally, sync the UI:
            --   MyAddon_SV.scale = 75
            --   scaleSetting:Refresh()
            --
            --   MyAddon_SV.mode = "Fast"
            --   MySettings:RefreshSetting("Mode")
            --
            --   MyAddon:LoadProfile(profileData)  -- bulk change
            --   MySettings:RefreshAll()
        end)
--]]

function LibSettingsService:AddAddon(addonName, config)
    assert(type(addonName)        == "string", "[LibSettingsService] addonName must be a string")
    assert(type(config)           == "table",  "[LibSettingsService] config must be a table")
    assert(type(config.savedVars) == "table",  "[LibSettingsService] config.savedVars must be a table")

    config.controls = config.controls or {}
    assert(type(config.controls)  == "table",  "[LibSettingsService] config.controls must be a table")

    if type(config.defaults) == "table" then
        ApplyDefaults(config.savedVars, config.defaults)
    end
    for _, ctrl in ipairs(config.controls) do
        ApplySettingDefault(config.savedVars, ctrl)
    end

    local addon = {
        name          = addonName,
        savedVars     = config.savedVars,
        controls      = config.controls,
        allowDefaults = config.allowDefaults == true,
        allowRefresh  = config.allowRefresh  == true,
        _screen       = nil,
        -- Maps def → settingHandle, so RefreshSetting(nameOrDef) can
        -- accept a handle as well as a plain def or name string.
        _handleByDef  = {},
    }

    local function EnsureScreen()
        if not addon._screen then
            if addon.allowDefaults then
                local hasReset = false
                for _, ctrl in ipairs(addon.controls) do
                    if ctrl._isDefaultsButton then hasReset = true; break end
                end
                if not hasReset then
                    table.insert(addon.controls, {
                        type              = "button",
                        name              = "Reset to Defaults",
                        _isDefaultsButton = true,
                        onClick           = function() addon:ResetToDefaults() end,
                    })
                end
            end
            addon._screen = SettingsScreen:New(addon)
        end
    end

    -- ── Display ──────────────────────────────────────────────

    function addon:Show()    EnsureScreen(); self._screen:Show()   end
    function addon:Hide()    if self._screen then self._screen:Hide()   end end
    function addon:Toggle()  EnsureScreen(); self._screen:Toggle() end

    -- Internal: called by entry builders after a structural change
    -- (add/remove/update setting) or when allowRefresh is false and
    -- a user interaction has changed a value.
    function addon:_RefreshList()
        if self._screen then self._screen:RefreshList() end
    end

    -- Internal: called by every builder's write path after a user
    -- interaction changes a value.
    -- • allowRefresh = true  → targeted SyncDisplay + RefreshVisible on
    --                          just this entry (cheap, no repopulate).
    -- • allowRefresh = false → falls back to a full _RefreshList so the
    --                          row still updates correctly.
    function addon:_OnSettingWritten(entry)
        if self.allowRefresh then
            if self._screen and entry.SyncDisplay then
                -- The entry already updated its own subLabel before this
                -- call, so SyncDisplay will see no change and return false.
                -- We therefore call RefreshVisible directly.
                if SCENE_MANAGER:IsShowing(self._screen.sceneName) then
                    self._screen.list:RefreshVisible()
                end
            end
        else
            self:_RefreshList()
        end
    end

    -- ── Trigger-based refresh ─────────────────────────────────

    -- Build the canonical def reference from a name, def table, or handle.
    local function ResolveDef(nameOrDefOrHandle)
        if type(nameOrDefOrHandle) == "string" then
            local _, def = FindSetting(self.controls, nameOrDefOrHandle)
            return def
        elseif type(nameOrDefOrHandle) == "table" then
            -- Accept either a raw def or a settingHandle (.def field)
            if nameOrDefOrHandle.def then
                return nameOrDefOrHandle.def
            end
            return nameOrDefOrHandle
        end
    end

    ---Sync the display of a single setting on demand.
    ---nameOrDefOrHandle: the setting's name string, its def table,
    ---                   or the handle returned by AddSetting.
    function addon:RefreshSetting(nameOrDefOrHandle)
        if not self._screen then return end
        local def = ResolveDef(nameOrDefOrHandle)
        if def then
            self._screen:RefreshSetting(def)
        end
    end

    ---Sync the display of every setting at once.
    ---Use after a bulk external change (e.g. profile load).
    function addon:RefreshAll()
        if not self._screen then return end
        self._screen:RefreshAll()
    end

    -- ── Setting management ────────────────────────────────────

    ---Add a new setting and return a handle for it.
    ---@param def       table
    ---@param afterName string|nil
    ---@return table settingHandle  { def=def, Refresh=fn }
    function addon:AddSetting(def, afterName)
        assert(type(def) == "table", "[LibSettingsService] AddSetting: def must be a table")
        assert(def.type  ~= nil,     "[LibSettingsService] AddSetting: def.type is required")

        ApplySettingDefault(self.savedVars, def)

        -- Determine insert position. Priority:
        --   1. Immediately after afterName (if supplied and found)
        --   2. Immediately before the auto-defaults button (if present)
        --   3. Append to end
        local inserted = false

        if afterName then
            local idx = FindSetting(self.controls, afterName)
            if idx then
                table.insert(self.controls, idx + 1, def)
                inserted = true
            end
        end

        if not inserted then
            local insertBefore
            for i, ctrl in ipairs(self.controls) do
                if ctrl._isDefaultsButton then insertBefore = i; break end
            end
            if insertBefore then
                table.insert(self.controls, insertBefore, def)
            else
                table.insert(self.controls, def)
            end
        end

        self:_RefreshList()

        -- Build the settingHandle that the caller holds onto
        local handle = {
            def = def,
        }
        function handle:Refresh()
            addon:RefreshSetting(self.def)
        end

        self._handleByDef[def] = handle
        return handle
    end

    ---Remove a setting. Accepts a name, def, or handle.
    function addon:RemoveSetting(nameOrDefOrHandle)
        local target = (type(nameOrDefOrHandle) == "table" and nameOrDefOrHandle.def)
            or nameOrDefOrHandle
        local idx = FindSetting(self.controls, target)
        if idx then
            local def = self.controls[idx]
            self._handleByDef[def] = nil
            table.remove(self.controls, idx)
            self:_RefreshList()
        else
            d(string.format("[LibSettingsService] RemoveSetting: '%s' not found in '%s'",
                tostring(nameOrDefOrHandle), tostring(self.name)))
        end
    end

    ---Merge changes into an existing def and refresh.
    function addon:UpdateSetting(nameOrDefOrHandle, changes)
        assert(type(changes) == "table", "[LibSettingsService] UpdateSetting: changes must be a table")
        local target = (type(nameOrDefOrHandle) == "table" and nameOrDefOrHandle.def)
            or nameOrDefOrHandle
        local _, def = FindSetting(self.controls, target)
        if def then
            for k, v in pairs(changes) do def[k] = v end
            ApplySettingDefault(self.savedVars, def)
            self:_RefreshList()
        else
            d(string.format("[LibSettingsService] UpdateSetting: '%s' not found in '%s'",
                tostring(nameOrDefOrHandle), tostring(self.name)))
        end
    end

    ---Return the def table for the first setting whose .name matches.
    function addon:GetSetting(name)
        local _, def = FindSetting(self.controls, name)
        return def
    end

    ---Reset every setting with a .default back to that value.
    function addon:ResetToDefaults()
        for _, ctrl in ipairs(self.controls) do
            if ctrl.default ~= nil and not ctrl._isDefaultsButton then
                ResolveSet(ctrl, self.savedVars, ctrl.default)
            end
        end
        self:_RefreshList()
    end

    return addon
end
