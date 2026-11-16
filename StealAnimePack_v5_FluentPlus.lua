--[[
    StealAnimePack v5 — Separated Features + FluentPlus UI
    Auto Farm / Auto Steal / Auto Hatch / Auto Place = independent
    No combined logic. Steal goes straight to highest priority target by rarity.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")

local LP   = Players.LocalPlayer
local Char = LP.Character or LP.CharacterAdded:Wait()
local HRP  = Char:WaitForChild("HumanoidRootPart")
local Hum  = Char:WaitForChild("Humanoid")

-- ── STATE (each feature independent) ─────────────────────────────────────────
local farmEnabled  = false
local stealEnabled = false
local hatchEnabled = false
local placeEnabled = false

local CFG = {
    StealSpeed  = 500,
    ComboDelay  = 0.012,
    StealDelay  = 0.03,
    HopDist     = 12,
    ACBypass    = true,
    TargetTiers = {
        omniverse  = true,
        eternal    = true,
        primordial = true,
        godlike    = true,
    },
}

-- Priority order (highest first)
local TIER_PRIORITY = {"omniverse", "eternal", "primordial", "godlike"}

local State = {
    BasePosition = HRP.CFrame,
    FarmPosition = HRP.CFrame,
    ActiveTween  = nil,
}

local GUI_NAME = "StealAnimePack_FluentPlus"

-- ── CHARACTER ────────────────────────────────────────────────────────────────
local function apply_char(c)
    Char = c
    HRP  = c:WaitForChild("HumanoidRootPart")
    Hum  = c:WaitForChild("Humanoid")
    State.BasePosition = HRP.CFrame
    State.FarmPosition = HRP.CFrame
    task.wait(0.4)
    Hum.WalkSpeed = CFG.StealSpeed
    Hum.JumpPower = 0
    pcall(function() HRP:SetNetworkOwner(nil) end)
end
LP.CharacterAdded:Connect(apply_char)

local function set_speed(v)
    CFG.StealSpeed = math.clamp(v, 50, 2000)
    if Hum then Hum.WalkSpeed = CFG.StealSpeed end
end

-- ── REMOTE ───────────────────────────────────────────────────────────────────
local function fire_remote(name, ...)
    local r = ReplicatedStorage:FindFirstChild(name, true)
           or Workspace:FindFirstChild(name, true)
    if not r then return end
    if r:IsA("RemoteEvent") then
        r:FireServer(...)
    elseif r:IsA("RemoteFunction") then
        return r:InvokeServer(...)
    end
end

-- ── MOVEMENT ─────────────────────────────────────────────────────────────────
local function cancel_tween()
    if State.ActiveTween then
        pcall(function() State.ActiveTween:Cancel() end)
        State.ActiveTween = nil
    end
end

local function tween_to(cf, t)
    cancel_tween()
    local tw = TweenService:Create(HRP, TweenInfo.new(t or 0.05, Enum.EasingStyle.Linear), {CFrame = cf})
    State.ActiveTween = tw
    tw:Play()
    tw.Completed:Wait()
    if State.ActiveTween == tw then State.ActiveTween = nil end
end

local function hop_to(targetCF)
    local origin = HRP.CFrame
    local dist   = (targetCF.Position - origin.Position).Magnitude
    if dist < 2 then return end
    if not CFG.ACBypass or dist < CFG.HopDist then
        tween_to(targetCF, 0.05)
        return
    end
    local steps = math.ceil(dist / CFG.HopDist)
    for i = 1, steps do
        local hop = origin:Lerp(targetCF, i / steps)
        tween_to(hop, 0.03)
        if (HRP.CFrame.Position - hop.Position).Magnitude > 18 then
            task.wait(0.05)
            cancel_tween()
            HRP.CFrame = hop
        end
    end
end

-- ── TARGET SCAN (priority by rarity) ─────────────────────────────────────────
local function name_has_tier(str)
    local low = str:lower()
    for _, tier in ipairs(TIER_PRIORITY) do
        if CFG.TargetTiers[tier] and low:find(tier, 1, true) then
            return tier
        end
    end
    return nil
end

local function obj_has_tier(obj)
    local t = name_has_tier(obj.Name)
    if t then return t end
    for _, ch in ipairs(obj:GetChildren()) do
        if ch:IsA("StringValue") or ch:IsA("TextLabel") or ch:IsA("TextBox") then
            local v = ch:IsA("StringValue") and ch.Value or ch.Text
            if v then
                t = name_has_tier(v)
                if t then return t end
            end
        end
    end
    return nil
end

local function get_best_target()
    local best, bestPri, bestDist = nil, 999, math.huge
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if (obj:IsA("Model") or obj:IsA("BasePart")) then
            local tier = obj_has_tier(obj)
            if tier then
                local pri = table.find(TIER_PRIORITY, tier) or 99
                local part = obj:IsA("BasePart") and obj or obj:FindFirstChildWhichIsA("BasePart")
                if part then
                    local d = (part.Position - HRP.Position).Magnitude
                    if pri < bestPri or (pri == bestPri and d < bestDist) then
                        bestPri = pri
                        bestDist = d
                        best = {model = obj, part = part, tier = tier}
                    end
                end
            end
        end
    end
    return best
end

-- ── BASE ─────────────────────────────────────────────────────────────────────
local function get_base()
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            local n = obj.Name:lower()
            if n:find("base",1,true) or n:find("plot",1,true) or n:find("spawn",1,true) then
                local ow = obj:FindFirstChild("Owner") or obj:FindFirstChild("PlayerName")
                if ow and (tostring(ow.Value) == LP.Name or tostring(ow.Value) == tostring(LP.UserId)) then
                    return obj.CFrame + Vector3.new(0, 5, 0)
                end
            end
        end
    end
    return State.BasePosition
end

-- ── PLACE (independent) ──────────────────────────────────────────────────────
local PLACE_REMOTES = {"PlacePack","PlaceInBase","SetPack","EquipPack","DeployPack"}
local PLACE_PATS    = {"place","equip","put","deploy","set"}

local function is_own_gui(obj)
    local p = obj
    while p do
        if p.Name == GUI_NAME then return true end
        p = p.Parent
    end
    return false
end

local function fire_btn_all(btn)
    pcall(function()
        for _, c in ipairs(getconnections(btn.MouseButton1Click)) do
            if c.Function then c.Function() end
        end
    end)
    pcall(function() firesignal(btn.MouseButton1Click) end)
    pcall(function()
        for _, c in ipairs(getconnections(btn.Activated)) do
            if c.Function then c.Function() end
        end
    end)
    pcall(function() firesignal(btn.Activated) end)
    pcall(function() btn.MouseButton1Click:Fire() end)
end

local function btn_in_viewport(btn)
    local ap  = btn.AbsolutePosition
    local asz = btn.AbsoluteSize
    if asz.X <= 0 or asz.Y <= 0 then return false end
    local vp = Workspace.CurrentCamera.ViewportSize
    return ap.X < vp.X and ap.Y < vp.Y and (ap.X + asz.X) > 0 and (ap.Y + asz.Y) > 0
end

local function do_place()
    local baseCF = get_base()
    hop_to(baseCF)
    cancel_tween()
    HRP.CFrame = baseCF
    task.wait(0.08)

    for _, name in ipairs(PLACE_REMOTES) do
        fire_remote(name)
    end

    local gui = LP:FindFirstChildOfClass("PlayerGui")
    if gui then
        for _, obj in ipairs(gui:GetDescendants()) do
            if (obj:IsA("TextButton") or obj:IsA("ImageButton"))
                and obj.Visible and not is_own_gui(obj) and btn_in_viewport(obj)
            then
                local full = obj.Name:lower() .. (obj:IsA("TextButton") and obj.Text:lower() or "")
                for _, pat in ipairs(PLACE_PATS) do
                    if full:find(pat, 1, true) then
                        fire_btn_all(obj)
                        task.wait(0.06)
                        break
                    end
                end
            end
        end
    end
end

-- ── STEAL (independent — goes straight to target) ────────────────────────────
local STEAL_REMOTES = {"StealPack","Steal","GrabPack","PickupPack","TakePack"}

local function do_steal(target)
    Hum.WalkSpeed = CFG.StealSpeed
    pcall(function() HRP:SetNetworkOwner(nil) end)

    hop_to(target.part.CFrame + Vector3.new(0, 3, 0))
    cancel_tween()
    HRP.CFrame = target.part.CFrame + Vector3.new(0, 2, 0)

    for _, name in ipairs(STEAL_REMOTES) do
        fire_remote(name, target.model)
    end
    task.wait(CFG.StealDelay)
end

-- ── HATCH (independent) ──────────────────────────────────────────────────────
local HATCH_PATS = {"open","hatch","ready","crack"}

local function do_hatch_once()
    fire_remote("OpenPack"); fire_remote("HatchPack")
    fire_remote("OpenEgg");  fire_remote("Hatch")
    local gui = LP:FindFirstChildOfClass("PlayerGui")
    if not gui then return end
    for _, obj in ipairs(gui:GetDescendants()) do
        if (obj:IsA("TextButton") or obj:IsA("ImageButton"))
            and obj.Visible and not is_own_gui(obj) and btn_in_viewport(obj)
        then
            local full = obj.Name:lower() .. (obj:IsA("TextButton") and obj.Text:lower() or "")
            for _, pat in ipairs(HATCH_PATS) do
                if full:find(pat, 1, true) then
                    fire_btn_all(obj)
                    break
                end
            end
        end
    end
end

-- ── COMBO FARM (independent) ─────────────────────────────────────────────────
local COMBO_PATS = {
    "x2","x3","x4","x5","2x","3x","4x","5x",
    "combo","train","click","speed","tap","punch","hit"
}

local function do_combo_tick()
    local gui = LP:FindFirstChildOfClass("PlayerGui")
    if not gui then return end
    for _, obj in ipairs(gui:GetDescendants()) do
        if (obj:IsA("TextButton") or obj:IsA("ImageButton"))
            and obj.Visible and not is_own_gui(obj) and btn_in_viewport(obj)
        then
            local full = obj.Name:lower() .. (obj:IsA("TextButton") and obj.Text:lower() or "")
            for _, pat in ipairs(COMBO_PATS) do
                if full:find(pat, 1, true) then
                    fire_btn_all(obj)
                    task.wait(CFG.ComboDelay)
                    break
                end
            end
        end
    end
    fire_remote("SpeedCombo"); fire_remote("Combo")
    fire_remote("TrainingCombo"); fire_remote("ClickTrain")
    fire_remote("SpeedTrain");    fire_remote("PunchTrain")
end

-- ── INDEPENDENT LOOPS ────────────────────────────────────────────────────────
-- Farm loop
task.spawn(function()
    while true do
        if farmEnabled then
            hop_to(State.FarmPosition)
            do_combo_tick()
        end
        task.wait(0.01)
    end
end)

-- Steal loop (goes directly to best target, no farm/hatch/place mixed)
task.spawn(function()
    while true do
        if stealEnabled then
            local target = get_best_target()
            if target then
                do_steal(target)
            else
                task.wait(0.35)
            end
        else
            task.wait(0.2)
        end
        task.wait(0.02)
    end
end)

-- Hatch loop
task.spawn(function()
    while true do
        if hatchEnabled then
            do_hatch_once()
        end
        task.wait(0.25)
    end
end)

-- Place loop
task.spawn(function()
    while true do
        if placeEnabled then
            do_place()
            task.wait(0.8)
        else
            task.wait(0.3)
        end
    end
end)

-- ── NOTIF HOOK (only triggers steal when stealEnabled) ───────────────────────
local function notif_has_tier(text)
    local low = text:lower()
    for _, tier in ipairs(TIER_PRIORITY) do
        if CFG.TargetTiers[tier] and low:find(tier, 1, true) then
            return true
        end
    end
    return false
end

local function hook_label(obj)
    if not (obj:IsA("TextLabel") or obj:IsA("TextBox")) then return end
    local function check(txt)
        if notif_has_tier(txt) and stealEnabled then
            -- steal loop will pick it up immediately
        end
    end
    check(obj.Text)
    obj:GetPropertyChangedSignal("Text"):Connect(function()
        check(obj.Text)
    end)
end

local function hook_container(container)
    for _, obj in ipairs(container:GetDescendants()) do
        hook_label(obj)
    end
    container.DescendantAdded:Connect(function(obj)
        task.wait(0.03)
        hook_label(obj)
    end)
end

task.spawn(function()
    local pg = LP:WaitForChild("PlayerGui")
    for _, gui in ipairs(pg:GetChildren()) do
        if gui.Name ~= GUI_NAME then
            hook_container(gui)
        end
    end
    pg.ChildAdded:Connect(function(gui)
        if gui.Name ~= GUI_NAME then
            task.wait(0.05)
            hook_container(gui)
        end
    end)
end)

-- ── FLUENTPLUS UI (compact mobile) ───────────────────────────────────────────
-- Lightweight FluentPlus-style (no external library, pure Roblox UI)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = GUI_NAME
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent         = LP:WaitForChild("PlayerGui")

local MAIN_W = 260
local MAIN_H = 380

local Main = Instance.new("Frame")
Main.Name             = "Main"
Main.Size             = UDim2.new(0, MAIN_W, 0, MAIN_H)
Main.Position         = UDim2.new(0.5, -MAIN_W/2, 0.5, -MAIN_H/2)
Main.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
Main.BorderSizePixel  = 0
Main.ClipsDescendants = true
Main.Parent           = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 10)

local Stroke = Instance.new("UIStroke")
Stroke.Color = Color3.fromRGB(140, 60, 200)
Stroke.Thickness = 1.2
Stroke.Transparency = 0.35
Stroke.Parent = Main

-- Title bar
local TitleBar = Instance.new("Frame")
TitleBar.Size             = UDim2.new(1, 0, 0, 34)
TitleBar.BackgroundColor3 = Color3.fromRGB(24, 24, 32)
TitleBar.BorderSizePixel  = 0
TitleBar.Parent           = Main

local Title = Instance.new("TextLabel")
Title.Size                   = UDim2.new(1, -70, 1, 0)
Title.Position               = UDim2.new(0, 10, 0, 0)
Title.BackgroundTransparency = 1
Title.Text                   = "StealAnime • Fluent+"
Title.TextColor3             = Color3.fromRGB(220, 180, 255)
Title.TextSize               = 12
Title.Font                   = Enum.Font.GothamBold
Title.TextXAlignment         = Enum.TextXAlignment.Left
Title.Parent                 = TitleBar

local MinBtn = Instance.new("TextButton")
MinBtn.Size             = UDim2.new(0, 28, 0, 22)
MinBtn.Position         = UDim2.new(1, -34, 0.5, -11)
MinBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
MinBtn.Text             = "—"
MinBtn.TextColor3       = Color3.fromRGB(230, 230, 240)
MinBtn.TextSize         = 13
MinBtn.Font             = Enum.Font.GothamBold
MinBtn.BorderSizePixel  = 0
MinBtn.Parent           = TitleBar
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 5)

local Content = Instance.new("ScrollingFrame")
Content.Size                   = UDim2.new(1, 0, 1, -34)
Content.Position               = UDim2.new(0, 0, 0, 34)
Content.BackgroundTransparency = 1
Content.ScrollBarThickness     = 3
Content.ScrollBarImageColor3   = Color3.fromRGB(140, 60, 200)
Content.CanvasSize             = UDim2.new(0, 0, 0, 0)
Content.AutomaticCanvasSize    = Enum.AutomaticSize.Y
Content.Parent                 = Main

local List = Instance.new("UIListLayout")
List.Padding       = UDim.new(0, 5)
List.SortOrder     = Enum.SortOrder.LayoutOrder
List.FillDirection = Enum.FillDirection.Vertical
List.Parent        = Content

local Pad = Instance.new("UIPadding")
Pad.PaddingLeft   = UDim.new(0, 8)
Pad.PaddingRight  = UDim.new(0, 8)
Pad.PaddingTop    = UDim.new(0, 6)
Pad.PaddingBottom = UDim.new(0, 8)
Pad.Parent        = Content

-- Helpers
local function section(txt, order)
    local l = Instance.new("TextLabel")
    l.Size                   = UDim2.new(1, 0, 0, 16)
    l.BackgroundTransparency = 1
    l.Text                   = txt
    l.TextColor3             = Color3.fromRGB(160, 100, 220)
    l.TextSize               = 10
    l.Font                   = Enum.Font.GothamBold
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.LayoutOrder            = order
    l.Parent                 = Content
end

local function toggle(label, default, order, cb)
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1, 0, 0, 30)
    row.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
    row.BorderSizePixel  = 0
    row.LayoutOrder      = order
    row.Parent           = Content
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -55, 1, 0)
    lbl.Position               = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = label
    lbl.TextColor3             = Color3.fromRGB(210, 210, 230)
    lbl.TextSize               = 11
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = row

    local s = default
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, 42, 0, 20)
    btn.Position         = UDim2.new(1, -48, 0.5, -10)
    btn.BackgroundColor3 = s and Color3.fromRGB(140, 60, 200) or Color3.fromRGB(50, 50, 65)
    btn.Text             = s and "ON" or "OFF"
    btn.TextColor3       = Color3.fromRGB(255, 255, 255)
    btn.TextSize         = 10
    btn.Font             = Enum.Font.GothamBold
    btn.BorderSizePixel  = 0
    btn.Parent           = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

    btn.MouseButton1Click:Connect(function()
        s = not s
        btn.BackgroundColor3 = s and Color3.fromRGB(140, 60, 200) or Color3.fromRGB(50, 50, 65)
        btn.Text = s and "ON" or "OFF"
        cb(s)
    end)
end

local function tier_toggle(tier, order)
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1, 0, 0, 26)
    row.BackgroundColor3 = Color3.fromRGB(24, 24, 34)
    row.BorderSizePixel  = 0
    row.LayoutOrder      = order
    row.Parent           = Content
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -55, 1, 0)
    lbl.Position               = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = tier:sub(1,1):upper() .. tier:sub(2)
    lbl.TextColor3             = Color3.fromRGB(190, 190, 215)
    lbl.TextSize               = 11
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = row

    local s = CFG.TargetTiers[tier] == true
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, 42, 0, 18)
    btn.Position         = UDim2.new(1, -48, 0.5, -9)
    btn.BackgroundColor3 = s and Color3.fromRGB(120, 50, 180) or Color3.fromRGB(45, 45, 60)
    btn.Text             = s and "ON" or "OFF"
    btn.TextColor3       = Color3.fromRGB(255, 255, 255)
    btn.TextSize         = 10
    btn.Font             = Enum.Font.GothamBold
    btn.BorderSizePixel  = 0
    btn.Parent           = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

    btn.MouseButton1Click:Connect(function()
        s = not s
        CFG.TargetTiers[tier] = s or nil
        btn.BackgroundColor3 = s and Color3.fromRGB(120, 50, 180) or Color3.fromRGB(45, 45, 60)
        btn.Text = s and "ON" or "OFF"
    end)
end

local function slider(label, minV, maxV, default, order, cb)
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
    row.BorderSizePixel  = 0
    row.LayoutOrder      = order
    row.Parent           = Content
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -10, 0, 16)
    lbl.Position               = UDim2.new(0, 8, 0, 3)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = label .. ": " .. tostring(default)
    lbl.TextColor3             = Color3.fromRGB(210, 210, 230)
    lbl.TextSize               = 11
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = row

    local track = Instance.new("Frame")
    track.Size             = UDim2.new(1, -16, 0, 8)
    track.Position         = UDim2.new(0, 8, 0, 28)
    track.BackgroundColor3 = Color3.fromRGB(45, 45, 58)
    track.BorderSizePixel  = 0
    track.Parent           = row
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

    local initRel = math.clamp((default - minV) / (maxV - minV), 0, 1)

    local fill = Instance.new("Frame")
    fill.Size             = UDim2.new(initRel, 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(140, 60, 200)
    fill.BorderSizePixel  = 0
    fill.Parent           = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size             = UDim2.new(0, 14, 0, 14)
    knob.Position         = UDim2.new(initRel, -7, 0.5, -7)
    knob.BackgroundColor3 = Color3.fromRGB(220, 180, 255)
    knob.BorderSizePixel  = 0
    knob.ZIndex           = 3
    knob.Parent           = track
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local hit = Instance.new("TextButton")
    hit.Size                   = UDim2.new(1, 16, 1, 16)
    hit.Position               = UDim2.new(0, -8, 0, -8)
    hit.BackgroundTransparency = 1
    hit.Text                   = ""
    hit.ZIndex                 = 4
    hit.Parent                 = track

    local dragging = false
    local function update(x)
        local ap  = track.AbsolutePosition
        local asz = track.AbsoluteSize
        if asz.X == 0 then return end
        local rel = math.clamp((x - ap.X) / asz.X, 0, 1)
        local val = math.floor(minV + (maxV - minV) * rel)
        fill.Size     = UDim2.new(rel, 0, 1, 0)
        knob.Position = UDim2.new(rel, -7, 0.5, -7)
        lbl.Text      = label .. ": " .. tostring(val)
        cb(val)
    end

    hit.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            update(inp.Position.X)
        end
    end)
    hit.InputChanged:Connect(function(inp)
        if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            update(inp.Position.X)
        end
    end)
    hit.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

local function action_btn(txt, color, order, cb)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(1, 0, 0, 28)
    b.BackgroundColor3 = color
    b.Text             = txt
    b.TextColor3       = Color3.fromRGB(230, 230, 240)
    b.TextSize         = 11
    b.Font             = Enum.Font.GothamBold
    b.BorderSizePixel  = 0
    b.LayoutOrder      = order
    b.Parent           = Content
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.MouseButton1Click:Connect(cb)
end

-- ── BUILD UI ─────────────────────────────────────────────────────────────────
section("MAIN TOGGLES", 1)

toggle("Auto Farm", false, 2, function(v)
    farmEnabled = v
    if v then
        State.FarmPosition = HRP.CFrame
    end
end)

toggle("Auto Steal", false, 3, function(v)
    stealEnabled = v
end)

toggle("Auto Hatch", false, 4, function(v)
    hatchEnabled = v
end)

toggle("Auto Place", false, 5, function(v)
    placeEnabled = v
end)

section("TARGET RARITY", 10)
tier_toggle("omniverse",  11)
tier_toggle("eternal",    12)
tier_toggle("primordial", 13)
tier_toggle("godlike",    14)

section("MOVEMENT", 20)
toggle("AC Hop Bypass", true, 21, function(v)
    CFG.ACBypass = v
end)

slider("Speed", 50, 2000, CFG.StealSpeed, 22, function(v)
    set_speed(v)
end)

action_btn("Set Farm Spot", Color3.fromRGB(30, 55, 35), 23, function()
    State.FarmPosition = HRP.CFrame
end)

action_btn("Set Base Pos", Color3.fromRGB(45, 30, 70), 24, function()
    State.BasePosition = HRP.CFrame
end)

-- ── DRAG ─────────────────────────────────────────────────────────────────────
local dragging = false
local dragStart, frameStart

TitleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = Vector2.new(inp.Position.X, inp.Position.Y)
        local ap = Main.AbsolutePosition
        frameStart = Vector2.new(ap.X, ap.Y)
    end
end)

TitleBar.InputChanged:Connect(function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
        local delta = Vector2.new(inp.Position.X, inp.Position.Y) - dragStart
        local vp = Workspace.CurrentCamera.ViewportSize
        local nx = math.clamp(frameStart.X + delta.X, 0, vp.X - MAIN_W)
        local ny = math.clamp(frameStart.Y + delta.Y, 0, vp.Y - 34)
        Main.Position = UDim2.new(0, nx, 0, ny)
    end
end)

TitleBar.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

UserInputService.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- ── MINIMIZE ─────────────────────────────────────────────────────────────────
local minimized = false
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    Content.Visible = not minimized
    Main.Size = minimized and UDim2.new(0, MAIN_W, 0, 34) or UDim2.new(0, MAIN_W, 0, MAIN_H)
    MinBtn.Text = minimized and "+" or "—"
end)

-- ── BOOT ─────────────────────────────────────────────────────────────────────
Hum.WalkSpeed = CFG.StealSpeed
Hum.JumpPower = 0
pcall(function() HRP:SetNetworkOwner(nil) end)

task.wait(0.6)
State.BasePosition = HRP.CFrame
State.FarmPosition = HRP.CFrame

print("[StealAnimePack] v5 Fluent+ — features fully separated")
