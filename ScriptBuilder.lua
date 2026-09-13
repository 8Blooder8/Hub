-- ScriptBuilder.lua
-- Simple executor-friendly GUI builder.
-- Workflow:
--   local Builder = loadstring(game:HttpGet(URL))()
--   local gui = Builder.New("My GUI")
--   gui:AddModule({Name="Auto Farm", Category="Autofarms", Control={Type="Toggle"}, Remote="ReplicatedStorage.Remotes.Example", Args={"Base"}})
--   gui:BuildGui()
--   gui:Show()
--
-- Args are literal values by default:
--   "Base" -> string Base
--   123 -> number 123
--   true / false -> boolean
--   nil -> nil
--
-- For a dynamic Lua expression, use { __expr = "game.Players.LocalPlayer" }.

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
    Sidebar = Color3.fromRGB(20,20,20),
    Content = Color3.fromRGB(17,17,17),
    Row = Color3.fromRGB(35,35,35),
    Text = Color3.fromRGB(235,235,235),
    Text2 = Color3.fromRGB(190,190,190),
    Text3 = Color3.fromRGB(130,130,130),
    Accent = Color3.fromRGB(111,168,247),
    ToggleOff = Color3.fromRGB(78,78,78),
}

local SIZE = {W=532,H=349,Header=39,Sidebar=123,Row=33,Gap=5}

local function make(className, props)
    local o = Instance.new(className)
    for k,v in pairs(props or {}) do
        if k ~= "Parent" then o[k] = v end
    end
    if props and props.Parent then o.Parent = props.Parent end
    return o
end

local function corner(parent, r)
    make("UICorner", {Parent=parent, CornerRadius=UDim.new(0,r or 4)})
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function resolve(path)
    path = trim(path)
    if path == "" then return nil end
    local roots = {
        game = game,
        ReplicatedStorage = ReplicatedStorage,
        Players = Players,
        Workspace = workspace,
    }
    local parts = {}
    for p in path:gmatch("[^%.]+") do parts[#parts+1] = p end
    if #parts == 0 then return nil end
    local node = roots[parts[1]] or game:FindFirstChild(parts[1])
    if not node then return nil end
    for i=2,#parts do
        node = node:FindFirstChild(parts[i])
        if not node then return nil end
    end
    return node
end

local function resolveRemote(path)
    if typeof(path) == "Instance" then return path end
    if type(path) ~= "string" then return nil end
    local direct = resolve(path)
    if direct and (direct:IsA("RemoteEvent") or direct:IsA("RemoteFunction")) then return direct end

    local serviceName, rest = path:match('^game:GetService%(%s*["\']([^"\']+)["\']%s*%)%.(.+)$')
    if serviceName and rest then
        local ok, service = pcall(game.GetService, game, serviceName)
        if ok and service then
            local node = service
            for p in rest:gmatch("[^%.]+") do
                node = node:FindFirstChild(p)
                if not node then break end
            end
            if node and (node:IsA("RemoteEvent") or node:IsA("RemoteFunction")) then return node end
        end
    end
end

local function evalValue(v)
    if type(v) ~= "table" or v.__expr == nil then return v end
    local source = "return " .. tostring(v.__expr)
    local fn = loadstring and loadstring(source)
    if not fn then return nil end
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

local function disconnectAll(list)
    for i=#list,1,-1 do
        pcall(function() list[i]:Disconnect() end)
        list[i]=nil
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
    self.Status = "Ready"
    self._connections = {}
    self.Visible = false
    return self
end

function Builder:AddModule(def)
    assert(type(def)=="table", "AddModule expects a table")
    assert(def.Name, "AddModule: Name is required")
    assert(def.Category, "AddModule: Category is required")

    local name, category = tostring(def.Name), tostring(def.Category)
    local control = def.Control or {Type=def.Type or "Toggle"}
    if type(control)=="string" then control={Type=control} end

    local mod = {}
    for k,v in pairs(def) do mod[k]=v end
    mod.Name = name
    mod.Category = category
    mod.Control = control
    mod.Type = tostring(control.Type or "Toggle")
    mod.Args = def.Args or {}
    mod.Options = def.Options or {}
    mod.Enabled = def.Enabled == true
    mod.Value = def.Value
    mod.Remote = resolveRemote(def.Remote)
    mod.UI = {}
    mod._connections = {}

    self.Modules[name] = mod
    if not self.CategoryMap[category] then
        self.CategoryMap[category] = {}
        self.Categories[#self.Categories+1] = category
    end
    table.insert(self.CategoryMap[category], mod)

    if self.Gui then self:BuildGui() end
    return mod
end

function Builder:AddModules(list)
    for _,def in ipairs(list or {}) do self:AddModule(def) end
    return self
end

function Builder:RemoveModule(name)
    local mod = self.Modules[name]
    if not mod then return false end
    disconnectAll(mod._connections)
    self.Modules[name]=nil
    local list = self.CategoryMap[mod.Category]
    if list then
        for i,v in ipairs(list) do
            if v==mod then table.remove(list,i) break end
        end
        if #list==0 then
            self.CategoryMap[mod.Category]=nil
            for i,v in ipairs(self.Categories) do if v==mod.Category then table.remove(self.Categories,i) break end end
        end
    end
    if self.Gui then self:BuildGui() end
    return true
end

function Builder:_fire(mod, extra)
    if not mod.Remote then
        self.Status = mod.Name .. ": Remote not found"
        self:_updateStatus()
        return false
    end

    local args = table.create(#mod.Args)
    for i,v in ipairs(mod.Args) do args[i] = evalValue(v) end
    if extra ~= nil then args[#args+1] = extra end

    task.spawn(function()
        local ok, result = pcall(function()
            if mod.Remote:IsA("RemoteEvent") then
                return mod.Remote:FireServer(table.unpack(args))
            elseif mod.Remote:IsA("RemoteFunction") then
                return mod.Remote:InvokeServer(table.unpack(args))
            end
            error("Unsupported remote type")
        end)
        self.Status = ok and (mod.Name .. ": OK") or (mod.Name .. ": " .. tostring(result))
        self:_updateStatus()
    end)
    return true
end

function Builder:_updateStatus()
    if self.StatusLabel then self.StatusLabel.Text = self.Status end
end

function Builder:_toggleVisual(mod)
    local track, knob = mod.UI.Track, mod.UI.Knob
    if not track or not knob then return end
    TweenService:Create(track,TweenInfo.new(0.12),{BackgroundColor3=mod.Enabled and COLORS.Accent or COLORS.ToggleOff}):Play()
    TweenService:Create(knob,TweenInfo.new(0.12),{Position=mod.Enabled and UDim2.new(1,-18,0.5,-8) or UDim2.new(0,2,0.5,-8)}):Play()
end

function Builder:_makeRow(mod, order)
    local row = make("Frame",{
        Parent=self.Content,
        Size=UDim2.new(1,0,0,SIZE.Row),
        BackgroundColor3=COLORS.Row,
        BorderSizePixel=0,
        LayoutOrder=order,
    })
    row:SetAttribute("SBContent", true)
    corner(row,4)
    make("TextLabel",{
        Parent=row, BackgroundTransparency=1,
        Size=UDim2.new(1,-125,1,0), Position=UDim2.fromOffset(10,0),
        Text=mod.Name, TextColor3=COLORS.Text2,
        Font=Enum.Font.Gotham, TextSize=10,
        TextXAlignment=Enum.TextXAlignment.Left,
        TextYAlignment=Enum.TextYAlignment.Center,
    })

    local typ = string.lower(mod.Type)
    if typ=="toggle" then
        local track=make("Frame",{Parent=row,Size=UDim2.fromOffset(34,18),Position=UDim2.new(1,-44,0.5,-9),BackgroundColor3=COLORS.ToggleOff,BorderSizePixel=0})
        corner(track,9)
        local knob=make("Frame",{Parent=track,Size=UDim2.fromOffset(16,16),Position=UDim2.new(0,2,0.5,-8),BackgroundColor3=Color3.fromRGB(244,244,244),BorderSizePixel=0})
        corner(knob,8)
        mod.UI.Track,mod.UI.Knob=track,knob
        local hit=make("TextButton",{Parent=row,Size=UDim2.fromOffset(60,33),Position=UDim2.new(1,-65,0,0),BackgroundTransparency=1,Text=""})
        table.insert(mod._connections,hit.MouseButton1Click:Connect(function()
            mod.Enabled=not mod.Enabled
            mod.Value=mod.Enabled
            self:_toggleVisual(mod)
            if mod.Enabled then self:_fire(mod) end
        end))
        self:_toggleVisual(mod)

    elseif typ=="select" or typ=="dropdown" then
        local box=make("TextButton",{Parent=row,Size=UDim2.fromOffset(105,22),Position=UDim2.new(1,-115,0.5,-11),BackgroundColor3=Color3.fromRGB(40,40,40),BorderSizePixel=0,Text=tostring(mod.Value or mod.Options[1] or "Select"),TextColor3=COLORS.Text2,Font=Enum.Font.Gotham,TextSize=9,AutoButtonColor=false})
        corner(box,4)
        table.insert(mod._connections,box.MouseButton1Click:Connect(function()
            if #mod.Options==0 then return end
            local current=tostring(mod.Value or mod.Options[1])
            local idx=1
            for i,v in ipairs(mod.Options) do if tostring(v)==current then idx=i break end end
            idx=idx%#mod.Options+1
            mod.Value=mod.Options[idx]
            box.Text=tostring(mod.Value)
            self:_fire(mod,mod.Value)
        end))

    elseif typ=="button" then
        local b=make("TextButton",{Parent=row,Size=UDim2.fromOffset(50,21),Position=UDim2.new(1,-60,0.5,-10.5),BackgroundColor3=COLORS.Accent,BorderSizePixel=0,Text="Fire",TextColor3=Color3.new(1,1,1),Font=Enum.Font.GothamMedium,TextSize=9,AutoButtonColor=false})
        corner(b,4)
        table.insert(mod._connections,b.MouseButton1Click:Connect(function() self:_fire(mod) end))

    elseif typ=="input" then
        local box=make("TextBox",{Parent=row,Size=UDim2.fromOffset(105,22),Position=UDim2.new(1,-115,0.5,-11),BackgroundColor3=Color3.fromRGB(40,40,40),BorderSizePixel=0,Text=tostring(mod.Value or ""),PlaceholderText="Enter value...",TextColor3=COLORS.Text2,Font=Enum.Font.Gotham,TextSize=9,ClearTextOnFocus=false})
        corner(box,4)
        table.insert(mod._connections,box.FocusLost:Connect(function(enter) if enter then mod.Value=box.Text self:_fire(mod,box.Text) end end))
    end
end

function Builder:_showCategory(category)
    self.ActiveCategory=category

    -- Disconnect all old module-control events before rebuilding category content.
    for _,mod in pairs(self.Modules) do
        disconnectAll(mod._connections)
        mod._connections={}
        mod.UI={}
    end

    if self.Content then
        for _,c in ipairs(self.Content:GetChildren()) do
            if c:GetAttribute("SBContent") then c:Destroy() end
        end
    end

    local label=make("TextLabel",{Parent=self.Content,Size=UDim2.new(1,0,0,17),BackgroundTransparency=1,Text=self.Config.SectionLabels and self.Config.SectionLabels[category] or "Settings",TextColor3=COLORS.Text3,Font=Enum.Font.GothamMedium,TextSize=9,TextXAlignment=Enum.TextXAlignment.Left,LayoutOrder=0})
    label:SetAttribute("SBContent",true)
    local list=self.CategoryMap[category] or {}
    for i,mod in ipairs(list) do
        self:_makeRow(mod,i)
    end
end

function Builder:BuildGui()
    if self.Gui then self.Gui:Destroy() end
    disconnectAll(self._connections)
    for _,m in pairs(self.Modules) do disconnectAll(m._connections) m._connections={} m.UI={} end

    self.Gui=make("ScreenGui",{Name="ScriptBuilder_"..self.Name:gsub("%W","_"),Parent=PlayerGui,ResetOnSpawn=false,IgnoreGuiInset=true,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,DisplayOrder=9999})
    self.Root=make("Frame",{Parent=self.Gui,Size=UDim2.fromOffset(SIZE.W,SIZE.H),Position=UDim2.new(0.5,-SIZE.W/2,0.5,-SIZE.H/2),BackgroundColor3=COLORS.Outer,BorderSizePixel=0})
    corner(self.Root,5)

    local header=make("Frame",{Parent=self.Root,Size=UDim2.new(1,0,0,SIZE.Header),BackgroundColor3=COLORS.Header,BorderSizePixel=0})
    make("TextLabel",{Parent=header,Size=UDim2.new(1,-130,1,0),Position=UDim2.fromOffset(12,0),BackgroundTransparency=1,Text=self.Name,TextColor3=COLORS.Text2,Font=Enum.Font.GothamMedium,TextSize=13,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Center})
    self.StatusLabel=make("TextLabel",{Parent=header,Size=UDim2.fromOffset(180,20),Position=UDim2.new(1,-215,0.5,-10),BackgroundTransparency=1,Text=self.Status,TextColor3=COLORS.Text3,Font=Enum.Font.Gotham,TextSize=9,TextXAlignment=Enum.TextXAlignment.Right})
    local close=make("TextButton",{Parent=header,Size=UDim2.fromOffset(24,24),Position=UDim2.new(1,-30,0.5,-12),BackgroundTransparency=1,Text="×",TextColor3=COLORS.Text3,Font=Enum.Font.GothamBold,TextSize=17,AutoButtonColor=false})
    table.insert(self._connections,close.MouseButton1Click:Connect(function() self:Hide() end))

    local dragging=false; local dragStart; local startPos
    table.insert(self._connections,header.InputBegan:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=true dragStart=input.Position startPos=self.Root.Position end end))
    table.insert(self._connections,UserInputService.InputChanged:Connect(function(input) if dragging and input.UserInputType==Enum.UserInputType.MouseMovement then local d=input.Position-dragStart self.Root.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y) end end))
    table.insert(self._connections,UserInputService.InputEnded:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end end))

    local sidebar=make("Frame",{Parent=self.Root,Size=UDim2.new(0,SIZE.Sidebar,1,-SIZE.Header),Position=UDim2.new(0,0,0,SIZE.Header),BackgroundColor3=COLORS.Sidebar,BorderSizePixel=0})
    make("UIPadding",{Parent=sidebar,PaddingTop=UDim.new(0,7),PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6),PaddingBottom=UDim.new(0,6)})
    make("UIListLayout",{Parent=sidebar,Padding=UDim.new(0,4),SortOrder=Enum.SortOrder.LayoutOrder})

    for i,cat in ipairs(self.Categories) do
        local b=make("TextButton",{Parent=sidebar,Size=UDim2.new(1,0,0,31),LayoutOrder=i,BackgroundColor3=COLORS.Sidebar,BorderSizePixel=0,Text=cat,TextColor3=COLORS.Text2,Font=Enum.Font.Gotham,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,AutoButtonColor=false})
        corner(b,4)
        table.insert(self._connections,b.MouseButton1Click:Connect(function() self:_showCategory(cat) end))
    end

    self.Content=make("ScrollingFrame",{Parent=self.Root,Size=UDim2.new(1,-SIZE.Sidebar,1,-SIZE.Header),Position=UDim2.new(0,SIZE.Sidebar,0,SIZE.Header),BackgroundColor3=COLORS.Content,BorderSizePixel=0,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4})
    make("UIPadding",{Parent=self.Content,PaddingTop=UDim.new(0,7),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8)})
    make("UIListLayout",{Parent=self.Content,Padding=UDim.new(0,SIZE.Gap),SortOrder=Enum.SortOrder.LayoutOrder})

    if self.Categories[1] then self:_showCategory(self.ActiveCategory or self.Categories[1]) end
    self.Gui.Enabled=self.Visible
    return self.Gui
end

function Builder:Show()
    if not self.Gui then self:BuildGui() end
    self.Gui.Enabled=true
    self.Visible=true
end

function Builder:Hide()
    if self.Gui then self.Gui.Enabled=false end
    self.Visible=false
end

function Builder:Toggle()
    if self.Visible then self:Hide() else self:Show() end
end

function Builder:Run()
    self:Show()
    if self._f7 then self._f7:Disconnect() end
    self._f7=UserInputService.InputBegan:Connect(function(input,processed) if not processed and input.KeyCode==Enum.KeyCode.F7 then self:Toggle() end end)
end

function Builder:SetModuleValue(name,value)
    local mod=self.Modules[name]
    if not mod then return false end
    mod.Value=value
    mod.Enabled=value==true
    if mod.UI.Track then self:_toggleVisual(mod) end
    return true
end

function Builder:GetModule(name) return self.Modules[name] end
function Builder:GetAllModules() return self.Modules end
function Builder:FireModule(name, ...) local m=self.Modules[name] if not m then return false end return self:_fire(m,...) end
function Builder:StatusText(text) self.Status=tostring(text) self:_updateStatus() end

function Builder:AddRemote(name, category, remote, options)
    options=options or {}
    options.Name=name
    options.Category=category or options.Category or "Settings"
    options.Remote=remote
    return self:AddModule(options)
end

function Builder:AddRemoteSpy(category,name,snippet,options)
    options=options or {}
    options.Name=name or options.Name or "Remote Spy"
    options.Category=category or options.Category or "Settings"
    options.Snippet=snippet
    return self:AddModule(options)
end

_G.Builder=Builder
return Builder
