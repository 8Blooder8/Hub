--[[
    Example: Steal an Egg - using ScriptBuilder + RemoteSpy 2.3.0

    WORKFLOW:
    1. Open RemoteSpy, trigger a remote call
    2. Click "Copy Remote" on the captured call
    3. Paste into the script below - done!

    No manual path typing. Everything from RemoteSpy.
]]

local Builder = _G.Builder or loadstring(game:HttpGet("https://YOUR_SERVER/ScriptBuilder.lua"))()
-- OR paste ScriptBuilder.lua content directly above this line

local myScript = Builder.Init("Steal an Egg")

-- ================================================================
-- Quick API: AddRemoteSpy(category, name, remote, arg, type, default)
-- Remote: paste from RemoteSpy "Copy Remote"
-- ================================================================

-- Autofarms category
--[==[ Paste from RemoteSpy:
Remote: game:GetService("ReplicatedStorage"):WaitForChild("Paper"):WaitForChild("Remotes"):WaitForChild("__remoteevent")
]==]
myScript:AddRemoteSpy("Autofarms", "Auto Collect",
    'game:GetService("ReplicatedStorage"):WaitForChild("Paper"):WaitForChild("Remotes"):WaitForChild("__remoteevent")',
    "Collect Egg", "toggle", false)

myScript:AddRemoteSpy("Autofarms", "Auto Deposit",
    'game:GetService("ReplicatedStorage"):WaitForChild("Paper"):WaitForChild("Remotes"):WaitForChild("__remotefunction")',
    "Deposit Eggs", "toggle", false)

myScript:AddRemoteSpy("Autofarms", "Auto Sell",
    'game:GetService("ReplicatedStorage"):WaitForChild("Paper"):WaitForChild("Remotes"):WaitForChild("__remotefunction")',
    "Collect Cash", "toggle", false)

-- Button example - fires once per click
myScript:AddRemoteSpy("Autofarms", "Manual Collect",
    'game:GetService("ReplicatedStorage"):WaitForChild("Paper"):WaitForChild("Remotes"):WaitForChild("__remoteevent")',
    "Collect Egg", "button", false)

-- Slider example - adjusts value, sent with action
myScript:AddRemoteSpy("Settings", "Collect Speed",
    'game:GetService("ReplicatedStorage"):WaitForChild("Paper"):WaitForChild("Remotes"):WaitForChild("__remoteevent")',
    "Set Speed", "slider", 1)

-- Input example - paste UUID, code, etc.
-- No remote: just a text field
myScript:AddRemoteSpy("Settings", "Target Egg UUID",
    nil,       -- no remote
    nil,       -- no arg
    "input",   -- control type
    "")        -- default value

-- ================================================================
-- Full API (same thing, explicit)
-- ================================================================
-- myScript:AddModule({
--     Category  = "Autofarms",
--     Name      = "Auto Collect",
--     Remote    = {
--         Type  = "Event",
--         Path  = 'game:GetService("ReplicatedStorage"):WaitForChild("Paper")...',
--         Args  = {"Collect Egg", nil},
--     },
--     Control = {
--         Type     = "toggle",
--         Default  = false,
--         Min      = 0,
--         Max      = 100,
--         Step     = 1,
--     },
-- })

-- ================================================================
-- Done! GUI is live.
-- F7 = show/hide  |  F8 = toggle all
-- ================================================================

-- Console shortcuts:
-- _G._SB_Steal_an_Egg:AddRemoteSpy("New Cat", "New Func", "<paste>", "arg1", "toggle", false)
-- _G._SB_Steal_an_Egg:FireModule("Auto Collect")
-- _G._SB_Steal_an_Egg:SetModuleValue("Collect Speed", 5)
-- _G._SB_Steal_an_Egg:Status("Hello")
