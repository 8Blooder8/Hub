-- ScriptBuilder.lua
-- Executor-friendly GUI builder.
-- Module fields:
--   Subcategory = "Main"
--   Interval = 0.1 -- optional; Toggle only
--
-- Remote may be:
--   "ReplicatedStorage.Remotes.SomeRemote"
--   "ReplicatedStorage.Remotes:GetChildren()[70]"
--   "game:GetService(\"ReplicatedStorage\").Remotes:GetChildren()[70]"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
assert(Player, "ScriptBuilder must run in a LocalScript / executor")
local PlayerGui = Player:WaitForChild("PlayerGui")

local Builder = {}
Builder.__index = Builder

local COLORS = {
    Outer = Color3.fromRGB(18,18,18),
    Header = Color3.fromRGB(24,24,24),
    Sidebar = Color3.fromRGB(17,17,17),
    Content = Color3.fromRGB(17,17,17),
    Row = Color3.fromRGB(34,34,34),
    Selected = Color3.fromRGB(36,36,38),
    Hover = Color3.fromRGB(42,42,44),
    Text = Color3.fromRGB(235,235,235),
    Text2 = Color3.fromRGB(190,190,190),
    Text3 = Color3.fromRGB(130,130,130),
    Accent = Color3.fromRGB(111,168,247),
    ToggleOff = Color3.fromRGB(78,78,78),
    Knob = Color3.fromRGB(244,244,244),
    Border = Color3.fromRGB(67,63,70),
}

local SIZE = {W=535,H=411,Header=47,Sidebar=141,Row=37}
local EASE = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MIN_INTERVAL = 0.01

local function make(className, props)
    local o = Instance.new(className)
    for k,v in pairs(props or {}) do
        if k ~= "Parent" then o[k] = v end
    end
    if props and props.Parent then o.Parent = props.Parent end
    return o
end

local function corner(parent, radius)
    make("UICorner", {Parent=parent, CornerRadius=UDim.new(0, radius or 4)})
end

local function stroke(parent, color, thickness, transparency)
    return make("UIStroke", {
        Parent=parent,
        Color=color or COLORS.Border,
        Thickness=thickness or 1,
        Transparency=transparency or 0,
    })
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function isRemote(value)
    return typeof(value) == "Instance"
        and (value:IsA("RemoteEvent") or value:IsA("RemoteFunction"))
end

local function serviceByName(name)
    local ok, result = pcall(game.GetService, game, name)
    if ok then return result end
    return nil
end

-- Resolves only the base part of a remote expression.
-- No loadstring is used here. This is important because executor/loadstring
-- environments are not guaranteed to expose local variables from this module.
local function resolveBase(path)
    path = trim(path)
    if path == "" then return nil end

    -- game:GetService("ReplicatedStorage").Remotes.Foo
    local serviceName, rest = path:match(
        '^game:GetService%(%s*["\']([^"\']+)["\']%s*%)%.(.+)$'
    )

    local node

    if serviceName then
        node = serviceByName(serviceName)
        if not node then return nil end
    else
        local rootName, remainder = path:match("^(%w+)%.(.+)$")
        if not rootName then
            if path == "game" then return game end
            if path == "workspace" or path == "Workspace" then return workspace end
            return nil
        end

        local roots = {
            game = game,
            ReplicatedStorage = ReplicatedStorage,
            Players = Players,
            workspace = workspace,
            Workspace = workspace,
        }

        node = roots[rootName]
        rest = remainder
        if not node then return nil end
    end

    for part in tostring(rest):gmatch("[^%.]+") do
        node = node:FindFirstChild(part)
        if not node then return nil end
    end

    return node
end

-- Resolves the exact syntax used by the user's working example:
--   ReplicatedStorage.Remotes:GetChildren()[70]
-- and also:
--   game:GetService("ReplicatedStorage").Remotes:GetChildren()[70]
local function resolveRemote(path)
    if typeof(path) == "Instance" then
        return isRemote(path) and path or nil
    end

    if type(path) == "table" and path.__expr ~= nil then
        path = tostring(path.__expr)
    end

    if type(path) ~= "string" then return nil end
    path = trim(path)
    if path == "" then return nil end

    local prefix, index = path:match("^(.-):GetChildren%(%s*%)%[(%d+)%]$")
    if prefix and index then
        local parent = resolveBase(prefix)
        if not parent then return nil end

        local children = parent:GetChildren()
        local child = children[tonumber(index)]
        return isRemote(child) and child or nil
    end

    local direct = resolveBase(path)
    if isRemote(direct) then
        return direct
    end

    return nil
end

local function evalValue(value)
    if type(value) ~= "table" or value.__expr == nil then
        return value
    end

    local fn = loadstring and loadstring("return " .. tostring(value.__expr))
    if not fn then return nil end

    local ok, result = pcall(fn)
    return ok and result or nil
end

local function disconnectAll(list)
    for i = #list, 1, -1 do
        pcall(function() list[i]:Disconnect() end)
        list[i] = nil
    end
end

function Builder.New(name, config)
    local self = setmetatable({}, Builder)
    self.Name = tostring(name or "ScriptBuilder")
    self.Config = config or {}
    self.Modules = {}
    self.Categories = {}
    self.CategoryMap = {}
    self.ActiveCategory = nil
    self.Gui = nil
    self.Root = nil
    self.Content = nil
    self.Sidebar = nil
    self.Body = nil
    self.Status = "Ready"
    self.StatusLabel = nil
    self._connections = {}
    self.Visible = false
    self._minimized = false
    self._categoryButtons = {}
    return self
end

function Builder:_stopInterval(mod)
    mod._loopToken = (mod._loopToken or 0) + 1
    mod._loopRunning = false
end

function Builder:_updateStatus()
    if self.StatusLabel then
        self.StatusLabel.Text = self.Status
    end
end

function Builder:_invokeRemote(mod, extra)
    if not isRemote(mod.Remote) then
        self.Status = mod.Name .. ": Remote not found"
        self:_updateStatus()
        warn("[ScriptBuilder] " .. self.Status .. " | " .. tostring(mod.RemotePath))
        return false, nil
    end

    local args = table.create(#mod.Args)
    for i,v in ipairs(mod.Args) do
        args[i] = evalValue(v)
    end
    if extra ~= nil then
        args[#args + 1] = extra
    end

    local ok, result = pcall(function()
        if mod.Remote:IsA("RemoteEvent") then
            mod.Remote:FireServer(table.unpack(args))
            return true
        elseif mod.Remote:IsA("RemoteFunction") then
            return mod.Remote:InvokeServer(table.unpack(args))
        end
        error("Unsupported remote type: " .. mod.Remote.ClassName)
    end)

    self.Status = ok and (mod.Name .. ": OK") or (mod.Name .. ": " .. tostring(result))
    self:_updateStatus()
    if not ok then
        warn("[ScriptBuilder] " .. self.Status)
    end
    return ok, result
end

function Builder:_fire(mod, extra)
    task.spawn(function()
        self:_invokeRemote(mod, extra)
    end)
    return true
end

function Builder:_startInterval(mod)
    local interval = tonumber(mod.Interval)

    if not interval or interval <= 0 then
        self:_fire(mod)
        return
    end

    interval = math.max(interval, MIN_INTERVAL)
    self:_stopInterval(mod)

    local token = mod._loopToken
    mod._loopRunning = true

    task.spawn(function()
        while mod.Enabled and mod._loopToken == token do
            self:_invokeRemote(mod)

            if not mod.Enabled or mod._loopToken ~= token then
                break
            end

            task.wait(interval)
        end

        if mod._loopToken == token then
            mod._loopRunning = false
        end
    end)
end

function Builder:_toggleVisual(mod)
    local track, knob = mod.UI.Track, mod.UI.Knob
    if not track or not knob then return end

    TweenService:Create(track, EASE, {
        BackgroundColor3 = mod.Enabled and COLORS.Accent or COLORS.ToggleOff,
    }):Play()

    TweenService:Create(knob, EASE, {
        Position = mod.Enabled
            and UDim2.new(1,-18,0.5,-8)
            or UDim2.new(0,2,0.5,-8),
    }):Play()
end

function Builder:_setToggleState(mod, state)
    mod.Enabled = state == true
    mod.Value = mod.Enabled
    self:_toggleVisual(mod)

    if mod.Enabled then
        if mod.Interval and mod.Interval > 0 then
            self:_startInterval(mod)
        else
            self:_fire(mod)
        end
    else
        self:_stopInterval(mod)
    end
end

function Builder:AddModule(def)
    assert(type(def) == "table", "AddModule expects a table")
    assert(def.Name, "AddModule: Name is required")
    assert(def.Category, "AddModule: Category is required")

    local name = tostring(def.Name)
    local category = tostring(def.Category)
    local old = self.Modules[name]

    if old then
        self:_stopInterval(old)
        disconnectAll(old._connections)

        local oldList = self.CategoryMap[old.Category]
        if oldList then
            for i = #oldList, 1, -1 do
                if oldList[i] == old then
                    table.remove(oldList, i)
                end
            end

            if #oldList == 0 then
                self.CategoryMap[old.Category] = nil
                for i = #self.Categories, 1, -1 do
                    if self.Categories[i] == old.Category then
                        table.remove(self.Categories, i)
                    end
                end
            end
        end
    end

    local control = def.Control or {Type = def.Type or "Toggle"}
    if type(control) == "string" then
        control = {Type = control}
    end

    local mod = {}
    for k,v in pairs(def) do
        mod[k] = v
    end

    mod.Name = name
    mod.Category = category
    mod.Control = control
    mod.Type = tostring(control.Type or "Toggle")
    mod.Args = def.Args or {}
    mod.Options = def.Options or {}
    mod.Enabled = def.Enabled == true
    mod.Value = def.Value
    mod.RemotePath = def.Remote
    mod.Remote = resolveRemote(def.Remote)
    mod.Subcategory = trim(def.Subcategory or def.SubCategory or def.SubcategoryName or "")
    mod.Interval = tonumber(def.Interval)
    mod.UI = {}
    mod._connections = {}
    mod._loopToken = 0
    mod._loopRunning = false

    self.Modules[name] = mod

    if not self.CategoryMap[category] then
        self.CategoryMap[category] = {}
        self.Categories[#self.Categories + 1] = category
    end

    table.insert(self.CategoryMap[category], mod)

    if not mod.Remote then
        warn("[ScriptBuilder] " .. name .. ": could not resolve Remote: " .. tostring(def.Remote))
    end

    if self.Gui then
        self:BuildGui()
    end

    return mod
end

function Builder:AddModules(list)
    for _,def in ipairs(list or {}) do
        self:AddModule(def)
    end
    return self
end

function Builder:RemoveModule(name)
    local mod = self.Modules[name]
    if not mod then return false end

    self:_stopInterval(mod)
    disconnectAll(mod._connections)
    self.Modules[name] = nil

    local list = self.CategoryMap[mod.Category]
    if list then
        for i = #list, 1, -1 do
            if list[i] == mod then
                table.remove(list, i)
            end
        end

        if #list == 0 then
            self.CategoryMap[mod.Category] = nil
            for i = #self.Categories, 1, -1 do
                if self.Categories[i] == mod.Category then
                    table.remove(self.Categories, i)
                end
            end
        end
    end

    if self.Gui then
        self:BuildGui()
    end

    return true
end

function Builder:_makeRow(mod, parent, order)
    parent = parent or self.Content

    local row = make("Frame", {
        Parent = parent,
        Size = UDim2.new(1,0,0,SIZE.Row),
        BackgroundColor3 = COLORS.Row,
        BorderSizePixel = 0,
        LayoutOrder = order or 1,
    })
    row:SetAttribute("SBContent", true)
    corner(row, 5)
    stroke(row, Color3.fromRGB(47,47,47), 1, 0.65)

    make("TextLabel", {
        Parent = row,
        BackgroundTransparency = 1,
        Size = UDim2.new(1,-125,1,0),
        Position = UDim2.fromOffset(11,0),
        Text = mod.Name,
        TextColor3 = COLORS.Text2,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    })

    table.insert(mod._connections, row.MouseEnter:Connect(function()
        TweenService:Create(row, EASE, {BackgroundColor3 = COLORS.Hover}):Play()
    end))

    table.insert(mod._connections, row.MouseLeave:Connect(function()
        TweenService:Create(row, EASE, {BackgroundColor3 = COLORS.Row}):Play()
    end))

    local typ = string.lower(mod.Type)

    if typ == "toggle" then
        local track = make("Frame", {
            Parent = row,
            Size = UDim2.fromOffset(39,20),
            Position = UDim2.new(1,-51,0.5,-10),
            BackgroundColor3 = COLORS.ToggleOff,
            BorderSizePixel = 0,
        })
        corner(track,10)

        local knob = make("Frame", {
            Parent = track,
            Size = UDim2.fromOffset(18,18),
            Position = UDim2.new(0,1,0.5,-9),
            BackgroundColor3 = COLORS.Knob,
            BorderSizePixel = 0,
        })
        corner(knob,9)

        mod.UI.Track = track
        mod.UI.Knob = knob

        local hit = make("TextButton", {
            Parent = row,
            Size = UDim2.fromOffset(70,SIZE.Row),
            Position = UDim2.new(1,-75,0,0),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            Modal = false,
        })

        table.insert(mod._connections, hit.MouseButton1Click:Connect(function()
            self:_setToggleState(mod, not mod.Enabled)
        end))

        self:_toggleVisual(mod)

    elseif typ == "select" or typ == "dropdown" then
        local box = make("TextButton", {
            Parent = row,
            Size = UDim2.fromOffset(110,24),
            Position = UDim2.new(1,-120,0.5,-12),
            BackgroundColor3 = Color3.fromRGB(40,40,40),
            BorderSizePixel = 0,
            Text = tostring(mod.Value or mod.Options[1] or "Select"),
            TextColor3 = COLORS.Text2,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            AutoButtonColor = false,
        })
        corner(box,5)

        table.insert(mod._connections, box.MouseButton1Click:Connect(function()
            if #mod.Options == 0 then return end

            local current = tostring(mod.Value or mod.Options[1])
            local index = 1
            for i,v in ipairs(mod.Options) do
                if tostring(v) == current then
                    index = i
                    break
                end
            end

            index = index % #mod.Options + 1
            mod.Value = mod.Options[index]
            box.Text = tostring(mod.Value)
            self:_fire(mod, mod.Value)
        end))

    elseif typ == "button" then
        local button = make("TextButton", {
            Parent = row,
            Size = UDim2.fromOffset(54,23),
            Position = UDim2.new(1,-64,0.5,-11.5),
            BackgroundColor3 = COLORS.Accent,
            BorderSizePixel = 0,
            Text = "Fire",
            TextColor3 = Color3.new(1,1,1),
            Font = Enum.Font.GothamMedium,
            TextSize = 10,
            AutoButtonColor = false,
            Modal = false,
        })
        corner(button,5)

        table.insert(mod._connections, button.MouseButton1Click:Connect(function()
            self:_fire(mod)
        end))

    elseif typ == "input" then
        local box = make("TextBox", {
            Parent = row,
            Size = UDim2.fromOffset(110,24),
            Position = UDim2.new(1,-120,0.5,-12),
            BackgroundColor3 = Color3.fromRGB(40,40,40),
            BorderSizePixel = 0,
            Text = tostring(mod.Value or ""),
            PlaceholderText = "Enter value...",
            TextColor3 = COLORS.Text2,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            ClearTextOnFocus = false,
        })
        corner(box,5)

        table.insert(mod._connections, box.FocusLost:Connect(function(enterPressed)
            if enterPressed then
                mod.Value = box.Text
                self:_fire(mod, box.Text)
            end
        end))
    end

    return row
end

function Builder:_makeGroup(parent, subcategory, modules, layoutOrder)
    local group = make("Frame", {
        Parent = parent,
        Size = UDim2.new(1,0,0,0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = layoutOrder,
    })
    group:SetAttribute("SBContent", true)

    make("UIListLayout", {
        Parent = group,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0,3),
    })

    make("TextLabel", {
        Parent = group,
        Size = UDim2.new(1,0,0,16),
        BackgroundTransparency = 1,
        Text = subcategory,
        TextColor3 = COLORS.Text3,
        Font = Enum.Font.GothamMedium,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        LayoutOrder = 0,
    })

    local rows = make("Frame", {
        Parent = group,
        Size = UDim2.new(1,0,0,0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
    })

    make("UIListLayout", {
        Parent = rows,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0,2),
    })

    for i,mod in ipairs(modules) do
        self:_makeRow(mod, rows, i)
    end
end

function Builder:_showCategory(category)
    self.ActiveCategory = category

    -- Rebuild UI connections without touching interval loop tokens.
    for _,mod in pairs(self.Modules) do
        disconnectAll(mod._connections)
        mod._connections = {}
        mod.UI = {}
    end

    if self.Content then
        for _,child in ipairs(self.Content:GetChildren()) do
            if child:GetAttribute("SBContent") then
                child:Destroy()
            end
        end
    end

    local list = self.CategoryMap[category] or {}
    local groups = {}
    local groupOrder = {}
    local ungrouped = {}
    local seen = {}

    for _,mod in ipairs(list) do
        if mod and not seen[mod.Name] then
            seen[mod.Name] = true

            if mod.Subcategory ~= "" then
                if not groups[mod.Subcategory] then
                    groups[mod.Subcategory] = {}
                    groupOrder[#groupOrder + 1] = mod.Subcategory
                end
                groups[mod.Subcategory][#groups[mod.Subcategory] + 1] = mod
            else
                ungrouped[#ungrouped + 1] = mod
            end
        end
    end

    for i,subcategory in ipairs(groupOrder) do
        self:_makeGroup(self.Content, subcategory, groups[subcategory], i)
    end

    local offset = #groupOrder + 1
    for i,mod in ipairs(ungrouped) do
        self:_makeRow(mod, self.Content, offset + i)
    end
end

function Builder:_setCategoryVisual(category)
    for name,button in pairs(self._categoryButtons) do
        TweenService:Create(button, EASE, {
            BackgroundColor3 = name == category and COLORS.Selected or COLORS.Sidebar,
        }):Play()
    end
end

local function headerButton(parent, text, position)
    local button = make("TextButton", {
        Parent = parent,
        Size = UDim2.fromOffset(28,28),
        Position = position,
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = COLORS.Text3,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        AutoButtonColor = false,
    })

    button.MouseEnter:Connect(function()
        TweenService:Create(button, EASE, {TextColor3 = COLORS.Text}):Play()
    end)

    button.MouseLeave:Connect(function()
        TweenService:Create(button, EASE, {TextColor3 = COLORS.Text3}):Play()
    end)

    return button
end

function Builder:_setMinimized(minimized)
    self._minimized = minimized
    if not self.Root then return end

    if minimized then
        self.Root.ClipsDescendants = true
        if self.Sidebar then self.Sidebar.Visible = false end
        if self.Body then self.Body.Visible = false end
        TweenService:Create(self.Root, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Size = UDim2.fromOffset(SIZE.W, SIZE.Header),
        }):Play()
    else
        TweenService:Create(self.Root, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Size = UDim2.fromOffset(SIZE.W, SIZE.H),
        }):Play()
        task.delay(0.12, function()
            if self.Sidebar then self.Sidebar.Visible = true end
            if self.Body then self.Body.Visible = true end
        end)
    end
end

function Builder:BuildGui()
    if self.Gui then self.Gui:Destroy() end
    disconnectAll(self._connections)

    for _,mod in pairs(self.Modules) do
        disconnectAll(mod._connections)
        mod._connections = {}
        mod.UI = {}
    end

    self._categoryButtons = {}
    self._minimized = false

    self.Gui = make("ScreenGui", {
        Name = "ScriptBuilder_" .. self.Name:gsub("%W", "_"),
        Parent = PlayerGui,
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    })

    self.Root = make("Frame", {
        Parent = self.Gui,
        Size = UDim2.fromOffset(SIZE.W, SIZE.H),
        Position = UDim2.new(0.5,-SIZE.W/2,0.5,-SIZE.H/2),
        BackgroundColor3 = COLORS.Outer,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    })
    corner(self.Root,6)
    stroke(self.Root,COLORS.Border,1,0.18)

    local header = make("Frame", {
        Parent = self.Root,
        Size = UDim2.new(1,0,0,SIZE.Header),
        BackgroundColor3 = COLORS.Header,
        BorderSizePixel = 0,
    })
    corner(header,6)
    make("Frame", {
        Parent = header,
        Size = UDim2.new(1,0,0,8),
        Position = UDim2.new(0,0,1,-8),
        BackgroundColor3 = COLORS.Header,
        BorderSizePixel = 0,
    })

    make("TextLabel", {
        Parent = header,
        Size = UDim2.new(0,240,1,0),
        Position = UDim2.fromOffset(15,0),
        BackgroundTransparency = 1,
        Text = self.Name,
        TextColor3 = COLORS.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    })

    self.StatusLabel = make("TextLabel", {
        Parent = header,
        Size = UDim2.fromOffset(1,1),
        Position = UDim2.fromOffset(0,0),
        BackgroundTransparency = 1,
        Text = self.Status,
        Visible = false,
    })

    local discord = headerButton(header,"●",UDim2.new(1,-139,0.5,-14))
    discord.TextColor3 = Color3.fromRGB(160,174,250)
    local youtube = headerButton(header,"▶",UDim2.new(1,-104,0.5,-14))
    youtube.TextColor3 = Color3.fromRGB(190,190,190)
    local minimize = headerButton(header,"−",UDim2.new(1,-70,0.5,-14))
    local close = headerButton(header,"×",UDim2.new(1,-35,0.5,-14))

    table.insert(self._connections, close.MouseButton1Click:Connect(function()
        self:Hide()
    end))

    table.insert(self._connections, minimize.MouseButton1Click:Connect(function()
        self:_setMinimized(not self._minimized)
    end))

    local dragging, dragStart, startPos = false, nil, nil

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

    self.Sidebar = make("Frame", {
        Parent = self.Root,
        Size = UDim2.new(0,SIZE.Sidebar,1,-SIZE.Header),
        Position = UDim2.new(0,0,0,SIZE.Header),
        BackgroundColor3 = COLORS.Sidebar,
        BorderSizePixel = 0,
    })

    make("UIPadding", {
        Parent = self.Sidebar,
        PaddingTop = UDim.new(0,8),
        PaddingLeft = UDim.new(0,7),
        PaddingRight = UDim.new(0,7),
        PaddingBottom = UDim.new(0,8),
    })

    make("UIListLayout", {
        Parent = self.Sidebar,
        Padding = UDim.new(0,5),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })

    for i,category in ipairs(self.Categories) do
        local button = make("TextButton", {
            Parent = self.Sidebar,
            Size = UDim2.new(1,0,0,33),
            LayoutOrder = i,
            BackgroundColor3 = COLORS.Sidebar,
            BorderSizePixel = 0,
            Text = "   " .. category,
            TextColor3 = COLORS.Text2,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
        })
        corner(button,5)

        make("TextLabel", {
            Parent = button,
            Size = UDim2.fromOffset(19,33),
            Position = UDim2.fromOffset(8,0),
            BackgroundTransparency = 1,
            Text = "⌁",
            TextColor3 = COLORS.Accent,
            Font = Enum.Font.GothamMedium,
            TextSize = 16,
            TextXAlignment = Enum.TextXAlignment.Center,
            TextYAlignment = Enum.TextYAlignment.Center,
        })

        self._categoryButtons[category] = button

        table.insert(self._connections, button.MouseEnter:Connect(function()
            if self.ActiveCategory ~= category then
                TweenService:Create(button,EASE,{BackgroundColor3=COLORS.Hover}):Play()
            end
        end))

        table.insert(self._connections, button.MouseLeave:Connect(function()
            if self.ActiveCategory ~= category then
                TweenService:Create(button,EASE,{BackgroundColor3=COLORS.Sidebar}):Play()
            end
        end))

        table.insert(self._connections, button.MouseButton1Click:Connect(function()
            self:_showCategory(category)
            self:_setCategoryVisual(category)
        end))
    end

    self.Body = make("Frame", {
        Parent = self.Root,
        Size = UDim2.new(1,-SIZE.Sidebar,1,-SIZE.Header),
        Position = UDim2.new(0,SIZE.Sidebar,0,SIZE.Header),
        BackgroundTransparency = 1,
    })

    self.Content = make("ScrollingFrame", {
        Parent = self.Body,
        Size = UDim2.new(1,0,1,0),
        BackgroundColor3 = COLORS.Content,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Color3.fromRGB(70,70,70),
        ScrollBarImageTransparency = 0.25,
    })

    make("UIPadding", {
        Parent = self.Content,
        PaddingTop = UDim.new(0,8),
        PaddingLeft = UDim.new(0,12),
        PaddingRight = UDim.new(0,12),
        PaddingBottom = UDim.new(0,10),
    })

    make("UIListLayout", {
        Parent = self.Content,
        Padding = UDim.new(0,7),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })

    local active = self.ActiveCategory or self.Categories[1]
    if active then
        self:_showCategory(active)
        self:_setCategoryVisual(active)
    end

    self.Gui.Enabled = self.Visible
    return self.Gui
end

function Builder:Show()
    if not self.Gui then self:BuildGui() end
    self.Gui.Enabled = true
    self.Visible = true
end

function Builder:Hide()
    if self.Gui then self.Gui.Enabled = false end
    self.Visible = false
end

function Builder:Toggle()
    if self.Visible then self:Hide() else self:Show() end
end

function Builder:Run()
    self:Show()
    if self._f7 then self._f7:Disconnect() end
    self._f7 = UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and input.KeyCode == Enum.KeyCode.F7 then
            self:Toggle()
        end
    end)
end

function Builder:SetModuleValue(name, value)
    local mod = self.Modules[name]
    if not mod then return false end

    if string.lower(mod.Type) == "toggle" then
        self:_setToggleState(mod, value == true)
    else
        mod.Value = value
    end

    return true
end

function Builder:GetModule(name)
    return self.Modules[name]
end

function Builder:GetAllModules()
    return self.Modules
end

function Builder:FireModule(name, ...)
    local mod = self.Modules[name]
    if not mod then return false end
    return self:_fire(mod, ...)
end

function Builder:StatusText(text)
    self.Status = tostring(text)
    self:_updateStatus()
end

function Builder:AddRemote(name, category, remote, options)
    options = options or {}
    options.Name = name
    options.Category = category or options.Category or "Settings"
    options.Remote = remote
    return self:AddModule(options)
end

function Builder:AddRemoteSpy(category, name, snippet, options)
    options = options or {}
    options.Name = name or options.Name or "Remote Spy"
    options.Category = category or options.Category or "Settings"
    options.Snippet = snippet
    return self:AddModule(options)
end

_G.Builder = Builder
return Builder
