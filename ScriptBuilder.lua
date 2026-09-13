--[[
    ScriptBuilder.lua â€” Refactored
    Repository: https://github.com/8Blooder8/Hub
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local UserInputService    = game:GetService("UserInputService")
local TweenService        = game:GetService("TweenService")

local Player    = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

Builder = {}
local BUILDER_META = {__index = Builder}

local GUILIB = {}
local GUILIB_META = {__index = GUILIB}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function resolvePath(path)
    if not path or path == "" then return nil end
    if path:match(":") then return nil end
    local segments = {}
    for part in string.gmatch(path, "[^.]+") do
        segments[#segments + 1] = part
    end
    if #segments == 0 then return nil end

    local serviceNames = {
        Players = "Players",
        ReplicatedStorage = "ReplicatedStorage",
        Workspace = "Workspace",
        StarterGui = "StarterGui",
        CoreGui = "CoreGui",
        Lighting = "Lighting",
    }

    local root = game:GetService(serviceNames[segments[1]]) or game:FindFirstChild(segments[1])
    if not root then return nil end

    local node = root
    for i = 2, #segments do
        node = node:FindFirstChild(segments[i])
        if not node then return nil end
    end
    return node
end

local function resolveRemote(expression)
    if not expression or expression == "" then return nil end
    local path = expression:gsub("^%s+", ""):gsub("%s+$", "")
    if path == "" then return nil end
    if path:match(":%s*(FireServer|InvokeServer)") then return nil end

    -- Try direct evaluation (e.g. game:GetService("...").Remotes.X)
    if path:sub(1, 5) == "game:" or path:sub(1, 5) == "game." then
        local ok, result = pcall(function()
            local fn = loadstring("return " .. path)
            if fn then return fn() end
        end)
        if ok and result and typeof(result) == "Instance" then
            return result
        end
    end

    local ok2, pathResult = pcall(resolvePath, path)
    if ok2 and pathResult then return pathResult end
    return nil
end

local function make(className, props)
    local obj = Instance.new(className)
    if props then
        for k, v in pairs(props) do
            if k ~= "Parent" then
                obj[k] = v
            end
        end
    end
    if props and props.Parent then
        obj.Parent = props.Parent
    end
    return obj
end

local function corner(parent, radius)
    return make("UICorner", {
        CornerRadius = UDim.new(0, radius or 4),
        Parent = parent,
    })
end

local function stroke(parent, color, thickness)
    return make("UIStroke", {
        Color = color or Color3.fromRGB(34, 34, 34),
        Thickness = thickness or 1,
        Parent = parent,
    })
end

local function tweenProperty(obj, props, duration)
    local tween = TweenService:Create(obj, TweenInfo.new(duration or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
    tween:Play()
    return tween
end

-- ============================================================
-- COLOR PALETTE (design tokens)
-- ============================================================

local COLORS = {
    Window        = Color3.fromRGB(26, 26, 26),   -- #1A1A1A
    Header        = Color3.fromRGB(26, 26, 26),   -- #1A1A1A
    Sidebar       = Color3.fromRGB(26, 26, 26),   -- #1A1A1A
    Content       = Color3.fromRGB(20, 20, 16),   -- #141410
    Row           = Color3.fromRGB(34, 34, 34),    -- #222222
    Divider       = Color3.fromRGB(34, 34, 34),    -- #222222
    ToggleOn      = Color3.fromRGB(104, 159, 251), -- #689FFB
    Knob          = Color3.fromRGB(247, 255, 255), -- #F7FFFF
    TitleText     = Color3.fromRGB(205, 205, 205), -- #CDCDCD
    ModuleText    = Color3.fromRGB(192, 192, 192), -- #C0C0C0
    SidebarText   = Color3.fromRGB(166, 166, 166), -- #A6A6A6
    SecondaryText = Color3.fromRGB(142, 142, 142), -- #8E8E8E
    Icon          = Color3.fromRGB(110, 167, 232), -- #6EA7E8
    ButtonBg      = Color3.fromRGB(104, 159, 251), -- #689FFB
    ButtonText    = Color3.fromRGB(245, 245, 245), -- #F5F5F5
    InputBg       = Color3.fromRGB(27, 27, 27),    -- #1B1B1B
    InputBorder   = Color3.fromRGB(42, 42, 42),    -- #2A2A2A
    InputText     = Color3.fromRGB(189, 189, 189), -- #BDBDBD
}

-- ============================================================
-- SLICE PARSER â€” Cobalt snippet -> structured data
-- ============================================================

local function trim(s)
    return s:match("^%s*(.-)%s*$") or ""
end

-- Parse a comma-separated argument string, respecting nesting of (), {}, []
-- and string literals. Returns array of trimmed argument strings.
local function parseArgumentList(argStr)
    local args = {}
    local depth = 0
    local current = {}
    local inString = nil
    local i = 1

    while i <= #argStr do
        local c = argStr:sub(i, i)

        if inString then
            table.insert(current, c)
            if c == "\\" and i < #argStr then
                i = i + 1
                table.insert(current, argStr:sub(i, i))
            elseif c == inString then
                inString = nil
            end
        else
            if c == '"' or c == "'" then
                inString = c
                table.insert(current, c)
            elseif c == "(" or c == "[" or c == "{" then
                depth = depth + 1
                table.insert(current, c)
            elseif c == ")" or c == "]" or c == "}" then
                depth = math.max(depth - 1, 0)
                table.insert(current, c)
            elseif c == "," and depth == 0 then
                local arg = trim(table.concat(current))
                if arg ~= "" then
                    table.insert(args, arg)
                end
                current = {}
            else
                table.insert(current, c)
            end
        end
        i = i + 1
    end

    local last = trim(table.concat(current))
    if last ~= "" then
        table.insert(args, last)
    end

    return args
end

-- Try to convert a string argument to a Lua value.
-- Simple literals: string, number, boolean, nil
-- Complex expressions: return as-is (evaluated later at fire time)
local function tryParseValue(str)
    str = trim(str)
    if str == "nil" then return nil end
    if str == "true" then return true end
    if str == "false" then return false end
    if str:match("^[+-]?%d+%.?%d*$") then
        return tonumber(str)
    end
    -- String literal
    local s1, s2 = str:match('^"(.*)"$'), str:match("^'(.*)'$")
    if s1 then return s1 end
    if s2 then return s2 end
    -- Keep expression as string for later evaluation
    return str
end

-- Parse a Cobalt snippet and extract structured remote data.
-- Returns: { RemoteExpression, Method, RemoteType, Args }
local function parseRemoteSnippet(snippet)
    local result = {
        RemoteExpression = "",
        Method = "",
        RemoteType = "Event",
        Args = {},
    }

    if not snippet or snippet == "" then
        return result
    end

    local clean = trim(snippet)

    -- Find method call: :FireServer( or :InvokeServer(
    local methodName, parenStart
    local m = clean:match(":(FireServer|InvokeServer)%(")
    if m then
        methodName = m
        parenStart = clean:find(":" .. m .. "%(")
        if parenStart then
            parenStart = parenStart + #m + 2  -- position of the opening paren
        end
    end

    if not methodName or not parenStart then
        return result
    end

    result.Method = methodName
    result.RemoteType = (methodName == "InvokeServer") and "Function" or "Event"

    -- Find the closing parenthesis for this call
    local depth = 1
    local j = parenStart + 1
    while j <= #clean and depth > 0 do
        local c = clean:sub(j, j)
        if c == "(" or c == "[" or c == "{" then
            depth = depth + 1
        elseif c == ")" or c == "]" or c == "}" then
            depth = depth - 1
        elseif c == '"' or c == "'" then
            local esc = c
            j = j + 1
            while j <= #clean do
                local cc = clean:sub(j, j)
                if cc == "\\" then
                    j = j + 1
                elseif cc == esc then
                    break
                end
                j = j + 1
            end
        end
        j = j + 1
    end

    -- Extract the argument string between ( and )
    local argStr = clean:sub(parenStart + 1, j - 2)
    local rawArgs = parseArgumentList(argStr)

    -- Convert each argument
    for _, raw in ipairs(rawArgs) do
        local val = tryParseValue(raw)
        table.insert(result.Args, val)
    end

    -- Find the object expression before the colon
    -- parenStart is position of (, colon is at parenStart - #methodName - 1
    local colonPos = parenStart - #methodName - 1
    if colonPos and colonPos > 0 then
        local beforeColon = clean:sub(1, colonPos - 1)
        local objExpr = trim(beforeColon)

        -- If objExpr is a simple variable (e.g. "Event"), try to find its assignment
        if objExpr and not objExpr:match("%.") then
            -- Search for assignment pattern: local/varName = expression
            local assignmentPattern = "[%a_][%w_]*%s*%=%s*" .. objExpr .. "%s*"
            -- Try to find "local X = <expr>" or "X = <expr>" where X is our var
            local varName = objExpr
            -- Pattern for: local VarName = expression
            local locPattern = "local%s+" .. varName .. "%s*=%s*(.-)%s*$"
            -- Pattern for: VarName = expression (end of line)
            local eqPattern = "^%s*" .. varName .. "%s*=%s*(.-)%s*$"

            for line in clean:gmatch("[^\n]+") do
                local lineTrimmed = line:gsub("%s+$", "")
                local locMatch = lineTrimmed:match("^%s*local%s+" .. varName .. "%s*=%s*(.-)%s*$")
                if locMatch then
                    objExpr = trim(locMatch)
                    break
                end
                local eqMatch = lineTrimmed:match("^" .. varName .. "%s*=%s*(.-)%s*$")
                if eqMatch then
                    objExpr = trim(eqMatch)
                    break
                end
            end
        end

        result.RemoteExpression = objExpr or ""
    end

    return result
end

-- ============================================================
-- GUILIB CLASS
-- ============================================================

function GUILIB.New(scriptName, config)
    local self = setmetatable({}, GUILIB_META)

    self.ScriptName = scriptName or "Script"
    self.Config     = config or {}

    -- Data model: Modules is a MAP, ModuleList is an ordered ARRAY
    self.Modules    = {}          -- name -> module object
    self.ModuleList = {}          -- ordered array of module objects
    self.Categories = {}          -- ordered array of category names
    self.CategoryMap = {}         -- category -> ordered array of MODULE OBJECTS

    self.Gui        = nil
    self.Root       = nil
    self.Sidebar    = nil
    self.Content    = nil
    self.Visible    = false
    self.StatusText = "Ready"

    -- UI references
    self.StatusLabel    = nil
    self.CloseButton    = nil
    self._closeConn     = {}

    return self
end

-- Centralized status update
function GUILIB:_setStatus(text)
    self.StatusText = text
    if self.StatusLabel then
        self.StatusLabel.Text = text
    end
end

-- ============================================================
-- ADD MODULE (core registration)
-- ============================================================

function GUILIB:AddModule(moduleDef)
    if not moduleDef or not moduleDef.Category or not moduleDef.Name then
        warn("[Builder] AddModule: missing Category or Name")
        return false, "Missing Category or Name"
    end

    local category = moduleDef.Category
    local name     = moduleDef.Name

    -- Duplicate name check
    if self.Modules[name] then
        return false, "Module already exists: " .. name
    end

    -- Setup category if new
    if not self.CategoryMap[category] then
        self.Categories[#self.Categories + 1] = category
        self.CategoryMap[category] = {}
    end
    self.CategoryMap[category][#self.CategoryMap[category] + 1] = moduleDef  -- store object, not name

    -- Determine control type and defaults
    local controlType = moduleDef.Control and moduleDef.Control.Type or "toggle"
    local defaultVal = false
    local minVal, maxVal, stepVal = 0, 100, 1

    if moduleDef.Control then
        if controlType == "toggle" then
            defaultVal = (moduleDef.Control.Default ~= nil) and moduleDef.Control.Default or false
        elseif controlType == "slider" then
            defaultVal = moduleDef.Control.Default or 0
            minVal = moduleDef.Control.Min or 0
            maxVal = moduleDef.Control.Max or 100
            stepVal = moduleDef.Control.Step or 1
        elseif controlType == "input" then
            defaultVal = moduleDef.Control.Default or ""
        end
    end

    -- Resolve remote if present
    local remoteRef = nil
    local remoteType = "Event"
    local remoteArgs = {}
    if moduleDef.Remote then
        remoteType = moduleDef.Remote.Type or "Event"
        remoteRef = resolveRemote(moduleDef.Remote.Path)
        if moduleDef.Remote.Args then
            remoteArgs = moduleDef.Remote.Args
        end
    end

    local mod = {
        Category      = category,
        Name          = name,
        ControlType   = controlType,
        Default       = defaultVal,
        Min           = minVal,
        Max           = maxVal,
        Step          = stepVal,
        Remote        = remoteRef,
        RemoteType    = remoteType,
        RemoteArgs    = remoteArgs,
        Value         = defaultVal,
        Enabled       = false,
        UI            = {},
        SliderValue   = defaultVal,
        _connections  = {},
    }

    self.Modules[name] = mod
    table.insert(self.ModuleList, mod)

    -- If GUI already built, dynamically add UI
    if self.Content and self._sidebarBuilt then
        self:_addModuleUIDynamic(mod)
    end

    return true
end

-- ============================================================
-- ADD REMOTE â€” new public API
-- ============================================================

function GUILIB:AddRemote(category, name, cobaltSnippet, controlType, controlConfig)
    -- Validate inputs
    if not category or category == "" then
        return false, "category cannot be nil or empty"
    end
    if not name or name == "" then
        return false, "name cannot be nil or empty"
    end
    if not cobaltSnippet or cobaltSnippet == "" then
        return false, "snippet cannot be nil or empty"
    end

    local validControlTypes = {button = true, toggle = true, slider = true, input = true}
    controlType = controlType or "button"
    if not validControlTypes[controlType] then
        return false, "invalid controlType: " .. tostring(controlType)
    end

    -- Parse the Cobalt snippet
    local parsed = parseRemoteSnippet(cobaltSnippet)
    if parsed.RemoteExpression == "" then
        return false, "could not parse remote expression from snippet"
    end

    -- Resolve the remote expression
    local remoteRef = resolveRemote(parsed.RemoteExpression)

    -- Build control config table
    local ctrlTbl = { Type = controlType }
    if controlConfig then
        for k, v in pairs(controlConfig) do
            ctrlTbl[k] = v
        end
    end

    -- Validate slider config
    if controlType == "slider" then
        ctrlTbl.Min = ctrlTbl.Min or 0
        ctrlTbl.Max = ctrlTbl.Max or 100
        ctrlTbl.Step = ctrlTbl.Step or 1
        if ctrlTbl.Min and ctrlTbl.Max and ctrlTbl.Min > ctrlTbl.Max then
            return false, "slider Min > Max"
        end
        if ctrlTbl.Argument and ctrlTbl.Argument < 1 then
            return false, "slider Argument must be >= 1"
        end
        ctrlTbl.Default = ctrlTbl.Default or ctrlTbl.Min or 0
    end

    local modDef = {
        Category = category,
        Name     = name,
        Control  = ctrlTbl,
        Remote   = {
            Type = parsed.RemoteType,
            Path = parsed.RemoteExpression,
            Args = parsed.Args,
        },
    }

    -- Store parsed args for dynamic modification (input/slider)
    modDef._ParsedArgs = parsed.Args
    modDef._RemoteType = parsed.RemoteType
    modDef._RemoteMethod = parsed.Method

    return self:AddModule(modDef)
end

-- ============================================================
-- ADD REMOTE SPY â€” backward compatibility layer
-- ============================================================

function GUILIB:AddRemoteSpy(category, name, remotePath, arg1, controlType, defaultVal)
    local ref = resolveRemote(remotePath)
    local remoteType = "Event"
    if ref then
        if ref:IsA("RemoteFunction") then
            remoteType = "Function"
        elseif ref:IsA("RemoteEvent") then
            remoteType = "Event"
        end
    end

    local control = controlType or "toggle"
    local ctrlTbl = { Type = control }
    if control == "slider" then
        ctrlTbl.Default = defaultVal or 0
        ctrlTbl.Min = 0
        ctrlTbl.Max = 100
        ctrlTbl.Step = 1
    else
        ctrlTbl.Default = (defaultVal ~= nil) and defaultVal or (control == "input" and "" or false)
    end

    local modDef = {
        Category = category,
        Name     = name,
        Control  = ctrlTbl,
    }

    if remotePath and remotePath ~= "" then
        modDef.Remote = {
            Type  = remoteType,
            Path  = remotePath,
            Args  = arg1 and {arg1} or {},
        }
    end

    return self:AddModule(modDef)
end

-- ============================================================
-- ADD MODULES (batch)
-- ============================================================

function GUILIB:AddModules(modules)
    for _, mod in ipairs(modules) do
        self:AddModule(mod)
    end
end

-- ============================================================
-- MODULE UI â€” static build (called during BuildGui)
-- ============================================================

function GUILIB:_buildModuleUI(mod)
    if not self.Content then return end

    local controlType = mod.ControlType

    -- Create container
    local container = make("Frame", {
        BackgroundColor3 = COLORS.Row,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 27),
        LayoutOrder = mod._layoutOrder or 1,
        Visible = false,
    })
    corner(container, 4)

    -- Name label
    local label = make("TextLabel", {
        Parent = container,
        BackgroundTransparency = 1,
        Text = mod.Name,
        TextColor3 = COLORS.ModuleText,
        Font = Enum.Font.GothamMedium,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(6, 0),
        Size = UDim2.new(1, -120, 1, 0),
    })

    mod.UI.Container = container
    mod.UI.Label = label

    -- Build control based on type
    if controlType == "toggle" then
        self:_buildToggle(mod, container)
    elseif controlType == "button" then
        self:_buildButton(mod, container)
    elseif controlType == "slider" then
        self:_buildSlider(mod, container)
    elseif controlType == "input" then
        self:_buildInput(mod, container)
    end
end

-- Dynamic add after Run() â€” creates UI and adds to visible content
function GUILIB:_addModuleUIDynamic(mod)
    if not self.Content then return end

    -- Set layout order
    mod._layoutOrder = #self.ModuleList

    -- Build the UI
    self:_buildModuleUI(mod)

    -- Add to category map (it was already added to CategoryMap in AddModule)
    -- Make it visible if its category is active
    local activeCategory = self._activeCategory
    if activeCategory and mod.Category == activeCategory then
        self:_refreshVisibleModules()
    end

    -- Update sidebar counters
    self:_refreshSidebar()
end

-- ============================================================
-- CONTROL BUILDERS
-- ============================================================

function GUILIB:_buildToggle(mod, container)
    local track = make("TextButton", {
        Parent = container,
        BackgroundColor3 = mod.Enabled and COLORS.ToggleOn or COLORS.Divider,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(36, 18),
        Position = UDim2.new(1, -46, 0.5, -9),
        Text = mod.Enabled and "ON" or "OFF",
        TextColor3 = COLORS.Knob,
        Font = Enum.Font.GothamMedium,
        TextSize = 8,
        AutoButtonColor = false,
    })
    corner(track, 9)

    local knob = make("Frame", {
        Parent = track,
        BackgroundColor3 = COLORS.Knob,
        BorderSizePixel = 0,
        Size = UDim2.new(0, 11, 0, 11),
        Position = mod.Enabled and UDim2.new(1, -13, 0.5, -5.5) or UDim2.new(0, 1, 0.5, -5.5),
    })
    corner(knob, 9)

    mod.UI.Track = track
    mod.UI.Knob = knob

    local conn = track.MouseButton1Click:Connect(function()
        mod.Enabled = not mod.Enabled
        mod.Value = mod.Enabled
        self:_updateToggleVisual(mod)
        self:_onModuleToggle(mod)
    end)
    table.insert(mod._connections, conn)

    self:_updateToggleVisual(mod)
end

function GUILIB:_updateToggleVisual(mod)
    if not mod.UI.Track then return end
    local on = mod.Enabled
    mod.UI.Track.Text = on and "ON" or "OFF"
    mod.UI.Track.BackgroundColor3 = on and COLORS.ToggleOn or COLORS.Divider
    if mod.UI.Knob then
        mod.UI.Knob.Position = on and UDim2.new(1, -13, 0.5, -5.5) or UDim2.new(0, 1, 0.5, -5.5)
    end
end

function GUILIB:_buildButton(mod, container)
    local btn = make("TextButton", {
        Parent = container,
        BackgroundColor3 = COLORS.ButtonBg,
        BorderSizePixel = 0,
        Text = "Fire",
        TextColor3 = COLORS.ButtonText,
        Font = Enum.Font.GothamMedium,
        TextSize = 8,
        Size = UDim2.fromOffset(44, 18),
        Position = UDim2.new(1, -54, 0.5, -9),
        AutoButtonColor = false,
    })
    corner(btn, 4)

    local busy = false
    local conn = btn.MouseButton1Click:Connect(function()
        if busy then return end
        busy = true
        btn.Text = "..."
        self:_fireRemote(mod)
        btn.Text = "Fire"
        busy = false
    end)
    table.insert(mod._connections, conn)

    mod.UI.Button = btn
end

function GUILIB:_buildSlider(mod, container)
    local sliderFrame = make("Frame", {
        Parent = container,
        BackgroundColor3 = COLORS.InputBg,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(90, 6),
        Position = UDim2.new(1, -140, 0.5, -3),
    })
    corner(sliderFrame, 3)

    local fill = make("Frame", {
        Parent = sliderFrame,
        BackgroundColor3 = COLORS.ToggleOn,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(40, 6),
    })
    corner(fill, 3)

    local knob = make("Frame", {
        Parent = sliderFrame,
        BackgroundColor3 = COLORS.Knob,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(11, 11),
        Position = UDim2.fromOffset(33, -2),
    })
    corner(knob, 5)

    local valueLabel = make("TextLabel", {
        Parent = container,
        BackgroundTransparency = 1,
        Text = tostring(mod.Value),
        TextColor3 = COLORS.SecondaryText,
        Font = Enum.Font.Gotham,
        TextSize = 8,
        Position = UDim2.fromOffset(10, 10),
        Size = UDim2.new(1, -120, 0, 10),
    })

    mod.UI.SliderFrame = sliderFrame
    mod.UI.SliderFill  = fill
    mod.UI.SliderKnob  = knob
    mod.UI.SliderValue = valueLabel
    mod.SliderValue    = mod.Value

    local dragging = false
    local UIS = UserInputService

    local function clampNum(v, lo, hi)
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end

    local function updateSlider(inputX)
        local absPos = sliderFrame.AbsolutePosition.X
        local absSize = sliderFrame.AbsoluteSize.X
        if absSize <= 0 then return end
        local relative = clampNum((inputX - absPos) / absSize, 0, 1)
        local raw = mod.Min + (mod.Max - mod.Min) * relative
        local val = math.floor(raw / mod.Step) * mod.Step
        val = math.floor(val * 100 + 0.5) / 100
        val = clampNum(val, mod.Min, mod.Max)
        mod.Value = val
        mod.SliderValue = val

        local px = relative * absSize
        fill.Size = UDim2.fromOffset(math.max(px, 4), 6)
        knob.Position = UDim2.fromOffset(math.max(px - 5, 0), -2)
        valueLabel.Text = tostring(val)

        -- If this slider controls a specific argument index, update mod._ParsedArgs
        local argIdx = mod.Control.Argument
        if argIdx and argIdx >= 1 and mod._ParsedArgs and mod._ParsedArgs[argIdx] ~= nil then
            mod._ParsedArgs[argIdx] = val
        end
    end

    local conn1 = sliderFrame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            updateSlider(input.Position.X)
        end
    end)
    table.insert(mod._connections, conn1)

    local conn2 = UIS.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            updateSlider(input.Position.X)
        end
    end)
    table.insert(mod._connections, conn2)

    local conn3 = UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if dragging then
                dragging = false
                self:_onModuleSlider(mod, mod.SliderValue)
            end
        end
    end)
    table.insert(mod._connections, conn3)

    -- Initial position
    task.defer(function()
        if not sliderFrame or not sliderFrame.AbsoluteSize then return end
        local absSize = sliderFrame.AbsoluteSize.X
        if absSize and absSize > 0 and mod.Max > mod.Min then
            local ratio = clampNum((mod.Value - mod.Min) / (mod.Max - mod.Min), 0, 1)
            local px = ratio * absSize
            fill.Size = UDim2.fromOffset(math.max(px, 4), 6)
            knob.Position = UDim2.fromOffset(math.max(px - 5, 0), -2)
            valueLabel.Text = tostring(mod.Value)
        end
    end)
end

function GUILIB:_buildInput(mod, container)
    local inputBox = make("TextBox", {
        Parent = container,
        BackgroundColor3 = COLORS.InputBg,
        BorderSizePixel = 0,
        PlaceholderText = "Enter value...",
        PlaceholderColor3 = COLORS.SecondaryText,
        ClearTextOnFocus = false,
        Text = mod.Default or "",
        TextColor3 = COLORS.InputText,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.fromOffset(90, 18),
        Position = UDim2.new(1, -140, 0.5, -9),
    })
    corner(inputBox, 4)
    make("UIStroke", {
        Color = COLORS.InputBorder,
        Thickness = 1,
        Parent = inputBox,
    })

    mod.UI.Input = inputBox

    local conn = inputBox.FocusLost:Connect(function(enterPressed)
        if enterPressed then
            mod.Value = inputBox.Text
            self:_onModuleInput(mod, inputBox.Text)
        end
    end)
    table.insert(mod._connections, conn)
end

-- ============================================================
-- CALLBACKS
-- ============================================================

function GUILIB:_onModuleToggle(mod)
    if mod.Enabled then
        self:_fireRemote(mod)
    end
end

function GUILIB:_onModuleSlider(mod, value)
    self:_fireRemote(mod, value)
end

function GUILIB:_onModuleInput(mod, value)
    self:_fireRemote(mod, value)
end

-- ============================================================
-- REMOTE EXECUTION
-- ============================================================

-- Evaluate a single argument string to a Lua value, safely
local function evalArg(arg)
    if type(arg) ~= "string" then return arg end
    local fn = loadstring("return " .. arg)
    if fn then
        local ok, result = pcall(fn)
        if ok then return result end
    end
    return arg
end

function GUILIB:_fireRemote(mod, extraArg)
    if not mod then return end

    local args = {}
    local parsedArgs = mod._ParsedArgs

    -- Build args: use parsed args (possibly modified by slider/input),
    -- falling back to original remote args
    if parsedArgs and #parsedArgs > 0 then
        for i, v in ipairs(parsedArgs) do
            args[i] = v
        end
    elseif #mod.RemoteArgs > 0 then
        for i, v in ipairs(mod.RemoteArgs) do
            args[i] = v
        end
    end

    -- Replace nil slots with extraArg, mod.Value, or ""
    for i = 1, #args do
        if args[i] == nil then
            if extraArg ~= nil then
                args[i] = extraArg
            elseif mod.Value ~= nil then
                args[i] = mod.Value
            else
                args[i] = ""
            end
        end
    end

    -- Also handle case where RemoteArgs has more entries than parsedArgs
    if #mod.RemoteArgs > #args then
        args = {}
        for i, v in ipairs(mod.RemoteArgs) do
            args[i] = v
        end
        for i = 1, #args do
            if args[i] == nil then
                if extraArg ~= nil then
                    args[i] = extraArg
                elseif mod.Value ~= nil then
                    args[i] = mod.Value
                else
                    args[i] = ""
                end
            end
        end
    end

    local methodName = mod._RemoteMethod or "FireServer"
    local remoteType = mod.RemoteType or "Event"

    if remoteType == "Function" or methodName == "InvokeServer" then
        task.spawn(function()
            local ok, result = pcall(function()
                if mod.Remote and mod.Remote:IsA("RemoteFunction") then
                    local vals = {}
                    for _, a in ipairs(args) do
                        vals[#vals + 1] = evalArg(a)
                    end
                    return mod.Remote:InvokeServer(table.unpack(vals))
                end
            end)
            if ok then
                self:_setStatus(mod.Name .. ": OK")
            else
                self:_setStatus(mod.Name .. ": " .. tostring(result))
            end
        end)
    else
        task.spawn(function()
            local ok, err = pcall(function()
                if mod.Remote and mod.Remote:IsA("RemoteEvent") then
                    local vals = {}
                    for _, a in ipairs(args) do
                        vals[#vals + 1] = evalArg(a)
                    end
                    mod.Remote:FireServer(table.unpack(vals))
                end
            end)
            if ok then
                self:_setStatus(mod.Name .. ": fired")
            else
                self:_setStatus(mod.Name .. ": error")
            end
        end)
    end
end

-- ============================================================
-- BUILD GUI
-- ============================================================

function GUILIB:BuildGui()
    local old = PlayerGui:FindFirstChild(self.ScriptName .. "Builder")
    if old then old:Destroy() end

    self.Gui = make("ScreenGui", {
        Name = self.ScriptName .. "Builder",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = PlayerGui,
    })

    -- Main window: ~371x284
    local root = make("Frame", {
        Parent = self.Gui,
        Size = UDim2.fromOffset(371, 284),
        Position = UDim2.new(0.5, -185, 0.5, -142),
        BackgroundColor3 = COLORS.Window,
        BorderSizePixel = 0,
        Active = true,
        ClipsDescendants = true,
    })
    corner(root, 6)
    self.Root = root

    -- Draggable only via header area
    local header = make("Frame", {
        Parent = root,
        Size = UDim2.new(1, 0, 0, 29),
        BackgroundColor3 = COLORS.Header,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
    })
    corner(root, 6)

    local titleLabel = make("TextLabel", {
        Parent = header,
        BackgroundTransparency = 1,
        Text = self.ScriptName,
        TextColor3 = COLORS.TitleText,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -50, 1, 0),
    })

    -- Close button
    local closeBtn = make("TextButton", {
        Parent = header,
        Size = UDim2.fromOffset(14, 14),
        Position = UDim2.new(1, -24, 0.5, -7),
        BackgroundColor3 = Color3.fromRGB(40, 40, 40),
        BorderSizePixel = 0,
        Text = "Ă—",
        TextColor3 = Color3.fromRGB(160, 160, 160),
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        AutoButtonColor = false,
    })
    corner(closeBtn, 3)

    local closeConn = closeBtn.MouseButton1Click:Connect(function()
        self:Hide()
    end)
    self._closeConn[#self._closeConn + 1] = closeConn

    -- Header icons (small)
    local icon1 = make("TextLabel", {
        Parent = header,
        BackgroundTransparency = 1,
        Text = "âšˇ",
        TextColor3 = COLORS.Icon,
        Font = Enum.Font.GothamMedium,
        TextSize = 10,
        Position = UDim2.new(1, -70, 0.5, -6),
        Size = UDim2.fromOffset(10, 10),
    })
    local icon2 = make("TextLabel", {
        Parent = header,
        BackgroundTransparency = 1,
        Text = "âš™",
        TextColor3 = COLORS.Icon,
        Font = Enum.Font.GothamMedium,
        TextSize = 10,
        Position = UDim2.new(1, -56, 0.5, -6),
        Size = UDim2.fromOffset(10, 10),
    })

    -- Sidebar (~96px)
    local sidebar = make("Frame", {
        Parent = root,
        Size = UDim2.new(0, 96, 1, -29),
        Position = UDim2.fromOffset(0, 29),
        BackgroundColor3 = COLORS.Sidebar,
        BorderSizePixel = 0,
    })
    self.Sidebar = sidebar

    -- Divider between sidebar and content
    make("Frame", {
        Parent = root,
        Size = UDim2.new(0, 1, 1, -29),
        Position = UDim2.fromOffset(96, 29),
        BackgroundColor3 = COLORS.Divider,
        BorderSizePixel = 0,
    })

    -- Content area (#141410)
    local content = make("ScrollingFrame", {
        Parent = root,
        Size = UDim2.new(1, -96, 1, -29),
        Position = UDim2.fromOffset(96, 29),
        BackgroundColor3 = COLORS.Content,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 1,
        ScrollBarImageColor3 = COLORS.Divider,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        BackgroundTransparency = 0,
    })
    self.Content = content

    make("UIListLayout", {
        Parent = content,
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
    make("UIPadding", {
        Parent = content,
        PaddingLeft = UDim.new(0, 7),
        PaddingRight = UDim.new(0, 7),
        PaddingTop = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
    })

    -- Status bar
    local statusBar = make("Frame", {
        Parent = root,
        Size = UDim2.new(1, -16, 0, 20),
        Position = UDim2.fromOffset(8, 255),
        BackgroundColor3 = Color3.fromRGB(30, 30, 30),
        BorderSizePixel = 0,
    })
    corner(statusBar, 3)

    local statusLabel = make("TextLabel", {
        Parent = statusBar,
        BackgroundTransparency = 1,
        Text = "Ready",
        TextColor3 = COLORS.SecondaryText,
        Font = Enum.Font.Gotham,
        TextSize = 8,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(6, 0),
        Size = UDim2.new(1, -12, 1, 0),
    })
    self.StatusLabel = statusLabel

    -- Build module UI for all existing modules (using ModuleList, not Modules map)
    for i, mod in ipairs(self.ModuleList) do
        mod._layoutOrder = i
        self:_buildModuleUI(mod)
    end

    -- Build sidebar
    self:_buildSidebar()
    self._sidebarBuilt = true

    -- Show first category
    if #self.Categories > 0 then
        self:_showCategory(self.Categories[1])
    end

    self.Gui.Destroying:Connect(function()
        self:Hide()
    end)

    return self.Gui
end

-- ============================================================
-- SIDEBAR
-- ============================================================

function GUILIB:_buildSidebar()
    -- Clear existing category buttons
    for _, child in ipairs(self.Sidebar:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    local yOffset = 30
    for _, category in ipairs(self.Categories) do
        local moduleCount = self.CategoryMap[category] and #self.CategoryMap[category] or 0

        local btn = make("TextButton", {
            Parent = self.Sidebar,
            Size = UDim2.new(1, -8, 0, 24),
            Position = UDim2.fromOffset(4, yOffset),
            BackgroundColor3 = COLORS.Row,
            BorderSizePixel = 0,
            Text = category,
            TextColor3 = COLORS.SidebarText,
            Font = Enum.Font.GothamMedium,
            TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
        })
        corner(btn, 4)

        local countLabel = make("TextLabel", {
            Parent = btn,
            BackgroundTransparency = 1,
            Text = tostring(moduleCount),
            TextColor3 = COLORS.SecondaryText,
            Font = Enum.Font.GothamBold,
            TextSize = 8,
            TextXAlignment = Enum.TextXAlignment.Right,
            Position = UDim2.new(1, -18, 0.5, 0),
            Size = UDim2.fromOffset(14, 12),
        })

        btn.MouseButton1Click:Connect(function()
            self:_showCategory(category)
        end)

        yOffset = yOffset + 30
    end
end

function GUILIB:_refreshSidebar()
    self:_buildSidebar()
    -- Re-highlight active category
    if self._activeCategory then
        self:_showCategory(self._activeCategory)
    end
end

-- ============================================================
-- CATEGORY SWITCHING
-- ============================================================

function GUILIB:_showCategory(category)
    self._activeCategory = category

    -- Hide all module containers
    for _, mod in ipairs(self.ModuleList) do
        if mod.UI.Container then
            mod.UI.Container.Parent = nil
            mod.UI.Container.Visible = false
        end
    end

    -- Show modules for this category
    local moduleObjects = self.CategoryMap[category] or {}
    local order = 0
    for _, mod in ipairs(moduleObjects) do
        if mod.UI.Container then
            order = order + 1
            mod.UI.Container.LayoutOrder = order
            mod.UI.Container.Visible = true
            mod.UI.Container.Parent = self.Content
        end
    end

    -- Update sidebar button highlighting
    for _, child in ipairs(self.Sidebar:GetChildren()) do
        if child:IsA("TextButton") then
            if child.Text == category then
                child.BackgroundColor3 = Color3.fromRGB(36, 36, 36)
                child.TextColor3 = COLORS.ModuleText
            else
                child.BackgroundColor3 = COLORS.Row or Color3.fromRGB(34, 34, 34)
                child.TextColor3 = COLORS.SidebarText
            end
        end
    end

    self:_setStatus("Category: " .. category)
end

function GUILIB:_refreshVisibleModules()
    if not self._activeCategory then return end
    self:_showCategory(self._activeCategory)
end

-- ============================================================
-- SHOW / HIDE / TOGGLE / RUN
-- ============================================================

function GUILIB:Show()
    if not self.Gui then
        self:BuildGui()
    end
    self.Gui.Enabled = true
    if self.Root then
        tweenProperty(self.Root, { BackgroundTransparency = 0 }, 0.15)
    end
    self.Visible = true
end

function GUILIB:Hide()
    if self.Root then
        tweenProperty(self.Root, { BackgroundTransparency = 1 }, 0.15)
    end
    task.delay(0.2, function()
        if self.Gui then
            self.Gui.Enabled = false
        end
    end)
    self.Visible = false
end

function GUILIB:Toggle()
    if self.Visible then
        self:Hide()
    else
        self:Show()
    end
end

function GUILIB:Run()
    self:Show()

    local inputConn
    inputConn = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.F7 then
            self:Toggle()
        end
    end)

    self.Gui.Destroying:Connect(function()
        if inputConn then inputConn:Disconnect() end
    end)
end

-- ============================================================
-- BUILDER CLASS
-- ============================================================

function Builder.New(scriptName, config)
    local self = setmetatable({}, BUILDER_META)
    local guiLib = GUILIB.New(scriptName, config or {})
    assert(guiLib, "[Builder] GUILIB.New returned nil")
    self.GuiLib = guiLib
    return self
end

function Builder:AddModule(moduleDef)
    return self.GuiLib:AddModule(moduleDef)
end

function Builder:AddRemote(category, name, cobaltSnippet, controlType, controlConfig)
    return self.GuiLib:AddRemote(category, name, cobaltSnippet, controlType, controlConfig)
end

function Builder:AddRemoteSpy(category, name, remotePath, arg1, controlType, defaultVal)
    return self.GuiLib:AddRemoteSpy(category, name, remotePath, arg1, controlType, defaultVal)
end

function Builder:AddModules(modules)
    return self.GuiLib:AddModules(modules)
end

function Builder:Run()
    return self.GuiLib:Run()
end

function Builder:Show()
    return self.GuiLib:Show()
end

function Builder:Hide()
    return self.GuiLib:Hide()
end

function Builder:Toggle()
    return self.GuiLib:Toggle()
end

function Builder:GetModule(name)
    return self.GuiLib.Modules[name]
end

function Builder:GetAllModules()
    return self.GuiLib.Modules
end

function Builder:SetModuleValue(name, value)
    local mod = self.GuiLib.Modules[name]
    if not mod then return false end
    mod.Value = value
    mod.Enabled = value ~= false and value ~= 0 and value ~= "" and value ~= nil
    if mod.UI.Track then
        self.GuiLib:_updateToggleVisual(mod)
    end
    if mod.UI.SliderValue then
        mod.UI.SliderValue.Text = tostring(value)
    end
    return true
end

function Builder:FireModule(name, ...)
    local mod = self.GuiLib.Modules[name]
    if not mod then return false end
    return self.GuiLib:_fireRemote(mod, ...)
end

function Builder:Status(text)
    if self.GuiLib and self.GuiLib.StatusLabel then
        self.GuiLib.StatusLabel.Text = tostring(text)
    end
    if self.GuiLib then
        self.GuiLib.StatusText = tostring(text)
    end
end

function Builder.Init(scriptName, config)
    local instance = Builder.New(scriptName, config)

    local globalName = "_SB_" .. scriptName:gsub("%W", "_")
    _G[globalName] = instance

    local conn
    conn = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.F7 then
            instance:Toggle()
        end
    end)

    instance._F7Conn = conn

    return instance, globalName
end

_G.Builder = Builder
return Builder
