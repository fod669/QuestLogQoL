local addonName = ...
local hooked = false
local rowsByButton = {}

local function GetObjectives(questID)
	return C_QuestLog.GetQuestObjectives(questID) or {}
end

local function NormalizeText(text)
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match("^%s*(.-)%s*$"))
end

local function AddCompletedObjectives()
	local scroll = QuestMapFrame.QuestsFrame.ScrollFrame
	for _, rows in pairs(rowsByButton) do
		for _, row in ipairs(rows) do
			row:Hide()
			row:ClearAllPoints()
		end
	end

	if QuestLogQoLSettings.showCompleted == false
		or not GetCVarBool("showQuestObjectivesInLog") then return end

	-- The native objective rows form an anchor chain starting at the title text.
	local nextRow = {}
	for row in scroll.objectiveFramePool:EnumerateActive() do
		local _, anchor = row:GetPoint(1)
		if anchor then nextRow[anchor] = row end
	end

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
					row.Text:SetTextColor(0.45, 0.90, 0.48)
					row.Dash:SetTextColor(0.45, 0.90, 0.48)
					rows[count] = row
				end

				local gap = anchor == button.Text and 3 or 2
				row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
				row.Text:SetText(objective.text)
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

	if resized then scroll.Contents:Layout() end
end

local function InstallHook()
	local quests = QuestMapFrame and QuestMapFrame.QuestsFrame
	local scroll = quests and quests.ScrollFrame
	if not hooked and QuestLogQoLSettings
		and scroll and scroll.titleFramePool and scroll.objectiveFramePool
		and type(QuestLogQuests_Update) == "function" then
		hooksecurefunc("QuestLogQuests_Update", AddCompletedObjectives)
		hooked = true
	end
end

local optionLabel = "Show Completed Quest Objectives"

local function ShowCompleted()
	return QuestLogQoLSettings.showCompleted ~= false
end

local function SetShowCompleted(enabled)
	QuestLogQoLSettings.showCompleted = enabled
	if hooked and QuestMapFrame.QuestsFrame:IsVisible() then
		QuestLogQuests_Update()
	end
end

local function RegisterQuestLogOption()
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
			tooltip:AddLine("Keeps finished objectives visible in green under each quest. Requires Show Quest Objectives.", 1, 1, 1, true)
			tooltip:AddLine("Added by QuestLogQoL.", 0.7, 0.7, 0.7, true)
			tooltip:Show()
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

	panel:SetScript("OnShow", function()
		checkbox:SetChecked(ShowCompleted())
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
