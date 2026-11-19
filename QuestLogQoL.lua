local addonName = ...
local hooked = false
local rowsByButton = {}
local defaultCompletedColor = { r = 0.45, g = 0.90, b = 0.48 }

local function GetCompletedColor()
	local color = QuestLogQoLSettings.completedColor or defaultCompletedColor
	return color.r, color.g, color.b
end

local function UseFlatQuestLog()
	return QuestLogQoLSettings.flatQuestLog == true
end

local function GetObjectives(questID)
	return C_QuestLog.GetQuestObjectives(questID) or {}
end

local function NormalizeText(text)
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match("^%s*(.-)%s*$"))
end

local function AddCompletedObjectives(scroll, hideObjectives)
	for _, rows in pairs(rowsByButton) do
		for _, row in ipairs(rows) do
			row:Hide()
			row:ClearAllPoints()
		end
	end

	if hideObjectives or QuestLogQoLSettings.showCompleted == false
		or not GetCVarBool("showQuestObjectivesInLog") then return end

	-- The native objective rows form an anchor chain starting at the title text.
	local nextRow = {}
	for row in scroll.objectiveFramePool:EnumerateActive() do
		local _, anchor = row:GetPoint(1)
		if anchor then nextRow[anchor] = row end
	end

	local r, g, b = GetCompletedColor()
	local resized = false
	for button in scroll.titleFramePool:EnumerateActive() do
		local questID = button.info.questID
		local nativeText = {}
		local anchor = button.Text
		while nextRow[anchor] do
			anchor = nextRow[anchor]
			local text = anchor.Text:GetText()
			if text then
				nativeText[NormalizeText(text)] = true
			end
		end

		local count, addedHeight = 0, 0
		for _, objective in ipairs(GetObjectives(questID)) do
			if objective.finished and objective.text and objective.text ~= ""
				and not nativeText[NormalizeText(objective.text)] then
				count = count + 1
				local rows = rowsByButton[button]
				if not rows then
					rows = {}
					rowsByButton[button] = rows
				end

				local row = rows[count]
				if not row then
					row = CreateFrame("Frame", nil, button, "QuestLogObjectiveTemplate")
					row:EnableMouse(false)
					rows[count] = row
				end

				local gap = anchor == button.Text and 3 or 2
				row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
				row.Text:SetText(objective.text)
				row.Text:SetTextColor(r, g, b)
				row.Dash:SetTextColor(r, g, b)
				row:Show()
				local height = row.Text:GetStringHeight()
				row:SetHeight(height)
				addedHeight = addedHeight + height + gap
				anchor = row
			end
		end

		-- Blizzard resets each title's height before this post-hook runs.
		if addedHeight > 0 then
			button:SetHeight(button:GetHeight() + addedHeight)
			resized = true
		end
	end

	return resized
end

local allZonesHeader

local function SetAllZonesCollapsed(collapsed)
	QuestLogQoLSettings.allZonesCollapsed = collapsed
	QuestLogQuests_Update()
end

local function SetAllZonesTracked(tracked)
	local wasIgnoringUpdates = QuestMapFrame.ignoreQuestWatchListChanged
	QuestMapFrame.ignoreQuestWatchListChanged = true
	for index = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(index)
		if info and not info.isHeader and info.questID and info.questID > 0 then
			local watched = QuestUtils_IsQuestWatched(info.questID)
			if tracked and not watched then
				C_QuestLog.AddQuestWatch(info.questID)
			elseif not tracked and watched and QuestUtil.CanRemoveQuestWatch() then
				C_QuestLog.RemoveQuestWatch(info.questID)
			end
		end
	end
	QuestMapFrame.ignoreQuestWatchListChanged = wasIgnoringUpdates
	QuestMapFrame_UpdateAll()
end

local function OnAllZonesHeaderClick(header, mouseButton)
	PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	if mouseButton == "LeftButton" then
		SetAllZonesCollapsed(not QuestLogQoLSettings.allZonesCollapsed)
	elseif mouseButton == "RightButton" then
		local menu = MenuUtil.CreateContextMenu(header, function(_, root)
			root:CreateButton(QUEST_LOG_TRACK_ALL, function() SetAllZonesTracked(true) end)
			root:CreateButton(QUEST_LOG_UNTRACK_ALL, function() SetAllZonesTracked(false) end)
			root:CreateButton("Expand All", function() SetAllZonesCollapsed(false) end)
			root:CreateButton("Collapse All", function() SetAllZonesCollapsed(true) end)
		end)
		if InputUtil.IsGamepadUIEnabled() then
			menu:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
		end
	end
end

local function ShowAllZones(scroll, collapsed)
	scroll.headerFramePool:ReleaseAll()
	scroll.campaignHeaderFramePool:ReleaseAll()
	scroll.campaignHeaderMinimalFramePool:ReleaseAll()
	scroll.covenantCallingsHeaderFramePool:ReleaseAll()
	scroll.Contents.StoryHeader:Hide()
	scroll.Contents.Separator:Hide()

	if not allZonesHeader then
		allZonesHeader = CreateFrame("Button", nil, scroll.Contents, "QuestLogHeaderTemplate")
		allZonesHeader:SetText("All Zones")
		allZonesHeader:SetClickHandler(OnAllZonesHeaderClick)
		allZonesHeader.layoutIndex = 0
		allZonesHeader.topPadding = 8
		allZonesHeader.buttonContext = "ButtonContext_QuestLogHeader"
	end
	allZonesHeader:UpdateCollapsedState(nil, { isCollapsed = collapsed })
	allZonesHeader:Show()

	if collapsed then
		for button in scroll.titleFramePool:EnumerateActive() do
			local poi = scroll.Contents:FindButtonByQuestID(button.questID)
			if poi then poi:Hide() end
			button:Hide()
		end
		scroll.objectiveFramePool:ReleaseAll()
		return
	end

	local quests = {}
	for button in scroll.titleFramePool:EnumerateActive() do
		quests[#quests + 1] = button
	end
	table.sort(quests, function(a, b)
		if a.info.level ~= b.info.level then
			return a.info.level < b.info.level
		end
		return a.questLogIndex < b.questLogIndex
	end)
	for index, button in ipairs(quests) do
		button.layoutIndex = index
		-- Match Blizzard's spacing between consecutive quest rows.
		button.topPadding = index == 1 and 2 or -3
	end
end

local rebuildingFlatLog = false
local function UpdateQuestRows()
	local scroll = QuestMapFrame.QuestsFrame.ScrollFrame
	local flat = UseFlatQuestLog()
	if flat and not rebuildingFlatLog then
		local groupedStates = QuestLogQoLSettings.groupedHeaderStates or {}
		QuestLogQoLSettings.groupedHeaderStates = groupedStates
		local collapsedHeaders = {}
		for index = 1, C_QuestLog.GetNumQuestLogEntries() do
			local info = C_QuestLog.GetInfo(index)
			if info and info.isHeader then
				local key = info.headerSortKey
				if key ~= nil and groupedStates[key] == nil then
					groupedStates[key] = not not info.isCollapsed
				end
				if info.isCollapsed then
					collapsedHeaders[#collapsedHeaders + 1] = index
				end
			end
		end

		if #collapsedHeaders > 0 then
			-- Keep native groups expanded so their quest rows stay active and interactive.
			local wasIgnoringUpdates = QuestMapFrame.ignoreQuestLogUpdate
			QuestMapFrame.ignoreQuestLogUpdate = true
			rebuildingFlatLog = true
			for _, index in ipairs(collapsedHeaders) do
				ExpandQuestHeader(index, true)
			end
			QuestLogQuests_Update()
			rebuildingFlatLog = false
			QuestMapFrame.ignoreQuestLogUpdate = wasIgnoringUpdates
			return
		end
	end

	local collapsed = flat and QuestLogQoLSettings.allZonesCollapsed == true
	local headerWasShown = allZonesHeader and allZonesHeader:IsShown()
	if flat then
		ShowAllZones(scroll, collapsed)
	elseif headerWasShown then
		allZonesHeader:Hide()
	end
	local resized = AddCompletedObjectives(scroll, collapsed)
	if flat or headerWasShown or resized then scroll.Contents:Layout() end
end

local function ScrollToFlatQuest(scroll, questID)
	if not UseFlatQuestLog() or QuestLogQoLSettings.allZonesCollapsed or not scroll:IsVisible() then return end
	for button in scroll.titleFramePool:EnumerateActive() do
		if button.questID == questID then
			local above = button:GetTop() - scroll:GetTop()
			local below = scroll:GetBottom() - button:GetBottom()
			if above > 0 or below > 0 then
				local offset = above > 0 and -above or below
				local position = scroll:GetVerticalScroll() + offset
				scroll:SetVerticalScroll(math.max(0, math.min(position, scroll:GetVerticalScrollRange())))
			end
			return
		end
	end
end

local function InstallHook()
	local quests = QuestMapFrame and QuestMapFrame.QuestsFrame
	local scroll = quests and quests.ScrollFrame
	if not hooked and QuestLogQoLSettings
		and scroll and scroll.titleFramePool and scroll.objectiveFramePool
		and type(QuestLogQuests_Update) == "function" then
		hooksecurefunc("QuestLogQuests_Update", UpdateQuestRows)
		hooksecurefunc(scroll, "ScrollToQuest", ScrollToFlatQuest)
		hooked = true
	end
end

local optionLabel = "Show Completed Quest Objectives"
local flatQuestLogLabel = "Group All Zones"
local colorSwatchTooltip = "Completed Objective Colour"
local colorSwatchGap, colorSwatchSize = 8, 16

local function ShowCompleted()
	return QuestLogQoLSettings.showCompleted ~= false
end

local function RefreshQuestLog()
	if hooked and QuestMapFrame.QuestsFrame:IsVisible() then
		QuestLogQuests_Update()
	end
end

local function SetShowCompleted(enabled)
	QuestLogQoLSettings.showCompleted = enabled
	RefreshQuestLog()
end

local function SetFlatQuestLog(enabled)
	QuestLogQoLSettings.flatQuestLog = enabled
	local groupedStates = QuestLogQoLSettings.groupedHeaderStates
	if not enabled and groupedStates then
		local wasIgnoringUpdates = QuestMapFrame.ignoreQuestLogUpdate
		QuestMapFrame.ignoreQuestLogUpdate = true
		for index = 1, C_QuestLog.GetNumQuestLogEntries() do
			local info = C_QuestLog.GetInfo(index)
			if info and info.isHeader then
				local wasCollapsed = groupedStates[info.headerSortKey]
				if wasCollapsed and not info.isCollapsed then
					CollapseQuestHeader(index, true)
				elseif wasCollapsed == false and info.isCollapsed then
					ExpandQuestHeader(index, true)
				end
			end
		end
		QuestMapFrame.ignoreQuestLogUpdate = wasIgnoringUpdates
		QuestLogQoLSettings.groupedHeaderStates = nil
	end
	RefreshQuestLog()
end

local function OpenCompletedColorPicker(updateSwatch)
	local previousColor = QuestLogQoLSettings.completedColor
	local r, g, b = GetCompletedColor()

	local function ApplyColor(color)
		QuestLogQoLSettings.completedColor = color
		if updateSwatch then updateSwatch() end
		RefreshQuestLog()
	end

	ColorPickerFrame:SetupColorPickerAndShow({
		r = r,
		g = g,
		b = b,
		hasOpacity = false,
		swatchFunc = function()
			local red, green, blue = ColorPickerFrame:GetColorRGB()
			ApplyColor({ r = red, g = green, b = blue })
		end,
		cancelFunc = function()
			ApplyColor(previousColor)
		end,
	})
end

local function RegisterQuestLogOption()
	Menu.ModifyMenu("MENU_QUEST_MAP_FRAME", function(_, root)
		root:CreateButton("Expand All", function()
			ExpandQuestHeader(0)
		end)
		root:CreateButton("Collapse All", function()
			CollapseQuestHeader(0)
		end)
	end)

	Menu.ModifyMenu("MENU_QUEST_MAP_FRAME_SETTINGS", function(_, root)
		local checkbox = root:CreateCheckbox(optionLabel, ShowCompleted, function()
			SetShowCompleted(not ShowCompleted())
		end)
		checkbox:SetEnabled(function()
			return GetCVarBool("showQuestObjectivesInLog")
		end)
		checkbox:SetOnEnter(function(frame, description)
			local tooltip = description:GetTooltipFrame()
			tooltip:SetOwner(frame, "ANCHOR_RIGHT")
			tooltip:SetText(optionLabel)
			tooltip:AddLine("Keeps finished objectives visible under each quest. Requires Show Quest Objectives.", 1, 1, 1, true)
			tooltip:AddLine("Added by QuestLogQoL.", 0.7, 0.7, 0.7, true)
			tooltip:Show()
		end)
		checkbox:AddInitializer(function(row, _, menu)
			local button = MenuTemplates.AttachBasicButton(row, colorSwatchSize, colorSwatchSize)
			button:SetPoint("LEFT", row.fontString, "RIGHT", colorSwatchGap, 0)
			button:RegisterForClicks("LeftButtonUp")

			local swatch = row:AttachTemplate("ColorSwatchTemplate")
			swatch:SetFrameStrata(row:GetFrameStrata())
			swatch:SetAllPoints(button)
			swatch:SetColorRGB(GetCompletedColor())
			swatch:EnableMouse(false)
			swatch:Show()
			MenuTemplates.SetUtilityButtonTooltipText(button, colorSwatchTooltip)
			button:SetScript("OnClick", function()
				Menu.GetManager():CloseMenu(menu)
				OpenCompletedColorPicker()
			end)

			local labelWidth = row.leftTexture1:GetWidth() + 7 + row.fontString:GetWidth()
			return labelWidth + colorSwatchGap + colorSwatchSize, row.fontString:GetHeight()
		end)
		root:CreateCheckbox(flatQuestLogLabel, UseFlatQuestLog, function()
			SetFlatQuestLog(not UseFlatQuestLog())
		end)
	end)
end

local function RegisterOptions()
	local panel = CreateFrame("Frame")
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("QuestLogQoL")

	local checkbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	checkbox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", -4, -12)
	local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetPoint("LEFT", checkbox, "RIGHT", 4, 0)
	label:SetText(optionLabel)

	local swatch = CreateFrame("Button", nil, panel, "ColorSwatchTemplate")
	swatch:SetPoint("LEFT", label, "RIGHT", colorSwatchGap, -1)
	swatch:SetSize(colorSwatchSize, colorSwatchSize)
	swatch:RegisterForClicks("LeftButtonUp")
	MenuTemplates.SetUtilityButtonTooltipText(swatch, colorSwatchTooltip)

	local function UpdateSwatch()
		swatch:SetColorRGB(GetCompletedColor())
	end
	UpdateSwatch()
	swatch:SetScript("OnClick", function()
		OpenCompletedColorPicker(UpdateSwatch)
	end)

	local flatCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	flatCheckbox:SetPoint("TOPLEFT", checkbox, "BOTTOMLEFT", 0, -4)
	local flatLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	flatLabel:SetPoint("LEFT", flatCheckbox, "RIGHT", 4, 0)
	flatLabel:SetText(flatQuestLogLabel)
	flatCheckbox:SetScript("OnClick", function(self)
		SetFlatQuestLog(not not self:GetChecked())
	end)

	panel:SetScript("OnShow", function()
		checkbox:SetChecked(ShowCompleted())
		flatCheckbox:SetChecked(UseFlatQuestLog())
		UpdateSwatch()
	end)
	checkbox:SetScript("OnClick", function(self)
		SetShowCompleted(not not self:GetChecked())
	end)

	local category = Settings.RegisterCanvasLayoutCategory(panel, "QuestLogQoL")
	Settings.RegisterAddOnCategory(category)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, loadedAddon)
	if event == "ADDON_LOADED" and loadedAddon == addonName then
		QuestLogQoLSettings = QuestLogQoLSettings or {}
		RegisterQuestLogOption()
		RegisterOptions()
	end

	InstallHook()
	if hooked then events:UnregisterAllEvents() end
end)

SLASH_QUESTLOGQOL1 = "/qlql"
SlashCmdList.QUESTLOGQOL = function(message)
	InstallHook()
	print("QuestLogQoL: Inline quest log hook " .. (hooked and "active" or "unavailable"))
	local questID = tonumber(message) or C_QuestLog.GetSelectedQuest()
	if not questID or questID <= 0 then
		print("QuestLogQoL: Select a quest or enter /qlql <questID>.")
		return
	end

	local objectives = GetObjectives(questID)
	print("QuestLogQoL: Live objectives for quest " .. questID)
	for _, objective in ipairs(objectives) do
		if objective.text and objective.text ~= "" then
			print((objective.finished and "DONE: " or "OPEN: ") .. objective.text)
		end
	end
	if #objectives == 0 then print("QuestLogQoL: The API returned no objectives.") end

	if hooked then
		print("QuestLogQoL: Quest ready to turn in: " .. tostring(C_QuestLog.IsComplete(questID)))
		local scroll = QuestMapFrame.QuestsFrame.ScrollFrame
		for row in scroll.objectiveFramePool:EnumerateActive() do
			if row.questID == questID then
				print("QuestLogQoL: Blizzard row: " .. string.format("%q", NormalizeText(row.Text:GetText() or "")))
			end
		end
	end
end
