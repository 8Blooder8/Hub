-- ScriptBuilder.lua
-- Simple module builder.
-- A module only needs Name, Category, optional Subcategory, Type, Interval,
-- optional Params and a Lua Code snippet. No Remote/Args API is required.

local Players = game:GetService("Players")
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
    local object = Instance.new(className)
    for key, value in pairs(props or {}) do
        if key ~= "Parent" then object[key] = value end
    end
    if props and props.Parent then object.Parent = props.Parent end
    return object
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

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function disconnectAll(list)
    for i = #list, 1, -1 do
        pcall(function() list[i]:Disconnect() end)
        list[i] = nil
    end
end

local function globalEnv()
    if getgenv then
        local ok, env = pcall(getgenv)
        if ok and type(env) == "table" then return env end
    end
    return _G
end

local function executeSnippet(mod, value)
    local code = trim(mod.Code)
    if code == "" then return false, "Code is empty" end

    local compiler = loadstring or load
    if not compiler then return false, "loadstring/load is unavailable" end

    local fn, compileError = compiler(code)
    if not fn then return false, compileError end

    local env = {
        game = game,
        workspace = workspace,
        Workspace = workspace,
        Players = Players,
        LocalPlayer = Player,
        UserInputService = UserInputService,
        TweenService = TweenService,
        Enum = Enum,
        task = task,
        math = math,
        string = string,
        table = table,
        typeof = typeof,
        print = print,
        warn = warn,

        module = mod,
        value = value,
        Value = value,
        enabled = mod.Enabled == true,
        Enabled = mod.Enabled == true,
        params = mod.Params,
        Params = mod.Params,
    }

    if setfenv then
        local ok, envError = pcall(setfenv, fn, setmetatable(env, {__index=globalEnv()}))
        if not ok then return false, envError end
    end

    return pcall(fn)
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

function Builder:_updateStatus()
    if self.StatusLabel then self.StatusLabel.Text = self.Status end
end

function Builder:_stopInterval(mod)
    mod._loopToken = (mod._loopToken or 0) + 1
    mod._loopRunning = false
end

function Builder:_execute(mod, value)
    local ok, result = executeSnippet(mod, value ~= nil and value or mod.Value)
    self.Status = ok and (mod.Name .. ": OK") or (mod.Name .. ": " .. tostring(result))
    self:_updateStatus()
    if not ok then warn("[ScriptBuilder] " .. self.Status) end
    return ok, result
end

function Builder:_fire(mod, value)
    task.spawn(function()
        self:_execute(mod, value ~= nil and value or mod.Value)
    end)
    return true
end

function Builder:_startInterval(mod)
    local interval = tonumber(mod.Interval)
    if not interval or interval <= 0 then
        self:_fire(mod, mod.Value)
        return
    end

    self:_stopInterval(mod)
    interval = math.max(interval, MIN_INTERVAL)
    local token = mod._loopToken
    mod._loopRunning = true

    task.spawn(function()
        while mod.Enabled and mod._loopToken == token do
            self:_execute(mod, mod.Value)
            if not mod.Enabled or mod._loopToken ~= token then break end
            task.wait(interval)
        end
        if mod._loopToken == token then mod._loopRunning = false end
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
            self:_fire(mod, true)
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
                if oldList[i] == old then table.remove(oldList, i) end
            end
            if #oldList == 0 then
                self.CategoryMap[old.Category] = nil
                for i = #self.Categories, 1, -1 do
                    if self.Categories[i] == old.Category then table.remove(self.Categories, i) end
                end
            end
        end
    end

    local params = type(def.Params) == "table" and def.Params or {}
    local typ = tostring(def.Type or "Button")
    local lowerType = typ:lower()

    local mod = {}
    for key, value in pairs(def) do mod[key] = value end
    mod.Name = name
    mod.Category = category
    mod.Subcategory = trim(def.Subcategory or "")
    mod.Type = typ
    mod.Interval = tonumber(def.Interval)
    mod.Params = params
    mod.Options = type(params.Options) == "table" and params.Options or {}
    mod.Code = tostring(def.Code or "")
    mod.Value = def.Value
    if mod.Value == nil then mod.Value = params.Default end
    if lowerType == "toggle" then mod.Enabled = def.Enabled == true or params.Default == true else mod.Enabled = false end
    mod.UI = {}
    mod._connections = {}
    mod._loopToken = 0
    mod._loopRunning = false

    if lowerType == "slider" then
        mod.Params.Min = tonumber(mod.Params.Min) or 0
        mod.Params.Max = tonumber(mod.Params.Max) or 100
        mod.Params.Step = math.max(tonumber(mod.Params.Step) or 1, 0.000001)
        mod.Value = tonumber(mod.Value) or mod.Params.Min
        mod.Value = math.clamp(mod.Value, mod.Params.Min, mod.Params.Max)
    elseif lowerType == "select" or lowerType == "dropdown" then
        if mod.Value == nil then mod.Value = mod.Options[1] end
    end

    self.Modules[name] = mod
    if not self.CategoryMap[category] then
        self.CategoryMap[category] = {}
        table.insert(self.Categories, category)
    end
    table.insert(self.CategoryMap[category], mod)

    if mod.Code == "" then warn("[ScriptBuilder] " .. name .. ": Code is empty") end
    if self.Gui then self:BuildGui() end
    return mod
end

function Builder:AddModules(list)
    for _, def in ipairs(list or {}) do self:AddModule(def) end
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
            if list[i] == mod then table.remove(list, i) end
        end
        if #list == 0 then
            self.CategoryMap[mod.Category] = nil
            for i = #self.Categories, 1, -1 do
                if self.Categories[i] == mod.Category then table.remove(self.Categories, i) end
            end
        end
    end
    if self.Gui then self:BuildGui() end
    return true
end

function Builder:_makeRow(mod, parent, order)
    local row = make("Frame", {
        Parent=parent,
        Size=UDim2.new(1,0,0,SIZE.Row),
        BackgroundColor3=COLORS.Row,
        BorderSizePixel=0,
        LayoutOrder=order,
    })
    row:SetAttribute("SBContent", true)
    corner(row,5)
    stroke(row, Color3.fromRGB(47,47,47),1,0.65)

    make("TextLabel", {
        Parent=row, BackgroundTransparency=1,
        Size=UDim2.new(1,-125,1,0), Position=UDim2.fromOffset(11,0),
        Text=mod.Name, TextColor3=COLORS.Text2, Font=Enum.Font.Gotham, TextSize=11,
        TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Center,
    })

    table.insert(mod._connections, row.MouseEnter:Connect(function()
        TweenService:Create(row,EASE,{BackgroundColor3=COLORS.Hover}):Play()
    end))
    table.insert(mod._connections, row.MouseLeave:Connect(function()
        TweenService:Create(row,EASE,{BackgroundColor3=COLORS.Row}):Play()
    end))

    local typ = mod.Type:lower()

    if typ == "toggle" then
        local track = make("Frame", {
            Parent=row, Size=UDim2.fromOffset(39,20), Position=UDim2.new(1,-51,0.5,-10),
            BackgroundColor3=COLORS.ToggleOff, BorderSizePixel=0,
        })
        corner(track,10)
        local knob = make("Frame", {
            Parent=track, Size=UDim2.fromOffset(18,18), Position=UDim2.new(0,1,0.5,-9),
            BackgroundColor3=COLORS.Knob, BorderSizePixel=0,
        })
        corner(knob,9)
        mod.UI.Track, mod.UI.Knob = track, knob
        local hit = make("TextButton", {
            Parent=row, Size=UDim2.fromOffset(70,SIZE.Row), Position=UDim2.new(1,-75,0,0),
            BackgroundTransparency=1, BorderSizePixel=0, Text="", AutoButtonColor=false,
        })
        table.insert(mod._connections, hit.MouseButton1Click:Connect(function()
            self:_setToggleState(mod, not mod.Enabled)
        end))
        self:_toggleVisual(mod)

    elseif typ == "slider" then
        local p = mod.Params
        local minValue, maxValue, step = p.Min, p.Max, p.Step
        local slider = make("Frame", {
            Parent=row, Size=UDim2.fromOffset(110,24), Position=UDim2.new(1,-121,0.5,-12),
            BackgroundTransparency=1, BorderSizePixel=0,
        })
        local bar = make("Frame", {
            Parent=slider, Size=UDim2.new(1,0,0,4), Position=UDim2.new(0,0,0.5,-2),
            BackgroundColor3=COLORS.ToggleOff, BorderSizePixel=0,
        })
        corner(bar,2)
        local fill = make("Frame", {
            Parent=bar, Size=UDim2.new(0,0,1,0), BackgroundColor3=COLORS.Accent, BorderSizePixel=0,
        })
        corner(fill,2)
        local knob = make("Frame", {
            Parent=slider, Size=UDim2.fromOffset(10,10), AnchorPoint=Vector2.new(0.5,0.5),
            BackgroundColor3=COLORS.Knob, BorderSizePixel=0,
        })
        corner(knob,5)
        local hit = make("TextButton", {
            Parent=slider, Size=UDim2.new(1,0,1,0), BackgroundTransparency=1,
            BorderSizePixel=0, Text="", AutoButtonColor=false,
        })

        local function render()
            local alpha = maxValue > minValue and math.clamp((mod.Value-minValue)/(maxValue-minValue),0,1) or 0
            fill.Size = UDim2.new(alpha,0,1,0)
            knob.Position = UDim2.new(alpha,0,0.5,0)
        end
        local function setValue(x)
            local width = math.max(slider.AbsoluteSize.X,1)
            local alpha = math.clamp((x-slider.AbsolutePosition.X)/width,0,1)
            local raw = minValue+(maxValue-minValue)*alpha
            mod.Value = math.clamp(minValue+math.round((raw-minValue)/step)*step,minValue,maxValue)
            render()
            self:_fire(mod,mod.Value)
        end
        local dragging = false
        table.insert(mod._connections, hit.MouseButton1Down:Connect(function()
            dragging=true
            setValue(UserInputService:GetMouseLocation().X)
        end))
        table.insert(mod._connections, UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then setValue(input.Position.X) end
        end))
        table.insert(mod._connections, UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging=false end
        end))
        mod.UI.Slider,mod.UI.Fill,mod.UI.Knob=slider,fill,knob
        render()

    elseif typ == "select" or typ == "dropdown" then
        local box = make("TextButton", {
            Parent=row, Size=UDim2.fromOffset(110,24), Position=UDim2.new(1,-121,0.5,-12),
            BackgroundColor3=COLORS.Selected, BorderSizePixel=0, TextColor3=COLORS.Text,
            Font=Enum.Font.Gotham, TextSize=10, AutoButtonColor=false,
            Text=tostring(mod.Value or "Select"),
        })
        corner(box,4); stroke(box,COLORS.Border,1,0.55); mod.UI.Box=box
        local index=1
        for i,opt in ipairs(mod.Options) do if opt==mod.Value then index=i break end end
        table.insert(mod._connections,box.MouseButton1Click:Connect(function()
            if #mod.Options==0 then return end
            index=index%#mod.Options+1
            mod.Value=mod.Options[index]
            box.Text=tostring(mod.Value)
            self:_fire(mod,mod.Value)
        end))

    elseif typ == "input" or typ == "textbox" then
        local box = make("TextBox", {
            Parent=row, Size=UDim2.fromOffset(110,24), Position=UDim2.new(1,-121,0.5,-12),
            BackgroundColor3=COLORS.Selected, BorderSizePixel=0, TextColor3=COLORS.Text,
            PlaceholderColor3=COLORS.Text3, Font=Enum.Font.Gotham, TextSize=10,
            ClearTextOnFocus=false, Text=tostring(mod.Value or ""),
            PlaceholderText=tostring(mod.Params.Placeholder or "Value"),
        })
        corner(box,4); stroke(box,COLORS.Border,1,0.55); mod.UI.Box=box
        table.insert(mod._connections,box.FocusLost:Connect(function(enterPressed)
            mod.Value=box.Text
            if enterPressed then self:_fire(mod,box.Text) end
        end))

    else
        local button = make("TextButton", {
            Parent=row, Size=UDim2.fromOffset(110,24), Position=UDim2.new(1,-121,0.5,-12),
            BackgroundColor3=COLORS.Selected, BorderSizePixel=0,
            Text=tostring(mod.Params.ButtonText or mod.ButtonText or "Execute"),
            TextColor3=COLORS.Text, Font=Enum.Font.Gotham, TextSize=10, AutoButtonColor=false,
        })
        corner(button,4); stroke(button,COLORS.Border,1,0.55); mod.UI.Button=button
        table.insert(mod._connections,button.MouseButton1Click:Connect(function() self:_fire(mod,mod.Value) end))
    end

    return row
end

function Builder:_clearContent()
    if not self.Content then return end
    for _, object in ipairs(self.Content:GetChildren()) do
        if object:GetAttribute("SBContent") then object:Destroy() end
    end
    for _, mod in pairs(self.Modules) do
        mod.UI={}
        mod._connections={}
    end
end

function Builder:_showCategory(category)
    if not self.Content then return end
    self.ActiveCategory=category
    self:_clearContent()
    local list=self.CategoryMap[category] or {}
    local grouped, ungrouped, orderGroups={},{},{}
    for _,mod in ipairs(list) do
        local sub=trim(mod.Subcategory)
        if sub=="" then table.insert(ungrouped,mod) else
            if not grouped[sub] then grouped[sub]={}; table.insert(orderGroups,sub) end
            table.insert(grouped[sub],mod)
        end
    end
    table.sort(orderGroups,function(a,b)return a:lower()<b:lower()end)
    table.sort(ungrouped,function(a,b)return a.Name:lower()<b.Name:lower()end)
    local order=1
    for _,sub in ipairs(orderGroups) do
        local label=make("TextLabel",{
            Parent=self.Content,Size=UDim2.new(1,0,0,22),BackgroundTransparency=1,
            Text=sub,TextColor3=COLORS.Text3,Font=Enum.Font.GothamSemibold,TextSize=10,
            TextXAlignment=Enum.TextXAlignment.Left,LayoutOrder=order,
        })
        label:SetAttribute("SBContent",true); order+=1
        table.sort(grouped[sub],function(a,b)return a.Name:lower()<b.Name:lower()end)
        for _,mod in ipairs(grouped[sub]) do self:_makeRow(mod,self.Content,order);order+=1 end
    end
    for _,mod in ipairs(ungrouped) do self:_makeRow(mod,self.Content,order);order+=1 end
end

function Builder:BuildGui()
    if self.Gui then pcall(function() self.Gui:Destroy() end) end
    disconnectAll(self._connections)
    for _,mod in pairs(self.Modules) do disconnectAll(mod._connections) end

    local gui=make("ScreenGui",{
        Parent=PlayerGui,Name=self.Name.."_UI",ResetOnSpawn=false,IgnoreGuiInset=true,
        ZIndexBehavior=Enum.ZIndexBehavior.Sibling,DisplayOrder=9999,
    })
    local root=make("Frame",{
        Parent=gui,Name="Root",Size=UDim2.fromOffset(SIZE.W,SIZE.H),
        Position=UDim2.new(0.5,-SIZE.W/2,0.5,-SIZE.H/2),BackgroundColor3=COLORS.Outer,BorderSizePixel=0,
    })
    corner(root,6);stroke(root,COLORS.Border,1,0.2)
    local header=make("Frame",{Parent=root,Size=UDim2.new(1,0,0,SIZE.Header),BackgroundColor3=COLORS.Header,BorderSizePixel=0})
    corner(header,6)
    make("TextLabel",{
        Parent=header,BackgroundTransparency=1,Size=UDim2.new(1,-90,1,0),Position=UDim2.fromOffset(15,0),
        Text=self.Name,TextColor3=COLORS.Text,Font=Enum.Font.GothamSemibold,TextSize=13,
        TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Center,
    })
    local close=make("TextButton",{
        Parent=header,BackgroundTransparency=1,Size=UDim2.fromOffset(35,47),Position=UDim2.new(1,-35,0,0),
        Text="×",TextColor3=COLORS.Text2,Font=Enum.Font.GothamBold,TextSize=19,AutoButtonColor=false,
    })
    local minimize=make("TextButton",{
        Parent=header,BackgroundTransparency=1,Size=UDim2.fromOffset(35,47),Position=UDim2.new(1,-70,0,0),
        Text="—",TextColor3=COLORS.Text2,Font=Enum.Font.GothamBold,TextSize=17,AutoButtonColor=false,
    })
    local body=make("Frame",{Parent=root,Position=UDim2.fromOffset(0,SIZE.Header),Size=UDim2.new(1,0,1,-SIZE.Header),BackgroundTransparency=1,BorderSizePixel=0})
    local sidebar=make("Frame",{Parent=body,Size=UDim2.new(0,SIZE.Sidebar,1,0),BackgroundColor3=COLORS.Sidebar,BorderSizePixel=0})
    local content=make("Frame",{Parent=body,Position=UDim2.fromOffset(SIZE.Sidebar,0),Size=UDim2.new(1,-SIZE.Sidebar,1,0),BackgroundColor3=COLORS.Content,BorderSizePixel=0})
    make("UIListLayout",{Parent=sidebar,Padding=UDim.new(0,2),SortOrder=Enum.SortOrder.LayoutOrder})
    make("UIPadding",{Parent=sidebar,PaddingTop=UDim.new(0,7),PaddingLeft=UDim.new(0,7),PaddingRight=UDim.new(0,7)})
    make("UIListLayout",{Parent=content,Padding=UDim.new(0,5),SortOrder=Enum.SortOrder.LayoutOrder})
    make("UIPadding",{Parent=content,PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8)})
    local footer=make("TextLabel",{
        Parent=root,AnchorPoint=Vector2.new(1,1),Position=UDim2.new(1,-8,1,-5),Size=UDim2.fromOffset(240,16),
        BackgroundTransparency=1,Text=self.Status,TextColor3=COLORS.Text3,Font=Enum.Font.Gotham,TextSize=9,
        TextXAlignment=Enum.TextXAlignment.Right,TextYAlignment=Enum.TextYAlignment.Center,ZIndex=10,
    })

    self.Gui,self.Root,self.Content,self.Sidebar,self.Body,self.StatusLabel=gui,root,content,sidebar,body,footer
    self._categoryButtons={}

    for index,category in ipairs(self.Categories) do
        local button=make("TextButton",{
            Parent=sidebar,Size=UDim2.new(1,0,0,32),BackgroundColor3=index==1 and COLORS.Selected or COLORS.Sidebar,
            BorderSizePixel=0,Text=category,TextColor3=index==1 and COLORS.Text or COLORS.Text2,
            Font=Enum.Font.Gotham,TextSize=10,AutoButtonColor=false,LayoutOrder=index,
        })
        corner(button,4);self._categoryButtons[category]=button
        table.insert(self._connections,button.MouseButton1Click:Connect(function()
            self:_showCategory(category)
            for cat,b in pairs(self._categoryButtons) do
                TweenService:Create(b,EASE,{BackgroundColor3=cat==category and COLORS.Selected or COLORS.Sidebar,TextColor3=cat==category and COLORS.Text or COLORS.Text2}):Play()
            end
        end))
    end
    if self.Categories[1] then self:_showCategory(self.Categories[1]) end

    local dragging=false;local dragStart;local startPos
    table.insert(self._connections,header.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=true;dragStart=input.Position;startPos=root.Position end
    end))
    table.insert(self._connections,UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType==Enum.UserInputType.MouseMovement then
            local delta=input.Position-dragStart
            root.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+delta.X,startPos.Y.Scale,startPos.Y.Offset+delta.Y)
        end
    end))
    table.insert(self._connections,UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
    end))
    table.insert(self._connections,close.MouseButton1Click:Connect(function() self:Hide() end))
    table.insert(self._connections,minimize.MouseButton1Click:Connect(function()
        self._minimized=not self._minimized
        body.Visible=not self._minimized
        root.Size=self._minimized and UDim2.fromOffset(SIZE.W,SIZE.Header) or UDim2.fromOffset(SIZE.W,SIZE.H)
    end))

    return self
end

function Builder:Show()
    if not self.Gui then self:BuildGui() end
    self.Gui.Enabled=true;self.Visible=true
    return self
end

function Builder:Hide()
    if self.Gui then self.Gui.Enabled=false end
    self.Visible=false
    return self
end

function Builder:Toggle()
    if self.Visible then return self:Hide() end
    return self:Show()
end

function Builder:FireModule(name, value)
    local mod=self.Modules[name]
    if not mod then return false,"Module not found" end
    if value~=nil then mod.Value=value end
    return self:_execute(mod,mod.Value)
end

return Builder
