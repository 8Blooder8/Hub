-- ScriptBuilder.lua
-- Executor-friendly GUI builder.
-- Remote resolver accepts Instances, normal paths and Lua-style expressions.

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
    local ok, result = pcall(function()
        return game:GetService(name)
    end)
    return ok and result or nil
end

local ROOTS = {
    game = function() return game end,
    ReplicatedStorage = function() return ReplicatedStorage end,
    Players = function() return Players end,
    workspace = function() return workspace end,
    Workspace = function() return workspace end,
}

-- Resolve a dotted Roblox instance path without loadstring.
local function resolveBase(path)
    path = trim(path)
    if path == "" then return nil end

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

        local rootFactory = ROOTS[rootName]
        node = rootFactory and rootFactory() or nil
        rest = remainder
        if not node then return nil end
    end

    for part in tostring(rest):gmatch("[^%.]+") do
        node = node:FindFirstChild(part)
        if not node then return nil end
    end

    return node
end

local function resolveGetChildrenIndex(path)
    local prefix, index = path:match("^(.-):%s*GetChildren%s*%(%s*%)%s*%[%s*(%d+)%s*%]$")
    if not prefix then return nil end

    local parent = resolveBase(prefix)
    if not parent then return nil end

    local children = parent:GetChildren()
    local child = children[tonumber(index)]
    return child
end

-- Last-resort expression resolver with an explicit environment.
-- This is deliberately isolated from the common path above.
local function resolveExpression(path)
    if not loadstring then return nil end

    local fn, err = loadstring("return " .. path)
    if not fn then return nil, err end

    local env = {
        game = game,
        workspace = workspace,
        Workspace = workspace,
        ReplicatedStorage = ReplicatedStorage,
        Players = Players,
    }

    local okSet = false
    if setfenv then
        okSet = pcall(setfenv, fn, env)
    end

    local ok, result = pcall(fn)
    if ok and typeof(result) == "Instance" then
        return result
    end

    return nil, result
end

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

    -- Exact syntax used by the user's working script:
    -- ReplicatedStorage.Remotes:GetChildren()[70]
    local child = resolveGetChildrenIndex(path)
    if child ~= nil then
        return isRemote(child) and child or nil
    end

    -- Normal dotted path:
    -- ReplicatedStorage.Remotes.SomeRemote
    local direct = resolveBase(path)
    if isRemote(direct) then
        return direct
    end

    -- Also support more complicated valid Lua expressions.
    local expressionResult = resolveExpression(path)
    if isRemote(expressionResult) then
        return expressionResult
    end

    return nil
end

local function evalValue(value)
    if type(value) ~= "table" or value.__expr == nil then
        return value
    end

    local result = select(1, resolveExpression(tostring(value.__expr)))
    return result
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
            Position = UDim2.new(1,-121,0.5,-12),
            BackgroundColor3 = COLORS.Selected,
            BorderSizePixel = 0,
            TextColor3 = COLORS.Text,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            AutoButtonColor = false,
            Text = tostring(mod.Value or mod.Options[1] or "Select"),
        })
        corner(box,4)
        stroke(box, COLORS.Border, 1, 0.55)
        mod.UI.Box = box

        local idx = 1
        for i,opt in ipairs(mod.Options) do
            if opt == mod.Value then idx = i break end
        end
        table.insert(mod._connections, box.MouseButton1Click:Connect(function()
            if #mod.Options == 0 then return end
            idx = idx % #mod.Options + 1
            mod.Value = mod.Options[idx]
            box.Text = tostring(mod.Value)
            self:_fire(mod, mod.Value)
        end))

    elseif typ == "input" or typ == "textbox" then
        local box = make("TextBox", {
            Parent = row,
            Size = UDim2.fromOffset(110,24),
            Position = UDim2.new(1,-121,0.5,-12),
            BackgroundColor3 = COLORS.Selected,
            BorderSizePixel = 0,
            TextColor3 = COLORS.Text,
            PlaceholderColor3 = COLORS.Text3,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            ClearTextOnFocus = false,
            Text = tostring(mod.Value or ""),
            PlaceholderText = tostring(mod.Placeholder or "Value"),
        })
        corner(box,4)
        stroke(box, COLORS.Border, 1, 0.55)
        mod.UI.Box = box

        table.insert(mod._connections, box.FocusLost:Connect(function(enterPressed)
            mod.Value = box.Text
            if enterPressed then self:_fire(mod, box.Text) end
        end))

    else
        local button = make("TextButton", {
            Parent = row,
            Size = UDim2.fromOffset(110,24),
            Position = UDim2.new(1,-121,0.5,-12),
            BackgroundColor3 = COLORS.Selected,
            BorderSizePixel = 0,
            Text = tostring(mod.ButtonText or "Execute"),
            TextColor3 = COLORS.Text,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            AutoButtonColor = false,
        })
        corner(button,4)
        stroke(button, COLORS.Border, 1, 0.55)
        mod.UI.Button = button

        table.insert(mod._connections, button.MouseButton1Click:Connect(function()
            self:_fire(mod)
        end))
    end

    return row
end

function Builder:_clearContent()
    if not self.Content then return end
    for _,obj in ipairs(self.Content:GetChildren()) do
        if obj:GetAttribute("SBContent") then
            obj:Destroy()
        end
    end

    for _,mod in pairs(self.Modules) do
        mod.UI = {}
        mod._connections = {}
    end
end

function Builder:_showCategory(category)
    if not self.Content then return end
    self.ActiveCategory = category
    self:_clearContent()

    local list = self.CategoryMap[category] or {}
    local grouped = {}
    local ungrouped = {}
    local groupOrder = {}

    for _,mod in ipairs(list) do
        local sub = trim(mod.Subcategory)
        if sub == "" then
            table.insert(ungrouped, mod)
        else
            if not grouped[sub] then
                grouped[sub] = {}
                table.insert(groupOrder, sub)
            end
            table.insert(grouped[sub], mod)
        end
    end

    table.sort(groupOrder, function(a,b) return a:lower() < b:lower() end)
    table.sort(ungrouped, function(a,b) return a.Name:lower() < b.Name:lower() end)

    local order = 1
    for _,sub in ipairs(groupOrder) do
        make("TextLabel", {
            Parent = self.Content,
            Size = UDim2.new(1,0,0,22),
            BackgroundTransparency = 1,
            Text = sub,
            TextColor3 = COLORS.Text3,
            Font = Enum.Font.GothamSemibold,
            TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            LayoutOrder = order,
            Attribute = nil,
        })
        local label = self.Content:GetChildren()[#self.Content:GetChildren()]
        label:SetAttribute("SBContent", true)
        order += 1

        table.sort(grouped[sub], function(a,b) return a.Name:lower() < b.Name:lower() end)
        for _,mod in ipairs(grouped[sub]) do
            self:_makeRow(mod, self.Content, order)
            order += 1
        end
    end

    for _,mod in ipairs(ungrouped) do
        self:_makeRow(mod, self.Content, order)
        order += 1
    end
end

function Builder:BuildGui()
    if self.Gui then
        pcall(function() self.Gui:Destroy() end)
    end
    disconnectAll(self._connections)
    for _,mod in pairs(self.Modules) do
        disconnectAll(mod._connections)
    end

    local gui = make("ScreenGui", {
        Parent = PlayerGui,
        Name = self.Name .. "_UI",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    })

    local root = make("Frame", {
        Parent = gui,
        Name = "Root",
        Size = UDim2.fromOffset(SIZE.W,SIZE.H),
        Position = UDim2.new(0.5,-SIZE.W/2,0.5,-SIZE.H/2),
        BackgroundColor3 = COLORS.Outer,
        BorderSizePixel = 0,
    })
    corner(root,6)
    stroke(root, COLORS.Border, 1, 0.2)

    local header = make("Frame", {
        Parent = root,
        Size = UDim2.new(1,0,0,SIZE.Header),
        BackgroundColor3 = COLORS.Header,
        BorderSizePixel = 0,
    })
    corner(header,6)

    make("TextLabel", {
        Parent = header,
        BackgroundTransparency = 1,
        Size = UDim2.new(1,-90,1,0),
        Position = UDim2.fromOffset(15,0),
        Text = self.Name,
        TextColor3 = COLORS.Text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    })

    local close = make("TextButton", {
        Parent = header,
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(35,47),
        Position = UDim2.new(1,-35,0,0),
        Text = "×",
        TextColor3 = COLORS.Text2,
        Font = Enum.Font.GothamBold,
        TextSize = 19,
        AutoButtonColor = false,
    })

    local minimize = make("TextButton", {
        Parent = header,
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(35,47),
        Position = UDim2.new(1,-70,0,0),
        Text = "—",
        TextColor3 = COLORS.Text2,
        Font = Enum.Font.GothamBold,
        TextSize = 17,
        AutoButtonColor = false,
    })

    local body = make("Frame", {
        Parent = root,
        Position = UDim2.fromOffset(0,SIZE.Header),
        Size = UDim2.new(1,0,1,-SIZE.Header),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    })

    local sidebar = make("Frame", {
        Parent = body,
        Size = UDim2.new(0,SIZE.Sidebar,1,0),
        BackgroundColor3 = COLORS.Sidebar,
        BorderSizePixel = 0,
    })

    local content = make("Frame", {
        Parent = body,
        Position = UDim2.fromOffset(SIZE.Sidebar,0),
        Size = UDim2.new(1,-SIZE.Sidebar,1,0),
        BackgroundColor3 = COLORS.Content,
        BorderSizePixel = 0,
    })

    local sideList = make("UIListLayout", {
        Parent = sidebar,
        Padding = UDim.new(0,2),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })

    make("UIPadding", {
        Parent = sidebar,
        PaddingTop = UDim.new(0,7),
        PaddingLeft = UDim.new(0,7),
        PaddingRight = UDim.new(0,7),
    })

    local contentList = make("UIListLayout", {
        Parent = content,
        Padding = UDim.new(0,5),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
    make("UIPadding", {
        Parent = content,
        PaddingTop = UDim.new(0,8),
        PaddingLeft = UDim.new(0,8),
        PaddingRight = UDim.new(0,8),
        PaddingBottom = UDim.new(0,8),
    })

    local footer = make("TextLabel", {
        Parent = root,
        AnchorPoint = Vector2.new(1,1),
        Position = UDim2.new(1,-8,1,-5),
        Size = UDim2.fromOffset(240,16),
        BackgroundTransparency = 1,
        Text = self.Status,
        TextColor3 = COLORS.Text3,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextYAlignment = Enum.TextYAlignment.Center,
        ZIndex = 10,
    })

    self.Gui = gui
    self.Root = root
    self.Content = content
    self.Sidebar = sidebar
    self.Body = body
    self.StatusLabel = footer
    self._categoryButtons = {}

    for i,category in ipairs(self.Categories) do
        local b = make("TextButton", {
            Parent = sidebar,
            Size = UDim2.new(1,0,0,32),
            BackgroundColor3 = i == 1 and COLORS.Selected or COLORS.Sidebar,
            BorderSizePixel = 0,
            Text = category,
            TextColor3 = i == 1 and COLORS.Text or COLORS.Text2,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            AutoButtonColor = false,
        })
        corner(b,4)
        b.LayoutOrder = i
        self._categoryButtons[category] = b

        table.insert(self._connections, b.MouseEnter:Connect(function()
            if self.ActiveCategory ~= category then
                TweenService:Create(b, EASE, {BackgroundColor3 = COLORS.Hover}):Play()
            end
        end))
        table.insert(self._connections, b.MouseLeave:Connect(function()
            if self.ActiveCategory ~= category then
                TweenService:Create(b, EASE, {BackgroundColor3 = COLORS.Sidebar}):Play()
            end
        end))
        table.insert(self._connections, b.MouseButton1Click:Connect(function()
            self:_showCategory(category)
            for cat,btn in pairs(self._categoryButtons) do
                TweenService:Create(btn, EASE, {
                    BackgroundColor3 = cat == category and COLORS.Selected or COLORS.Sidebar,
                    TextColor3 = cat == category and COLORS.Text or COLORS.Text2,
                }):Play()
            end
        end))
    end

    if self.Categories[1] then
        self:_showCategory(self.Categories[1])
    end

    local dragging = false
    local dragStart, startPos

    table.insert(self._connections, header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = root.Position
        end
    end))

    table.insert(self._connections, UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            root.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end))

    table.insert(self._connections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end))

    table.insert(self._connections, close.MouseButton1Click:Connect(function()
        self:Hide()
    end))

    table.insert(self._connections, minimize.MouseButton1Click:Connect(function()
        self._minimized = not self._minimized
        body.Visible = not self._minimized
        root.Size = self._minimized
            and UDim2.fromOffset(SIZE.W,SIZE.Header)
            or UDim2.fromOffset(SIZE.W,SIZE.H)
    end))

    return self
end

function Builder:Show()
    if not self.Gui then self:BuildGui() end
    self.Gui.Enabled = true
    self.Visible = true
    return self
end

function Builder:Hide()
    if self.Gui then self.Gui.Enabled = false end
    self.Visible = false
    return self
end

function Builder:Toggle()
    if self.Visible then return self:Hide() end
    return self:Show()
end

function Builder:FireModule(name, extra)
    local mod = self.Modules[name]
    if not mod then return false, "Module not found" end
    return self:_invokeRemote(mod, extra)
end

function Builder:AddRemote(name, remote)
    assert(name, "AddRemote: name is required")
    self.Config.Remotes = self.Config.Remotes or {}
    self.Config.Remotes[name] = remote
    return remote
end

function Builder:AddRemoteSpy(callback)
    assert(type(callback) == "function", "AddRemoteSpy expects a function")
    self.Config.RemoteSpy = callback
    return self
end

return Builder
