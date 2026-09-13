--[=[
    ScriptBuilder.lua — rebuilt UI / stability pass
    Target layout: Steal an Egg style shown in the reference screenshot.

    Public API kept compatible with the previous file:
      Builder.New / Builder.Init
      :AddModule / :AddRemote / :AddRemoteSpy / :AddModules
      :BuildGui / :Run / :Show / :Hide / :Toggle
      :GetModule / :GetAllModules / :SetModuleValue / :FireModule / :Status

    Main fixes:
      • removed the local typeof() shadow that broke Instance detection
      • fixed nil indexing in AddModule when Remote is absent
      • robust remote path resolution
      • dynamic modules/categories refresh correctly
      • rebuilt the GUI dimensions/layout to match the supplied reference
      • added select/dropdown support
      • added real header drag logic instead of deprecated GuiObject.Draggable
      • deterministic category/module ordering
      • correct cleanup of old GUI connections
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
assert(Player, "ScriptBuilder must run as a LocalScript / executor LocalScript")
local PlayerGui = Player:WaitForChild("PlayerGui")

local Builder = {}
local BUILDER_META = { __index = Builder }

local GUILIB = {}
local GUILIB_META = { __index = GUILIB }

-- ============================================================
-- HELPERS
-- ============================================================

local function make(className, props)
    local obj = Instance.new(className)
    if props then
        for k, v in pairs(props) do
            if k ~= "Parent" then
                obj[k] = v
            end
        end
        if props.Parent then
            obj.Parent = props.Parent
        end
    end
    return obj
end

local function addCorner(parent, radius)
    return make("UICorner", {
        Parent = parent,
        CornerRadius = UDim.new(0, radius or 4),
    })
end

local function addStroke(parent, color, thickness, transparency)
    return make("UIStroke", {
        Parent = parent,
        Color = color,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function disconnectAll(list)
    for i = #list, 1, -1 do
        local c = list[i]
        list[i] = nil
        pcall(function() c:Disconnect() end)
    end
end

local function resolvePath(path)
    path = trim(path)
    if path == "" or path:find(":") then
        return nil
    end

    local parts = {}
    for part in path:gmatch("[^%.]+") do
        parts[#parts + 1] = part
    end
    if #parts == 0 then
        return nil
    end

    local roots = {
        game = game,
        Players = Players,
        ReplicatedStorage = ReplicatedStorage,
        Workspace = workspace,
        StarterGui = game:GetService("StarterGui"),
        CoreGui = game:GetService("CoreGui"),
        Lighting = game:GetService("Lighting"),
    }

    local node = roots[parts[1]] or game:FindFirstChild(parts[1])
    if not node then
        return nil
    end

    for i = 2, #parts do
        node = node:FindFirstChild(parts[i])
        if not node then
            return nil
        end
    end

    return node
end

local function resolveRemote(expression)
    expression = trim(expression)
    if expression == "" then
        return nil
    end

    -- Simple dot path: ReplicatedStorage.Remotes.Example
    local direct = resolvePath(expression)
    if direct and (direct:IsA("RemoteEvent") or direct:IsA("RemoteFunction")) then
        return direct
    end

    -- game:GetService("X").Foo.Bar
    local serviceName, rest = expression:match('^game:GetService%(%s*["\']([^"\']+)["\']%s*%)%.(.+)$')
    if serviceName and rest then
        local ok, service = pcall(game.GetService, game, serviceName)
        if ok and service then
            local node = service
            for part in rest:gmatch("[^%.]+") do
                node = node:FindFirstChild(part)
                if not node then break end
            end
            if node and (node:IsA("RemoteEvent") or node:IsA("RemoteFunction")) then
                return node
            end
        end
    end

    return nil
end

local NIL = {}

local function parseValue(text)
    text = trim(text)
    if text == "nil" then return NIL end
    if text == "true" then return true end
    if text == "false" then return false end
    if text:match("^[+-]?%d+%.?%d*$") then return tonumber(text) end
    local a = text:match('^"(.*)"$')
    if a ~= nil then return a end
    local b = text:match("^'(.*)'$")
    if b ~= nil then return b end
    return text
end

local function splitArgs(text)
    local out, current = {}, {}
    local depth, quote, escaped = 0, nil, false
    for i = 1, #text do
        local c = text:sub(i, i)
        if quote then
            current[#current + 1] = c
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == quote then
                quote = nil
            end
        else
            if c == "'" or c == '"' then
                quote = c
                current[#current + 1] = c
            elseif c == "(" or c == "[" or c == "{" then
                depth += 1
                current[#current + 1] = c
            elseif c == ")" or c == "]" or c == "}" then
                depth = math.max(0, depth - 1)
                current[#current + 1] = c
            elseif c == "," and depth == 0 then
                local v = trim(table.concat(current))
                if v ~= "" then out[#out + 1] = parseValue(v) end
                table.clear(current)
            else
                current[#current + 1] = c
            end
        end
    end
    local v = trim(table.concat(current))
    if v ~= "" then out[#out + 1] = parseValue(v) end
    return out
end

local function parseRemoteSnippet(snippet)
    snippet = trim(snippet)
    if snippet == "" then
        return nil, "empty snippet"
    end

    local method = snippet:find(":InvokeServer%s*%(") and "InvokeServer"
        or (snippet:find(":FireServer%s*%(") and "FireServer")
    if not method then
        return nil, "could not find FireServer or InvokeServer"
    end

    local callStart = snippet:find(":" .. method)
    local openParen = snippet:find("%(", callStart or 1)
    if not openParen then
        return nil, "malformed remote call"
    end

    local depth, quote, escaped, closeParen = 1, nil, false, nil
    for i = openParen + 1, #snippet do
        local c = snippet:sub(i, i)
        if quote then
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == quote then
                quote = nil
            end
        else
            if c == "'" or c == '"' then
                quote = c
            elseif c == "(" or c == "[" or c == "{" then
                depth += 1
            elseif c == ")" or c == "]" or c == "}" then
                depth -= 1
                if depth == 0 then
                    closeParen = i
                    break
                end
            end
        end
    end
    if not closeParen then
        return nil, "unbalanced remote call"
    end

    local before = trim(snippet:sub(1, callStart - 1))
    before = before:gsub(";", "\n")
    local remoteExpr = ""
    for line in before:gmatch("[^\n]+") do
        remoteExpr = trim(line)
    end

    if remoteExpr ~= "" and not remoteExpr:find("%.") then
        local escapedName = remoteExpr:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
        local assignment = snippet:match("local%s+" .. escapedName .. "%s*=%s*(.-)%s*$")
        if not assignment then
            assignment = snippet:match("^" .. escapedName .. "%s*=%s*(.-)%s*$")
        end
        if assignment then
            remoteExpr = trim(assignment)
        end
    end

    return {
        RemoteExpression = remoteExpr,
        Method = method,
        RemoteType = method == "InvokeServer" and "Function" or "Event",
        Args = splitArgs(snippet:sub(openParen + 1, closeParen - 1)),
    }
end

local function evalArg(v)
    if type(v) ~= "string" then return v end
    local fn = loadstring and loadstring("return " .. v)
    if fn then
        local ok, result = pcall(fn)
        if ok then return result end
    end
    return v
end

-- ============================================================
-- VISUAL TOKENS — reference proportions
-- ============================================================

local C = {
    Outer = Color3.fromRGB(18, 18, 18),
    Header = Color3.fromRGB(24, 24, 24),
    Sidebar = Color3.fromRGB(20, 20, 20),
    Content = Color3.fromRGB(17, 17, 17),
    Row = Color3.fromRGB(35, 35, 35),
    RowHover = Color3.fromRGB(40, 40, 40),
    Divider = Color3.fromRGB(54, 54, 54),
    Stroke = Color3.fromRGB(72, 72, 72),
    Accent = Color3.fromRGB(111, 168, 247),
    AccentDark = Color3.fromRGB(71, 113, 171),
    Text = Color3.fromRGB(235, 235, 235),
    Text2 = Color3.fromRGB(190, 190, 190),
    Text3 = Color3.fromRGB(130, 130, 130),
    ToggleOff = Color3.fromRGB(78, 78, 78),
    Knob = Color3.fromRGB(244, 244, 244),
}

local SIZE = {
    W = 532,
    H = 349,
    HeaderH = 39,
    SidebarW = 123,
    RowH = 33,
    Gap = 5,
}

-- ============================================================
-- GUILIB
-- ============================================================

function GUILIB.New(scriptName, config)
    local self = setmetatable({}, GUILIB_META)
    self.ScriptName = tostring(scriptName or "Script")
    self.Config = config or {}
    self.Modules = {}
    self.ModuleList = {}
    self.Categories = {}
    self.CategoryMap = {}
    self.Gui = nil
    self.Root = nil
    self.Sidebar = nil
    self.Content = nil
    self.Visible = false
    self.StatusText = "Ready"
    self.StatusLabel = nil
    self.CloseButton = nil
    self._connections = {}
    self._f7Conn = nil
    self._categoryButtonCache = {}
    self._activeCategory = nil
    return self
end

function GUILIB:_setStatus(text)
    self.StatusText = tostring(text or "")
    if self.StatusLabel then
        self.StatusLabel.Text = self.StatusText
    end
end

local function normalizeControl(moduleDef)
    local control = moduleDef.Control or moduleDef.Type or moduleDef.Kind or "Toggle"
    if type(control) == "string" then
        return { Type = control }
    end
    return control
end

function GUILIB:AddModule(moduleDef)
    if type(moduleDef) ~= "table" or not moduleDef.Category or not moduleDef.Name then
        warn("[Builder] AddModule: missing Category or Name")
        return false
    end

    local name = tostring(moduleDef.Name)
    if self.Modules[name] then
        self:RemoveModule(name)
    end

    local mod = {}
    for k, v in pairs(moduleDef) do
        mod[k] = v
    end

    mod.Name = name
    mod.Category = tostring(moduleDef.Category)
    mod.Control = normalizeControl(moduleDef)
    mod.Value = moduleDef.Value
    mod.Enabled = moduleDef.Enabled == true or moduleDef.Value == true
    mod.Options = moduleDef.Options or moduleDef.Values or {}
    mod.Min = tonumber(moduleDef.Min or (type(mod.Control) == "table" and mod.Control.Min) or 0) or 0
    mod.Max = tonumber(moduleDef.Max or (type(mod.Control) == "table" and mod.Control.Max) or 100) or 100
    mod.Step = tonumber(moduleDef.Step or (type(mod.Control) == "table" and mod.Control.Step) or 1) or 1
    mod._ParsedArgs = {}
    mod._connections = {}
    mod.UI = {}

    if moduleDef.Args then
        for i, v in ipairs(moduleDef.Args) do
            mod._ParsedArgs[i] = v
        end
    end

    if moduleDef.Remote then
        if typeof(moduleDef.Remote) == "Instance" and (moduleDef.Remote:IsA("RemoteEvent") or moduleDef.Remote:IsA("RemoteFunction")) then
            mod.Remote = moduleDef.Remote
        elseif type(moduleDef.Remote) == "string" then
            mod.Remote = resolveRemote(moduleDef.Remote)
            mod.RemoteExpression = moduleDef.Remote
        elseif type(moduleDef.Remote) == "table" then
            mod.Remote = moduleDef.Remote.Instance or mod.Remote
            mod.RemoteExpression = moduleDef.Remote.Path
            if not mod.Remote and mod.RemoteExpression then
                mod.Remote = resolveRemote(mod.RemoteExpression)
            end
        end
    elseif moduleDef.Snippet then
        local parsed, err = parseRemoteSnippet(moduleDef.Snippet)
        if parsed then
            mod.RemoteExpression = parsed.RemoteExpression
            mod.Remote = resolveRemote(parsed.RemoteExpression)
            mod._ParsedArgs = parsed.Args
            mod.RemoteMethod = parsed.Method
        else
            mod.ParseError = err
        end
    end

    self.Modules[name] = mod
    self.ModuleList[#self.ModuleList + 1] = mod
    self.CategoryMap[mod.Category] = self.CategoryMap[mod.Category] or {}
    self.CategoryMap[mod.Category][#self.CategoryMap[mod.Category] + 1] = mod

    local exists = false
    for _, cat in ipairs(self.Categories) do
        if cat == mod.Category then
            exists = true
            break
        end
    end
    if not exists then
        self.Categories[#self.Categories + 1] = mod.Category
    end

    if self.Gui then
        self:_refreshGuiData()
    end
    return mod
end

function GUILIB:RemoveModule(name)
    local mod = self.Modules[name]
    if not mod then return false end
    disconnectAll(mod._connections or {})
    if mod.UI and mod.UI.Container then
        mod.UI.Container:Destroy()
    end
    self.Modules[name] = nil
    for i, item in ipairs(self.ModuleList) do
        if item == mod then
            table.remove(self.ModuleList, i)
            break
        end
    end
    local list = self.CategoryMap[mod.Category]
    if list then
        for i, item in ipairs(list) do
            if item == mod then
                table.remove(list, i)
                break
            end
        end
        if #list == 0 then
            self.CategoryMap[mod.Category] = nil
            for i, cat in ipairs(self.Categories) do
                if cat == mod.Category then
                    table.remove(self.Categories, i)
                    break
                end
            end
        end
    end
    if self.Gui then self:_refreshGuiData() end
    return true
end

function GUILIB:AddModules(modules)
    for _, moduleDef in ipairs(modules or {}) do
        self:AddModule(moduleDef)
    end
    return self
end

function GUILIB:AddRemote(name, category, remote, options)
    options = options or {}
    options.Name = name
    options.Category = category or options.Category or "Autofarms"
    options.Remote = remote
    return self:AddModule(options)
end

function GUILIB:AddRemoteSpy(category, name, snippet, options)
    options = options or {}
    options.Name = name or options.Name or "Remote Spy"
    options.Category = category or options.Category or "Autofarms"
    options.Snippet = snippet
    return self:AddModule(options)
end

-- ============================================================
-- BUILD GUI
-- ============================================================

function GUILIB:_createScreenGui()
    local gui = make("ScreenGui", {
        Name = "ScriptBuilder_" .. self.ScriptName:gsub("%W", "_"),
        Parent = PlayerGui,
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    })
    return gui
end

function GUILIB:_destroyGui()
    disconnectAll(self._connections)
    for _, mod in ipairs(self.ModuleList) do
        disconnectAll(mod._connections or {})
        mod.UI = {}
    end
    if self.Gui then
        self.Gui:Destroy()
    end
    self.Gui, self.Root, self.Sidebar, self.Content = nil, nil, nil, nil
    self.StatusLabel, self.CloseButton = nil, nil
end

function GUILIB:_buildHeader()
    local header = make("Frame", {
        Parent = self.Root,
        Size = UDim2.new(1, 0, 0, SIZE.HeaderH),
        Position = UDim2.new(0, 0, 0, 0),
        BackgroundColor3 = C.Header,
        BorderSizePixel = 0,
    })
    addStroke(header, C.Stroke, 1, 0.2)

    local title = make("TextLabel", {
        Parent = header,
        Size = UDim2.new(1, -100, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        BackgroundTransparency = 1,
        Text = self.ScriptName,
        TextColor3 = C.Text2,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    })

    self.CloseButton = make("TextButton", {
        Parent = header,
        Size = UDim2.fromOffset(24, 24),
        Position = UDim2.new(1, -30, 0.5, -12),
        BackgroundTransparency = 1,
        Text = "×",
        TextColor3 = C.Text3,
        Font = Enum.Font.GothamBold,
        TextSize = 17,
        AutoButtonColor = false,
    })
    table.insert(self._connections, self.CloseButton.MouseButton1Click:Connect(function()
        self:Hide()
    end))

    self.StatusLabel = make("TextLabel", {
        Parent = header,
        Size = UDim2.fromOffset(180, 20),
        Position = UDim2.new(1, -215, 0.5, -10),
        BackgroundTransparency = 1,
        Text = self.StatusText,
        TextColor3 = C.Text3,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Right,
    })

    -- Header drag support
    local dragging = false
    local dragStart, startPos
    table.insert(self._connections, header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = self.Root.Position
        end
    end))
    table.insert(self._connections, UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            self.Root.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end))
    table.insert(self._connections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end))
end

function GUILIB:_buildSidebar()
    local sidebar = make("Frame", {
        Parent = self.Root,
        Size = UDim2.new(0, SIZE.SidebarW, 1, -SIZE.HeaderH),
        Position = UDim2.new(0, 0, 0, SIZE.HeaderH),
        BackgroundColor3 = C.Sidebar,
        BorderSizePixel = 0,
    })
    self.Sidebar = sidebar

    local layout = make("UIListLayout", {
        Parent = sidebar,
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
    make("UIPadding", {
        Parent = sidebar,
        PaddingTop = UDim.new(0, 7),
        PaddingLeft = UDim.new(0, 6),
        PaddingRight = UDim.new(0, 6),
        PaddingBottom = UDim.new(0, 6),
    })

    self._categoryButtonCache = {}
    for i, category in ipairs(self.Categories) do
        local button = make("TextButton", {
            Parent = sidebar,
            LayoutOrder = i,
            Size = UDim2.new(1, 0, 0, 31),
            BackgroundColor3 = C.Sidebar,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
        })
        addCorner(button, 4)

        local accent = make("Frame", {
            Parent = button,
            Size = UDim2.fromOffset(2, 17),
            Position = UDim2.new(0, 3, 0.5, -8.5),
            BackgroundColor3 = C.Accent,
            BorderSizePixel = 0,
            Visible = false,
        })
        addCorner(accent, 1)

        make("TextLabel", {
            Parent = button,
            Size = UDim2.new(1, -18, 1, 0),
            Position = UDim2.fromOffset(12, 0),
            BackgroundTransparency = 1,
            Text = category,
            TextColor3 = C.Text2,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
        })

        self._categoryButtonCache[category] = {Button = button, Accent = accent}
        table.insert(self._connections, button.MouseButton1Click:Connect(function()
            self:_showCategory(category)
        end))
    end
end

function GUILIB:_buildContent()
    local content = make("ScrollingFrame", {
        Parent = self.Root,
        Size = UDim2.new(1, -SIZE.SidebarW, 1, -SIZE.HeaderH),
        Position = UDim2.new(0, SIZE.SidebarW, 0, SIZE.HeaderH),
        BackgroundColor3 = C.Content,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = C.Stroke,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    })
    self.Content = content

    make("UIPadding", {
        Parent = content,
        PaddingTop = UDim.new(0, 7),
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
    })
    make("UIListLayout", {
        Parent = content,
        Padding = UDim.new(0, SIZE.Gap),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
end

function GUILIB:_makeSectionLabel(text)
    local label = make("TextLabel", {
        Parent = self.Content,
        Name = "SectionLabel",
        Size = UDim2.new(1, 0, 0, 17),
        BackgroundTransparency = 1,
        Text = tostring(text or "Settings"),
        TextColor3 = C.Text3,
        Font = Enum.Font.GothamMedium,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = -1000,
    })
    return label
end

function GUILIB:_updateToggleVisual(mod)
    local track = mod.UI.Track
    local knob = mod.UI.Knob
    if not track or not knob then return end
    local targetColor = mod.Enabled and C.Accent or C.ToggleOff
    TweenService:Create(track, TweenInfo.new(0.12), {BackgroundColor3 = targetColor}):Play()
    TweenService:Create(knob, TweenInfo.new(0.12), {
        Position = mod.Enabled and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8),
    }):Play()
end

function GUILIB:_buildToggle(mod, row)
    local track = make("Frame", {
        Parent = row,
        Size = UDim2.fromOffset(34, 18),
        Position = UDim2.new(1, -44, 0.5, -9),
        BackgroundColor3 = C.ToggleOff,
        BorderSizePixel = 0,
    })
    addCorner(track, 9)
    local knob = make("Frame", {
        Parent = track,
        Size = UDim2.fromOffset(16, 16),
        Position = UDim2.new(0, 2, 0.5, -8),
        BackgroundColor3 = C.Knob,
        BorderSizePixel = 0,
    })
    addCorner(knob, 8)
    mod.UI.Track = track
    mod.UI.Knob = knob
    mod.Enabled = mod.Enabled == true
    self:_updateToggleVisual(mod)

    local hit = make("TextButton", {
        Parent = row,
        Size = UDim2.new(0, 55, 1, 0),
        Position = UDim2.new(1, -60, 0, 0),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    })
    table.insert(mod._connections, hit.MouseButton1Click:Connect(function()
        mod.Enabled = not mod.Enabled
        mod.Value = mod.Enabled
        self:_updateToggleVisual(mod)
        self:_onModuleToggle(mod)
    end))
end

function GUILIB:_buildSelect(mod, row)
    local box = make("TextButton", {
        Parent = row,
        Size = UDim2.fromOffset(105, 22),
        Position = UDim2.new(1, -115, 0.5, -11),
        BackgroundColor3 = C.RowHover,
        BorderSizePixel = 0,
        Text = tostring(mod.Value or mod.Options[1] or "Select"),
        TextColor3 = C.Text2,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        AutoButtonColor = false,
    })
    addCorner(box, 4)
    addStroke(box, C.Divider, 1, 0)
    mod.UI.Select = box

    local conn = box.MouseButton1Click:Connect(function()
        local options = mod.Options
        if #options == 0 then return end
        local current = tostring(mod.Value)
        local idx = 1
        for i, v in ipairs(options) do
            if tostring(v) == current then
                idx = i
                break
            end
        end
        idx = idx % #options + 1
        mod.Value = options[idx]
        box.Text = tostring(mod.Value)
        self:_onModuleSelect(mod, mod.Value)
    end)
    table.insert(mod._connections, conn)
end

function GUILIB:_buildButton(mod, row)
    local button = make("TextButton", {
        Parent = row,
        Size = UDim2.fromOffset(48, 21),
        Position = UDim2.new(1, -58, 0.5, -10.5),
        BackgroundColor3 = C.Accent,
        BorderSizePixel = 0,
        Text = "Fire",
        TextColor3 = Color3.fromRGB(255, 255, 255),
        Font = Enum.Font.GothamMedium,
        TextSize = 9,
        AutoButtonColor = false,
    })
    addCorner(button, 4)
    mod.UI.Button = button
    local busy = false
    local conn = button.MouseButton1Click:Connect(function()
        if busy then return end
        busy = true
        button.Text = "..."
        self:_fireRemote(mod)
        task.delay(0.1, function()
            if button then button.Text = "Fire" end
            busy = false
        end)
    end)
    table.insert(mod._connections, conn)
end

function GUILIB:_buildSlider(mod, row)
    local track = make("Frame", {
        Parent = row,
        Size = UDim2.fromOffset(80, 6),
        Position = UDim2.new(1, -90, 0.5, -3),
        BackgroundColor3 = C.ToggleOff,
        BorderSizePixel = 0,
    })
    addCorner(track, 3)
    local fill = make("Frame", {
        Parent = track,
        Size = UDim2.new(0.5, 0, 1, 0),
        BackgroundColor3 = C.Accent,
        BorderSizePixel = 0,
    })
    addCorner(fill, 3)
    local knob = make("Frame", {
        Parent = track,
        Size = UDim2.fromOffset(12, 12),
        Position = UDim2.new(0.5, -6, 0.5, -6),
        BackgroundColor3 = C.Knob,
        BorderSizePixel = 0,
    })
    addCorner(knob, 6)
    mod.UI.Slider = track
    mod.UI.SliderFill = fill
    mod.UI.SliderKnob = knob

    local dragging = false
    local function update(x)
        local p = track.AbsolutePosition.X
        local s = track.AbsoluteSize.X
        if s <= 0 then return end
        local ratio = math.clamp((x - p) / s, 0, 1)
        local raw = mod.Min + (mod.Max - mod.Min) * ratio
        local value = math.floor(raw / mod.Step + 0.5) * mod.Step
        value = math.clamp(value, mod.Min, mod.Max)
        mod.Value = value
        local r = (value - mod.Min) / math.max(1e-9, mod.Max - mod.Min)
        fill.Size = UDim2.new(r, 0, 1, 0)
        knob.Position = UDim2.new(r, -6, 0.5, -6)
        self:_onModuleSlider(mod, value)
    end

    local c1 = track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            update(input.Position.X)
        end
    end)
    local c2 = UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            update(input.Position.X)
        end
    end)
    local c3 = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    table.insert(mod._connections, c1)
    table.insert(mod._connections, c2)
    table.insert(mod._connections, c3)
end

function GUILIB:_buildInput(mod, row)
    local box = make("TextBox", {
        Parent = row,
        Size = UDim2.fromOffset(104, 22),
        Position = UDim2.new(1, -114, 0.5, -11),
        BackgroundColor3 = C.RowHover,
        BorderSizePixel = 0,
        Text = tostring(mod.Value or ""),
        PlaceholderText = "Enter value...",
        PlaceholderColor3 = C.Text3,
        TextColor3 = C.Text2,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    addCorner(box, 4)
    addStroke(box, C.Divider, 1, 0)
    mod.UI.Input = box
    table.insert(mod._connections, box.FocusLost:Connect(function(enterPressed)
        if enterPressed then
            mod.Value = box.Text
            self:_onModuleInput(mod, box.Text)
        end
    end))
end

function GUILIB:_buildModule(mod, order)
    local row = make("Frame", {
        Parent = self.Content,
        Name = "Module_" .. mod.Name:gsub("%W", "_"),
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, SIZE.RowH),
        BackgroundColor3 = C.Row,
        BorderSizePixel = 0,
    })
    addCorner(row, 4)

    local label = make("TextLabel", {
        Parent = row,
        Size = UDim2.new(1, -125, 1, 0),
        Position = UDim2.fromOffset(10, 0),
        BackgroundTransparency = 1,
        Text = mod.Name,
        TextColor3 = C.Text2,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    })

    mod.UI.Container = row
    mod.UI.Label = label
    disconnectAll(mod._connections)
    mod._connections = {}

    local controlType = type(mod.Control) == "table" and mod.Control.Type or mod.Control
    controlType = tostring(controlType or "Toggle"):lower()
    if controlType == "toggle" then
        self:_buildToggle(mod, row)
    elseif controlType == "select" or controlType == "dropdown" or controlType == "choice" then
        self:_buildSelect(mod, row)
    elseif controlType == "button" then
        self:_buildButton(mod, row)
    elseif controlType == "slider" then
        self:_buildSlider(mod, row)
    elseif controlType == "input" or controlType == "textbox" then
        self:_buildInput(mod, row)
    else
        self:_buildToggle(mod, row)
    end
end

function GUILIB:_showCategory(category)
    self._activeCategory = category
    for cat, refs in pairs(self._categoryButtonCache) do
        local active = cat == category
        refs.Accent.Visible = active
        refs.Button.BackgroundColor3 = active and C.Row or C.Sidebar
    end

    for _, child in ipairs(self.Content:GetChildren()) do
        if child.Name == "SectionLabel" or child.Name:match("^Module_") then
            child:Destroy()
        end
    end

    local labelText = (self.Config.SectionLabels and self.Config.SectionLabels[category]) or "Settings"
    local label = self:_makeSectionLabel(labelText)
    label.LayoutOrder = 0

    local modules = self.CategoryMap[category] or {}
    for i, mod in ipairs(modules) do
        self:_buildModule(mod, i)
    end
    self:_setStatus("Category: " .. tostring(category))
end

function GUILIB:_refreshGuiData()
    self:_buildEntireGuiContent()
end

function GUILIB:_buildEntireGuiContent()
    if not self.Gui then return end
    self:_destroyGui()
    self.Gui = self:_createScreenGui()

    self.Root = make("Frame", {
        Parent = self.Gui,
        Size = UDim2.fromOffset(SIZE.W, SIZE.H),
        Position = UDim2.new(0.5, -SIZE.W / 2, 0.5, -SIZE.H / 2),
        BackgroundColor3 = C.Outer,
        BorderSizePixel = 0,
    })
    addCorner(self.Root, 5)
    addStroke(self.Root, C.Stroke, 1, 0)

    self:_buildHeader()
    self:_buildSidebar()
    self:_buildContent()

    if self._activeCategory and self.CategoryMap[self._activeCategory] then
        self:_showCategory(self._activeCategory)
    elseif self.Categories[1] then
        self:_showCategory(self.Categories[1])
    end
end

function GUILIB:BuildGui()
    if self.Gui then
        self:_destroyGui()
    end

    self.Gui = self:_createScreenGui()
    self.Root = make("Frame", {
        Parent = self.Gui,
        Size = UDim2.fromOffset(SIZE.W, SIZE.H),
        Position = UDim2.new(0.5, -SIZE.W / 2, 0.5, -SIZE.H / 2),
        BackgroundColor3 = C.Outer,
        BorderSizePixel = 0,
    })
    addCorner(self.Root, 5)
    addStroke(self.Root, C.Stroke, 1, 0)
    self:_buildHeader()
    self:_buildSidebar()
    self:_buildContent()

    if self.Categories[1] then
        self:_showCategory(self._activeCategory or self.Categories[1])
    else
        self:_makeSectionLabel("Settings")
    end

    self.Gui.Enabled = self.Visible
    return self.Gui
end

function GUILIB:_onModuleToggle(mod)
    if mod.Enabled then
        self:_fireRemote(mod)
    end
end

function GUILIB:_onModuleSelect(mod, value)
    local idx = mod.Control.Argument
    if idx and idx >= 1 then
        mod._ParsedArgs[idx] = value
    end
    self:_fireRemote(mod, value)
end

function GUILIB:_onModuleSlider(mod, value)
    local idx = mod.Control.Argument
    if idx and idx >= 1 then mod._ParsedArgs[idx] = value end
    self:_fireRemote(mod, value)
end

function GUILIB:_onModuleInput(mod, value)
    local idx = mod.Control.Argument
    if idx and idx >= 1 then mod._ParsedArgs[idx] = value end
    self:_fireRemote(mod, value)
end

function GUILIB:_buildFireArgs(mod, extraArg)
    local args = {}
    local maxIdx = 0
    for i, v in ipairs(mod._ParsedArgs or {}) do
        args[i] = (v == NIL) and nil or v
        maxIdx = i
    end
    local idx = mod.Control and mod.Control.Argument
    if idx and idx >= 1 and extraArg ~= nil then
        args[idx] = extraArg
        maxIdx = math.max(maxIdx, idx)
    elseif extraArg ~= nil then
        args[#args + 1] = extraArg
        maxIdx = #args
    end
    return args, maxIdx
end

function GUILIB:_fireRemote(mod, extraArg)
    if not mod or not mod.Remote then
        self:_setStatus((mod and mod.Name or "Module") .. ": Remote not resolved")
        return false, "Remote not resolved"
    end

    local args, n = self:_buildFireArgs(mod, extraArg)
    local callArgs = table.create(n)
    for i = 1, n do
        callArgs[i] = evalArg(args[i])
    end

    task.spawn(function()
        local ok, result = pcall(function()
            if mod.Remote:IsA("RemoteFunction") then
                return mod.Remote:InvokeServer(table.unpack(callArgs, 1, n))
            elseif mod.Remote:IsA("RemoteEvent") then
                return mod.Remote:FireServer(table.unpack(callArgs, 1, n))
            end
            error("Unsupported remote instance")
        end)
        if ok then
            self:_setStatus(mod.Name .. ": OK")
        else
            self:_setStatus(mod.Name .. ": " .. tostring(result))
        end
    end)
    return true
end

-- ============================================================
-- PUBLIC LIFECYCLE
-- ============================================================

function GUILIB:Show()
    if not self.Gui then self:BuildGui() end
    self.Gui.Enabled = true
    self.Root.BackgroundTransparency = 0
    self.Visible = true
end

function GUILIB:Hide()
    if self.Gui then self.Gui.Enabled = false end
    self.Visible = false
end

function GUILIB:Toggle()
    if self.Visible then self:Hide() else self:Show() end
end

function GUILIB:Run()
    self:Show()
    if self._f7Conn then self._f7Conn:Disconnect() end
    self._f7Conn = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.F7 then
            self:Toggle()
        end
    end)
end

-- ============================================================
-- BUILDER WRAPPER
-- ============================================================

function Builder.New(scriptName, config)
    local self = setmetatable({}, BUILDER_META)
    self.GuiLib = GUILIB.New(scriptName, config)
    return self
end

function Builder:AddModule(def) return self.GuiLib:AddModule(def) end
function Builder:RemoveModule(name) return self.GuiLib:RemoveModule(name) end
function Builder:AddRemote(...) return self.GuiLib:AddRemote(...) end
function Builder:AddRemoteSpy(...) return self.GuiLib:AddRemoteSpy(...) end
function Builder:AddModules(modules) return self.GuiLib:AddModules(modules) end
function Builder:BuildGui() return self.GuiLib:BuildGui() end
function Builder:Run() return self.GuiLib:Run() end
function Builder:Show() return self.GuiLib:Show() end
function Builder:Hide() return self.GuiLib:Hide() end
function Builder:Toggle() return self.GuiLib:Toggle() end
function Builder:GetModule(name) return self.GuiLib.Modules[name] end
function Builder:GetAllModules() return self.GuiLib.Modules end
function Builder:SetModuleValue(name, value)
    local mod = self.GuiLib.Modules[name]
    if not mod then return false end
    mod.Value = value
    mod.Enabled = value == true
    if mod.UI.Track then self.GuiLib:_updateToggleVisual(mod) end
    if mod.UI.Select then mod.UI.Select.Text = tostring(value) end
    if mod.UI.Input then mod.UI.Input.Text = tostring(value or "") end
    return true
end
function Builder:FireModule(name, ...)
    local mod = self.GuiLib.Modules[name]
    if not mod then return false end
    return self.GuiLib:_fireRemote(mod, ...)
end
function Builder:Status(text)
    self.GuiLib:_setStatus(text)
end

function Builder.Init(scriptName, config)
    local instance = Builder.New(scriptName, config)
    local globalName = "_SB_" .. tostring(scriptName or "Script"):gsub("%W", "_")
    _G[globalName] = instance
    return instance, globalName
end

_G.Builder = Builder
return Builder
