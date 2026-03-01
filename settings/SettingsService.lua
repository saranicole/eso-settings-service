-- ============================================================
--  LibSettingsService.lua  (Console / Gamepad)
--  Drop-in settings framework for Elder Scrolls Online addons
--  targeting the CONSOLE / GAMEPAD UI layer.
--
--  REQUIRES LibSettingsService.xml in your addon manifest, listed
--  before this file. Uses the native GAMEPAD_TEXT_INPUT dialog.
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
--  2. Set up SavedVars in EVENT_ADD_ON_LOADED, but call AddAddon() from
--     EVENT_PLAYER_ACTIVATED -- gamepad UI templates are not ready until
--     then. Your slash command can safely reference the panel variable
--     because players can't type commands before the world loads.
--
--        local MySettings
--
--        -- EVENT_ADD_ON_LOADED:
--        MySavedVarsTable = ZO_SavedVars:NewAccountWide(...)
--        SLASH_COMMANDS["/mysettings"] = function()
--            if MySettings then MySettings:Show() end
--        end
--
--        -- EVENT_PLAYER_ACTIVATED:
--        MySettings = LibSettingsService:AddAddon("My Addon", {
--            savedVars     = MySavedVarsTable,
--            allowDefaults = true,
--            allowRefresh  = true,
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
local CHECKBOX_TEMPLATE  = "ZO_GamepadOptionsCheckboxRow"
local SLIDER_TEMPLATE    = "ZO_GamepadOptionsSliderRow"
local LABEL_TEMPLATE     = "ZO_GamepadOptionsLabelRow"
local DROPDOWN_TEMPLATE  = "ZO_GamepadHorizontalListRow"
local COLOR_TEMPLATE     = "ZO_GamepadOptionsColorRow"
local SECTION_TEMPLATE   = "ZO_Options_SectionTitle_WithDivider"
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
    local entry = ZO_GamepadEntryData:New(def.name or "")
    entry.isInteractive = false
    entry.canSelect     = false
    entry.templateName  = SECTION_TEMPLATE
    entry.SyncDisplay   = function() return false end
    return { entry }
end

-- ── divider ──────────────────────────────────────────────────
EntryBuilders["divider"] = function(_def, _sv, _addon)
    local entry = ZO_GamepadEntryData:New("")
    entry.isInteractive = false
    entry.canSelect     = false
    entry.templateName  = DIVIDER_TEMPLATE
    entry.SyncDisplay   = function() return false end
    return { entry }
end

-- ── checkbox ─────────────────────────────────────────────────
-- Uses ZO_GamepadOptionsCheckboxRow: Name + Checkbox widget.
EntryBuilders["checkbox"] = function(def, sv, addon)
    local function GetVal() return ResolveGet(def, sv) == true end

    local entry = ZO_GamepadEntryData:New(def.name or "")
    entry.checked             = GetVal()
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = CHECKBOX_TEMPLATE
    entry._lastDisplayedValue = GetVal()

    entry.Activate = function()
        local newVal = not GetVal()
        ResolveSet(def, sv, newVal)
        entry.checked             = newVal
        entry._lastDisplayedValue = newVal
        -- Update visual state if the row is currently displayed.
        if entry._applyCheckboxState then
            entry._applyCheckboxState(newVal)
        end
        addon:_OnSettingWritten(entry)
        if def.onChange then def.onChange(newVal) end
    end
    entry.OnDirectionalInput = function(_) entry.Activate() end

    entry.SyncDisplay = function()
        local cur = GetVal()
        if cur ~= entry._lastDisplayedValue then
            entry.checked             = cur
            entry._lastDisplayedValue = cur
            if entry._applyCheckboxState then
                entry._applyCheckboxState(cur)
            end
            return true
        end
        return false
    end

    return { entry }
end

-- ── slider ───────────────────────────────────────────────────
-- Uses ZO_GamepadOptionsSliderRow: Name + Slider widget.
EntryBuilders["slider"] = function(def, sv, addon)
    local min  = def.min  or 0
    local max  = def.max  or 100
    local step = def.step or 1

    local function GetVal()
        local v = ResolveGet(def, sv)
        return SnapToStep(v ~= nil and v or min, min, max, step)
    end

    local entry = ZO_GamepadEntryData:New(def.name or "")
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = SLIDER_TEMPLATE
    entry._lastDisplayedValue = GetVal()

    entry._sliderSetup = function(slider, control)
        slider:SetHandler("OnValueChanged", nil)
        slider:SetMinMax(min, max)
        slider:SetValue(GetVal())
        slider:SetValueStep(step)
        -- Show current value in a label if present
        local label = control and control:GetNamedChild("ValueLabel")
        if label then label:SetText(FmtNum(GetVal())) end
        slider:SetHandler("OnValueChanged", function(s, value)
            local snapped = SnapToStep(value, min, max, step)
            ResolveSet(def, sv, snapped)
            entry._lastDisplayedValue = snapped
            if label then label:SetText(FmtNum(snapped)) end
            addon:_OnSettingWritten(entry)
            if def.onChange then def.onChange(snapped) end
        end)
    end

    entry.Activate = function() end  -- slider handles input directly
    entry.OnDirectionalInput = function(direction)
        local delta = direction == MOVEMENT_CONTROLLER_DIRECTION_NEGATIVE and -step or step
        local newVal = SnapToStep(GetVal() + delta, min, max, step)
        ResolveSet(def, sv, newVal)
        entry._lastDisplayedValue = newVal
        addon:_OnSettingWritten(entry)
        if def.onChange then def.onChange(newVal) end
    end

    entry.SyncDisplay = function()
        local cur = GetVal()
        if cur ~= entry._lastDisplayedValue then
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── dropdown ─────────────────────────────────────────────────
-- Uses ZO_GamepadHorizontalListRow: Name + horizontal scroll list.
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

    local entry = ZO_GamepadEntryData:New(def.name or "")
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = DROPDOWN_TEMPLATE
    entry._lastDisplayedValue = GetVal()

    local function SetChoice(newVal)
        ResolveSet(def, sv, newVal)
        entry._lastDisplayedValue = newVal
        addon:_OnSettingWritten(entry)
        if def.onChange then def.onChange(newVal) end
    end

    entry._dropdownSetup = function(hList, control)
        hList:Clear()
        for i, c in ipairs(choices) do
            hList:AddEntry({ name = tostring(c) })
        end
        hList:Commit()
        hList:SetSelectedIndex(GetIndex(), false, true)
        hList:SetOnSelectedDataChangedCallback(function(data)
            SetChoice(data.name)
        end)
    end

    entry.Activate = function() end  -- handled by horizontal list
    entry.OnDirectionalInput = function(direction)
        local delta = direction == MOVEMENT_CONTROLLER_DIRECTION_NEGATIVE and -1 or 1
        if #choices == 0 then return end
        local newVal = choices[((GetIndex() - 1 + delta) % #choices) + 1]
        SetChoice(newVal)
    end

    entry.SyncDisplay = function()
        local cur = GetVal()
        if cur ~= entry._lastDisplayedValue then
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── colorpicker ───────────────────────────────────────────────
-- Uses ZO_GamepadOptionsColorRow: Name + Color swatch.
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

    local entry = ZO_GamepadEntryData:New(def.name or "")
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = COLOR_TEMPLATE
    entry._lastDisplayedValue = ColorKey(GetVal())
    entry._getColor           = GetVal

    entry.Activate = function()
        ShowColorInput(def.name, GetVal(), function(col)
            ResolveSet(def, sv, col)
            entry._lastDisplayedValue = ColorKey(col)
            entry._getColor = function() return col end
            addon:_OnSettingWritten(entry)
            if def.onChange then def.onChange(col) end
        end)
    end

    entry.SyncDisplay = function()
        local cur = ColorKey(GetVal())
        if cur ~= entry._lastDisplayedValue then
            entry._lastDisplayedValue = cur
            entry._getColor = GetVal
            return true
        end
        return false
    end

    return { entry }
end

-- ── textbox ───────────────────────────────────────────────────
-- Uses ZO_GamepadOptionsLabelRow: Name only, opens keyboard on activate.
EntryBuilders["textbox"] = function(def, sv, addon)
    local function GetVal()
        local v = ResolveGet(def, sv)
        return v ~= nil and v or (def.default or "")
    end

    local entry = ZO_GamepadEntryData:New(def.name or "")
    entry._subLabelIdx        = entry:AddSubLabel(tostring(GetVal()))
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = LABEL_TEMPLATE
    entry._lastDisplayedValue = tostring(GetVal())

    entry.Activate = function()
        ShowTextInput(def.name, tostring(GetVal()), def.maxChars or 256,
            function(text)
                ResolveSet(def, sv, text)
                entry:SetSubLabel(entry._subLabelIdx, text)
                entry._lastDisplayedValue = text
                addon:_OnSettingWritten(entry)
                if def.onChange then def.onChange(text) end
            end)
    end

    entry.SyncDisplay = function()
        local cur = tostring(GetVal())
        if cur ~= entry._lastDisplayedValue then
            entry:SetSubLabel(entry._subLabelIdx, cur)
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── iconchooser ───────────────────────────────────────────────
-- Uses ZO_GamepadHorizontalListRow like dropdown but shows icons.
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

    local entry = ZO_GamepadEntryData:New(def.name or "")
    entry.tooltip             = def.tooltip
    entry.isInteractive       = true
    entry.templateName        = DROPDOWN_TEMPLATE
    entry._lastDisplayedValue = GetVal()

    local function SetIcon(newVal)
        ResolveSet(def, sv, newVal)
        entry._lastDisplayedValue = newVal
        addon:_OnSettingWritten(entry)
        if def.onChange then def.onChange(newVal) end
    end

    entry._dropdownSetup = function(hList, control)
        hList:Clear()
        for _, path in ipairs(icons) do
            hList:AddEntry({ icon = path, name = path })
        end
        hList:Commit()
        hList:SetSelectedIndex(GetIndex(), false, true)
        hList:SetOnSelectedDataChangedCallback(function(data)
            SetIcon(data.name)
        end)
    end

    entry.Activate = function() end
    entry.OnDirectionalInput = function(direction)
        if #icons == 0 then return end
        local delta = direction == MOVEMENT_CONTROLLER_DIRECTION_NEGATIVE and -1 or 1
        local newVal = icons[((GetIndex() - 1 + delta) % #icons) + 1]
        SetIcon(newVal)
    end

    entry.SyncDisplay = function()
        local cur = GetVal()
        if cur ~= entry._lastDisplayedValue then
            entry._lastDisplayedValue = cur
            return true
        end
        return false
    end

    return { entry }
end

-- ── button ────────────────────────────────────────────────────
-- Uses ZO_GamepadOptionsLabelRow: just a tappable label row.
EntryBuilders["button"] = function(def, _sv, _addon)
    local entry = ZO_GamepadEntryData:New(def.name or "Button")
    if def.subLabel and def.subLabel ~= "" then
        entry:AddSubLabel(def.subLabel)
    end
    entry.tooltip       = def.tooltip
    entry.isInteractive = true
    entry.templateName  = LABEL_TEMPLATE
    entry.Activate      = function() if def.onClick then def.onClick() end end
    entry.SyncDisplay   = function() return false end
    return { entry }
end


-- ─────────────────────────────────────────────────────────────
--  SETTINGS SCREEN  (per-addon settings list)
-- ─────────────────────────────────────────────────────────────

local SettingsScreen = ZO_Gamepad_ParametricList_Screen:Subclass()

function SettingsScreen:New(control, scene)
    self._pendingScene = scene
    return ZO_Gamepad_ParametricList_Screen.New(self, control)
end

function SettingsScreen:Initialize(control)
    ZO_Gamepad_ParametricList_Screen.Initialize(self, control, false, true, self._pendingScene)
    self.addon       = SettingsScreen._pendingAddon
    self._sceneName  = SettingsScreen._pendingSceneName
    self._entryByDef = {}
    local list = self:GetMainList()

    -- All ZOS option templates confirmed available. Register with correct setup fns.

    -- Checkbox: Name label + On/Off labels + checkbox widget
    list:AddDataTemplate(CHECKBOX_TEMPLATE,
        function(control, data)
            control:GetNamedChild("Name"):SetText(data:GetText())
            local onLabel  = control:GetNamedChild("On")
            local offLabel = control:GetNamedChild("Off")
            local cb       = control.checkbox or control:GetNamedChild("Checkbox")
            -- Hide the checkbox widget — on console the On/Off labels are
            -- the sole visual indicator. The checkbox is PC-only chrome.
            if cb then cb:SetHidden(true) end

            local state = data.checked == true

            -- Read the label's default colors from the template itself so we
            -- never hardcode values. On = bright when checked, Off = bright when unchecked.
            local function applyState(s)
                if onLabel then
                    onLabel:SetAlpha(s and 1 or 0.3)
                end
                if offLabel then
                    offLabel:SetAlpha(s and 0.3 or 1)
                end
            end

            applyState(state)

            -- Wire toggle through the keybind/primary action, not the hidden checkbox.
            data._applyCheckboxState = applyState
        end,
        ZO_GamepadMenuEntryTemplateParametricListFunction)

    -- Slider: Name label + Slider widget (+ optional ValueLabel in LHAS extension)
    list:AddDataTemplate(SLIDER_TEMPLATE,
        function(control, data)
            control:GetNamedChild("Name"):SetText(data:GetText())
            local slider = control:GetNamedChild("Slider")
            if slider and data._sliderSetup then
                data._sliderSetup(slider, control)
            end
        end,
        ZO_GamepadMenuEntryTemplateParametricListFunction)

    -- Label row: Name label + subLabels via ZO_SharedGamepadEntry_OnSetup
    list:AddDataTemplate(LABEL_TEMPLATE,
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction)

    -- Horizontal list row: Name label + horizontalListObject
    list:AddDataTemplate(DROPDOWN_TEMPLATE,
        function(control, data)
            control:GetNamedChild("Name"):SetText(data:GetText())
            local hList = control.horizontalListObject
            if hList and data._dropdownSetup then
                data._dropdownSetup(hList, control)
            end
        end,
        ZO_GamepadMenuEntryTemplateParametricListFunction)

    -- Color row: Name label + Color swatch
    list:AddDataTemplate(COLOR_TEMPLATE,
        function(control, data)
            control:GetNamedChild("Name"):SetText(data:GetText())
            local swatch = control:GetNamedChild("Color")
            if swatch and data._getColor then
                local c = data._getColor()
                swatch:SetColor(c.r, c.g, c.b, c.a or 1)
            end
        end,
        ZO_GamepadMenuEntryTemplateParametricListFunction)

    -- Section title: Label child (not "Name")
    list:AddDataTemplate(SECTION_TEMPLATE,
        function(control, data)
            local label = control:GetNamedChild("Label")
            if label then label:SetText(data:GetText()) end
        end,
        ZO_GamepadMenuEntryTemplateParametricListFunction)

    -- Generic fallbacks
    list:AddDataTemplate(LIST_TEMPLATE,
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction)
    list:AddDataTemplate(HEADER_TEMPLATE,
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction)
    list:AddDataTemplate(DIVIDER_TEMPLATE,
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction)
end

function SettingsScreen:PerformUpdate() end
function SettingsScreen:SetupList(list) end

function SettingsScreen:OnShowing()
    ZO_Gamepad_ParametricList_Screen.OnShowing(self)
    self:_PopulateList()
end

function SettingsScreen:InitializeKeybindStripDescriptors()
    local screen = self
    self.keybindStripDescriptor = {
        alignment = KEYBIND_STRIP_ALIGN_LEFT,
        {
            name     = GetString(SI_GAMEPAD_SELECT_OPTION),
            keybind  = "UI_SHORTCUT_PRIMARY",
            sound    = SOUNDS.GAMEPAD_MENU_FORWARD,
            visible  = function()
                local entry = screen:GetMainList():GetTargetData()
                return entry ~= nil and entry.isInteractive == true
            end,
            callback = function()
                local entry = screen:GetMainList():GetTargetData()
                if entry and entry.isInteractive and entry.Activate then
                    entry.Activate()
                end
            end,
        },
    }
    ZO_Gamepad_AddBackNavigationKeybindDescriptors(
        self.keybindStripDescriptor,
        GAME_NAVIGATION_TYPE_BUTTON,
        function() SCENE_MANAGER:HideCurrentScene() end
    )
end

function SettingsScreen:_PopulateList()
    if not self.addon then return end
    local list = self:GetMainList()
    list:Clear()
    self._entryByDef = {}
    local sv   = self.addon.savedVars
    local defs = self.addon.controls
    for _, def in ipairs(defs) do
        local builder = EntryBuilders[def.type]
        if builder then
            local entries = builder(def, sv, self.addon)
            self._entryByDef[def] = entries
            for _, entry in ipairs(entries) do
                list:AddEntry(entry.templateName or LIST_TEMPLATE, entry)
            end
        else
            d(string.format("[LibSettingsService] Unknown control type '%s' in '%s'",
                tostring(def.type), tostring(self.addon.name)))
        end
    end
    list:Commit()
end

function SettingsScreen:IsShowing()
    return SCENE_MANAGER:IsShowing(self._sceneName)
end

function SettingsScreen:Show()
    SCENE_MANAGER:Push(self._sceneName)
end

function SettingsScreen:Hide()
    SCENE_MANAGER:HideCurrentScene()
end

function SettingsScreen:Toggle()
    if self:IsShowing() then self:Hide() else self:Show() end
end

function SettingsScreen:RefreshList()
    if self:IsShowing() then self:_PopulateList() end
end

function SettingsScreen:RefreshSetting(def)
    if not self:IsShowing() then return end
    local entries = self._entryByDef[def]
    if not entries then return end
    local dirty = false
    for _, entry in ipairs(entries) do
        if entry.SyncDisplay and entry.SyncDisplay() then dirty = true end
    end
    if dirty then self:GetMainList():RefreshVisible() end
end

function SettingsScreen:RefreshAll()
    if not self:IsShowing() then return end
    local dirty = false
    for _, entries in pairs(self._entryByDef) do
        for _, entry in ipairs(entries) do
            if entry.SyncDisplay and entry.SyncDisplay() then dirty = true end
        end
    end
    if dirty then self:GetMainList():RefreshVisible() end
end

local function BuildAddonScreen(addon)
    local sceneName = SCENE_NAME_PREFIX .. tostring(addon.name):gsub("[%s%p]", "_")
    local scene = ZO_Scene:New(sceneName, SCENE_MANAGER)
    scene:AddFragmentGroup(FRAGMENT_GROUP.GAMEPAD_DRIVEN_UI_WINDOW)
    scene:AddFragmentGroup(FRAGMENT_GROUP.FRAME_TARGET_GAMEPAD_OPTIONS)
    scene:AddFragment(GAMEPAD_NAV_QUADRANT_1_BACKGROUND_FRAGMENT)
    scene:AddFragment(MINIMIZE_CHAT_FRAGMENT)
    scene:AddFragment(GAMEPAD_MENU_SOUND_FRAGMENT)
    local control = WINDOW_MANAGER:CreateControlFromVirtual(
        sceneName .. "_Control", GuiRoot, "LibSettingsService_Screen")
    -- Fragment connects scene show/hide to control visibility.
    local fragment = ZO_FadeSceneFragment:New(control)
    scene:AddFragment(fragment)
    SettingsScreen._pendingAddon     = addon
    SettingsScreen._pendingSceneName = sceneName
    local screen = SettingsScreen:New(control, scene)
    SettingsScreen._pendingAddon     = nil
    SettingsScreen._pendingSceneName = nil
    return screen
end

-- ─────────────────────────────────────────────────────────────
--  ADDON LIST SCENE
--
--  A single shared scene that lists all registered addons.
--  Inserted into the gamepad main menu. Selecting an addon
--  pushes that addon's own settings scene on top.
-- ─────────────────────────────────────────────────────────────

local ADDON_LIST_SCENE_NAME = "LibSettingsServiceAddonList"
local _addonListScreen      = nil   -- AddonListScreen instance, built once

-- AddonListScreen: lists all registered addons; selecting one pushes
-- that addon's own settings scene.
local _registeredAddons = {}

local AddonListScreen = ZO_Gamepad_ParametricList_Screen:Subclass()

function AddonListScreen:New(control, scene)
    self._pendingScene = scene
    return ZO_Gamepad_ParametricList_Screen.New(self, control)
end

function AddonListScreen:Initialize(control)
    ZO_Gamepad_ParametricList_Screen.Initialize(self, control, false, true, self._pendingScene)
    local list = self:GetMainList()
    list:AddDataTemplate("ZO_GamepadMenuEntryTemplate",
        ZO_SharedGamepadEntry_OnSetup,
        ZO_GamepadMenuEntryTemplateParametricListFunction)
end

function AddonListScreen:PerformUpdate() end
function AddonListScreen:SetupList(list) end

function AddonListScreen:OnShowing()
    ZO_Gamepad_ParametricList_Screen.OnShowing(self)
    -- Rebuild list each time in case addons were added after init.
    local list = self:GetMainList()
    list:Clear()
    -- Sort alphabetically.
    local sorted = {}
    for _, addon in ipairs(_registeredAddons) do
        sorted[#sorted + 1] = addon
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)
    for _, addon in ipairs(sorted) do
        local addonRef  = addon
        local entry = ZO_GamepadEntryData:New(addonRef.name,
            "/esoui/art/options/gamepad/gp_options_addons.dds")
        entry:SetIconTintOnSelection(true)
        entry.addonRef = addonRef
        list:AddEntry("ZO_GamepadMenuEntryTemplate", entry)
    end
    list:Commit()
end

function AddonListScreen:InitializeKeybindStripDescriptors()
    local screen = self
    self.keybindStripDescriptor = {
        alignment = KEYBIND_STRIP_ALIGN_LEFT,
        {
            name     = GetString(SI_GAMEPAD_SELECT_OPTION),
            keybind  = "UI_SHORTCUT_PRIMARY",
            sound    = SOUNDS.GAMEPAD_MENU_FORWARD,
            callback = function()
                local entry = screen:GetMainList():GetTargetData()
                if entry and entry.addonRef and entry.addonRef._screen then
                    entry.addonRef._screen:Show()
                end
            end,
        },
    }
    ZO_Gamepad_AddBackNavigationKeybindDescriptors(
        self.keybindStripDescriptor,
        GAME_NAVIGATION_TYPE_BUTTON,
        function() SCENE_MANAGER:HideCurrentScene() end
    )
end

-- All addons registered with LibSettingsService, in insertion order.
local _menuInitialized  = false

local function InitializeMenu()
    if _menuInitialized then return end
    _menuInitialized = true

    -- Build each addon's settings screen now that gamepad UI is ready.
    for _, addon in ipairs(_registeredAddons) do
        if not addon._screen then
            addon._screen = BuildAddonScreen(addon)
        end
        if addon._pendingShow then
            addon._pendingShow = false
            addon._screen:Show()
        end
    end

    if #_registeredAddons == 0 then return end

    -- If LHAS is present, register each addon into it so our addons appear
    -- inside LHAS's panel rather than creating a competing menu entry.
    if LibHarvensAddonSettings then
        -- Map our control types to LHAS ST_ constants.
        local typeMap = {
            checkbox = LibHarvensAddonSettings.ST_CHECKBOX,
            slider   = LibHarvensAddonSettings.ST_SLIDER,
            dropdown = LibHarvensAddonSettings.ST_DROPDOWN,
            button   = LibHarvensAddonSettings.ST_BUTTON,
            label    = LibHarvensAddonSettings.ST_LABEL,
            section  = LibHarvensAddonSettings.ST_SECTION,
            color    = LibHarvensAddonSettings.ST_COLOR,
            edit     = LibHarvensAddonSettings.ST_EDIT,
        }
        for _, addon in ipairs(_registeredAddons) do
            local lhasPanel = LibHarvensAddonSettings:AddAddon(addon.name, {
                allowDefaults  = addon.allowDefaults,
                defaultsFunction = addon.allowDefaults and function()
                    addon:ResetToDefaults()
                end or nil,
            })
            for _, def in ipairs(addon.controls) do
                if not def._isDefaultsButton then
                    local lhasType = typeMap[def.type]
                    if lhasType then
                        local sv = addon.savedVars
                        lhasPanel:AddSetting({
                            type        = lhasType,
                            label       = def.name,
                            tooltip     = def.tooltip,
                            default     = def.default,
                            getFunction = def.getFunction or (def.key and function()
                                return sv and sv[def.key]
                            end),
                            setFunction = def.setFunction or (def.key and function(v)
                                if sv then sv[def.key] = v end
                            end),
                            -- slider
                            min  = def.min,
                            max  = def.max,
                            step = def.step,
                            -- dropdown
                            items = def.choices and (function()
                                local items = {}
                                for _, c in ipairs(def.choices) do
                                    items[#items+1] = { name = c }
                                end
                                return items
                            end)(),
                            -- button
                            clickHandler = def.onClick,
                        })
                    end
                end
            end
        end
        return
    end

    -- No LHAS: insert our own top-level menu entry, replicating the LHAS
    -- CreateEntry pattern exactly (id, data, subMenu all on the entry directly).
    local function MakeEntry(id, data)
        local name = type(data.name) == "function" and data.name() or (data.name or "")
        local entry = ZO_GamepadEntryData:New(name, data.icon)
        entry:SetIconTintOnSelection(true)
        entry:SetIconDisabledTintOnSelection(true)
        entry.data = data
        entry.id   = id
        if data.subMenu then
            entry.subMenu = {}
            for i, subData in ipairs(data.subMenu) do
                entry.subMenu[i] = MakeEntry(i, subData)
            end
        end
        return entry
    end

    local insertPos = #ZO_MENU_ENTRIES
    for i, e in ipairs(ZO_MENU_ENTRIES) do
        if e.id == ZO_MENU_MAIN_ENTRIES.ACTIVITY_FINDER then
            insertPos = i
            break
        end
    end

    local addonItems = {}
    for _, addon in ipairs(_registeredAddons) do
        local addonRef = addon
        addonItems[#addonItems + 1] = {
            name = addonRef.name,
            icon = "/esoui/art/options/gamepad/gp_options_addons.dds",
            activatedCallback = function()
                addonRef._screen:Show()
            end,
        }
    end
    table.sort(addonItems, function(a, b) return a.name < b.name end)

    table.insert(ZO_MENU_ENTRIES, insertPos, MakeEntry("LibSettingsService", {
        customTemplate = "ZO_GamepadMenuEntryTemplateWithArrow",
        name    = GetString(SI_GAME_MENU_ADDONS),
        icon    = "/esoui/art/options/gamepad/gp_options_addons.dds",
        subMenu = addonItems,
    }))

    MAIN_MENU_GAMEPAD:RefreshMainList()
end


local function OnMainMenuGamepadSceneStateChange(_, newState)
    if newState ~= SCENE_SHOWING then return end
    MAIN_MENU_GAMEPAD_SCENE:UnregisterCallback("StateChange", OnMainMenuGamepadSceneStateChange)
    InitializeMenu()
end
MAIN_MENU_GAMEPAD_SCENE:RegisterCallback("StateChange", OnMainMenuGamepadSceneStateChange)


-- ─────────────────────────────────────────────────────────────
--  PUBLIC API  –  LibSettingsService:AddAddon(addonName, config)
-- ─────────────────────────────────────────────────────────────
function LibSettingsService:AddAddon(addonName, config)
    assert(type(addonName) == "string" and #addonName > 0,
        "[LibSettingsService] AddAddon: addonName must be a non-empty string")
    config = config or {}

    local sv = config.savedVars
    -- Apply top-level defaults non-destructively
    if config.defaults then
        ApplyDefaults(sv, config.defaults)
    end

    local addon = {
        name         = addonName,
        savedVars    = sv,
        controls     = config.controls and ZO_DeepTableCopy(config.controls) or {},
        allowDefaults = config.allowDefaults == true,
        allowRefresh  = config.allowRefresh  == true,
        _screen       = nil,
        _pendingShow  = false,
        _handleByDef  = {},
    }

    -- Seed defaults from any pre-supplied controls
    for _, def in ipairs(addon.controls) do
        ApplySettingDefault(sv, def)
    end


    -- Register this addon so InitializeMenu() picks it up.
    table.insert(_registeredAddons, addon)

    -- ── Display ──────────────────────────────────────────────

    function addon:Show()
        if self._screen then
            self._screen:Show()
        else
            -- Screen not built yet (menu hasn't shown). Queue for after init.
            self._pendingShow = true
        end
    end

    function addon:Hide()
        if self._screen then self._screen:Hide() end
    end

    function addon:Toggle()
        if self._screen then
            self._screen:Toggle()
        else
            self._pendingShow = true
        end
    end

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
                if self._screen:IsShowing() then
                    self._screen:GetMainList():RefreshVisible()
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
