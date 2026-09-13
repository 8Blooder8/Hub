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

local function resolvePath(path)
    if not path or path == "" then return nil end
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

local function resolveRemote(raw)
    if not raw or raw == "" then return nil end
    local path = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if path == "" then return nil end

    
    if path:sub(1, 5) == "game:" or path:sub(1, 5) == "game." then
        local ok, result = pcall(function()
            local fn = loadstring("return " .. path)
            if fn then return fn() end
        end)
        if ok and result and typeof(result) == "Instance" then
            return result
        end
    end

    
    return resolvePath(path)
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
        CornerRadius = UDim.new(0, radius or 7),
        Parent = parent,
    })
end

local function stroke(parent, color, thickness)
    return make("UIStroke", {
        Color = color or Color3.fromRGB(49, 56, 66),
        Thickness = thickness or 1,
        Parent = parent,
    })
end

local function tweenProperty(obj, props, duration)
    local tween = TweenService:Create(obj, TweenInfo.new(duration or 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
    tween:Play()
    return tween
end

local COLORS = {
    BG         = Color3.fromRGB(13, 15, 18),
    PANEL      = Color3.fromRGB(21, 24, 29),
    PANEL2     = Color3.fromRGB(28, 32, 38),
    BORDER     = Color3.fromRGB(49, 56, 66),
    TEXT       = Color3.fromRGB(236, 239, 244),
    MUTED      = Color3.fromRGB(151, 159, 171),
    BLUE       = Color3.fromRGB(73, 133, 214),
    GREEN      = Color3.fromRGB(62, 154, 94),
    ORANGE     = Color3.fromRGB(184, 120, 51),
    OFF        = Color3.fromRGB(59, 64, 73),
    ON         = Color3.fromRGB(61, 154, 93),
    ACCENT     = Color3.fromRGB(0, 190, 150),
    DANGER     = Color3.fromRGB(255, 106, 106),
}

function GUILIB.New(scriptName, config)
    local self = setmetatable({}, GUILIB_META)

    self.ScriptName = scriptName or "Script"
    self.Config     = config or {}

    self.Modules    = {}      
    self.ModuleState = {}     
    self.Categories = {}      
    self.CategoryMap = {}     

    self.Gui        = nil
    self.Root        = nil
    self.Sidebar     = nil
    self.Content     = nil
    self.Visible     = false
    self.AllEnabled  = false
    self.StatusText  = "Ready"

    return self
end

function GUILIB:AddModule(moduleDef)
    if not moduleDef or not moduleDef.Category or not moduleDef.Name then
        warn("[Builder] AddModule: missing Category or Name")
        return false
    end

    local category = moduleDef.Category
    local name     = moduleDef.Name

    if not self.CategoryMap[category] then
        self.Categories[#self.Categories + 1] = category
        self.CategoryMap[category] = {}
    end
    self.CategoryMap[category][#self.CategoryMap[category] + 1] = name

    local controlType = "toggle"
    if moduleDef.Control and moduleDef.Control.Type then
        controlType = moduleDef.Control.Type
    end

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

    local remoteRef = nil
    local remoteType = "Event"
    local remoteArgs = {}
    if moduleDef.Remote then
        remoteType = moduleDef.Remote.Type or "Event"
        remoteRef  = resolveRemote(moduleDef.Remote.Path)
        if moduleDef.Remote.Args then
            remoteArgs = moduleDef.Remote.Args
        end
    end

    local mod = {
        Category    = category,
        Name        = name,
        ControlType = controlType,
        Default     = defaultVal,
        Min         = minVal,
        Max         = maxVal,
        Step        = stepVal,
        Remote      = remoteRef,
        RemoteType  = remoteType,
        RemoteArgs  = remoteArgs,
        Value       = defaultVal,
        Enabled     = false,
        UI = {},
    }

    self.Modules[name] = mod

    
    if self.Content then
        self:_buildModuleUI(mod)
    end

    return true
end

function GUILIB:_buildModuleUI(mod)
    if not self.Content then return end

    local controlType = mod.ControlType
    local container = make("Frame", {
        Parent = self.ModuleRegistry,
        BackgroundColor3 = COLORS.PANEL,
        BorderSizePixel = 0,
        Size = UDim2.new(1, -28, 0, 48),
        LayoutOrder = #self.Modules,
    })
    corner(container, 7)

    
    local label = make("TextLabel", {
        Parent = container,
        BackgroundTransparency = 1,
        Text = mod.Name,
        TextColor3 = COLORS.TEXT,
        Font = Enum.Font.GothamSemibold,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(10, 5),
        Size = UDim2.new(1, -100, 0, 20),
    })

    
    local sublabel = make("TextLabel", {
        Parent = container,
        BackgroundTransparency = 1,
        Text = mod.Remote and ("Remote: " .. mod.RemoteType) or "No remote",
        TextColor3 = COLORS.MUTED,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(10, 26),
        Size = UDim2.new(1, -100, 0, 14),
    })

    mod.UI.Container  = container
    mod.UI.Label      = label
    mod.UI.Sublabel   = sublabel

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

function GUILIB:_buildToggle(mod, container)
    local track = make("TextButton", {
        Parent = container,
        BackgroundColor3 = COLORS.OFF,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(72, 28),
        Position = UDim2.new(1, -82, 0.5, -14),
        Text = "OFF",
        TextColor3 = COLORS.TEXT,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        AutoButtonColor = false,
    })
    corner(track, 14)

    local knob = make("Frame", {
        Parent = track,
        BackgroundColor3 = COLORS.TEXT,
        BorderSizePixel = 0,
        Size = UDim2.new(0, 18, 0, 18),
        Position = UDim2.new(0, 3, 0.5, -9),
    })
    corner(knob, 9)

    mod.UI.Track = track
    mod.UI.Knob  = knob

    track.MouseButton1Click:Connect(function()
        mod.Enabled = not mod.Enabled
        mod.Value = mod.Enabled
        self:_updateToggleVisual(mod)
        self:_onModuleToggle(mod)
    end)

    self:_updateToggleVisual(mod)
end

function GUILIB:_updateToggleVisual(mod)
    if not mod.UI.Track then return end
    mod.UI.Track.Text = mod.Enabled and "ON" or "OFF"
    mod.UI.Track.BackgroundColor3 = mod.Enabled and COLORS.ON or COLORS.OFF
end

function GUILIB:_buildButton(mod, container)
    local btn = make("TextButton", {
        Parent = container,
        BackgroundColor3 = COLORS.BLUE,
        BorderSizePixel = 0,
        Text = "Fire",
        TextColor3 = COLORS.TEXT,
        Font = Enum.Font.GothamSemibold,
        TextSize = 12,
        Size = UDim2.fromOffset(72, 28),
        Position = UDim2.new(1, -82, 0.5, -14),
        AutoButtonColor = false,
    })
    corner(btn, 7)

    local busy = false
    btn.MouseButton1Click:Connect(function()
        if busy then return end
        busy = true
        btn.Text = "..."
        self:_fireRemote(mod)
        btn.Text = "Fire"
        busy = false
    end)

    mod.UI.Button = btn
end

function GUILIB:_buildSlider(mod, container)
    local sliderFrame = make("Frame", {
        Parent = container,
        BackgroundColor3 = COLORS.PANEL2,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(120, 8),
        Position = UDim2.new(1, -140, 0.5, -4),
    })
    corner(sliderFrame, 4)

    local fill = make("Frame", {
        Parent = sliderFrame,
        BackgroundColor3 = COLORS.BLUE,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(50, 8),
    })
    corner(fill, 4)

    local knob = make("Frame", {
        Parent = sliderFrame,
        BackgroundColor3 = COLORS.TEXT,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(14, 14),
        Position = UDim2.fromOffset(50, -3),
    })
    corner(knob, 7)

    local valueLabel = make("TextLabel", {
        Parent = container,
        BackgroundTransparency = 1,
        Text = tostring(mod.Default),
        TextColor3 = COLORS.MUTED,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        Position = UDim2.fromOffset(10, 32),
        Size = UDim2.new(1, -100, 0, 12),
    })

    mod.UI.SliderFrame = sliderFrame
    mod.UI.SliderFill  = fill
    mod.UI.SliderKnob  = knob
    mod.UI.SliderValue = valueLabel

    
    local function clampNum(v, lo, hi)
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end

    
    mod.SliderValue = mod.Default

    
    local dragging = false
    local UIS = UserInputService

    local function updateSlider(inputX)
        local absPos = sliderFrame.AbsolutePosition.X
        local absSize = sliderFrame.AbsoluteSize.X
        local relative = clampNum((inputX - absPos) / absSize, 0, 1)
        local raw = mod.Min + (mod.Max - mod.Min) * relative
        local val = math.floor(raw / mod.Step) * mod.Step
        val = math.floor(val * 100 + 0.5) / 100
        val = clampNum(val, mod.Min, mod.Max)
        mod.Value = val
        mod.SliderValue = val

        local px = relative * absSize
        fill.Size = UDim2.fromOffset(math.max(px, 8), 8)
        knob.Position = UDim2.fromOffset(math.max(px - 7, 0), -3)
        valueLabel.Text = tostring(val)
    end

    sliderFrame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            updateSlider(input.Position.X)
        end
    end)

    UIS.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            updateSlider(input.Position.X)
        end
    end)

    UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            if dragging then
                dragging = false
                self:_onModuleSlider(mod, mod.SliderValue)
            end
        end
    end)

    
    task.defer(function()
        local absSize = sliderFrame.AbsoluteSize.X
        if absSize and absSize > 0 then
            local ratio = clampNum((mod.Default - mod.Min) / (mod.Max - mod.Min), 0, 1)
            local px = ratio * absSize
            fill.Size = UDim2.fromOffset(math.max(px, 8), 8)
            knob.Position = UDim2.fromOffset(math.max(px - 7, 0), -3)
        end
    end)
end

function GUILIB:_buildInput(mod, container)
    local input = make("TextBox", {
        Parent = container,
        BackgroundColor3 = COLORS.PANEL2,
        BorderSizePixel = 0,
        PlaceholderText = "Enter value...",
        PlaceholderColor3 = COLORS.MUTED,
        ClearTextOnFocus = false,
        Text = mod.Default or "",
        TextColor3 = COLORS.TEXT,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.fromOffset(120, 24),
        Position = UDim2.new(1, -140, 0.5, -12),
    })
    corner(input, 6)

    mod.UI.Input = input

    input.FocusLost:Connect(function(enterPressed)
        if enterPressed then
            mod.Value = input.Text
            self:_onModuleInput(mod, input.Text)
        end
    end)
end

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

function GUILIB:_fireRemote(mod, extraArg)
    if not mod.Remote then
        self.StatusText = mod.Name .. ": no remote set"
        return
    end

    local args = {}
    for i, v in ipairs(mod.RemoteArgs) do
        if v == nil then
            
            if extraArg ~= nil then
                args[i] = extraArg
            elseif mod.Value ~= nil then
                args[i] = mod.Value
            else
                args[i] = ""
            end
        else
            args[i] = v
        end
    end

    if mod.RemoteType == "Function" then
        task.spawn(function()
            local ok, result = pcall(function()
                if mod.Remote:IsA("RemoteFunction") then
                    return { mod.Remote:InvokeServer(table.unpack(args)) }
                end
                return nil
            end)
            if ok then
                self.StatusText = mod.Name .. ": OK"
            else
                self.StatusText = mod.Name .. ": " .. tostring(result)
            end
        end)
    else
        
        task.spawn(function()
            local ok = pcall(function()
                if mod.Remote:IsA("RemoteEvent") then
                    mod.Remote:FireServer(table.unpack(args))
                end
            end)
            if ok then
                self.StatusText = mod.Name .. ": fired"
            else
                self.StatusText = mod.Name .. ": error"
            end
        end)
    end
end

function GUILIB:BuildGui()
    
    local old = PlayerGui:FindFirstChild(self.ScriptName .. "Builder")
    if old then old:Destroy() end

    self.Gui = make("ScreenGui", {
        Name = self.ScriptName .. "Builder",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = PlayerGui,
    })

    local root = make("Frame", {
        Parent = self.Gui,
        Size = UDim2.fromOffset(580, 420),
        Position = UDim2.new(0.5, -290, 0.5, -210),
        BackgroundColor3 = COLORS.BG,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
    })
    corner(root, 9)
    stroke(root)
    self.Root = root

    
    local titleBar = make("Frame", {
        Parent = root,
        Size = UDim2.new(1, 0, 0, 38),
        BackgroundColor3 = COLORS.PANEL2,
        BorderSizePixel = 0,
    })
    corner(titleBar, 9)

    local titleLabel = make("TextLabel", {
        Parent = titleBar,
        BackgroundTransparency = 1,
        Text = self.ScriptName .. " - Script Builder",
        TextColor3 = COLORS.TEXT,
        Font = Enum.Font.GothamSemibold,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -180, 1, 0),
    })

    local allToggleBtn = make("TextButton", {
        Parent = titleBar,
        BackgroundColor3 = COLORS.BLUE,
        BorderSizePixel = 0,
        Text = "All: OFF",
        TextColor3 = COLORS.TEXT,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        Size = UDim2.fromOffset(70, 24),
        Position = UDim2.new(1, -180, 0.5, -12),
        AutoButtonColor = false,
    })
    corner(allToggleBtn, 6)

    allToggleBtn.MouseButton1Click:Connect(function()
        self.AllEnabled = not self.AllEnabled
        for _, mod in pairs(self.Modules) do
            mod.Enabled = self.AllEnabled
            mod.Value = self.AllEnabled
            if mod.UI.Track then
                self:_updateToggleVisual(mod)
            end
        end
        allToggleBtn.Text = "All: " .. (self.AllEnabled and "ON" or "OFF")
        allToggleBtn.BackgroundColor3 = self.AllEnabled and COLORS.ON or COLORS.BLUE
    end)

    local closeBtn = make("TextButton", {
        Parent = titleBar,
        Size = UDim2.fromOffset(30, 30),
        Position = UDim2.new(1, -39, 0, 4),
        BackgroundColor3 = COLORS.PANEL,
        BorderSizePixel = 0,
        Text = "×",
        TextColor3 = COLORS.TEXT,
        Font = Enum.Font.GothamBold,
        TextSize = 17,
        AutoButtonColor = false,
    })
    corner(closeBtn, 6)
    closeBtn.MouseButton1Click:Connect(function()
        self:Hide()
    end)

    
    local registry = make("Frame", {
        Parent = root,
        Size = UDim2.fromOffset(0, 0, 0, 0),
        Position = UDim2.new(-10, 0, -10, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    })
    self.ModuleRegistry = registry

    
    local sidebar = make("Frame", {
        Parent = root,
        Size = UDim2.new(0, 130, 1, -46),
        Position = UDim2.fromOffset(8, 44),
        BackgroundColor3 = COLORS.PANEL,
        BorderSizePixel = 0,
    })
    corner(sidebar, 7)
    self.Sidebar = sidebar

    local sidebarTitle = make("TextLabel", {
        Parent = sidebar,
        BackgroundTransparency = 1,
        Text = "CATEGORIES",
        TextColor3 = COLORS.MUTED,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(10, 6),
        Size = UDim2.new(1, -20, 0, 16),
    })

    
    local content = make("ScrollingFrame", {
        Parent = root,
        Size = UDim2.new(1, -156, 1, -46),
        Position = UDim2.fromOffset(146, 44),
        BackgroundColor3 = COLORS.PANEL,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COLORS.BORDER,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    })
    self.Content = content

    local layout = make("UIListLayout", {
        Parent = content,
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
    make("UIPadding", {
        Parent = content,
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 8),
        PaddingTop = UDim.new(0, 6),
        PaddingBottom = UDim.new(0, 6),
    })

    
    for _, mod in ipairs(self.Modules) do
        self:_buildModuleUI(mod)
    end

    
    local statusBar = make("Frame", {
        Parent = root,
        Size = UDim2.new(1, -16, 0, 26),
        Position = UDim2.fromOffset(8, 386),
        BackgroundColor3 = COLORS.PANEL2,
        BorderSizePixel = 0,
    })
    corner(statusBar, 6)

    local statusLabel = make("TextLabel", {
        Parent = statusBar,
        BackgroundTransparency = 1,
        Text = "Ready",
        TextColor3 = COLORS.MUTED,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(8, 0),
        Size = UDim2.new(1, -16, 1, 0),
    })
    self.StatusLabel = statusLabel

    
    self:_buildSidebar()
    self:_showCategory(self.Categories[1])

    return self.Gui
end

function GUILIB:_buildSidebar()
    
    for _, child in ipairs(self.Sidebar:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    local yOffset = 24
    for _, category in ipairs(self.Categories) do
        local btn = make("TextButton", {
            Parent = self.Sidebar,
            Size = UDim2.new(1, -16, 0, 30),
            Position = UDim2.fromOffset(8, yOffset),
            BackgroundColor3 = COLORS.PANEL2,
            BorderSizePixel = 0,
            Text = category,
            TextColor3 = COLORS.TEXT,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
        })
        corner(btn, 6)

        local modCount = self.CategoryMap[category] and #self.CategoryMap[category] or 0
        local countLabel = make("TextLabel", {
            Parent = btn,
            BackgroundTransparency = 1,
            Text = tostring(modCount),
            TextColor3 = COLORS.MUTED,
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Right,
            Position = UDim2.new(1, -30, 0.5, 0),
            Size = UDim2.fromOffset(22, 14),
        })

        btn.MouseButton1Click:Connect(function()
            self:_showCategory(category)
        end)

        yOffset = yOffset + 36
    end
end

function GUILIB:_showCategory(category)
    
    for _, child in ipairs(self.Content:GetChildren()) do
        if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
            child.Parent = self.ModuleRegistry
        end
    end

    
    for _, child in ipairs(self.Sidebar:GetChildren()) do
        if child:IsA("TextButton") then
            if child.Text == category then
                child.BackgroundColor3 = COLORS.BLUE
                child.TextColor3 = COLORS.TEXT
            else
                child.BackgroundColor3 = COLORS.PANEL2
                child.TextColor3 = COLORS.TEXT
            end
        end
    end

    
    local moduleNames = self.CategoryMap[category] or {}
    local order = 0
    for _, name in ipairs(moduleNames) do
        local mod = self.Modules[name]
        if mod and mod.UI.Container then
            order = order + 1
            mod.UI.Container.LayoutOrder = order
            mod.UI.Container.Visible = true
            mod.UI.Container.Parent = self.Content
        end
    end

    self.StatusText = "Category: " .. category
end

function GUILIB:Show()
    if not self.Gui then
        self:BuildGui()
    end
    self.Gui.Enabled = true
    if self.Root then
        tweenProperty(self.Root, { BackgroundTransparency = 0 }, 0.2)
    end
    self.Visible = true
end

function GUILIB:Hide()
    if self.Root then
        tweenProperty(self.Root, { BackgroundTransparency = 1 }, 0.2)
    end
    task.delay(0.25, function()
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
        elseif input.KeyCode == Enum.KeyCode.F8 then
            self.AllEnabled = not self.AllEnabled
            for _, mod in pairs(self.Modules) do
                mod.Enabled = self.AllEnabled
                mod.Value = self.AllEnabled
                if mod.UI.Track then
                    self:_updateToggleVisual(mod)
                end
            end
            
            if self.Root then
                for _, child in ipairs(self.Root:GetDescendants()) do
                    if child:IsA("TextButton") and child.Text:sub(1, 4) == "All:" then
                        child.Text = "All: " .. (self.AllEnabled and "ON" or "OFF")
                        child.BackgroundColor3 = self.AllEnabled and COLORS.ON or COLORS.BLUE
                        break
                    end
                end
            end
        end
    end)

    
    self.Gui.Destroying:Connect(function()
        if inputConn then inputConn:Disconnect() end
    end)
end

function Builder.New(scriptName, config)
    local self = setmetatable({}, BUILDER_META)
    local guiLib = GUILIB.New(scriptName, config or {})
    assert(guiLib, "[Builder] GUILIB.New returned nil")
    self.GuiLib = guiLib
    self.GuiLib._RegisterInternal = true
    return self
end

function Builder:AddModule(moduleDef)
    return self.GuiLib:AddModule(moduleDef)
end

function Builder:AddRemoteSpy(category, name, remotePath, arg1, controlType, defaultVal)
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
        Category  = category,
        Name      = name,
        Control = ctrlTbl,
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

function Builder:AddModules(modules)
    for _, mod in ipairs(modules) do
        self.GuiLib:AddModule(mod)
    end
end

function Builder:Run()
    self.GuiLib:Run()
end

function Builder:Show()
    self.GuiLib:Show()
end

function Builder:Hide()
    self.GuiLib:Hide()
end

function Builder:Toggle()
    self.GuiLib:Toggle()
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

    return instance, globalName
end

_G.Builder = Builder
return Builder
