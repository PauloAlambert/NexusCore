local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer
local StarterGui = game:GetService("StarterGui")

local httpRequest = (syn and syn.request) or (http and http.request) or http_request or request

local Core = {
    Config = {
        FirebaseURL = "https://luauaicodes-default-rtdb.firebaseio.com/",
        ApiKeys = {},
        CurrentKeyIndex = 1,
        CurrentModel = "gemini-3.1-pro", 
        VaultID = "",
        AgenticEnabled = false,
        LastStatusID = nil
    }
}

-- [ FIREBASE & DB FUNCTIONS ]
function Core:RequestDB(endpoint, method, body)
    if not httpRequest then return nil end
    local url = self.Config.FirebaseURL .. endpoint .. ".json"
    local response = nil
    
    pcall(function()
        local params = {Url = url, Method = method}
        if body then
            params.Headers = {["Content-Type"] = "application/json"}
            params.Body = HttpService:JSONEncode(body)
        end
        response = httpRequest(params)
    end)
    
    if response and response.StatusCode == 200 then
        return HttpService:JSONDecode(response.Body)
    end
    return nil
end

-- [ VAULT FUNCTIONS ]
function Core:LoadVault(vaultId)
    self.Config.VaultID = vaultId
    local data = self:RequestDB("cofres/" .. vaultId .. "/scripts", "GET")
    return data or {}
end

function Core:SaveToVault(vaultId, name, content)
    if not vaultId or vaultId == "" then return false end
    local url = self.Config.FirebaseURL .. "cofres/" .. vaultId .. "/scripts.json"
    local success = pcall(function()
        httpRequest({
            Url = url, 
            Method = "POST", 
            Body = HttpService:JSONEncode({
                nome = name, 
                conteudo = content, 
                data = os.date("%d/%m/%Y"), 
                author = tostring(LocalPlayer.UserId)
            })
        })
    end)
    return success
end

function Core:DeleteFromVault(scriptId)
    if self.Config.VaultID == "" then return false end
    local url = self.Config.FirebaseURL .. "cofres/" .. self.Config.VaultID .. "/scripts/" .. scriptId .. ".json"
    return pcall(function() httpRequest({Url = url, Method = "DELETE"}) end)
end

-- [ NEXUS PRESENCE & USERS ]
function Core:UpdatePresence()
    local pos = Vector3.zero
    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then 
        pos = LocalPlayer.Character.HumanoidRootPart.Position 
    end
    
    local data = {
        name = LocalPlayer.Name, 
        userId = tostring(LocalPlayer.UserId), 
        jobId = game.JobId, 
        placeId = game.PlaceId, 
        pos = {x = pos.X, y = pos.Y, z = pos.Z}, 
        timestamp = os.time()
    }
    
    task.spawn(function()
        local res = self:RequestDB("usuarios/" .. tostring(LocalPlayer.UserId) .. "/status", "POST", data)
        if res and res.name then 
            if self.Config.LastStatusID then 
                self:RequestDB("usuarios/" .. tostring(LocalPlayer.UserId) .. "/status/" .. self.Config.LastStatusID, "DELETE") 
            end 
            self.Config.LastStatusID = res.name 
        else 
            self:RequestDB("usuarios/" .. tostring(LocalPlayer.UserId) .. "/status", "DELETE") 
            self.Config.LastStatusID = nil 
        end
    end)
end

function Core:GetActiveUsers()
    local all = self:RequestDB("usuarios", "GET")
    local active = {}
    if not all or type(all) ~= "table" then return active end
    
    for uid, data in pairs(all) do
        if data and type(data) == "table" and data.status and uid ~= tostring(LocalPlayer.UserId) then
            local latest = nil
            for statusKey, statusData in pairs(data.status) do
                if type(statusData) == "table" and statusData.timestamp then
                    if not latest or statusData.timestamp > latest.timestamp then latest = statusData end
                end
            end
            
            if latest and latest.timestamp and (os.time() - latest.timestamp) < 30 then
                table.insert(active, {
                    userId = uid,
                    name = latest.name or "Unknown",
                    placeId = latest.placeId,
                    jobId = latest.jobId
                })
            end
        end
    end
    return active
end

-- [ NEXUS FUNCTIONS ]
function Core:SendCommand(targetId, cmdType, payload)
    local data = {type = cmdType, sender = LocalPlayer.Name, timestamp = os.time()}
    if cmdType == "EXECUTE" then data.code = payload 
    elseif cmdType == "CHAT" or cmdType == "WARN" then data.msg = payload
    elseif cmdType == "SAFE_BRING" then 
        local p = LocalPlayer.Character.HumanoidRootPart.Position
        data.pos = {x = p.X, y = p.Y, z = p.Z}
        if payload then data.time = payload end
    elseif cmdType == "BRING_TP" then 
        local p = LocalPlayer.Character.HumanoidRootPart.Position
        data.pos = {x = p.X, y = p.Y, z = p.Z}
    elseif cmdType == "SYNC_MARK" then data.targetName = payload
    elseif cmdType == "JOIN_REQ" or cmdType == "SERVER_BRING" then
        data.placeId = game.PlaceId
        data.jobId = game.JobId
    end
    task.spawn(function() self:RequestDB("usuarios/" .. targetId .. "/inbox", "POST", data) end)
end

-- Handlers locais para a Inbox
local MarkedPlayers = {}
local function CreateWarnUI(sender, msg)
    local gui = Instance.new("ScreenGui", game:GetService("CoreGui"))
    local frame = Instance.new("Frame", gui)
    frame.Size = UDim2.new(1, 0, 1, 0)
    frame.BackgroundTransparency = 1
    local bar = Instance.new("Frame", frame)
    bar.Size = UDim2.new(1, 0, 0.2, 0)
    bar.Position = UDim2.new(0, 0, 0.4, 0)
    bar.BackgroundColor3 = Color3.fromRGB(150, 0, 0)
    bar.BackgroundTransparency = 0.2
    local txt = Instance.new("TextLabel", bar)
    txt.Size = UDim2.new(1, 0, 0.5, 0)
    txt.Position = UDim2.new(0, 0, 0.25, 0)
    txt.BackgroundTransparency = 1
    txt.Text = "⚠️ AVISO DE " .. string.upper(sender) .. ": " .. msg .. " ⚠️"
    txt.TextColor3 = Color3.fromRGB(255, 255, 255)
    txt.TextScaled = true
    txt.Font = Enum.Font.GothamBlack
    game:GetService("Debris"):AddItem(gui, 10)
end

function Core:StartInboxListener()
    -- Presence Loop
    task.spawn(function()
        while task.wait(15) do
            self:UpdatePresence()
        end
    end)
    
    -- Inbox Loop
    task.spawn(function()
        while task.wait(5) do
            local inbox = self:RequestDB("usuarios/" .. tostring(LocalPlayer.UserId) .. "/inbox", "GET")
            if inbox then
                for key, cmd in pairs(inbox) do
                    pcall(function()
                        if cmd.type == "EXECUTE" then
                            local func = loadstring or load
                            if func then 
                                local c = func(cmd.code)
                                if c then task.spawn(c) end
                            end
                            pcall(function() StarterGui:SetCore("SendNotification", {Title = "NEXUS", Text = "Script de " .. cmd.sender}) end)
                        elseif cmd.type == "CHAT" then
                            pcall(function() StarterGui:SetCore("SendNotification", {Title = cmd.sender, Text = cmd.msg}) end)
                        elseif cmd.type == "WARN" then
                            CreateWarnUI(cmd.sender, cmd.msg)
                        elseif cmd.type == "SAFE_BRING" then 
                            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then 
                                local hrp = LocalPlayer.Character.HumanoidRootPart 
                                local dist = (hrp.Position - Vector3.new(cmd.pos.x, cmd.pos.y, cmd.pos.z)).Magnitude
                                local time = dist / 100
                                if cmd.time then time = tonumber(cmd.time) end
                                TweenService:Create(hrp, TweenInfo.new(time), {CFrame = CFrame.new(cmd.pos.x, cmd.pos.y, cmd.pos.z)}):Play() 
                            end
                        elseif cmd.type == "BRING_TP" then 
                            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then 
                                LocalPlayer.Character.HumanoidRootPart.CFrame = CFrame.new(cmd.pos.x, cmd.pos.y, cmd.pos.z) 
                            end
                        elseif cmd.type == "SYNC_MARK" then 
                            if MarkedPlayers[cmd.targetName] then MarkedPlayers[cmd.targetName]:Destroy() end
                            local target = Players:FindFirstChild(cmd.targetName)
                            if target and target.Character then
                                local hl = Instance.new("Highlight")
                                hl.FillColor = Color3.fromRGB(255,0,0)
                                hl.OutlineColor = Color3.fromRGB(255,255,255)
                                hl.Adornee = target.Character
                                hl.Parent = game:GetService("CoreGui")
                                MarkedPlayers[cmd.targetName] = hl
                                pcall(function() StarterGui:SetCore("SendNotification", {Title = "NEXUS", Text = "ALVO: " .. cmd.targetName}) end)
                            end
                        elseif cmd.type == "JOIN_REQ" then 
                            TeleportService:TeleportToPlaceInstance(cmd.placeId, cmd.jobId, LocalPlayer)
                        elseif cmd.type == "SERVER_BRING" then 
                            pcall(function() StarterGui:SetCore("SendNotification", {Title = "NEXUS", Text = "Indo p/ server de " .. cmd.sender}) end)
                            TeleportService:TeleportToPlaceInstance(cmd.placeId, cmd.jobId, LocalPlayer)
                        end
                    end)
                    self:RequestDB("usuarios/" .. tostring(LocalPlayer.UserId) .. "/inbox/" .. key, "DELETE")
                end
            end
        end
    end)
end

-- [ GEMINI AGENTIC FUNCTIONS ]
function Core:AddApiKey(key)
    if key and key ~= "" then table.insert(self.Config.ApiKeys, key) end
end
function Core:GetCurrentApiKey()
    if #self.Config.ApiKeys == 0 then return nil end
    return self.Config.ApiKeys[self.Config.CurrentKeyIndex]
end
function Core:NextApiKey()
    if #self.Config.ApiKeys <= 1 then return end
    self.Config.CurrentKeyIndex = self.Config.CurrentKeyIndex + 1
    if self.Config.CurrentKeyIndex > #self.Config.ApiKeys then self.Config.CurrentKeyIndex = 1 end
end

local AgentTools = {
    {
        name = "get_children",
        description = "Gets the names of the children of an object in the game.",
        parameters = { type = "OBJECT", properties = { path = { type = "STRING", description = "Path to the object (e.g. 'game.ReplicatedStorage')" } }, required = {"path"} }
    },
    {
        name = "get_script_source",
        description = "Reads the source code of a LocalScript or ModuleScript in the game. Only works if your exploit supports getscripts/decompile or reading .Source.",
        parameters = { type = "OBJECT", properties = { path = { type = "STRING", description = "Path to the script object" } }, required = {"path"} }
    }
}
local function ResolvePath(pathStr)
    local parts = string.split(pathStr, ".")
    local current = game
    if parts[1] == "game" then table.remove(parts, 1) end
    if parts[1] == "workspace" or parts[1] == "Workspace" then current = workspace table.remove(parts, 1) end
    for _, part in ipairs(parts) do
        local nextObj = current:FindFirstChild(part)
        if not nextObj then return nil end
        current = nextObj
    end
    return current
end

function Core:ExecuteTool(toolName, args)
    if not self.Config.AgenticEnabled then return "Agentic mode is disabled by the user." end
    if toolName == "get_children" then
        local obj = ResolvePath(args.path)
        if obj then
            local res = {}
            for _, child in ipairs(obj:GetChildren()) do table.insert(res, child.Name .. " (" .. child.ClassName .. ")") end
            if #res == 0 then return "Folder is empty." end
            return table.concat(res, ", ")
        else return "Object not found." end
    elseif toolName == "get_script_source" then
        local obj = ResolvePath(args.path)
        if obj and (obj:IsA("LocalScript") or obj:IsA("ModuleScript")) then
            local success, src = pcall(function() return decompile and decompile(obj) or obj.Source end)
            if success and src and src ~= "" then return src else return "Could not read source. Executor might not support decompile()." end
        else return "Script not found or is not a Local/Module script." end
    end
    return "Tool not found."
end

function Core:SendGeminiPrompt(promptHistory, onUpdate)
    local apiKey = self:GetCurrentApiKey()
    if not apiKey then onUpdate("ERRO: Nenhuma API Key configurada.", true) return nil end
    local model = self.Config.CurrentModel
    local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apiKey
    local payload = { contents = promptHistory, generationConfig = { temperature = 0.5 } }
    if self.Config.AgenticEnabled then payload.tools = {{ functionDeclarations = AgentTools }} end

    local maxTurns = 5
    local currentTurn = 1

    while currentTurn <= maxTurns do
        local reqData = { Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode(payload) }
        onUpdate("⏳ Requisitando Gemini API (Turno " .. currentTurn .. ")...", false)
        local success, res = pcall(function() return httpRequest(reqData) end)

        if not success or not res then onUpdate("ERRO: Falha ao enviar requisição HTTP.", true) return nil end

        if res.StatusCode == 429 or res.StatusCode == 403 then
            self:NextApiKey()
            onUpdate("⚠️ API Key esgotada. Mudando para a próxima chave...", false)
            url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. self:GetCurrentApiKey()
            task.wait(1)
            continue
        end
        if res.StatusCode ~= 200 then onUpdate("ERRO API HTTP " .. tostring(res.StatusCode) .. "\n" .. tostring(res.Body), true) return nil end
        local data = HttpService:JSONDecode(res.Body)
        if not data.candidates or not data.candidates[1] then onUpdate("ERRO: Resposta vazia da IA.", true) return nil end

        local part = data.candidates[1].content.parts[1]
        table.insert(payload.contents, { role = "model", parts = data.candidates[1].content.parts })

        if part.functionCall then
            local fCall = part.functionCall
            onUpdate("🛠️ IA usando ferramenta: " .. fCall.name, false)
            local toolRes = self:ExecuteTool(fCall.name, fCall.args)
            table.insert(payload.contents, { role = "user", parts = {{ functionResponse = { name = fCall.name, response = { result = toolRes } } }} })
            currentTurn = currentTurn + 1
        elseif part.text then
            return part.text
        else
            onUpdate("ERRO: Resposta inesperada.", true)
            return nil
        end
    end
    onUpdate("ERRO: Limite de turnos agentic atingido.", true)
    return nil
end

return Core
