--[[
	pesde.toml의 GitHub 의존성 rev를 최신 커밋으로 갱신하는 모듈입니다.
]]

local FileSystem = require("@lune/fs")

local GitHubApi = require("./GitHubApi")

local function trim(value: string): string
	return value:match("^%s*(.-)%s*$")
end

local function splitLines(text: string): { string }
	local normalized = text:gsub("\r\n", "\n")
	normalized = normalized:gsub("\r", "\n")
	local lines: { string } = {}
	local startIndex = 1

	while true do
		local nextIndex = normalized:find("\n", startIndex, true)
		if not nextIndex then
			table.insert(lines, normalized:sub(startIndex))
			break
		end

		table.insert(lines, normalized:sub(startIndex, nextIndex - 1))
		startIndex = nextIndex + 1
	end

	return lines
end

local function stripComments(line: string): string
	local inString = false
	local escaped = false
	for i = 1, #line do
		local ch = line:sub(i, i)
		if escaped then
			escaped = false
		elseif ch == "\\" then
			escaped = true
		elseif ch == "\"" then
			inString = not inString
		elseif ch == "#" and not inString then
			return line:sub(1, i - 1)
		end
	end
	return line
end

local function stripCommentsFromText(text: string): string
	local lines = splitLines(text)
	local stripped: { string } = {}
	for _, line in lines do
		table.insert(stripped, stripComments(line))
	end
	return table.concat(stripped, "\n")
end

local function updateBraceDepth(text: string, depth: number): number
	local inString = false
	local escaped = false
	for i = 1, #text do
		local ch = text:sub(i, i)
		if escaped then
			escaped = false
		elseif ch == "\\" then
			escaped = true
		elseif ch == "\"" then
			inString = not inString
		elseif not inString then
			if ch == "{" then
				depth += 1
			elseif ch == "}" then
				depth -= 1
			end
		end
	end
	return depth
end

local function isDependencySection(sectionName: string?): boolean
	if sectionName == nil then
		return false
	end

	if sectionName == "dependencies" then
		return true
	end
	if sectionName == "dev-dependencies" then
		return true
	end
	if sectionName == "peer-dependencies" then
		return true
	end
	if sectionName:match("%.dependencies$") then
		return true
	end
	if sectionName:match("%.dev%-dependencies$") then
		return true
	end
	if sectionName:match("%.peer%-dependencies$") then
		return true
	end

	return false
end

local function extractStringValue(text: string, key: string): string?
	local pattern = key .. "%s*=%s*\"(.-)\""
	return text:match(pattern)
end

local function isCommitSha(value: string): boolean
	if #value ~= 40 then
		return false
	end
	return value:match("^[0-9a-fA-F]+$") ~= nil
end

local function replaceRev(entryText: string, newRev: string): (string, boolean)
	local pattern = "(%f[%w]rev%s*=%s*)\"(.-)\""
	local replaced, count = entryText:gsub(pattern, `%1"{newRev}"`, 1)
	if count == 0 then
		return entryText, false
	end
	return replaced, true
end

local function updateEntry(params)
	local entryText = params.Text
	local entryName = params.Name
	local token = params.Token

	local cleanText = stripCommentsFromText(entryText)
	local repo = extractStringValue(cleanText, "repo")
	if repo == nil then
		return entryText, nil, { Name = entryName, Reason = "MissingRepo" }, nil, false
	end

	local repoInfo = GitHubApi.ParseRepo(repo)
	if repoInfo == nil then
		return entryText, nil, { Name = entryName, Reason = "NotGitHub" }, nil, false
	end

	local rev = extractStringValue(cleanText, "rev")
	if rev == nil then
		return entryText, nil, { Name = entryName, Reason = "MissingRev" }, nil, false
	end

	local branch = extractStringValue(cleanText, "branch")
	if branch == nil and not isCommitSha(rev) then
		branch = rev
	end

	local okResolve, resolveResult = GitHubApi.ResolveLatestCommit({
		Repo = repoInfo,
		Branch = branch,
		Token = token,
	})
	if not okResolve then
		return entryText,
			nil,
			nil,
			{
				Name = entryName,
				Repo = repo,
				Code = resolveResult.Code,
				StatusCode = resolveResult.StatusCode,
				Detail = resolveResult.Detail,
			},
			true
	end

	local newRev = resolveResult.Sha
	if newRev == rev then
		return entryText, nil, { Name = entryName, Reason = "UpToDate" }, nil, true
	end

	local updatedText, didReplace = replaceRev(entryText, newRev)
	if not didReplace then
		return entryText,
			nil,
			nil,
			{
				Name = entryName,
				Repo = repo,
				Code = "RevReplaceFailed",
			},
			true
	end

	return updatedText,
		{
			Name = entryName,
			Repo = repo,
			OldRev = rev,
			NewRev = newRev,
			Branch = resolveResult.Branch,
		},
		nil,
		nil,
		true
end

local function updateContent(params)
	local content = params.Content
	local token = params.Token

	local lines = splitLines(content)
	local updatedLines: { string } = {}
	local updates = {}
	local skipped = {}
	local errors = {}
	local gitHubEntries = 0
	local currentSection = nil
	local activeEntry = nil

	for _, line in lines do
		if activeEntry ~= nil then
			table.insert(activeEntry.Lines, line)
			local lineForParse = stripComments(line)
			activeEntry.Depth = updateBraceDepth(lineForParse, activeEntry.Depth)
			if activeEntry.Depth == 0 then
				local entryText = table.concat(activeEntry.Lines, "\n")
				local updatedText, updateInfo, skipInfo, errorInfo, isGitHubEntry = updateEntry({
					Name = activeEntry.Name,
					Text = entryText,
					Token = token,
				})
				if isGitHubEntry then
					gitHubEntries += 1
				end

				local updatedEntryLines = splitLines(updatedText)
				for _, entryLine in updatedEntryLines do
					table.insert(updatedLines, entryLine)
				end

				if updateInfo ~= nil then
					table.insert(updates, updateInfo)
				elseif skipInfo ~= nil then
					table.insert(skipped, skipInfo)
				elseif errorInfo ~= nil then
					table.insert(errors, errorInfo)
				end

				activeEntry = nil
			end
		else
			local lineForParse = stripComments(line)
			local trimmedLine = trim(lineForParse)
			local sectionName = trimmedLine:match("^%[(.+)%]$")
			if sectionName ~= nil then
				currentSection = sectionName
				table.insert(updatedLines, line)
			else
				if isDependencySection(currentSection) then
					local name = lineForParse:match("^%s*([%w%-%_%.]+)%s*=%s*%{")
					if name == nil then
						name = lineForParse:match("^%s*\"(.-)\"%s*=%s*%{")
					end
					if name ~= nil then
						local depth = updateBraceDepth(lineForParse, 0)
						local entry = {
							Name = name,
							Lines = { line },
							Depth = depth,
						}
						if entry.Depth == 0 then
							local entryText = line
							local updatedText, updateInfo, skipInfo, errorInfo, isGitHubEntry =
								updateEntry({
									Name = entry.Name,
									Text = entryText,
									Token = token,
								})
							if isGitHubEntry then
								gitHubEntries += 1
							end

							local updatedEntryLines = splitLines(updatedText)
							for _, entryLine in updatedEntryLines do
								table.insert(updatedLines, entryLine)
							end

							if updateInfo ~= nil then
								table.insert(updates, updateInfo)
							elseif skipInfo ~= nil then
								table.insert(skipped, skipInfo)
							elseif errorInfo ~= nil then
								table.insert(errors, errorInfo)
							end
						else
							activeEntry = entry
						end
					else
						table.insert(updatedLines, line)
					end
				else
					table.insert(updatedLines, line)
				end
			end
		end
	end

	if activeEntry ~= nil then
		for _, entryLine in activeEntry.Lines do
			table.insert(updatedLines, entryLine)
		end
	end

	local updatedContent = table.concat(updatedLines, "\n")
	if content:sub(-1) == "\n" then
		updatedContent ..= "\n"
	end

	return updatedContent,
		{
			Updated = updates,
			Skipped = skipped,
			Errors = errors,
			Changed = updatedContent ~= content,
			GitHubEntries = gitHubEntries,
		}
end

local function readFile(path: string)
	if not FileSystem.isFile(path) then
		return false, { Code = "MissingFile", Path = path }
	end

	local okRead, contentOrErr = pcall(FileSystem.readFile, path)
	if not okRead then
		return false,
			{
				Code = "ReadFailed",
				Path = path,
				Detail = tostring(contentOrErr),
			}
	end

	return true, contentOrErr
end

local function writeFile(path: string, content: string)
	local okWrite, err = pcall(function()
		FileSystem.writeFile(path, content)
	end)
	if not okWrite then
		return false, {
			Code = "WriteFailed",
			Path = path,
			Detail = tostring(err),
		}
	end
	return true, nil
end

local PesdeTomlUpdater = {}

function PesdeTomlUpdater.Update(params)
	local path = params.Path
	local token = params.Token

	local okRead, contentOrErr = readFile(path)
	if not okRead then
		return false, contentOrErr
	end

	local updatedContent, result = updateContent({
		Content = contentOrErr,
		Token = token,
	})

	if result.Changed then
		local okWrite, writeErr = writeFile(path, updatedContent)
		if not okWrite then
			return false, writeErr
		end
	end

	return true, result
end

return PesdeTomlUpdater
