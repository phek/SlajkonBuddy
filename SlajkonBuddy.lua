local ADDON_NAME = ...
local PREFIX = "SLAJKBUDDY"
local MAX_COMMENT_LENGTH = 220
local MAX_TAG_LENGTH = 32
local CHUNK_SIZE = 190
local MAIN_FRAME_HEIGHT = 540
local REVIEW_FRAME_HEIGHT = 300
local MANUAL_REVIEW_FRAME_HEIGHT = 270
local RATINGS_PER_PAGE = 4
local KNOWN_PLAYERS_PER_PAGE = 5

local POSITIVE_TAGS = {
	"Skilled", "Friendly", "Helpful",
}
local NEGATIVE_TAGS = {
	"Rude", "Ninja looter", "Unskilled",
}

local db
local playerKey
local playerDisplay
local activeQueue
local reviewState
local refreshPending
local outgoingQueue = {}
local sending = false
local sendGeneration = 0
local receiveBatches = {}
local packetSerial = 0
local onlineFriends = {}
local addonFriends = {}
local battleNetAccountPeerKeys = {}
local battleNetGameAccountPeerKeys = {}
local friendRefreshPending
local mainFrame
local mainPage
local reviewFrame
local minimapButton
local selectedRatingKey
local ratingDetailPageNumber = 1
local knownPlayersPageNumber = 1
local ignoredPlayersPageNumber = 1
local ratingListPage
local ignoredListPage
local ratingDetailsPage
local ratingDetailsReturnPage
local CreateMainFrame
local RefreshMainFrame
local RefreshIgnoredPlayersPage
local RefreshOnlineFriends
local CreateReviewFrame
local CreateRatingDetailsPage
local OpenRatingDetails
local ShowReviewStep
local RefreshRatingDetails
local EnqueueDeletion
local EnqueuePlayerMetadata
local HookUnitFrameTooltips
local OpenReviewQueue

local function Trim(value)
	value = tostring(value or "")
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function SafeText(value, limit)
	value = tostring(value or "")
	value = value:gsub("[%c]", " ")
	value = value:gsub("|", "")
	value = Trim(value)
	if #value > limit then
		value = value:sub(1, limit)
	end
	return value
end

local function RealmName()
	if type(GetNormalizedRealmName) == "function" then
		local realm = GetNormalizedRealmName()
		if realm and realm ~= "" then
			return realm
		end
	end
	if type(GetRealmName) == "function" then
		return GetRealmName() or ""
	end
	return ""
end

local function FormatPlayerDisplay(value)
	value = SafeText(value, 80)
	local name, realm = value:match("^([^-]+)%-(.+)$")
	if name and realm then
		return name .. " " .. realm
	end
	return value
end

local function PlayerIdentityFromParts(name, realm)
	name = SafeText(name, 80)
	realm = SafeText(realm, 80)
	if name == "" then
		return nil, nil
	end

	-- WoW: Forever exposes first and last names as either "First Last" or
	-- "First-Last" on some APIs. Keep that pair together instead of appending
	-- the local realm, and use spaces for the display/contact form.
	if name:match("%s") or name:find("-", 1, true) then
		local display = FormatPlayerDisplay(name)
		return string.lower(display:gsub("%s+", "-")), display
	end
	if realm == "" then
		realm = RealmName()
	end
	local key = realm ~= "" and (name .. "-" .. realm) or name
	local display = realm ~= "" and (name .. " " .. realm) or name
	return string.lower(key), display
end

local function PlayerIdentity(unit)
	local name, realm
	if type(UnitFullName) == "function" then
		name, realm = UnitFullName(unit)
	end
	if not name or name == "" then
		name, realm = UnitName(unit)
	end
	if not name or name == "" then
		return nil, nil
	end
	return PlayerIdentityFromParts(name, realm)
end

local function NormalizePlayerName(value)
	value = SafeText(value, 80)
	if value == "" then
		return nil, nil
	end
	if not value:find("-", 1, true) then
		local name, realm = value:match("^([^%s]+)%s+(.+)$")
		if name and realm then
			value = name .. "-" .. realm
		else
			realm = RealmName()
			if realm ~= "" then
				value = value .. "-" .. realm
			end
		end
	end
	return string.lower(value), FormatPlayerDisplay(value)
end

local function PlayerContactName(key)
	if not key then
		return nil
	end
	local entry = db and db.players and db.players[key]
	local display = entry and entry.display
	if type(display) ~= "string" or display == "" then
		display = FormatPlayerDisplay(key)
	end
	return SafeText(display, 80)
end

local function InvitePlayer(key)
	local contactName = PlayerContactName(key)
	if not contactName then
		return
	end
	if C_PartyInfo and type(C_PartyInfo.InviteUnit) == "function" then
		C_PartyInfo.InviteUnit(contactName)
	elseif type(InviteUnit) == "function" then
		InviteUnit(contactName)
	end
end

local function WhisperPlayer(key)
	local contactName = PlayerContactName(key)
	if not contactName then
		return
	end
	if type(ChatFrame_SendTell) == "function" then
		ChatFrame_SendTell(contactName)
	elseif type(ChatFrame_OpenChat) == "function" then
		ChatFrame_OpenChat("/w " .. contactName .. " ")
	elseif ChatFrame1EditBox then
		ChatFrame1EditBox:SetText("/w " .. contactName .. " ")
		ChatFrame1EditBox:SetFocus()
	end
end

local function SafeClassToken(value)
	value = SafeText(value, 16):upper()
	return value:match("^[A-Z]+$") and value or nil
end

local function SafePlayerLevel(value)
	value = tonumber(value)
	if not value or value < 1 then
		return nil
	end
	return math.floor(value)
end

local function CurrentPlayerInfo()
	local units = { "player", "target", "focus", "mouseover" }
	local count = GetNumGroupMembers and GetNumGroupMembers() or 0
	local raid = IsInRaid and IsInRaid()
	local players = {}
	for index = 1, count do
		units[#units + 1] = raid and ("raid" .. index) or ("party" .. index)
	end
	for _, unit in ipairs(units) do
		if UnitExists(unit) and UnitIsPlayer(unit) then
			local unitKey = PlayerIdentity(unit)
			if unitKey then
				local _, classToken
				if type(UnitClass) == "function" then
					_, classToken = UnitClass(unit)
				end
				local level = type(UnitLevel) == "function" and UnitLevel(unit) or nil
				players[unitKey] = { class = SafeClassToken(classToken), level = SafePlayerLevel(level) }
			end
		end
	end
	return players
end

local function PlayerUnitInfo(key)
	local info = CurrentPlayerInfo()[key]
	return info and info.class or nil, info and info.level or nil
end

local function ClassTokenForPlayer(key)
	local classToken = PlayerUnitInfo(key)
	return classToken
end

local function ClassColor(classToken)
	local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
	local color = classToken and colors and colors[classToken]
	if not color and C_ClassColor and type(C_ClassColor.GetClassColor) == "function" and classToken then
		color = C_ClassColor.GetClassColor(classToken)
	end
	if color then
		if type(color.GetRGB) == "function" then
			return color:GetRGB()
		end
		return color.r or color[1] or 1, color.g or color[2] or 1, color.b or color[3] or 1
	end
	return 1, 1, 1
end

local function ReviewTargetFromInput(editBox)
	local value = Trim(editBox:GetText())
	if value ~= "" then
		local key, display = NormalizePlayerName(value)
		return key, display, key and ClassTokenForPlayer(key)
	end
	if UnitExists("target") and UnitIsPlayer("target") then
		local key, display = PlayerIdentity("target")
		local _, classToken = UnitClass("target")
		return key, display, classToken
	end
	return nil, nil
end

local function EnsurePlayerEntry(key, display)
	if not db.players[key] then
		db.players[key] = { display = display or key, reviews = {} }
	end
	local entry = db.players[key]
	entry.display = display or entry.display or key
	if type(entry.reviews) ~= "table" then
		entry.reviews = {}
	end
	return entry
end

local function IsRatingIgnored(targetKey, authorKey)
	local ignored = db.ignoredRatings and db.ignoredRatings[targetKey]
	return ignored and ignored[authorKey] == true or false
end

local function GetStoredReviewCounts(targetKey)
	local entry = db.players[targetKey]
	local ups, downs, ignored = 0, 0, 0
	if not entry or type(entry.reviews) ~= "table" then
		return ups, downs, ignored
	end
	for authorKey, review in pairs(entry.reviews) do
		if type(review) == "table" then
			if IsRatingIgnored(targetKey, review.authorKey or authorKey) then
				ignored = ignored + 1
			elseif tonumber(review.direction) == 1 then
				ups = ups + 1
			elseif tonumber(review.direction) == -1 then
				downs = downs + 1
			end
		end
	end
	return ups, downs, ignored
end

local function ListRatedPlayers()
	local rows = {}
	local onlinePlayers = CurrentPlayerInfo()
	for key, entry in pairs(db.players) do
		local ups, downs, ignored = GetStoredReviewCounts(key)
		if ups + downs > 0 then
			local liveInfo = onlinePlayers[key]
			local classToken = liveInfo and liveInfo.class
			local level = liveInfo and liveInfo.level
			local metadataChanged = false
			if classToken then
				metadataChanged = metadataChanged or entry.class ~= classToken
				entry.class = classToken
			end
			if level then
				metadataChanged = metadataChanged or entry.level ~= level
				entry.level = level
			end
			if metadataChanged then
				entry.metadataUpdated = time()
				if EnqueuePlayerMetadata then
					EnqueuePlayerMetadata(key)
				end
			end
			local rank = ups > downs and "Positive" or "Negative"
			rows[#rows + 1] = {
				display = entry.display or key,
				key = key,
				ups = ups,
				downs = downs,
				ignored = ignored,
				rank = rank,
				class = classToken or SafeClassToken(entry.class),
				level = level or SafePlayerLevel(entry.level),
			}
		end
	end
	local rankOrder = { Positive = 1, Negative = 2 }
	table.sort(rows, function(a, b)
		local aRank = rankOrder[a.rank] or 5
		local bRank = rankOrder[b.rank] or 5
		if aRank ~= bRank then
			return aRank < bRank
		end
		return string.lower(a.display) < string.lower(b.display)
	end)
	return rows
end

local function ListIgnoredPlayers()
	local rows = {}
	local onlinePlayers = CurrentPlayerInfo()
	for key, entry in pairs(db.players) do
		if type(entry) == "table" then
			local ups, downs, ignored = GetStoredReviewCounts(key)
			if ignored > 0 then
				local liveInfo = onlinePlayers[key]
				rows[#rows + 1] = {
					display = entry.display or key,
					key = key,
					ups = ups,
					downs = downs,
					ignored = ignored,
					class = liveInfo and liveInfo.class or SafeClassToken(entry.class),
					level = liveInfo and liveInfo.level or SafePlayerLevel(entry.level),
				}
			end
		end
	end
	table.sort(rows, function(a, b)
		return string.lower(a.display) < string.lower(b.display)
	end)
	return rows
end

local function GetDeletionTimestamp(targetKey, authorKey)
	local deleted = db.deletedReviews and db.deletedReviews[targetKey]
	return deleted and tonumber(deleted[authorKey]) or nil
end

local function GetSummary(key)
	local entry = db.players[key]
	if not entry or type(entry.reviews) ~= "table" then
		return nil
	end
	local ups, downs = 0, 0
	for authorKey, review in pairs(entry.reviews) do
		if type(review) == "table" then
			if IsRatingIgnored(key, review.authorKey or authorKey) then
				-- Ignored ratings stay available for management but do not affect this client's rank.
			elseif tonumber(review.direction) == 1 then
				ups = ups + 1
			elseif tonumber(review.direction) == -1 then
				downs = downs + 1
			end
		end
	end
	if ups + downs == 0 then
		return nil
	end
	local rank, r, g, b
	if ups > downs then
		rank, r, g, b = "Positive", 0.2, 1, 0.25
	else
		rank, r, g, b = "Negative", 1, 0.25, 0.25
	end
	return { rank = rank, ups = ups, downs = downs, r = r, g = g, b = b }
end

local function ReviewAuthorKey(review, storageKey)
	local authorKey = type(review) == "table" and review.authorKey or nil
	if type(authorKey) ~= "string" or authorKey == "" then
		authorKey = storageKey
	end
	return type(authorKey) == "string" and authorKey ~= "" and authorKey or nil
end

local function IsMyReview(review, storageKey)
	local authorKey = ReviewAuthorKey(review, storageKey)
	if authorKey == playerKey then
		return true
	end
	local normalizedKey = authorKey and NormalizePlayerName(authorKey)
	if normalizedKey == playerKey or (normalizedKey and db.ownCharacters and db.ownCharacters[normalizedKey]) then
		return true
	end
	local authorDisplay = type(review) == "table" and review.authorDisplay
	local displayHasRealm = type(authorDisplay) == "string"
		and (authorDisplay:find("-", 1, true) or authorDisplay:match("^[^%s]+%s+.+$"))
	local displayKey = displayHasRealm and NormalizePlayerName(authorDisplay)
	return displayKey ~= nil and (displayKey == playerKey or (db.ownCharacters and db.ownCharacters[displayKey]))
end

local function GetMyReview(key, requestedAuthorKey)
	local entry = db.players[key]
	if not entry or type(entry.reviews) ~= "table" then
		return nil
	end
	local requestedKey = requestedAuthorKey and NormalizePlayerName(requestedAuthorKey)
	local selectedReview, selectedStorageKey, selectedUpdated = nil, nil, -1
	for storageKey, review in pairs(entry.reviews) do
		local authorKey = ReviewAuthorKey(review, storageKey)
		if IsMyReview(review, storageKey) and (not requestedKey or NormalizePlayerName(authorKey) == requestedKey) then
			local updated = tonumber(review.updated) or 0
			if updated > selectedUpdated or (updated == selectedUpdated and (not selectedStorageKey or storageKey < selectedStorageKey)) then
				selectedReview, selectedStorageKey, selectedUpdated = review, storageKey, updated
			end
		end
	end
	return selectedReview, selectedStorageKey
end

local function NextReviewTimestamp(key, authorKey)
	authorKey = authorKey or playerKey
	local previous = GetMyReview(key, authorKey)
	local deletedAt = GetDeletionTimestamp(key, authorKey) or 0
	local previousAt = previous and tonumber(previous.updated) or 0
	return math.max(time(), deletedAt + 1, previousAt + 1)
end

local function MergeReview(review)
	if type(review) ~= "table" or not review.targetKey or review.targetKey == "" or not review.authorKey or review.authorKey == "" then
		return false
	end
	if review.direction ~= 1 and review.direction ~= -1 then
		return false
	end
	local updated = tonumber(review.updated)
	if not updated then
		return false
	end
	local deletedAt = GetDeletionTimestamp(review.targetKey, review.authorKey)
	if deletedAt and deletedAt >= updated then
		return false
	end
	local entry = EnsurePlayerEntry(review.targetKey, review.targetDisplay)
	local previous = entry.reviews[review.authorKey]
	if previous and (tonumber(previous.updated) or 0) >= updated then
		return false
	end
	review.targetClass = SafeClassToken(review.targetClass)
	review.targetLevel = SafePlayerLevel(review.targetLevel)
	if review.targetClass then
		entry.class = review.targetClass
	end
	if review.targetLevel then
		entry.level = review.targetLevel
	end
	if review.targetClass or review.targetLevel then
		entry.metadataUpdated = tonumber(review.updated) or time()
	end
	entry.reviews[review.authorKey] = review
	if deletedAt then
		db.deletedReviews[review.targetKey][review.authorKey] = nil
		if not next(db.deletedReviews[review.targetKey]) then
			db.deletedReviews[review.targetKey] = nil
		end
	end
	return true
end

local function MergeDeletion(deletion)
	if type(deletion) ~= "table" or not deletion.targetKey or deletion.targetKey == ""
		or not deletion.authorKey or deletion.authorKey == "" then
		return false
	end
	local updated = tonumber(deletion.updated)
	if not updated then
		return false
	end
	local entry = db.players[deletion.targetKey]
	local previousStorageKey, previous
	if entry and type(entry.reviews) == "table" then
		previous = entry.reviews[deletion.authorKey]
		previousStorageKey = previous and deletion.authorKey or nil
		if not previous then
			for storageKey, review in pairs(entry.reviews) do
				if type(review) == "table" and review.authorKey == deletion.authorKey then
					previousStorageKey, previous = storageKey, review
					break
				end
			end
		end
	end
	if previous and (tonumber(previous.updated) or 0) > updated then
		return false
	end
	db.deletedReviews = db.deletedReviews or {}
	local deleted = db.deletedReviews[deletion.targetKey]
	if type(deleted) ~= "table" then
		deleted = {}
		db.deletedReviews[deletion.targetKey] = deleted
	end
	if (tonumber(deleted[deletion.authorKey]) or 0) >= updated then
		return false
	end
	deleted[deletion.authorKey] = updated
	entry = EnsurePlayerEntry(deletion.targetKey, deletion.targetDisplay)
	if previous and (tonumber(previous.updated) or 0) <= updated then
		entry.reviews[previousStorageKey] = nil
	end
	return true
end

local function MergePlayerMetadata(metadata)
	if type(metadata) ~= "table" or not metadata.key or metadata.key == "" then
		return false
	end
	local updated = tonumber(metadata.updated)
	if not updated then
		return false
	end
	local entry = db.players[metadata.key]
	if entry and (tonumber(entry.metadataUpdated) or 0) >= updated then
		return false
	end
	entry = EnsurePlayerEntry(metadata.key, metadata.display)
	local classToken = SafeClassToken(metadata.class)
	local level = SafePlayerLevel(metadata.level)
	if not classToken and not level then
		return false
	end
	if classToken then
		entry.class = classToken
	end
	if level then
		entry.level = level
	end
	entry.metadataUpdated = updated
	return true
end

local function RemoveMyReview(targetKey)
	local entry = db.players[targetKey]
	if not entry or type(entry.reviews) ~= "table" then
		return false
	end
	local ownReviews = {}
	for storageKey, review in pairs(entry.reviews) do
		if IsMyReview(review, storageKey) then
			ownReviews[#ownReviews + 1] = {
				review = review,
				authorKey = ReviewAuthorKey(review, storageKey),
			}
		end
	end
	local removed = false
	for _, ownReview in ipairs(ownReviews) do
		local review = ownReview.review
		local deletion = {
			targetKey = targetKey,
			targetDisplay = entry.display or review.targetDisplay or targetKey,
			authorKey = ownReview.authorKey,
			updated = math.max(time(), (tonumber(review.updated) or 0) + 1),
		}
		if deletion.authorKey and MergeDeletion(deletion) then
			local ignoredForTarget = db.ignoredRatings and db.ignoredRatings[targetKey]
			if ignoredForTarget then
				ignoredForTarget[deletion.authorKey] = nil
				if not next(ignoredForTarget) then
					db.ignoredRatings[targetKey] = nil
				end
			end
			EnqueueDeletion(deletion)
			removed = true
		end
	end
	return removed
end

local function SetRatingIgnored(targetKey, authorKey, ignored)
	db.ignoredRatings = db.ignoredRatings or {}
	local ignoredForTarget = db.ignoredRatings[targetKey]
	if type(ignoredForTarget) ~= "table" then
		ignoredForTarget = {}
		db.ignoredRatings[targetKey] = ignoredForTarget
	end
	if ignored then
		ignoredForTarget[authorKey] = true
	else
		ignoredForTarget[authorKey] = nil
		if not next(ignoredForTarget) then
			db.ignoredRatings[targetKey] = nil
		end
	end
end

local function UnignorePlayerRatings(targetKey)
	local entry = db.players[targetKey]
	if not entry or type(entry.reviews) ~= "table" then
		return
	end
	for storageKey, review in pairs(entry.reviews) do
		if type(review) == "table" and not IsMyReview(review, storageKey) then
			local authorKey = ReviewAuthorKey(review, storageKey)
			if authorKey then
				SetRatingIgnored(targetKey, authorKey, false)
			end
		end
	end
end

local function Encode(value)
	return (tostring(value or ""):gsub("([^%w%-%._~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

local function Decode(value)
	return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

local function Split(value, separator)
	local result = {}
	separator = separator or "|"
	local pattern = "(.-)" .. separator
	for part in (tostring(value or "") .. separator):gmatch(pattern) do
		result[#result + 1] = part
	end
	return result
end

local function NormalizeTags(tags, direction)
	local allowedTags = direction == 1 and POSITIVE_TAGS or direction == -1 and NEGATIVE_TAGS or {}
	local allowed = {}
	for _, tag in ipairs(allowedTags) do
		allowed[string.lower(tag)] = tag
	end
	local normalized, seen = {}, {}
	for _, tag in ipairs(type(tags) == "table" and tags or {}) do
		local canonical = allowed[string.lower(SafeText(tag, MAX_TAG_LENGTH))]
		if canonical and not seen[canonical] then
			seen[canonical] = true
			normalized[#normalized + 1] = canonical
		end
	end
	return normalized
end

local function PackReview(review)
	local fields = {
		"V",
		Encode(review.targetKey),
		Encode(review.targetDisplay),
		Encode(review.authorKey),
		Encode(review.authorDisplay),
		tostring(review.direction),
		tostring(review.updated),
		Encode(table.concat(review.tags or {}, ",")),
		Encode(review.comment or ""),
	}
	return table.concat(fields, "|")
end

local function PackDeletion(deletion)
	return table.concat({
		"D",
		Encode(deletion.targetKey),
		Encode(deletion.targetDisplay),
		Encode(deletion.authorKey),
		tostring(deletion.updated),
	}, "|")
end

local function PackPlayerMetadata(key, entry)
	return table.concat({
		"M",
		Encode(key),
		Encode(entry.display or FormatPlayerDisplay(key)),
		Encode(SafeClassToken(entry.class) or ""),
		tostring(SafePlayerLevel(entry.level) or ""),
		tostring(tonumber(entry.metadataUpdated) or time()),
	}, "|")
end

local function DecodeReview(payload)
	local parts = Split(payload, "|")
	if #parts ~= 9 or parts[1] ~= "V" then
		return nil
	end
	local direction = tonumber(parts[6])
	local updated = tonumber(parts[7])
	if (direction ~= 1 and direction ~= -1) or not updated then
		return nil
	end
	local rawTags = Decode(parts[8])
	return {
		targetKey = SafeText(Decode(parts[2]), 100),
		targetDisplay = FormatPlayerDisplay(SafeText(Decode(parts[3]), 80)),
		authorKey = SafeText(Decode(parts[4]), 100),
		authorDisplay = FormatPlayerDisplay(SafeText(Decode(parts[5]), 80)),
		direction = direction,
		updated = updated,
		tags = NormalizeTags(Split(rawTags, ","), direction),
		comment = SafeText(Decode(parts[9]), MAX_COMMENT_LENGTH),
	}
end

local function DecodeDeletion(payload)
	local parts = Split(payload, "|")
	if #parts ~= 5 or parts[1] ~= "D" then
		return nil
	end
	local updated = tonumber(parts[5])
	if not updated then
		return nil
	end
	return {
		targetKey = SafeText(Decode(parts[2]), 100),
		targetDisplay = FormatPlayerDisplay(SafeText(Decode(parts[3]), 80)),
		authorKey = SafeText(Decode(parts[4]), 100),
		updated = updated,
	}
end

local function DecodePlayerMetadata(payload)
	local parts = Split(payload, "|")
	if #parts ~= 6 or parts[1] ~= "M" then
		return nil
	end
	local updated = tonumber(parts[6])
	local key = SafeText(Decode(parts[2]), 100)
	if not updated or key == "" then
		return nil
	end
	return {
		key = key,
		display = FormatPlayerDisplay(SafeText(Decode(parts[3]), 80)),
		class = SafeClassToken(Decode(parts[4])),
		level = SafePlayerLevel(Decode(parts[5])),
		updated = updated,
	}
end

local function GetOnlineFriends()
	local friends = {}
	local bnetAccountKeys = {}
	local bnetGameAccountKeys = {}
	if C_FriendList and type(C_FriendList.GetNumFriends) == "function"
		and type(C_FriendList.GetFriendInfoByIndex) == "function" then
		for index = 1, C_FriendList.GetNumFriends() do
			local info = C_FriendList.GetFriendInfoByIndex(index)
			if type(info) == "table" and info.connected and info.name then
				local key = NormalizePlayerName(info.name)
				if key and key ~= playerKey then
					friends[key] = { kind = "WHISPER", name = info.name, target = info.name }
				end
			end
		end
	elseif type(GetNumFriends) == "function" and type(GetFriendInfo) == "function" then
		for index = 1, GetNumFriends() do
			local name, _, _, _, connected = GetFriendInfo(index)
			if connected and name then
				local key = NormalizePlayerName(name)
				if key and key ~= playerKey then
					friends[key] = { kind = "WHISPER", name = name, target = name }
				end
			end
		end
	end

	local battleNet = C_BattleNet
	if battleNet and type(battleNet.GetFriendAccountInfo) == "function"
		and type(battleNet.GetFriendNumGameAccounts) == "function"
		and type(battleNet.GetFriendGameAccountInfo) == "function"
		and type(BNGetNumFriends) == "function" then
		local countOk, friendCount = pcall(BNGetNumFriends)
		friendCount = countOk and tonumber(friendCount) or 0
		for friendIndex = 1, friendCount do
			local accountOk, account = pcall(battleNet.GetFriendAccountInfo, friendIndex)
			local accountID = accountOk and account and tonumber(account.bnetAccountID)
			if accountID then
				local accountKey = "bnet:" .. tostring(accountID)
				local gameAccount
				local gameCountOk, gameCount = pcall(battleNet.GetFriendNumGameAccounts, friendIndex)
				gameCount = gameCountOk and tonumber(gameCount) or 0
				for accountIndex = 1, gameCount do
					local gameOk, candidate = pcall(battleNet.GetFriendGameAccountInfo, friendIndex, accountIndex)
					if gameOk and type(candidate) == "table" and candidate.isOnline
						and (not candidate.clientProgram or string.lower(candidate.clientProgram) == "wow")
						and (not WOW_PROJECT_ID or not candidate.wowProjectID or candidate.wowProjectID == WOW_PROJECT_ID)
						and tonumber(candidate.gameAccountID) then
						if not gameAccount or candidate.hasFocus then
							gameAccount = candidate
						end
						if candidate.hasFocus then
							break
						end
					end
				end
				if gameAccount then
					local routeName = gameAccount.characterName or account.accountName or accountKey
					if gameAccount.realmName and gameAccount.realmName ~= "" then
						routeName = routeName .. "-" .. gameAccount.realmName
					end
					friends[accountKey] = {
						kind = "BNET",
						name = routeName,
						gameAccountID = tonumber(gameAccount.gameAccountID),
					}
					bnetAccountKeys[accountID] = accountKey
					bnetGameAccountKeys[tonumber(gameAccount.gameAccountID)] = accountKey
				end
			end
		end
	end
	return friends, bnetAccountKeys, bnetGameAccountKeys
end

local function SendPacket(packet, route)
	if route and route.kind == "BNET" then
		if C_BattleNet and type(C_BattleNet.SendGameData) == "function" then
			local sent = pcall(C_BattleNet.SendGameData, route.gameAccountID, PREFIX, packet)
			if sent then
				return
			end
		end
		if type(BNSendGameData) == "function" then
			pcall(BNSendGameData, route.gameAccountID, PREFIX, packet)
		end
		return
	end
	local target = route and (route.target or route.name) or nil
	if not target then
		return
	end
	if C_ChatInfo and type(C_ChatInfo.SendAddonMessageLogged) == "function" then
		C_ChatInfo.SendAddonMessageLogged(PREFIX, packet, "WHISPER", target)
	elseif C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function" then
		C_ChatInfo.SendAddonMessage(PREFIX, packet, "WHISPER", target)
	end
end

local function PumpSendQueue(generation)
	if generation ~= sendGeneration then
		return
	end
	local item = table.remove(outgoingQueue, 1)
	if not item then
		sending = false
		return
	end
	local peer = addonFriends[item.friendKey]
	if onlineFriends[item.friendKey] and (not item.requiresVerified or (peer and peer.verified)) then
		SendPacket(item.message, onlineFriends[item.friendKey] or item.route)
	end
	C_Timer.After(0.35, function()
		PumpSendQueue(generation)
	end)
end

local function StartSendQueue()
	if sending or #outgoingQueue == 0 then
		return
	end
	sending = true
	sendGeneration = sendGeneration + 1
	local generation = sendGeneration
	C_Timer.After(0.1, function()
		PumpSendQueue(generation)
	end)
end

local function QueuePayloadForFriend(payload, friendKey, route, requiresVerified)
	if not onlineFriends[friendKey] then
		return
	end
	packetSerial = packetSerial + 1
	local id = tostring(time()) .. "_" .. tostring(packetSerial)
	local total = math.max(1, math.ceil(#payload / CHUNK_SIZE))
	for index = 1, total do
		local chunk = payload:sub((index - 1) * CHUNK_SIZE + 1, index * CHUNK_SIZE)
		outgoingQueue[#outgoingQueue + 1] = {
			friendKey = friendKey,
			route = route,
			requiresVerified = requiresVerified,
			message = table.concat({ "C", id, tostring(index), tostring(total), chunk }, "|"),
		}
	end
	StartSendQueue()
end

local function DropQueuedFriend(friendKey)
	local retained = {}
	for _, item in ipairs(outgoingQueue) do
		if item.friendKey ~= friendKey then
			retained[#retained + 1] = item
		end
	end
	outgoingQueue = retained
end

local function EnqueuePayload(payload, excludedFriendKey)
	for friendKey, peer in pairs(addonFriends) do
		if friendKey ~= excludedFriendKey and peer.verified and onlineFriends[friendKey] then
			QueuePayloadForFriend(payload, friendKey, peer.route, true)
		end
	end
end

local function SameFriendRoute(first, second)
	if not first or not second or first.kind ~= second.kind then
		return false
	end
	if first.kind == "BNET" then
		return first.gameAccountID == second.gameAccountID
	end
	return first.target == second.target
end

local function ResetBattleNetPeers()
	for friendKey, peer in pairs(addonFriends) do
		if peer.route and peer.route.kind == "BNET" then
			DropQueuedFriend(friendKey)
			addonFriends[friendKey] = nil
		end
	end
end

RefreshOnlineFriends = function(sendHello)
	local currentFriends, currentBNetAccounts, currentBNetGameAccounts = GetOnlineFriends()
	battleNetAccountPeerKeys = currentBNetAccounts or {}
	battleNetGameAccountPeerKeys = currentBNetGameAccounts or {}
	for friendKey, route in pairs(currentFriends) do
		local peer = addonFriends[friendKey]
		if peer and not SameFriendRoute(peer.route, route) then
			DropQueuedFriend(friendKey)
			peer.verified = false
			peer.snapshotSent = false
			peer.helloNonce = nil
			peer.remoteHelloNonce = nil
		end
		onlineFriends[friendKey] = route
		if sendHello and (not peer or not peer.helloNonce) then
			peer = peer or { verified = false, snapshotSent = false }
			peer.name = route.name
			peer.route = route
			peer.helloNonce = tostring(time()) .. "_" .. tostring(packetSerial + 1)
			addonFriends[friendKey] = peer
			QueuePayloadForFriend("H|" .. peer.helloNonce, friendKey, route, false)
		elseif peer then
			peer.name = route.name
			peer.route = route
		end
	end
	for friendKey in pairs(onlineFriends) do
		if not currentFriends[friendKey] then
			DropQueuedFriend(friendKey)
			onlineFriends[friendKey] = nil
			addonFriends[friendKey] = nil
		end
	end
end

local function EnqueueReview(review)
	EnqueuePayload(PackReview(review))
end

EnqueueDeletion = function(deletion)
	EnqueuePayload(PackDeletion(deletion))
end

EnqueuePlayerMetadata = function(key)
	local entry = db.players[key]
	if not entry or (not entry.class and not entry.level) then
		return
	end
	entry.metadataUpdated = tonumber(entry.metadataUpdated) or time()
	EnqueuePayload(PackPlayerMetadata(key, entry))
end

local function SendSnapshotToFriend(friendKey)
	local peer = addonFriends[friendKey]
	if not peer or not peer.verified or peer.snapshotSent or not onlineFriends[friendKey] then
		return
	end
	peer.snapshotSent = true
	for key, entry in pairs(db.players) do
		if type(entry) == "table" and type(entry.reviews) == "table" then
			for _, review in pairs(entry.reviews) do
				if type(review) == "table" and review.targetKey and review.authorKey then
					QueuePayloadForFriend(PackReview(review), friendKey, peer.route, true)
				end
			end
		end
		if type(entry) == "table" and (entry.class or entry.level) then
			QueuePayloadForFriend(PackPlayerMetadata(key, entry), friendKey, peer.route, true)
		end
	end
	for targetKey, deleted in pairs(db.deletedReviews or {}) do
		if type(deleted) == "table" then
			for authorKey, updated in pairs(deleted) do
				QueuePayloadForFriend(PackDeletion({
					targetKey = targetKey,
					targetDisplay = db.players[targetKey] and db.players[targetKey].display or FormatPlayerDisplay(targetKey),
					authorKey = authorKey,
					updated = updated,
				}), friendKey, peer.route, true)
			end
		end
	end
end

local function ScheduleFriendSync()
	if friendRefreshPending then
		return
	end
	friendRefreshPending = true
	C_Timer.After(0.75, function()
		friendRefreshPending = nil
		if RefreshOnlineFriends then
			RefreshOnlineFriends(true)
		end
	end)
end

local function HandlePacket(message, sender, senderKey)
	local parts = Split(message, "|")
	if #parts ~= 5 or parts[1] ~= "C" then
		return
	end
	local index, total = tonumber(parts[3]), tonumber(parts[4])
	if not index or not total or total < 1 or total > 24 or index < 1 or index > total then
		return
	end
	senderKey = senderKey or NormalizePlayerName(sender or "")
	local batchKey = tostring(senderKey or sender) .. ":" .. parts[2]
	local batch = receiveBatches[batchKey]
	if not batch then
		batch = { total = total, chunks = {}, received = 0 }
		receiveBatches[batchKey] = batch
		C_Timer.After(60, function()
			if receiveBatches[batchKey] == batch then
				receiveBatches[batchKey] = nil
			end
		end)
	end
	if batch.total ~= total then
		receiveBatches[batchKey] = nil
		return
	end
	if not batch.chunks[index] then
		batch.chunks[index] = parts[5]
		batch.received = batch.received + 1
	end
	if batch.received == batch.total then
		receiveBatches[batchKey] = nil
		local payload = table.concat(batch.chunks)
		local route = onlineFriends[senderKey]
		local friendName = route and route.name
		if payload:sub(1, 2) == "H|" then
			local nonce = payload:sub(3)
			if nonce == "" then
				return
			end
			local peer = addonFriends[senderKey] or { snapshotSent = false }
			peer.name = friendName or sender
			peer.route = route or peer.route
			peer.verified = true
			if peer.remoteHelloNonce ~= nonce then
				peer.remoteHelloNonce = nonce
				peer.snapshotSent = false
			end
			addonFriends[senderKey] = peer
			QueuePayloadForFriend("A|" .. nonce, senderKey, peer.route, true)
			SendSnapshotToFriend(senderKey)
			return
		elseif payload:sub(1, 2) == "A|" then
			local nonce = payload:sub(3)
			if nonce == "" then
				return
			end
			local peer = addonFriends[senderKey] or { snapshotSent = false }
			peer.name = friendName or sender
			peer.route = route or peer.route
			peer.verified = true
			addonFriends[senderKey] = peer
			if nonce == peer.helloNonce then
				SendSnapshotToFriend(senderKey)
			end
			return
		end
		local merged = false
		if payload:sub(1, 2) == "V|" then
			local review = DecodeReview(payload)
			merged = review and MergeReview(review)
		elseif payload:sub(1, 2) == "D|" then
			local deletion = DecodeDeletion(payload)
			merged = deletion and MergeDeletion(deletion)
		elseif payload:sub(1, 2) == "M|" then
			local metadata = DecodePlayerMetadata(payload)
			merged = metadata and MergePlayerMetadata(metadata)
		end
		if merged then
			RefreshMainFrame()
			EnqueuePayload(payload, senderKey)
		end
	end
end

OpenReviewQueue = function(targets, title, editOnly, requestedReturnPage)
	for _, target in ipairs(targets) do
		local classToken, level = PlayerUnitInfo(target.key)
		target.class = SafeClassToken(target.class) or classToken
		target.level = SafePlayerLevel(target.level) or level
	end
	if #targets == 0 then
		if DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy: No other group members were found to review.")
		end
		return
	end
	local returnPage = requestedReturnPage
	if not returnPage and mainFrame and mainFrame:IsShown() then
		if mainPage and mainPage:IsShown() then
			returnPage = mainPage
		elseif ratingDetailsPage and ratingDetailsPage:IsShown() then
			returnPage = ratingDetailsPage
		elseif ignoredListPage and ignoredListPage:IsShown() then
			returnPage = ignoredListPage
		end
	end
	activeQueue = { targets = targets, title = title, index = 1, returnPage = returnPage, editOnly = editOnly }
	if not mainFrame then
		CreateMainFrame()
	end
	mainFrame:SetHeight(title and title ~= "" and REVIEW_FRAME_HEIGHT or MANUAL_REVIEW_FRAME_HEIGHT)
	if not reviewFrame then
		CreateReviewFrame()
	end
	if ratingDetailsPage then
		ratingDetailsPage:Hide()
	end
	if ignoredListPage then
		ignoredListPage:Hide()
	end
	mainPage:Hide()
	mainFrame:Show()
	ShowReviewStep()
end

local function CloseReviewFlow(forceClose)
	local returnPage = activeQueue and activeQueue.returnPage
	activeQueue = nil
	if reviewFrame then
		reviewFrame:Hide()
	end
	if ratingDetailsPage then
		ratingDetailsPage:Hide()
	end
	if ignoredListPage then
		ignoredListPage:Hide()
	end
	if mainFrame then
		mainFrame:SetHeight(MAIN_FRAME_HEIGHT)
		if returnPage then
			returnPage:Show()
		elseif mainPage then
			mainPage:Show()
		end
		if forceClose or not returnPage then
			mainFrame:Hide()
		else
			mainFrame:Show()
		end
	end
	RefreshMainFrame()
end

local function ScheduleRefresh()
	if refreshPending then
		return
	end
	refreshPending = true
	C_Timer.After(0.25, function()
		refreshPending = nil
		if HookUnitFrameTooltips then
			HookUnitFrameTooltips()
		end
		RefreshMainFrame()
	end)
end

local function CreateButton(parent, text, width, height)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, height)
	button:SetText(text)
	return button
end

local function CreateInput(parent, width, height, maxLetters)
	local editBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	editBox:SetSize(width, height)
	editBox:SetAutoFocus(false)
	editBox:SetMaxLetters(maxLetters or 100)
	editBox:SetTextInsets(6, 6, 0, 0)
	editBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		if mainFrame then
			mainFrame:Hide()
		end
	end)
	return editBox
end

local function StylePanel(frame, width, height)
	frame:SetSize(width, height)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetBackdrop({
		bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	local solidBackground = frame:CreateTexture(nil, "BACKGROUND")
	solidBackground:SetAllPoints(frame)
	solidBackground:SetColorTexture(0.025, 0.03, 0.045, 1)
	frame:SetBackdropColor(0.03, 0.04, 0.07, 1)
	frame:SetBackdropBorderColor(0.7, 0.58, 0.28, 1)
end

CreateMainFrame = function()
	mainFrame = CreateFrame("Frame", "SlajkonBuddyMainFrame", UIParent, "BackdropTemplate")
	StylePanel(mainFrame, 560, MAIN_FRAME_HEIGHT)
	UISpecialFrames = UISpecialFrames or {}
	local escapeRegistered = false
	for _, frameName in ipairs(UISpecialFrames) do
		if frameName == "SlajkonBuddyMainFrame" then
			escapeRegistered = true
			break
		end
	end
	if not escapeRegistered then
		table.insert(UISpecialFrames, "SlajkonBuddyMainFrame")
	end
	mainFrame:Hide()
	mainPage = CreateFrame("Frame", nil, mainFrame)
	mainPage:SetAllPoints(mainFrame)
	mainFrame.mainPage = mainPage

	local title = mainPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -18)
	title:SetText("Slajkon Buddy")

	local close = CreateFrame("Button", nil, mainPage, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function()
		mainFrame:Hide()
	end)

	local note = mainPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", 22, -56)
	note:SetWidth(512)
	note:SetJustifyH("LEFT")
	note:SetText("Enter a name or target a player, then choose Review player.")

	local nameBox = CreateInput(mainPage, 360, 28, 80)
	nameBox:SetPoint("TOPLEFT", 24, -90)
	nameBox:SetText("")
	nameBox:SetScript("OnEnterPressed", function(self)
		local key, display, classToken = ReviewTargetFromInput(self)
		if key then
			OpenReviewQueue({ { key = key, display = display, class = classToken } })
			self:ClearFocus()
		else
			DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy: Enter a player name or target a player first.")
		end
	end)

	local reviewButton = CreateButton(mainPage, "Review player", 140, 28)
	reviewButton:SetPoint("LEFT", nameBox, "RIGHT", 12, 0)
	reviewButton:SetScript("OnClick", function()
		local key, display, classToken = ReviewTargetFromInput(nameBox)
		if key then
			OpenReviewQueue({ { key = key, display = display, class = classToken } })
			nameBox:ClearFocus()
		else
			DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy: Enter a player name or target a player first.")
		end
	end)

	CreateRatingDetailsPage()
	RefreshMainFrame()
end

CreateRatingDetailsPage = function()
	if ratingListPage then
		return
	end
	ratingListPage = CreateFrame("Frame", nil, mainPage)
	ratingListPage:SetPoint("TOPLEFT", mainPage, "TOPLEFT", 0, -136)
	ratingListPage:SetPoint("BOTTOMRIGHT", mainPage, "BOTTOMRIGHT", 0, 0)
	ratingListPage.rows = {}

	local empty = ratingListPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	empty:SetPoint("TOPLEFT", 28, -8)
	empty:SetWidth(330)
	empty:SetJustifyH("LEFT")
	empty:SetText("No player ratings yet.")
	ratingListPage.empty = empty

	local ignoredButton = CreateButton(ratingListPage, "Ignored", 100, 24)
	ignoredButton:SetPoint("TOPRIGHT", -22, 0)
	ignoredButton:SetScript("OnClick", function()
		ratingDetailsPage:Hide()
		mainPage:Hide()
		ignoredListPage:Show()
		RefreshIgnoredPlayersPage()
	end)
	ratingListPage.ignoredButton = ignoredButton

	local positiveHeader = ratingListPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	positiveHeader:SetText("Positive")
	positiveHeader:SetTextColor(0.2, 1, 0.25)
	ratingListPage.positiveHeader = positiveHeader

	local otherHeader = ratingListPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	otherHeader:SetText("Negative")
	otherHeader:SetTextColor(1, 0.25, 0.25)
	ratingListPage.otherHeader = otherHeader

	for index = 1, KNOWN_PLAYERS_PER_PAGE do
		local row = CreateFrame("Button", nil, ratingListPage)
		row:SetSize(512, 40)
		row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
		row:SetScript("OnClick", function(self)
			OpenRatingDetails(self.playerKey)
		end)

		local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		name:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -5)
		name:SetWidth(340)
		name:SetJustifyH("LEFT")
		row.name = name

		local inviteButton = CreateButton(row, "Invite", 68, 23)
		inviteButton:SetPoint("RIGHT", -4, 0)
		inviteButton:SetScript("OnClick", function()
			InvitePlayer(row.playerKey)
		end)
		row.inviteButton = inviteButton

		local whisperButton = CreateButton(row, "Whisper", 78, 23)
		whisperButton:SetPoint("RIGHT", inviteButton, "LEFT", -4, 0)
		whisperButton:SetScript("OnClick", function()
			WhisperPlayer(row.playerKey)
		end)
		row.whisperButton = whisperButton

		local tags = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		tags:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -24)
		tags:SetWidth(350)
		tags:SetJustifyH("LEFT")
		row.tags = tags

		local description = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		description:SetWidth(350)
		description:SetJustifyH("LEFT")
		description:SetTextColor(0.76, 0.76, 0.76)
		row.description = description

		local divider = row:CreateTexture(nil, "ARTWORK")
		divider:SetColorTexture(0.7, 0.58, 0.28, 0.28)
		divider:SetPoint("BOTTOMLEFT", 4, 0)
		divider:SetSize(504, 1)
		row:Hide()
		ratingListPage.rows[index] = row
	end

	local listPrevious = CreateButton(ratingListPage, "Previous", 84, 24)
	listPrevious:SetPoint("BOTTOM", -103, 12)
	listPrevious:SetScript("OnClick", function()
		if knownPlayersPageNumber > 1 then
			knownPlayersPageNumber = knownPlayersPageNumber - 1
			RefreshMainFrame()
		end
	end)
	ratingListPage.previous = listPrevious

	local listPageText = ratingListPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	listPageText:SetPoint("BOTTOM", 0, 17)
	ratingListPage.pageText = listPageText

	local listNext = CreateButton(ratingListPage, "Next", 84, 24)
	listNext:SetPoint("BOTTOM", 103, 12)
	listNext:SetScript("OnClick", function()
		knownPlayersPageNumber = knownPlayersPageNumber + 1
		RefreshMainFrame()
	end)
	ratingListPage.next = listNext

	ignoredListPage = CreateFrame("Frame", nil, mainFrame)
	ignoredListPage:SetAllPoints(mainFrame)
	ignoredListPage:Hide()
	ignoredListPage.rows = {}

	local ignoredBack = CreateButton(ignoredListPage, "Back", 78, 24)
	ignoredBack:SetPoint("TOPLEFT", 22, -16)
	ignoredBack:SetScript("OnClick", function()
		ignoredListPage:Hide()
		mainPage:Show()
		RefreshMainFrame()
	end)

	local ignoredClose = CreateFrame("Button", nil, ignoredListPage, "UIPanelCloseButton")
	ignoredClose:SetPoint("TOPRIGHT", -4, -4)
	ignoredClose:SetScript("OnClick", function()
		mainFrame:Hide()
	end)

	local ignoredTitle = ignoredListPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	ignoredTitle:SetPoint("TOP", 0, -18)
	ignoredTitle:SetText("Ignored ratings")

	local ignoredEmpty = ignoredListPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	ignoredEmpty:SetPoint("TOPLEFT", 28, -64)
	ignoredEmpty:SetText("No ignored ratings.")
	ignoredListPage.empty = ignoredEmpty

	for index = 1, KNOWN_PLAYERS_PER_PAGE do
		local row = CreateFrame("Button", nil, ignoredListPage)
		row:SetSize(512, 56)
		row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
		row:SetScript("OnClick", function(self)
			OpenRatingDetails(self.playerKey, ignoredListPage)
		end)

		local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		name:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -5)
		name:SetWidth(360)
		name:SetJustifyH("LEFT")
		row.name = name

		local description = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		description:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -30)
		description:SetWidth(370)
		description:SetJustifyH("LEFT")
		description:SetTextColor(0.76, 0.76, 0.76)
		row.description = description

		local restoreButton = CreateButton(row, "Restore", 80, 23)
		restoreButton:SetPoint("RIGHT", -4, 0)
		restoreButton:SetScript("OnClick", function()
			local key = row.playerKey
			if key then
				UnignorePlayerRatings(key)
				RefreshIgnoredPlayersPage()
				RefreshMainFrame()
			end
		end)
		row.restoreButton = restoreButton

		local divider = row:CreateTexture(nil, "ARTWORK")
		divider:SetColorTexture(0.7, 0.58, 0.28, 0.28)
		divider:SetPoint("BOTTOMLEFT", 4, 0)
		divider:SetSize(504, 1)
		row:Hide()
		ignoredListPage.rows[index] = row
	end

	local ignoredPrevious = CreateButton(ignoredListPage, "Previous", 84, 24)
	ignoredPrevious:SetPoint("BOTTOM", -103, 12)
	ignoredPrevious:SetScript("OnClick", function()
		if ignoredPlayersPageNumber > 1 then
			ignoredPlayersPageNumber = ignoredPlayersPageNumber - 1
			RefreshIgnoredPlayersPage()
		end
	end)
	ignoredListPage.previous = ignoredPrevious

	local ignoredPageText = ignoredListPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ignoredPageText:SetPoint("BOTTOM", 0, 17)
	ignoredListPage.pageText = ignoredPageText

	local ignoredNext = CreateButton(ignoredListPage, "Next", 84, 24)
	ignoredNext:SetPoint("BOTTOM", 103, 12)
	ignoredNext:SetScript("OnClick", function()
		ignoredPlayersPageNumber = ignoredPlayersPageNumber + 1
		RefreshIgnoredPlayersPage()
	end)
	ignoredListPage.next = ignoredNext

	ratingDetailsPage = CreateFrame("Frame", nil, mainFrame)
	ratingDetailsPage:SetAllPoints(mainFrame)
	ratingDetailsPage:Hide()
	ratingDetailsPage.rows = {}

	local back = CreateButton(ratingDetailsPage, "Back", 78, 24)
	back:SetPoint("TOPLEFT", 22, -16)
	back:SetScript("OnClick", function()
		ratingDetailsPage:Hide()
		local returnPage = ratingDetailsReturnPage or mainPage
		returnPage:Show()
		if returnPage == ignoredListPage then
			RefreshIgnoredPlayersPage()
		else
			RefreshMainFrame()
		end
	end)
	local close = CreateFrame("Button", nil, ratingDetailsPage, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function()
		mainFrame:Hide()
	end)

	local playerTitle = ratingDetailsPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	playerTitle:SetPoint("TOP", 0, -18)
	playerTitle:SetWidth(370)
	playerTitle:SetJustifyH("CENTER")
	ratingDetailsPage.playerTitle = playerTitle

	local level = ratingDetailsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	level:SetPoint("TOP", playerTitle, "BOTTOM", 0, -3)
	ratingDetailsPage.level = level

	local summary = ratingDetailsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	summary:SetPoint("TOP", level, "BOTTOM", 0, -4)
	ratingDetailsPage.summary = summary

	local removeButton = CreateButton(ratingDetailsPage, "Remove", 104, 24)
	removeButton:SetPoint("TOP", 104, -96)
	removeButton:SetScript("OnClick", function()
		local key = ratingDetailsPage.targetKey
		local entry = key and db.players[key]
		if not entry or type(entry.reviews) ~= "table" then
			return
		end
		local hasOwnReview, hasUnignoredReview = false, false
		for authorKey, review in pairs(entry.reviews) do
			if type(review) == "table" then
				local reviewAuthor = ReviewAuthorKey(review, authorKey)
				if IsMyReview(review, authorKey) then
					hasOwnReview = true
				elseif not IsRatingIgnored(key, reviewAuthor) then
					hasUnignoredReview = true
				end
			end
		end
		if hasOwnReview or hasUnignoredReview then
			if hasOwnReview then
				RemoveMyReview(key)
			end
			for authorKey, review in pairs(entry.reviews) do
				if type(review) == "table" then
					local reviewAuthor = ReviewAuthorKey(review, authorKey)
					if not IsMyReview(review, authorKey) then
						SetRatingIgnored(key, reviewAuthor, true)
					end
				end
			end
		else
			for authorKey, review in pairs(entry.reviews) do
				if type(review) == "table" then
					local reviewAuthor = ReviewAuthorKey(review, authorKey)
					if not IsMyReview(review, authorKey) then
						SetRatingIgnored(key, reviewAuthor, false)
					end
				end
			end
		end
		RefreshMainFrame()
	end)
	removeButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(self.ratingActionHint or "Removes or locally hides all reviews for this player.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	removeButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	ratingDetailsPage.removeButton = removeButton

	local inviteButton = CreateButton(ratingDetailsPage, "Invite", 96, 24)
	inviteButton:SetPoint("TOP", -108, -96)
	inviteButton:SetScript("OnClick", function()
		InvitePlayer(ratingDetailsPage.targetKey)
	end)
	ratingDetailsPage.inviteButton = inviteButton

	local whisperButton = CreateButton(ratingDetailsPage, "Whisper", 96, 24)
	whisperButton:SetPoint("TOP", -4, -96)
	whisperButton:SetScript("OnClick", function()
		WhisperPlayer(ratingDetailsPage.targetKey)
	end)
	ratingDetailsPage.whisperButton = whisperButton

	for index = 1, RATINGS_PER_PAGE do
		local row = CreateFrame("Frame", nil, ratingDetailsPage)
		row:SetSize(512, 61)
		row:SetPoint("TOPLEFT", 24, -128 - ((index - 1) * 63))

		local header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		header:SetPoint("TOPLEFT", 3, -2)
		header:SetWidth(500)
		header:SetJustifyH("LEFT")
		row.header = header

		local editButton = CreateButton(row, "Edit", 54, 22)
		editButton:SetPoint("RIGHT", -2, 0)
		editButton:SetScript("OnClick", function()
			local key = row.targetKey
			local authorKey = row.reviewAuthorKey
			local entry = key and db.players[key]
			if key and authorKey and entry and GetMyReview(key, authorKey) then
				OpenReviewQueue({ {
					key = key,
					display = entry.display or key,
					class = entry.class,
					level = entry.level,
					authorKey = authorKey,
				} }, "Edit your review", true, ratingDetailsPage)
			end
		end)
		row.editButton = editButton

		local details = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		details:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -3)
		details:SetSize(500, 37)
		details:SetJustifyH("LEFT")
		details:SetJustifyV("TOP")
		details:SetWordWrap(true)
		row.details = details

		local divider = row:CreateTexture(nil, "ARTWORK")
		divider:SetColorTexture(0.7, 0.58, 0.28, 0.28)
		divider:SetPoint("BOTTOMLEFT", 0, 0)
		divider:SetSize(512, 1)
		row:Hide()
		ratingDetailsPage.rows[index] = row
	end

	local previous = CreateButton(ratingDetailsPage, "Previous", 84, 24)
	previous:SetPoint("BOTTOM", -103, 12)
	previous:SetScript("OnClick", function()
		if ratingDetailPageNumber > 1 then
			ratingDetailPageNumber = ratingDetailPageNumber - 1
			RefreshRatingDetails(ratingDetailsPage.targetKey)
		end
	end)
	ratingDetailsPage.previous = previous

	local pageText = ratingDetailsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	pageText:SetPoint("BOTTOM", 0, 17)
	ratingDetailsPage.pageText = pageText

	local nextButton = CreateButton(ratingDetailsPage, "Next", 84, 24)
	nextButton:SetPoint("BOTTOM", 103, 12)
	nextButton:SetScript("OnClick", function()
		ratingDetailPageNumber = ratingDetailPageNumber + 1
		RefreshRatingDetails(ratingDetailsPage.targetKey)
	end)
	ratingDetailsPage.next = nextButton
end

OpenRatingDetails = function(key, returnPage)
	if not key or not ratingDetailsPage then
		return
	end
	selectedRatingKey = key
	ratingDetailsReturnPage = returnPage or mainPage
	ratingDetailPageNumber = 1
	mainPage:Hide()
	if ignoredListPage then
		ignoredListPage:Hide()
	end
	ratingDetailsPage:Show()
	RefreshRatingDetails(key)
end

RefreshIgnoredPlayersPage = function()
	if not ignoredListPage then
		return
	end
	local rows = ListIgnoredPlayers()
	local pageCount = math.max(1, math.ceil(#rows / KNOWN_PLAYERS_PER_PAGE))
	ignoredPlayersPageNumber = math.max(1, math.min(ignoredPlayersPageNumber, pageCount))
	local first = (ignoredPlayersPageNumber - 1) * KNOWN_PLAYERS_PER_PAGE + 1
	ignoredListPage.empty:SetShown(#rows == 0)
	for index, row in ipairs(ignoredListPage.rows) do
		local player = rows[first + index - 1]
		if player then
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", ignoredListPage, "TOPLEFT", 24, -72 - ((index - 1) * 58))
			row.playerKey = player.key
			local red, green, blue = ClassColor(player.class)
			local coloredName = player.class and string.format("|cff%02x%02x%02x%s|r",
				math.floor(red * 255 + 0.5), math.floor(green * 255 + 0.5), math.floor(blue * 255 + 0.5), player.display)
				or player.display
			local levelLabel = player.level and string.format("  |cffcccccc(Level %d)|r", player.level) or ""
			row.name:SetText(coloredName .. levelLabel)
			local ignoredText = string.format("%d ignored review%s", player.ignored, player.ignored == 1 and "" or "s")
			if player.ups + player.downs > 0 then
				ignoredText = ignoredText .. string.format("  ·  %d positive / %d negative still visible", player.ups, player.downs)
			end
			row.description:SetText(ignoredText)
			row.restoreButton:SetEnabled(true)
			row:Show()
		else
			row.playerKey = nil
			row:Hide()
		end
	end
	ignoredListPage.pageText:SetText(string.format("Page %d of %d", ignoredPlayersPageNumber, pageCount))
	ignoredListPage.previous:SetEnabled(ignoredPlayersPageNumber > 1)
	ignoredListPage.next:SetEnabled(ignoredPlayersPageNumber < pageCount)
	if pageCount > 1 then
		ignoredListPage.previous:Show()
		ignoredListPage.next:Show()
	else
		ignoredListPage.previous:Hide()
		ignoredListPage.next:Hide()
	end
end

RefreshMainFrame = function()
	if not mainFrame or not ratingListPage then
		return
	end
	local rows = ListRatedPlayers()
	local ignoredRows = ListIgnoredPlayers()
	ratingListPage.ignoredButton:SetText(string.format("Ignored (%d)", #ignoredRows))
	ratingListPage.ignoredButton:SetShown(#ignoredRows > 0)
	local pageCount = math.max(1, math.ceil(#rows / KNOWN_PLAYERS_PER_PAGE))
	knownPlayersPageNumber = math.max(1, math.min(knownPlayersPageNumber, pageCount))
	local first = (knownPlayersPageNumber - 1) * KNOWN_PLAYERS_PER_PAGE + 1
	ratingListPage.positiveHeader:Hide()
	ratingListPage.otherHeader:Hide()
	if #rows == 0 then
		ratingListPage.empty:SetText(#ignoredRows > 0 and "No active ratings. Open Ignored to view them." or "No player ratings yet.")
		ratingListPage.empty:Show()
	else
		ratingListPage.empty:Hide()
	end
	local cursor = 5
	local currentSection
	for index, row in ipairs(ratingListPage.rows) do
		local player = rows[first + index - 1]
		if player then
			local section = player.rank == "Positive" and "positive" or "negative"
			if section ~= currentSection then
				if currentSection then
					cursor = cursor + 22
				end
				local header = section == "positive" and ratingListPage.positiveHeader or ratingListPage.otherHeader
				header:ClearAllPoints()
				header:SetPoint("TOPLEFT", ratingListPage, "TOPLEFT", 28, -cursor)
				header:Show()
				cursor = cursor + 18
				currentSection = section
			end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", ratingListPage, "TOPLEFT", 24, -cursor)
			local red, green, blue = ClassColor(player.class)
			local coloredName = player.class and string.format("|cff%02x%02x%02x%s|r",
				math.floor(red * 255 + 0.5), math.floor(green * 255 + 0.5), math.floor(blue * 255 + 0.5), player.display)
				or player.display
			local levelLabel = player.level and string.format("  |cffcccccc(Level %d)|r", player.level) or ""
			row.name:SetText(coloredName .. levelLabel)
			row.playerKey = player.key

			local tagCounts = {}
			local ownDescription, ownDescriptionTime, ownDescriptionAuthor = nil, -1, nil
			local latestDescription, latestDescriptionTime, latestDescriptionAuthor = nil, -1, nil
			local entry = db.players[player.key]
			for authorKey, review in pairs(entry and entry.reviews or {}) do
				if type(review) == "table" and not IsRatingIgnored(player.key, review.authorKey or authorKey) then
					local comment = SafeText(review.comment, MAX_COMMENT_LENGTH)
					local updated = tonumber(review.updated) or 0
					local reviewAuthor = review.authorKey or authorKey
					if comment ~= "" then
						if IsMyReview(review, authorKey) then
							if updated > ownDescriptionTime
								or (updated == ownDescriptionTime and (not ownDescriptionAuthor or reviewAuthor < ownDescriptionAuthor)) then
								ownDescription = comment
								ownDescriptionTime = updated
								ownDescriptionAuthor = reviewAuthor
							end
						elseif updated > latestDescriptionTime
							or (updated == latestDescriptionTime and (not latestDescriptionAuthor or reviewAuthor < latestDescriptionAuthor)) then
							latestDescription = comment
							latestDescriptionTime = updated
							latestDescriptionAuthor = reviewAuthor
						end
					end
					for _, tag in ipairs(type(review.tags) == "table" and review.tags or {}) do
						tag = SafeText(tag, MAX_TAG_LENGTH)
						if tag ~= "" then
							tagCounts[tag] = (tagCounts[tag] or 0) + 1
						end
					end
				end
			end
			latestDescription = ownDescription or latestDescription
			local tags = {}
			for tag, count in pairs(tagCounts) do
				tags[#tags + 1] = { name = tag, count = count }
			end
			table.sort(tags, function(a, b)
				if a.count ~= b.count then
					return a.count > b.count
				end
				return string.lower(a.name) < string.lower(b.name)
			end)
			local tagLabels = {}
			for tagIndex = 1, math.min(3, #tags) do
				local tag = tags[tagIndex]
				tagLabels[#tagLabels + 1] = tag.name .. (tag.count > 1 and (" x" .. tag.count) or "")
			end
			if #tags > 3 then
				tagLabels[#tagLabels + 1] = string.format("+%d more", #tags - 3)
			end
			local tagText = table.concat(tagLabels, ", ")
			local showTags = tagText ~= ""
			row.tags:SetText(tagText)
			if showTags then
				row.tags:Show()
			else
				row.tags:Hide()
			end
			if latestDescription then
				if #latestDescription > 52 then
					latestDescription = latestDescription:sub(1, 49) .. "..."
				end
				row.description:SetText(latestDescription)
				row.description:Show()
			else
				row.description:SetText("")
				row.description:Hide()
			end
			if not showTags and not latestDescription then
				row.description:SetText("No comments")
				row.description:Show()
			end
			local contentLines = { row.name }
			if showTags then
				contentLines[#contentLines + 1] = row.tags
			end
			if latestDescription then
				contentLines[#contentLines + 1] = row.description
			elseif not showTags then
				contentLines[#contentLines + 1] = row.description
			end
			local lineGap, contentHeight = 6, 0
			for lineIndex, fontString in ipairs(contentLines) do
				contentHeight = contentHeight + math.max(1, fontString:GetStringHeight())
				if lineIndex > 1 then
					contentHeight = contentHeight + lineGap
				end
			end
			row:SetHeight(contentHeight + 14)
			local lineTop = math.max(0, (row:GetHeight() - contentHeight) / 2)
			for _, fontString in ipairs(contentLines) do
				local lineHeight = math.max(1, fontString:GetStringHeight())
				fontString:ClearAllPoints()
				fontString:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -lineTop)
				lineTop = lineTop + lineHeight + lineGap
			end
			row:Show()
			cursor = cursor + row:GetHeight() + 2
		else
			row.playerKey = nil
			row:Hide()
		end
	end
	ratingListPage.pageText:SetText(string.format("Page %d of %d", knownPlayersPageNumber, pageCount))
	ratingListPage.previous:SetEnabled(knownPlayersPageNumber > 1)
	ratingListPage.next:SetEnabled(knownPlayersPageNumber < pageCount)
	if pageCount > 1 then
		ratingListPage.previous:Show()
		ratingListPage.next:Show()
	else
		ratingListPage.previous:Hide()
		ratingListPage.next:Hide()
	end
	if ratingDetailsPage and ratingDetailsPage:IsShown() then
		RefreshRatingDetails(selectedRatingKey)
	end
	if ignoredListPage and ignoredListPage:IsShown() then
		RefreshIgnoredPlayersPage()
	end
end

RefreshRatingDetails = function(key)
	if not ratingDetailsPage or not ratingDetailsPage.rows then
		return
	end
	local entry = key and db.players[key]
	local liveInfo = key and CurrentPlayerInfo()[key]
	local classToken = liveInfo and liveInfo.class or entry and SafeClassToken(entry.class)
	local level = liveInfo and liveInfo.level or entry and SafePlayerLevel(entry.level)
	if entry and liveInfo then
		local metadataChanged = false
		if liveInfo.class and entry.class ~= liveInfo.class then
			entry.class = liveInfo.class
			metadataChanged = true
		end
		if liveInfo.level and entry.level ~= liveInfo.level then
			entry.level = liveInfo.level
			metadataChanged = true
		end
		if metadataChanged then
			entry.metadataUpdated = time()
			EnqueuePlayerMetadata(key)
		end
	end
	local reviews = {}
	if entry and type(entry.reviews) == "table" then
		for authorKey, review in pairs(entry.reviews) do
			if type(review) == "table" then
				review.authorKey = review.authorKey or authorKey
				reviews[#reviews + 1] = review
			end
		end
	end
	table.sort(reviews, function(a, b)
		return (tonumber(a.updated) or 0) > (tonumber(b.updated) or 0)
	end)
	local storedUps, storedDowns, ignoredCount = GetStoredReviewCounts(key)
	local summary = GetSummary(key)
	ratingDetailsPage.targetKey = key
	ratingDetailsPage.playerTitle:SetText(entry and entry.display or "No ratings saved")
	ratingDetailsPage.playerTitle:SetTextColor(ClassColor(classToken))
	ratingDetailsPage.level:SetText(string.format("Level %s", level and tostring(level) or "unknown"))
	ratingDetailsPage.level:SetTextColor(0.82, 0.82, 0.82)
	ratingDetailsPage.inviteButton:SetEnabled(key ~= nil)
	ratingDetailsPage.whisperButton:SetEnabled(key ~= nil)
	local hasOwnReview, hasUnignoredReview, hasIgnoredReview = false, false, false
	for _, review in ipairs(reviews) do
		local authorKey = ReviewAuthorKey(review, review.authorKey)
		if IsMyReview(review, review.authorKey) then
			hasOwnReview = true
		elseif IsRatingIgnored(key, authorKey) then
			hasIgnoredReview = true
		else
			hasUnignoredReview = true
		end
	end
	local canRemove = hasOwnReview or hasUnignoredReview
	local canRestore = not canRemove and hasIgnoredReview
	ratingDetailsPage.removeButton:SetText(canRestore and "Unignore all" or "Remove")
	ratingDetailsPage.removeButton:SetEnabled(canRemove or canRestore)
	ratingDetailsPage.removeButton.ratingActionHint = canRestore
		and "Shows all other reviews for this player in your local rating again."
		or "Removes your own review for everyone and locally ignores all other reviews for this player."
	if summary then
		ratingDetailsPage.summary:SetText(string.format("%s  ·  %d thumbs up  ·  %d thumbs down  ·  %d ignored",
			summary.rank, summary.ups, summary.downs, ignoredCount))
		ratingDetailsPage.summary:SetTextColor(summary.r, summary.g, summary.b)
	elseif storedUps + storedDowns + ignoredCount > 0 then
		ratingDetailsPage.summary:SetText(string.format("All %d ratings are ignored locally", ignoredCount))
		ratingDetailsPage.summary:SetTextColor(0.72, 0.72, 0.72)
	else
		ratingDetailsPage.summary:SetText("No ratings yet")
		ratingDetailsPage.summary:SetTextColor(1, 1, 1)
	end
	local pageCount = math.max(1, math.ceil(#reviews / RATINGS_PER_PAGE))
	ratingDetailPageNumber = math.max(1, math.min(ratingDetailPageNumber, pageCount))
	local first = (ratingDetailPageNumber - 1) * RATINGS_PER_PAGE + 1
	for index, row in ipairs(ratingDetailsPage.rows) do
		local review = reviews[first + index - 1]
		if review then
			local isOwnReview = IsMyReview(review, review.authorKey)
			local isIgnored = not isOwnReview
				and IsRatingIgnored(key, review.authorKey)
			local direction = review.direction == 1 and "Thumbs up" or "Thumbs down"
			local display = review.authorDisplay or FormatPlayerDisplay(review.authorKey or "Player")
			row.targetKey = key
			row.reviewAuthorKey = ReviewAuthorKey(review, review.authorKey)
			row.editButton:SetShown(isOwnReview)
			local contentWidth = isOwnReview and 420 or 500
			row.header:SetWidth(contentWidth)
			row.details:SetWidth(contentWidth)
			row.header:SetText(string.format("%s  ·  %s%s", direction, display,
				isIgnored and " (ignored locally)" or ""))
			if isIgnored then
				row.header:SetTextColor(0.68, 0.68, 0.68)
			elseif review.direction == 1 then
				row.header:SetTextColor(0.25, 1, 0.35)
			else
				row.header:SetTextColor(1, 0.4, 0.4)
			end
			local details = #((review.tags) or {}) > 0 and table.concat(review.tags, ", ") or ""
			local comment = SafeText(review.comment, MAX_COMMENT_LENGTH)
			if comment ~= "" then
				details = details ~= "" and (details .. "  ·  " .. comment) or comment
			end
			if details == "" then
				details = "No comments"
			end
			if type(review.updated) == "number" then
				details = string.format("%s  ·  %s", date("%Y-%m-%d", review.updated), details)
			end
			row.details:SetText(details)
			local headerHeight = row.header:GetStringHeight()
			local detailsHeight = math.min(37, row.details:GetStringHeight())
			local contentHeight = headerHeight + 3 + detailsHeight
			local topOffset = math.max(0, (row:GetHeight() - contentHeight) / 2)
			row.header:ClearAllPoints()
			row.header:SetPoint("TOPLEFT", 3, -topOffset)
			row.details:ClearAllPoints()
			row.details:SetPoint("TOPLEFT", row.header, "BOTTOMLEFT", 0, -3)
			row.details:SetSize(contentWidth, math.max(1, detailsHeight))
			row:Show()
		else
			row.targetKey = nil
			row.reviewAuthorKey = nil
			row.editButton:Hide()
			row:Hide()
		end
	end
	ratingDetailsPage.pageText:SetText(string.format("Page %d of %d", ratingDetailPageNumber, pageCount))
	ratingDetailsPage.previous:SetEnabled(ratingDetailPageNumber > 1)
	ratingDetailsPage.next:SetEnabled(ratingDetailPageNumber < pageCount)
	if pageCount > 1 then
		ratingDetailsPage.previous:Show()
		ratingDetailsPage.next:Show()
	else
		ratingDetailsPage.previous:Hide()
		ratingDetailsPage.next:Hide()
	end
end

local function RefreshReviewControls()
	if not reviewFrame or not reviewState then
		return
	end
	local hasChoice = reviewState.direction ~= nil
	reviewFrame.upButton:SetEnabled(true)
	reviewFrame.downButton:SetEnabled(true)
	reviewFrame.upButton:SetAlpha(reviewState.direction == 1 and 1 or 0.55)
	reviewFrame.downButton:SetAlpha(reviewState.direction == -1 and 1 or 0.55)
	if reviewFrame.saveButton then
		reviewFrame.saveButton:SetEnabled(hasChoice)
	end
	local tags = reviewState.direction == 1 and POSITIVE_TAGS or NEGATIVE_TAGS
	for index, button in ipairs(reviewFrame.tagButtons) do
		local tag = tags[index]
		button:SetText(tag or "")
		button:SetEnabled(hasChoice and tag ~= nil)
		button:SetAlpha(tag and reviewState.selectedTags[tag] and 1 or 0.55)
	end
end

local function LoadReviewStep()
	if not activeQueue or activeQueue.index > #activeQueue.targets then
		CloseReviewFlow(false)
		return
	end
	local target = activeQueue.targets[activeQueue.index]
	reviewState = { direction = nil, selectedTags = {}, comment = "" }
	local previous, previousStorageKey = GetMyReview(target.key, target.authorKey)
	if previous then
		reviewState.authorKey = ReviewAuthorKey(previous, previousStorageKey)
		reviewState.authorDisplay = previous.authorDisplay
		reviewState.direction = previous.direction
		reviewState.comment = previous.comment or ""
		for _, tag in ipairs(NormalizeTags(previous.tags, previous.direction)) do
			reviewState.selectedTags[tag] = true
		end
	end
	reviewFrame.title:SetText(activeQueue.title or "")
	local hasTitle = type(activeQueue.title) == "string" and activeQueue.title ~= ""
	reviewFrame.title:SetShown(hasTitle)
	reviewFrame.progress:SetText(string.format("Player %d of %d", activeQueue.index, #activeQueue.targets))
	reviewFrame.progress:ClearAllPoints()
	reviewFrame.progress:SetPoint("TOP", 0, hasTitle and -45 or -22)
	reviewFrame.target:SetText(target.display)
	reviewFrame.target:ClearAllPoints()
	reviewFrame.target:SetPoint("TOP", 0, hasTitle and -68 or -44)
	target.class = target.class or ClassTokenForPlayer(target.key)
	reviewFrame.target:SetTextColor(ClassColor(target.class))
	reviewFrame.comment:SetText(reviewState.comment)
	reviewFrame.upButton:ClearAllPoints()
	reviewFrame.upButton:SetPoint("TOP", -86, hasTitle and -98 or -74)
	for index, button in ipairs(reviewFrame.tagButtons) do
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", 55 + (index - 1) * 153, hasTitle and -138 or -114)
	end
	reviewFrame.commentLabel:ClearAllPoints()
	reviewFrame.commentLabel:SetPoint("TOPLEFT", 32, hasTitle and -180 or -156)
	reviewFrame.comment:ClearAllPoints()
	reviewFrame.comment:SetPoint("TOPLEFT", 32, hasTitle and -198 or -174)
	RefreshReviewControls()
	reviewFrame.saveButton:SetText(activeQueue.editOnly and "Save changes" or "Save & next")
	reviewFrame.saveButton:ClearAllPoints()
	reviewFrame.skipPlayerButton:ClearAllPoints()
	reviewFrame.skipAllButton:ClearAllPoints()
	if activeQueue.editOnly then
		reviewFrame.saveButton:SetPoint("BOTTOMLEFT", 146, 12)
		reviewFrame.skipPlayerButton:SetText("Cancel")
		reviewFrame.skipPlayerButton:SetPoint("LEFT", reviewFrame.saveButton, "RIGHT", 8, 0)
		reviewFrame.skipAllButton:Hide()
	else
		reviewFrame.saveButton:SetPoint("BOTTOMLEFT", 82, 12)
		reviewFrame.skipPlayerButton:SetText("Skip player")
		reviewFrame.skipPlayerButton:SetPoint("LEFT", reviewFrame.saveButton, "RIGHT", 8, 0)
		reviewFrame.skipAllButton:SetPoint("LEFT", reviewFrame.skipPlayerButton, "RIGHT", 8, 0)
		reviewFrame.skipAllButton:Show()
	end
	reviewFrame:Show()
end

ShowReviewStep = function()
	if not reviewFrame then
		CreateReviewFrame()
	end
	LoadReviewStep()
end

CreateReviewFrame = function()
	reviewFrame = CreateFrame("Frame", "SlajkonBuddyReviewPage", mainFrame)
	reviewFrame:SetAllPoints(mainFrame)
	reviewFrame:Hide()

	local close = CreateFrame("Button", nil, reviewFrame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function()
		CloseReviewFlow(true)
	end)

	reviewFrame.title = reviewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	reviewFrame.title:SetPoint("TOP", 0, -16)

	reviewFrame.progress = reviewFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	reviewFrame.progress:SetPoint("TOP", 0, -45)

	reviewFrame.target = reviewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	reviewFrame.target:SetPoint("TOP", 0, -68)

	reviewFrame.upButton = CreateButton(reviewFrame, "Thumbs up", 160, 32)
	reviewFrame.upButton:SetPoint("TOP", -86, -98)
	reviewFrame.upButton:SetScript("OnClick", function()
		if reviewState.direction ~= 1 then
			reviewState.selectedTags = {}
		end
		reviewState.direction = 1
		RefreshReviewControls()
	end)

	reviewFrame.downButton = CreateButton(reviewFrame, "Thumbs down", 160, 32)
	reviewFrame.downButton:SetPoint("LEFT", reviewFrame.upButton, "RIGHT", 12, 0)
	reviewFrame.downButton:SetScript("OnClick", function()
		if reviewState.direction ~= -1 then
			reviewState.selectedTags = {}
		end
		reviewState.direction = -1
		RefreshReviewControls()
	end)

	reviewFrame.tagButtons = {}
	for index = 1, 3 do
		local tagIndex = index
		local button = CreateButton(reviewFrame, "", 145, 25)
		button:SetPoint("TOPLEFT", 55 + (index - 1) * 153, -138)
		button:SetScript("OnClick", function()
			if not reviewState or not reviewState.direction then
				return
			end
			local options = reviewState.direction == 1 and POSITIVE_TAGS or NEGATIVE_TAGS
			local tag = options[tagIndex]
			if tag then
				reviewState.selectedTags[tag] = not reviewState.selectedTags[tag]
				RefreshReviewControls()
			end
		end)
		reviewFrame.tagButtons[index] = button
	end

	local commentLabel = reviewFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	commentLabel:SetPoint("TOPLEFT", 32, -180)
	commentLabel:SetText("Optional comment")
	reviewFrame.commentLabel = commentLabel
	reviewFrame.comment = CreateInput(reviewFrame, 496, 27, MAX_COMMENT_LENGTH)
	reviewFrame.comment:SetPoint("TOPLEFT", 32, -198)

	local saveButton = CreateButton(reviewFrame, "Save & next", 140, 30)
	saveButton:SetPoint("BOTTOMLEFT", 82, 12)
	reviewFrame.saveButton = saveButton
	saveButton:SetScript("OnClick", function()
		if not activeQueue or not reviewState or not reviewState.direction then
			return
		end
		local target = activeQueue.targets[activeQueue.index]
		local tags = {}
		for _, tag in ipairs(reviewState.direction == 1 and POSITIVE_TAGS or NEGATIVE_TAGS) do
			if reviewState.selectedTags[tag] then
				tags[#tags + 1] = tag
			end
		end
		local authorKey = reviewState.authorKey or playerKey
		local review = {
			targetKey = target.key,
			targetDisplay = target.display,
			authorKey = authorKey,
			authorDisplay = reviewState.authorDisplay or (authorKey == playerKey and playerDisplay or FormatPlayerDisplay(authorKey)),
			targetClass = target.class,
			targetLevel = target.level,
			direction = reviewState.direction,
			updated = NextReviewTimestamp(target.key, authorKey),
			tags = tags,
			comment = SafeText(reviewFrame.comment:GetText(), MAX_COMMENT_LENGTH),
		}
		MergeReview(review)
		EnqueueReview(review)
		EnqueuePlayerMetadata(target.key)
		activeQueue.index = activeQueue.index + 1
		LoadReviewStep()
	end)

	local skipPlayerButton = CreateButton(reviewFrame, "Skip player", 120, 30)
	skipPlayerButton:SetPoint("LEFT", saveButton, "RIGHT", 8, 0)
	reviewFrame.skipPlayerButton = skipPlayerButton
	skipPlayerButton:SetScript("OnClick", function()
		if activeQueue and activeQueue.editOnly then
			CloseReviewFlow(false)
		elseif activeQueue then
			activeQueue.index = activeQueue.index + 1
			LoadReviewStep()
		end
	end)

	local skipAllButton = CreateButton(reviewFrame, "Skip voting", 120, 30)
	skipAllButton:SetPoint("LEFT", skipPlayerButton, "RIGHT", 8, 0)
	reviewFrame.skipAllButton = skipAllButton
	skipAllButton:SetScript("OnClick", function()
		CloseReviewFlow(false)
	end)
end

local function IsSecretTooltipValue(value)
	if type(issecretvalue) ~= "function" then
		return false
	end
	local ok, secret = pcall(issecretvalue, value)
	return ok and secret == true
end

local function FindUnitByGUID(guid)
	if type(guid) ~= "string" or IsSecretTooltipValue(guid) then
		return nil
	end
	local units = { "player", "target", "focus", "mouseover" }
	local count = 0
	if type(GetNumGroupMembers) == "function" then
		local ok, groupCount = pcall(GetNumGroupMembers)
		if ok and type(groupCount) == "number" then
			count = groupCount
		end
	end
	local raid = type(IsInRaid) == "function" and IsInRaid()
	for index = 1, count do
		units[#units + 1] = raid and ("raid" .. index) or ("party" .. index)
	end
	for _, unit in ipairs(units) do
		local ok, exists = pcall(UnitExists, unit)
		if ok and not IsSecretTooltipValue(exists) and exists then
			local guidOk, unitGUID = pcall(UnitGUID, unit)
			if guidOk and not IsSecretTooltipValue(unitGUID) and unitGUID == guid then
				return unit
			end
		end
	end
	return nil
end

local function IsSafeTooltipUnit(unit)
	if type(unit) ~= "string" or IsSecretTooltipValue(unit) then
		return nil
	end
	local ok, exists = pcall(UnitExists, unit)
	if not ok or IsSecretTooltipValue(exists) or not exists then
		return nil
	end
	return unit
end

local function PlayerIdentityFromGUID(guid)
	if type(guid) ~= "string" or IsSecretTooltipValue(guid) then
		return nil, nil
	end
	local unit = FindUnitByGUID(guid)
	if unit then
		local ok, isPlayer = pcall(UnitIsPlayer, unit)
		if ok and not IsSecretTooltipValue(isPlayer) and isPlayer then
			local identityOk, key, display = pcall(PlayerIdentity, unit)
			if identityOk and type(key) == "string" and not IsSecretTooltipValue(key) then
				return key, display
			end
		end
	end
	if type(GetPlayerInfoByGUID) == "function" then
		local ok, _, classToken, _, _, _, name, realm = pcall(GetPlayerInfoByGUID, guid)
		if ok and type(classToken) == "string" and type(name) == "string"
			and not IsSecretTooltipValue(classToken) and not IsSecretTooltipValue(name)
			and not IsSecretTooltipValue(realm) then
			return PlayerIdentityFromParts(name, realm)
		end
	end
	return nil, nil
end

local tooltipRatingAdded = setmetatable({}, { __mode = "k" })
local tooltipResetHooksInstalled = setmetatable({}, { __mode = "k" })
local tooltipRatingHooksInstalled = false

local function EnsureTooltipResetHooks(tooltip)
	if tooltipResetHooksInstalled[tooltip] or type(tooltip.HookScript) ~= "function" then
		return
	end
	local cleared = pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", function(self)
		tooltipRatingAdded[self] = nil
	end)
	local hidden = pcall(tooltip.HookScript, tooltip, "OnHide", function(self)
		tooltipRatingAdded[self] = nil
	end)
	if cleared or hidden then
		tooltipResetHooksInstalled[tooltip] = true
	end
end

local function MatchTooltipLineFont(tooltip)
	local countOk, lineCount = pcall(tooltip.NumLines, tooltip)
	local nameOk, tooltipName = pcall(tooltip.GetName, tooltip)
	if not countOk or not nameOk or type(lineCount) ~= "number" or lineCount < 2 or not tooltipName then
		return
	end
	local newLine = _G[tooltipName .. "TextLeft" .. lineCount]
	local previousLine = _G[tooltipName .. "TextLeft" .. (lineCount - 1)]
	if not newLine or not previousLine then
		return
	end
	local fontOk, fontPath, fontSize, fontFlags = pcall(previousLine.GetFont, previousLine)
	if fontOk and fontPath then
		pcall(newLine.SetFont, newLine, fontPath, fontSize, fontFlags)
	end
	local shadowOk, shadowX, shadowY = pcall(previousLine.GetShadowOffset, previousLine)
	if shadowOk then
		pcall(newLine.SetShadowOffset, newLine, shadowX, shadowY)
	end
	local colorOk, shadowR, shadowG, shadowB, shadowA = pcall(previousLine.GetShadowColor, previousLine)
	if colorOk then
		pcall(newLine.SetShadowColor, newLine, shadowR, shadowG, shadowB, shadowA)
	end
end

local function FindTooltipRatingKey(key, display)
	if key and db.players[key] then
		return key
	end
	if type(display) ~= "string" or display == "" then
		return key
	end
	local expected = string.lower(SafeText(FormatPlayerDisplay(display), 80))
	for storedKey, entry in pairs(db.players) do
		if type(entry) == "table" then
			local storedDisplay = string.lower(SafeText(entry.display or FormatPlayerDisplay(storedKey), 80))
			if storedDisplay == expected then
				return storedKey
			end
		end
	end
	return key
end

local function AddTooltipRating(tooltip, unitArgument, tooltipData)
	if not tooltip or type(tooltip.AddLine) ~= "function" then
		return
	end
	if type(tooltip.IsForbidden) == "function" then
		local ok, forbidden = pcall(tooltip.IsForbidden, tooltip)
		if not ok or IsSecretTooltipValue(forbidden) then
			return
		end
		if forbidden then
			return
		end
	end
	local unit = IsSafeTooltipUnit(unitArgument)
	local guid
	if type(tooltipData) == "table" then
		local dataOk, dataGuid, unitToken, dataUnit = pcall(function()
			return tooltipData.guid, tooltipData.unitToken, tooltipData.unit
		end)
		if dataOk and not IsSecretTooltipValue(dataGuid) then
			guid = dataGuid
		end
		if dataOk then
			unit = unit or IsSafeTooltipUnit(unitToken) or IsSafeTooltipUnit(dataUnit)
		end
	end
	if not unit and TooltipUtil and type(TooltipUtil.GetDisplayedUnit) == "function" then
		local ok, _, displayedUnit = pcall(TooltipUtil.GetDisplayedUnit, tooltip)
		if ok then
			unit = IsSafeTooltipUnit(displayedUnit)
		end
	end
	if not unit and type(tooltip.GetUnit) == "function" then
		local ok, _, tooltipUnit = pcall(tooltip.GetUnit, tooltip)
		if ok then
			unit = IsSafeTooltipUnit(tooltipUnit)
		end
	end
	if not guid and unit then
		local ok, unitGUID = pcall(UnitGUID, unit)
		if ok and not IsSecretTooltipValue(unitGUID) then
			guid = unitGUID
		end
	end
	local key, display
	if unit then
		if guid then
			local unitGUIDOk, unitGUID = pcall(UnitGUID, unit)
			if not unitGUIDOk or IsSecretTooltipValue(unitGUID) or unitGUID ~= guid then
				unit = nil
			end
		end
	end
	if unit then
		local ok, isPlayer = pcall(UnitIsPlayer, unit)
		if ok and not IsSecretTooltipValue(isPlayer) and isPlayer then
			local identityOk
			identityOk, key, display = pcall(PlayerIdentity, unit)
			if not identityOk or type(key) ~= "string" or IsSecretTooltipValue(key) then
				key, display = nil, nil
			end
		end
	end
	if not key and guid then
		key, display = PlayerIdentityFromGUID(guid)
	end
	if not key then
		return
	end
	key = FindTooltipRatingKey(key, display)
	if tooltipRatingAdded[tooltip] == key then
		return
	end
	local summary = GetSummary(key)
	if not summary then
		return
	end
	EnsureTooltipResetHooks(tooltip)
	local addOk = pcall(tooltip.AddLine, tooltip,
		string.format("Slajkon Buddy: %s  (%d up, %d down)", summary.rank, summary.ups, summary.downs),
		summary.r, summary.g, summary.b, true)
	if not addOk then
		return
	end
	MatchTooltipLineFont(tooltip)
	tooltipRatingAdded[tooltip] = key
	if type(tooltip.Show) == "function" then
		pcall(tooltip.Show, tooltip)
	end
end

local function InstallTooltipRatingHooks()
	if tooltipRatingHooksInstalled then
		return
	end
	tooltipRatingHooksInstalled = true
	if GameTooltip then
		EnsureTooltipResetHooks(GameTooltip)
	end
	if TooltipDataProcessor and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
		and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
		local registered = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, function(tooltip, data)
			pcall(AddTooltipRating, tooltip, nil, data)
		end)
		if registered then
			return
		end
	end
	if GameTooltip then
		if type(GameTooltip.HookScript) == "function" then
			pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", AddTooltipRating)
		end
		if type(hooksecurefunc) == "function" and type(GameTooltip.SetUnit) == "function" then
			pcall(hooksecurefunc, GameTooltip, "SetUnit", function(tooltip, unit)
				AddTooltipRating(tooltip, unit)
			end)
		end
	end
end

local hookedUnitFrames = setmetatable({}, { __mode = "k" })

local function UnitTokenForFrame(frame)
	local unit = frame and frame.unit
	if type(unit) ~= "string" and frame and type(frame.GetAttribute) == "function" then
		local ok, attributeUnit = pcall(frame.GetAttribute, frame, "unit")
		if ok then
			unit = attributeUnit
		end
	end
	return type(unit) == "string" and unit or nil
end

HookUnitFrameTooltips = function()
	if type(EnumerateFrames) ~= "function" then
		return
	end
	local frame = EnumerateFrames()
	while frame do
		if frame and not hookedUnitFrames[frame] and type(frame.HookScript) == "function" and UnitTokenForFrame(frame) then
			local ok = pcall(frame.HookScript, frame, "OnEnter", function(self)
				local unit = UnitTokenForFrame(self)
				if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) or not GameTooltip then
					return
				end
				local _, tooltipUnit
				if type(GameTooltip.GetUnit) == "function" then
					_, tooltipUnit = GameTooltip:GetUnit()
				end
				if tooltipUnit and UnitIsUnit(tooltipUnit, unit) then
					return
				end
				if type(GameTooltip_SetDefaultAnchor) == "function" then
					GameTooltip_SetDefaultAnchor(GameTooltip, self)
				else
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				end
				if GameTooltip:SetUnit(unit) then
					GameTooltip:Show()
				end
			end)
			if ok then
				hookedUnitFrames[frame] = true
			end
		end
		frame = EnumerateFrames(frame)
	end
end

local MINIMAP_SHAPES = {
	ROUND = { true, true, true, true },
	SQUARE = { false, false, false, false },
	["CORNER-TOPLEFT"] = { true, false, false, false },
	["CORNER-TOPRIGHT"] = { false, false, true, false },
	["CORNER-BOTTOMLEFT"] = { false, true, false, false },
	["CORNER-BOTTOMRIGHT"] = { false, false, false, true },
	["SIDE-LEFT"] = { true, true, false, false },
	["SIDE-RIGHT"] = { false, false, true, true },
	["SIDE-TOP"] = { true, false, true, false },
	["SIDE-BOTTOM"] = { false, true, false, true },
	["TRICORNER-TOPLEFT"] = { true, true, true, false },
	["TRICORNER-TOPRIGHT"] = { true, false, true, true },
	["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
	["TRICORNER-BOTTOMRIGHT"] = { false, true, true, true },
}

local function PositionMinimapButton()
	if not minimapButton or not Minimap then
		return
	end
	local angle = math.rad(db.minimapAngle or 220)
	local x, y = math.cos(angle), math.sin(angle)
	local quadrant = 1
	if x < 0 then
		quadrant = quadrant + 1
	end
	if y > 0 then
		quadrant = quadrant + 2
	end
	local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
	local supportedQuadrants = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND
	if supportedQuadrants[quadrant] then
		x, y = x * 80, y * 80
	else
		local diagonalRadius = 103.13708498985
		x = math.max(-80, math.min(x * diagonalRadius, 80))
		y = math.max(-80, math.min(y * diagonalRadius, 80))
	end
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
	if minimapButton or not Minimap then
		return
	end
	if type(db.minimapAngle) ~= "number" then
		db.minimapAngle = 220
	end

	minimapButton = CreateFrame("Button", "SlajkonBuddyMinimapButton", Minimap)
	minimapButton:SetSize(32, 32)
	minimapButton:SetFrameStrata("MEDIUM")
	minimapButton:SetFrameLevel(8)
	minimapButton:RegisterForClicks("LeftButtonUp")
	minimapButton:RegisterForDrag("LeftButton")
	minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = minimapButton:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(22, 22)
	background:SetPoint("CENTER")

	local icon = minimapButton:CreateTexture(nil, "ARTWORK")
	icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
	icon:SetSize(18, 18)
	icon:SetPoint("CENTER")
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local border = minimapButton:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(54, 54)
	border:SetPoint("CENTER")

	minimapButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Slajkon Buddy")
		GameTooltip:AddLine("Click to open ratings. Drag to move.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	minimapButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	minimapButton:SetScript("OnClick", function(self)
		if self.dragMoved then
			self.dragMoved = nil
			return
		end
		if mainFrame:IsShown() then
			mainFrame:Hide()
		else
			mainFrame:Show()
			if activeQueue then
				mainPage:Hide()
				reviewFrame:Show()
			else
				mainPage:Show()
				if ratingDetailsPage then
					ratingDetailsPage:Hide()
				end
				if ignoredListPage then
					ignoredListPage:Hide()
				end
				if reviewFrame then
					reviewFrame:Hide()
				end
			end
		end
	end)
	minimapButton:SetScript("OnDragStart", function(self)
		self.dragMoved = false
		self:SetScript("OnUpdate", function(button)
			local centerX, centerY = Minimap:GetCenter()
			local cursorX, cursorY = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			cursorX, cursorY = cursorX / scale, cursorY / scale
			db.minimapAngle = math.deg(math.atan2(cursorY - centerY, cursorX - centerX)) % 360
			button.dragMoved = true
			PositionMinimapButton()
		end)
	end)
	minimapButton:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		C_Timer.After(0.1, function()
			self.dragMoved = nil
		end)
	end)
	PositionMinimapButton()
end

local function HandleAddonMessage(eventName, prefix, message, chatType, sender)
	if prefix ~= PREFIX or chatType ~= "WHISPER" then
		return
	end
	local senderKey
	if eventName == "BN_CHAT_MSG_ADDON" then
		local senderID = tonumber(sender)
		if not senderID then
			return
		end
		senderKey = battleNetAccountPeerKeys[senderID] or battleNetGameAccountPeerKeys[senderID]
		if not senderKey then
			RefreshOnlineFriends(false)
			senderKey = battleNetAccountPeerKeys[senderID] or battleNetGameAccountPeerKeys[senderID]
		end
	else
		senderKey = NormalizePlayerName(sender or "")
		if not senderKey or senderKey == playerKey then
			return
		end
		if not onlineFriends[senderKey] then
			RefreshOnlineFriends(false)
		end
	end
	if not senderKey or not onlineFriends[senderKey] then
		return
	end
	local route = onlineFriends[senderKey]
	HandlePacket(message, route and route.name or sender, senderKey)
end

local function HandleSlashCommand(rawArguments)
	local arguments = Trim(rawArguments)
	if arguments == "" then
		if not mainFrame then
			CreateMainFrame()
		end
		RefreshMainFrame()
		mainFrame:Show()
		if activeQueue and reviewFrame then
			mainPage:Hide()
			reviewFrame:Show()
		else
			if ratingDetailsPage then
				ratingDetailsPage:Hide()
			end
			if ignoredListPage then
				ignoredListPage:Hide()
			end
			mainPage:Show()
			if reviewFrame then
				reviewFrame:Hide()
			end
		end
		return
	end
	local command, commandArguments = arguments:match("^(%S+)%s*(.-)$")
	if command and (command:lower() == "own" or command:lower() == "unown") then
		if commandArguments == "" then
			DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy: Use /sbuddy own Character-Realm to link one of your characters.")
			return
		end
		local key, display = NormalizePlayerName(commandArguments)
		if not key then
			DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy: Enter a character name, optionally followed by its realm.")
			return
		end
		if command:lower() == "own" then
			db.ownCharacters[key] = true
			DEFAULT_CHAT_FRAME:AddMessage(string.format("Slajkon Buddy: %s is now linked as your character.", display))
		elseif key == playerKey then
			DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy: Your current character is always linked.")
		else
			db.ownCharacters[key] = nil
			DEFAULT_CHAT_FRAME:AddMessage(string.format("Slajkon Buddy: %s is no longer linked as your character.", display))
		end
		RefreshMainFrame()
		return
	end
	local targetName = arguments:gsub("^[Rr][Ee][Vv][Ii][Ee][Ww]%s+", "")
	local key, display = NormalizePlayerName(targetName)
	if not key then
		DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy: Use /sbuddy to open ratings, /review Player Name to review someone, or /sbuddy own Character-Realm to link an alt.")
		return
	end
	OpenReviewQueue({ { key = key, display = display, class = ClassTokenForPlayer(key) } })
end

local function HandleReviewSlashCommand(rawArguments)
	local targetName = Trim(rawArguments)
	local key, display, classToken
	if targetName == "" then
		if UnitExists("target") and UnitIsPlayer("target") then
			key, display = PlayerIdentity("target")
			local _, targetClass = UnitClass("target")
			classToken = targetClass
		end
	else
		key, display = NormalizePlayerName(targetName)
		classToken = key and ClassTokenForPlayer(key)
	end
	if not key then
		DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy: Target a player or use /review Player Name.")
		return
	end
	OpenReviewQueue({ { key = key, display = display, class = classToken } })
end

local function Initialize()
	if type(SlajkonBuddyDB) ~= "table" then
		SlajkonBuddyDB = { version = 1, players = {} }
	end
	if type(SlajkonBuddyDB.players) ~= "table" then
		SlajkonBuddyDB.players = {}
	end
	if type(SlajkonBuddyDB.ignoredRatings) ~= "table" then
		SlajkonBuddyDB.ignoredRatings = {}
	end
	if type(SlajkonBuddyDB.deletedReviews) ~= "table" then
		SlajkonBuddyDB.deletedReviews = {}
	end
	if type(SlajkonBuddyDB.ownCharacters) ~= "table" then
		SlajkonBuddyDB.ownCharacters = {}
	end
	SlajkonBuddyDB.version = 3
	db = SlajkonBuddyDB
	local normalizedOwnCharacters = {}
	for characterKey, isOwned in pairs(db.ownCharacters) do
		if isOwned then
			local normalizedKey = NormalizePlayerName(characterKey)
			if normalizedKey then
				normalizedOwnCharacters[normalizedKey] = true
			end
		end
	end
	db.ownCharacters = normalizedOwnCharacters
	for key, entry in pairs(db.players) do
		if type(entry) == "table" then
			entry.display = FormatPlayerDisplay(entry.display or key)
			entry.class = SafeClassToken(entry.class)
			entry.level = SafePlayerLevel(entry.level)
			entry.metadataUpdated = tonumber(entry.metadataUpdated)
		end
		if type(entry) == "table" and type(entry.reviews) == "table" then
			for _, review in pairs(entry.reviews) do
				if type(review) == "table" then
					review.tags = NormalizeTags(review.tags, tonumber(review.direction))
					review.targetDisplay = FormatPlayerDisplay(review.targetDisplay or entry.display or key)
					review.targetClass = SafeClassToken(review.targetClass)
					review.targetLevel = SafePlayerLevel(review.targetLevel)
					if not entry.class and review.targetClass then
						entry.class = review.targetClass
					end
					if not entry.level and review.targetLevel then
						entry.level = review.targetLevel
					end
					if (review.targetClass or review.targetLevel) and not entry.metadataUpdated then
						entry.metadataUpdated = tonumber(review.updated) or 0
					end
					if review.authorDisplay then
						review.authorDisplay = FormatPlayerDisplay(review.authorDisplay)
					end
				end
			end
		end
	end
	for targetKey, ignored in pairs(db.ignoredRatings) do
		if type(ignored) ~= "table" then
			db.ignoredRatings[targetKey] = nil
		end
	end
	for targetKey, deleted in pairs(db.deletedReviews) do
		if type(deleted) ~= "table" then
			db.deletedReviews[targetKey] = nil
		else
			for authorKey, updated in pairs(deleted) do
				deleted[authorKey] = tonumber(updated)
				if not deleted[authorKey] then
					deleted[authorKey] = nil
				end
			end
		end
	end
	playerKey, playerDisplay = PlayerIdentity("player")
	if not playerKey then
		playerKey, playerDisplay = "unknown-player", "Unknown player"
	end
	if playerKey ~= "unknown-player" then
		db.ownCharacters[playerKey] = true
	end
	for targetKey, entry in pairs(db.players) do
		local ignoredForTarget = db.ignoredRatings[targetKey]
		if ignoredForTarget and type(entry.reviews) == "table" then
			for storageKey, review in pairs(entry.reviews) do
				if IsMyReview(review, storageKey) then
					ignoredForTarget[ReviewAuthorKey(review, storageKey)] = nil
				end
			end
			if not next(ignoredForTarget) then
				db.ignoredRatings[targetKey] = nil
			end
		end
	end
	if C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	end
	CreateMainFrame()
	CreateMinimapButton()
	if HookUnitFrameTooltips then
		HookUnitFrameTooltips()
	end
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("Slajkon Buddy loaded. Type /sbuddy to review a player or see Ratings.")
	end
end

SLASH_SLAJKONBUDDY1 = "/sbuddy"
SLASH_SLAJKONBUDDY2 = "/slajkonbuddy"
SLASH_SLAJKONBUDDY3 = "/sb"
SlashCmdList.SLAJKONBUDDY = HandleSlashCommand
SLASH_SLAJKONREVIEW1 = "/review"
SlashCmdList.SLAJKONREVIEW = HandleReviewSlashCommand

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		local loadedName = ...
		if loadedName == ADDON_NAME then
			Initialize()
			eventFrame:UnregisterEvent("ADDON_LOADED")
			eventFrame:RegisterEvent("PLAYER_LOGIN")
			eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
			eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
			eventFrame:RegisterEvent("FRIENDLIST_UPDATE")
			eventFrame:RegisterEvent("BN_CHAT_MSG_ADDON")
			eventFrame:RegisterEvent("BN_FRIEND_ACCOUNT_ONLINE")
			eventFrame:RegisterEvent("BN_FRIEND_ACCOUNT_OFFLINE")
			eventFrame:RegisterEvent("BN_FRIEND_INFO_CHANGED")
			eventFrame:RegisterEvent("BN_FRIEND_LIST_SIZE_CHANGED")
			eventFrame:RegisterEvent("BN_CONNECTED")
			eventFrame:RegisterEvent("BN_DISCONNECTED")
			eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
			eventFrame:RegisterEvent("CHAT_MSG_ADDON")
			pcall(eventFrame.RegisterEvent, eventFrame, "CHAT_MSG_ADDON_LOGGED")
		end
	elseif event == "PLAYER_LOGIN" then
		InstallTooltipRatingHooks()
		local key, display = PlayerIdentity("player")
		if key then
			playerKey, playerDisplay = key, display
		end
		CreateMinimapButton()
		ScheduleRefresh()
		C_Timer.After(2, function()
			if RefreshOnlineFriends then
				RefreshOnlineFriends(true)
			end
		end)
	elseif event == "FRIENDLIST_UPDATE" then
		ScheduleFriendSync()
	elseif event == "BN_FRIEND_ACCOUNT_ONLINE" or event == "BN_FRIEND_ACCOUNT_OFFLINE"
		or event == "BN_FRIEND_INFO_CHANGED" or event == "BN_FRIEND_LIST_SIZE_CHANGED"
		or event == "BN_CONNECTED" or event == "BN_DISCONNECTED" then
		if event == "BN_FRIEND_ACCOUNT_ONLINE" or event == "BN_CONNECTED" then
			ResetBattleNetPeers()
		end
		ScheduleFriendSync()
	elseif event == "PLAYER_ENTERING_WORLD" then
		ScheduleRefresh()
		ScheduleFriendSync()
	elseif event == "CHAT_MSG_ADDON" or event == "CHAT_MSG_ADDON_LOGGED" or event == "BN_CHAT_MSG_ADDON" then
		HandleAddonMessage(event, ...)
	else
		ScheduleRefresh()
	end
end)
