local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local LP   = Players.LocalPlayer
local Char = LP.Character or LP.CharacterAdded:Wait()
local HRP  = Char:WaitForChild("HumanoidRootPart")
local Hum  = Char:WaitForChild("Humanoid")

-- ── STATE MACHINE ─────────────────────────────────────────────────────────────
-- IDLE → FARMING → STEALING → PLACING → FARMING → ...
-- notif trigger: FARMING → STEALING (farm paused until back)
local SM = {
    IDLE     = "IDLE",
    FARMING  = "FARMING",
    STEALING = "STEALING",
    PLACING  = "PLACING",
}
local state        = SM.IDLE
local farmEnabled  = false
local stealEnabled = false
local hatchEnabled = false

-- ── CONFIG ────────────────────────────────────────────────────────────────────
local CFG = {
    StealSpeed    = 500,
    ComboDelay    = 0.012,
    StealDelay    = 0.03,
    HopDist       = 12,
    ACBypass      = true,
    TargetTiers   = {
        omniverse  = true,
        eternal    = true,
        primordial = true,
        godlike    = true,
    },
}

local State = {
    BasePosition  = HRP.CFrame,
    FarmPosition  = HRP.CFrame,
    ActiveTween   = nil,
}

local GUI_NAME = "LarpAnimePackGUI"

-- ── CHAR SETUP ────────────────────────────────────────────────────────────────
local function apply_char(c)
    Char = c
    HRP  = c:WaitForChild("HumanoidRootPart")
    Hum  = c:WaitForChild("Humanoid")
    State.BasePosition = HRP.CFrame
    State.FarmPosition = HRP.CFrame
    task.wait(0.5)
    Hum.WalkSpeed = CFG.StealSpeed
    Hum.JumpPower = 0
    pcall(function() HRP:SetNetworkOwner(nil) end)
end
LP.CharacterAdded:Connect(apply_char)

local function set_speed(v)
    CFG.StealSpeed = math.clamp(v, 50, 2000)
    Hum.WalkSpeed  = CFG.StealSpeed
end

-- ── REMOTE FIRE ───────────────────────────────────────────────────────────────
local function fire_remote(name, ...)
    local r = ReplicatedStorage:FindFirstChild(name, true)
           or Workspace:FindFirstChild(name, true)
    if not r then return end
    if     r:IsA("RemoteEvent")    then r:FireServer(...)
    elseif r:IsA("RemoteFunction") then return r:InvokeServer(...) end
end

-- ── MOVEMENT ──────────────────────────────────────────────────────────────────
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
            task.wait(0.06)
            cancel_tween()
            HRP.CFrame = hop
        end
    end
end

-- ── TARGET SCAN ───────────────────────────────────────────────────────────────
local function name_has_tier(str)
    local low = str:lower()
    for tier in pairs(CFG.TargetTiers) do
        if low:find(tier, 1, true) then return true end
    end
    return false
end

local function obj_has_tier(obj)
    if name_has_tier(obj.Name) then return true end
    for _, ch in ipairs(obj:GetChildren()) do
        if ch:IsA("StringValue") or ch:IsA("TextLabel") or ch:IsA("TextBox") then
            local v = ch:IsA("StringValue") and ch.Value or ch.Text
            if v and name_has_tier(v) then return true end
        end
    end
    return false
end

local function get_steal_targets()
    local out = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if (obj:IsA("Model") or obj:IsA("BasePart")) and obj_has_tier(obj) then
            local part = obj:IsA("BasePart") and obj or obj:FindFirstChildWhichIsA("BasePart")
            if part then table.insert(out, {model = obj, part = part}) end
        end
    end
    return out
end

local function nearest_target()
    local best, bd = nil, math.huge
    for _, t in ipairs(get_steal_targets()) do
        local d = (t.part.Position - HRP.Position).Magnitude
        if d < bd then bd = d; best = t end
    end
    return best
end

-- ── BASE FIND ────────────────────────────────────────────────────────────────
local function get_base()
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            local n = obj.Name:lower()
            if n:find("base",1,true) or n:find("plot",1,true) or n:find("spawn",1,true) then
                local ow = obj:FindFirstChild("Owner") or obj:FindFirstChild("PlayerName")
                if ow and (tostring(ow.Value)==LP.Name or tostring(ow.Value)==tostring(LP.UserId)) then
                    return obj.CFrame + Vector3.new(0, 5, 0)
                end
            end
        end
    end
    return State.BasePosition
end

-- ── PLACE PACK ────────────────────────────────────────────────────────────────
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
    return ap.X < vp.X and ap.Y < vp.Y and (ap.X+asz.X) > 0 and (ap.Y+asz.Y) > 0
end

local function do_place_at_base()
    local baseCF = get_base()
    hop_to(baseCF)
    cancel_tween()
    HRP.CFrame = baseCF
    task.wait(0.1)

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
                        task.wait(0.08)
                        break
                    end
                end
            end
        end
    end
    task.wait(0.15)
end

-- ── STEAL ─────────────────────────────────────────────────────────────────────
local STEAL_REMOTES = {"StealPack","Steal","GrabPack","PickupPack","TakePack"}

local function do_steal(target)
    Hum.WalkSpeed = CFG.StealSpeed
    pcall(function() HRP:SetNetworkOwner(nil) end)

    hop_to(target.part.CFrame + Vector3.new(0, 3, 0))

    for _, name in ipairs(STEAL_REMOTES) do
        fire_remote(name, target.model)
    end

    cancel_tween()
    HRP.CFrame = target.part.CFrame + Vector3.new(0, 2, 0)
    task.wait(0.06)
end

-- ── HATCH ─────────────────────────────────────────────────────────────────────
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
                if full:find(pat, 1, true) then fire_btn_all(obj); break end
            end
        end
    end
end

-- ── COMBO FARM ────────────────────────────────────────────────────────────────
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

-- ── MAIN LOOP ─────────────────────────────────────────────────────────────────
-- single coroutine drives everything to avoid state collisions
local mainThread = nil

local function main_loop()
    while farmEnabled or stealEnabled do

        -- FARMING phase: combo click until steal is triggered
        if farmEnabled and state == SM.FARMING then
            Hum.WalkSpeed = CFG.StealSpeed
            hop_to(State.FarmPosition)
            while state == SM.FARMING and (farmEnabled or stealEnabled) do
                do_combo_tick()
                if hatchEnabled then do_hatch_once() end
                task.wait(0.008)
            end
        end

        -- STEALING phase
        if state == SM.STEALING then
            local target = nearest_target()
            if target then
                do_steal(target)
            end
            -- transition to PLACING if place enabled, else straight back to farm
            if stealEnabled then
                state = SM.PLACING
            else
                state = farmEnabled and SM.FARMING or SM.IDLE
            end
        end

        -- PLACING phase
        if state == SM.PLACING then
            do_place_at_base()
            -- return to farm spot
            hop_to(State.FarmPosition)
            cancel_tween()
            HRP.CFrame = State.FarmPosition
            task.wait(0.1)
            state = farmEnabled and SM.FARMING or SM.IDLE
        end

        -- guard: if neither enabled, exit
        if not farmEnabled and not stealEnabled then
            state = SM.IDLE
            break
        end

        -- if only steal enabled (no farm), scan and steal immediately
        if stealEnabled and not farmEnabled and state ~= SM.STEALING and state ~= SM.PLACING then
            local targets = get_steal_targets()
            if #targets > 0 then
                state = SM.STEALING
            else
                task.wait(0.5)
            end
        end

        task.wait(0.01)
    end
    state = SM.IDLE
end

local function ensure_main_loop()
    if mainThread and coroutine.status(mainThread) ~= "dead" then return end
    mainThread = task.spawn(main_loop)
end

-- ── NOTIF HOOK ────────────────────────────────────────────────────────────────
local notif_conns = {}

local function notif_has_tier(text)
    local low = text:lower()
    for tier in pairs(CFG.TargetTiers) do
        if low:find(tier, 1, true) then return true end
    end
    return false
end

local function hook_label(obj)
    if not (obj:IsA("TextLabel") or obj:IsA("TextBox")) then return end
    local function check(txt)
        if notif_has_tier(txt) and stealEnabled then
            -- interrupt farm, trigger steal
            state = SM.STEALING
            ensure_main_loop()
        end
    end
    check(obj.Text)
    local c = obj:GetPropertyChangedSignal("Text"):Connect(function()
        check(obj.Text)
    end)
    table.insert(notif_conns, c)
end

local function hook_container(container)
    for _, obj in ipairs(container:GetDescendants()) do hook_label(obj) end
    local c = container.DescendantAdded:Connect(function(obj)
        task.wait(0.03)
        hook_label(obj)
    end)
    table.insert(notif_conns, c)
end

local function setup_notif_hooks()
    local pg = LP:WaitForChild("PlayerGui")
    for _, gui in ipairs(pg:GetChildren()) do
        if gui.Name ~= GUI_NAME then hook_container(gui) end
    end
    pg.ChildAdded:Connect(function(gui)
        if gui.Name ~= GUI_NAME then task.wait(0.05); hook_container(gui) end
    end)
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then hook_container(obj) end
    end
    Workspace.DescendantAdded:Connect(function(obj)
        if obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then
            task.wait(0.05); hook_container(obj)
        end
    end)
end

-- ── GUI ───────────────────────────────────────────────────────────────────────
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = GUI_NAME
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent         = LP:WaitForChild("PlayerGui")

local FRAME_W = 310
local FRAME_H = 530

local MainFrame = Instance.new("Frame")
MainFrame.Name             = "Main"
MainFrame.AnchorPoint      = Vector2.new(0.5, 0.5)
MainFrame.Size             = UDim2.new(0, FRAME_W, 0, FRAME_H)
MainFrame.Position         = UDim2.new(0.5, 0, 0.5, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
MainFrame.BorderSizePixel  = 0
MainFrame.ClipsDescendants = false
MainFrame.Parent           = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 8)

local AccentBar = Instance.new("Frame")
AccentBar.Size             = UDim2.new(1, 0, 0, 3)
AccentBar.BackgroundColor3 = Color3.fromRGB(180, 60, 220)
AccentBar.BorderSizePixel  = 0
AccentBar.Parent           = MainFrame
Instance.new("UICorner", AccentBar).CornerRadius = UDim.new(0, 8)

local TitleBar = Instance.new("Frame")
TitleBar.Size             = UDim2.new(1, 0, 0, 36)
TitleBar.Position         = UDim2.new(0, 0, 0, 3)
TitleBar.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
TitleBar.BorderSizePixel  = 0
TitleBar.ZIndex           = 10
TitleBar.Parent           = MainFrame

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size                   = UDim2.new(1, -50, 1, 0)
TitleLabel.Position               = UDim2.new(0, 10, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text                   = "larp anime pack — @Archaes `78"
TitleLabel.TextColor3             = Color3.fromRGB(220, 180, 255)
TitleLabel.TextSize               = 11
TitleLabel.Font                   = Enum.Font.GothamBold
TitleLabel.TextXAlignment         = Enum.TextXAlignment.Left
TitleLabel.ZIndex                 = 10
TitleLabel.Parent                 = TitleBar

-- state indicator dot
local StateDot = Instance.new("TextLabel")
StateDot.Size                   = UDim2.new(0, 60, 0, 14)
StateDot.Position               = UDim2.new(0, 10, 1, -16)
StateDot.BackgroundTransparency = 1
StateDot.Text                   = "● IDLE"
StateDot.TextColor3             = Color3.fromRGB(120, 120, 140)
StateDot.TextSize               = 9
StateDot.Font                   = Enum.Font.GothamBold
StateDot.TextXAlignment         = Enum.TextXAlignment.Left
StateDot.ZIndex                 = 10
StateDot.Parent                 = TitleBar

local STATE_COLORS = {
    [SM.IDLE]     = Color3.fromRGB(120,120,140),
    [SM.FARMING]  = Color3.fromRGB(80,200,120),
    [SM.STEALING] = Color3.fromRGB(220,80,80),
    [SM.PLACING]  = Color3.fromRGB(80,160,220),
}

task.spawn(function()
    while true do
        StateDot.Text       = "● " .. state
        StateDot.TextColor3 = STATE_COLORS[state] or Color3.fromRGB(120,120,140)
        task.wait(0.1)
    end
end)

local MinBtn = Instance.new("TextButton")
MinBtn.Size             = UDim2.new(0, 30, 0, 24)
MinBtn.Position         = UDim2.new(1, -34, 0.5, -12)
MinBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
MinBtn.Text             = "—"
MinBtn.TextColor3       = Color3.fromRGB(220, 220, 220)
MinBtn.TextSize         = 14
MinBtn.Font             = Enum.Font.GothamBold
MinBtn.BorderSizePixel  = 0
MinBtn.ZIndex           = 11
MinBtn.Parent           = TitleBar
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 4)

local ContentFrame = Instance.new("ScrollingFrame")
ContentFrame.Name                   = "Content"
ContentFrame.Size                   = UDim2.new(1, 0, 1, -39)
ContentFrame.Position               = UDim2.new(0, 0, 0, 39)
ContentFrame.BackgroundTransparency = 1
ContentFrame.ScrollBarThickness     = 0
ContentFrame.CanvasSize             = UDim2.new(0, 0, 0, 0)
ContentFrame.AutomaticCanvasSize    = Enum.AutomaticSize.Y
ContentFrame.Parent                 = MainFrame

local UIList = Instance.new("UIListLayout")
UIList.Padding       = UDim.new(0, 5)
UIList.SortOrder     = Enum.SortOrder.LayoutOrder
UIList.FillDirection = Enum.FillDirection.Vertical
UIList.Parent        = ContentFrame

local UIPad = Instance.new("UIPadding")
UIPad.PaddingLeft   = UDim.new(0, 10)
UIPad.PaddingRight  = UDim.new(0, 10)
UIPad.PaddingTop    = UDim.new(0, 8)
UIPad.PaddingBottom = UDim.new(0, 8)
UIPad.Parent        = ContentFrame

local function make_section(parent, title, order)
    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -20, 0, 16)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = title
    lbl.TextColor3             = Color3.fromRGB(160, 100, 220)
    lbl.TextSize               = 10
    lbl.Font                   = Enum.Font.GothamBold
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.LayoutOrder            = order
    lbl.Parent                 = parent
end

local function make_toggle(parent, label, default, order, callback)
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1, -20, 0, 32)
    row.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
    row.BorderSizePixel  = 0
    row.LayoutOrder      = order
    row.Parent           = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -60, 1, 0)
    lbl.Position               = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = label
    lbl.TextColor3             = Color3.fromRGB(210, 210, 230)
    lbl.TextSize               = 11
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.TextTruncate           = Enum.TextTruncate.AtEnd
    lbl.Parent                 = row

    local s   = default
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, 46, 0, 22)
    btn.Position         = UDim2.new(1, -50, 0.5, -11)
    btn.BackgroundColor3 = s and Color3.fromRGB(140,60,200) or Color3.fromRGB(55,55,70)
    btn.Text             = s and "ON" or "OFF"
    btn.TextColor3       = Color3.fromRGB(255,255,255)
    btn.TextSize         = 11
    btn.Font             = Enum.Font.GothamBold
    btn.BorderSizePixel  = 0
    btn.Parent           = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

    btn.MouseButton1Click:Connect(function()
        s = not s
        btn.BackgroundColor3 = s and Color3.fromRGB(140,60,200) or Color3.fromRGB(55,55,70)
        btn.Text = s and "ON" or "OFF"
        callback(s)
    end)
end

local function make_tier_toggle(parent, tier, order)
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1, -20, 0, 28)
    row.BackgroundColor3 = Color3.fromRGB(22, 22, 32)
    row.BorderSizePixel  = 0
    row.LayoutOrder      = order
    row.Parent           = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -60, 1, 0)
    lbl.Position               = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = tier:sub(1,1):upper() .. tier:sub(2)
    lbl.TextColor3             = Color3.fromRGB(190, 190, 215)
    lbl.TextSize               = 11
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = row

    local s   = CFG.TargetTiers[tier] == true
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, 46, 0, 20)
    btn.Position         = UDim2.new(1, -50, 0.5, -10)
    btn.BackgroundColor3 = s and Color3.fromRGB(120,50,180) or Color3.fromRGB(45,45,60)
    btn.Text             = s and "ON" or "OFF"
    btn.TextColor3       = Color3.fromRGB(255,255,255)
    btn.TextSize         = 10
    btn.Font             = Enum.Font.GothamBold
    btn.BorderSizePixel  = 0
    btn.Parent           = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

    btn.MouseButton1Click:Connect(function()
        s = not s
        CFG.TargetTiers[tier] = s or nil
        btn.BackgroundColor3 = s and Color3.fromRGB(120,50,180) or Color3.fromRGB(45,45,60)
        btn.Text = s and "ON" or "OFF"
    end)
end

local function make_slider(parent, label, minVal, maxVal, default, order, callback)
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1, -20, 0, 52)
    row.BackgroundColor3 = Color3.fromRGB(28, 28, 38)
    row.BorderSizePixel  = 0
    row.LayoutOrder      = order
    row.Parent           = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -10, 0, 18)
    lbl.Position               = UDim2.new(0, 8, 0, 4)
    lbl.BackgroundTransparency = 1
    lbl.Text                   = label .. ": " .. tostring(default)
    lbl.TextColor3             = Color3.fromRGB(210, 210, 230)
    lbl.TextSize               = 11
    lbl.Font                   = Enum.Font.Gotham
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.Parent                 = row

    local track = Instance.new("Frame")
    track.Size             = UDim2.new(1, -20, 0, 10)
    track.Position         = UDim2.new(0, 10, 0, 32)
    track.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
    track.BorderSizePixel  = 0
    track.Parent           = row
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

    local initRel = math.clamp((default-minVal)/(maxVal-minVal), 0, 1)

    local fill = Instance.new("Frame")
    fill.Size             = UDim2.new(initRel, 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(140, 60, 200)
    fill.BorderSizePixel  = 0
    fill.Parent           = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size             = UDim2.new(0, 18, 0, 18)
    knob.Position         = UDim2.new(initRel, -9, 0.5, -9)
    knob.BackgroundColor3 = Color3.fromRGB(220, 180, 255)
    knob.BorderSizePixel  = 0
    knob.ZIndex           = 4
    knob.Parent           = track
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local hitbox = Instance.new("TextButton")
    hitbox.Size                   = UDim2.new(1, 20, 1, 20)
    hitbox.Position               = UDim2.new(0, -10, 0, -10)
    hitbox.BackgroundTransparency = 1
    hitbox.Text                   = ""
    hitbox.ZIndex                 = 5
    hitbox.Parent                 = track

    local sdrag = false

    local function update_slider(screenX)
        local ap  = track.AbsolutePosition
        local asz = track.AbsoluteSize
        if asz.X == 0 then return end
        local rel = math.clamp((screenX - ap.X) / asz.X, 0, 1)
        local val = math.floor(minVal + (maxVal - minVal) * rel)
        fill.Size     = UDim2.new(rel, 0, 1, 0)
        knob.Position = UDim2.new(rel, -9, 0.5, -9)
        lbl.Text      = label .. ": " .. tostring(val)
        callback(val)
    end

    hitbox.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
            sdrag = true; update_slider(inp.Position.X)
        end
    end)
    hitbox.InputChanged:Connect(function(inp)
        if sdrag and (inp.UserInputType == Enum.UserInputType.MouseMovement
                   or inp.UserInputType == Enum.UserInputType.Touch) then
            update_slider(inp.Position.X)
        end
    end)
    hitbox.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then sdrag = false end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then sdrag = false end
    end)
end

-- ── CONTROLS ──────────────────────────────────────────────────────────────────
make_section(ContentFrame, "MAIN LOOP", 10)

make_toggle(ContentFrame, "Auto Farm (speed combo)", false, 11, function(v)
    farmEnabled = v
    if v then
        State.FarmPosition = HRP.CFrame
        if state == SM.IDLE then state = SM.FARMING end
        ensure_main_loop()
    else
        if state == SM.FARMING then state = SM.IDLE end
    end
end)

make_toggle(ContentFrame, "Auto Steal + Auto Place", false, 12, function(v)
    stealEnabled = v
    if v then
        if state == SM.IDLE then state = SM.STEALING end
        ensure_main_loop()
    else
        if state == SM.STEALING or state == SM.PLACING then
            state = farmEnabled and SM.FARMING or SM.IDLE
        end
    end
end)

make_toggle(ContentFrame, "Auto Hatch (during farm)", false, 13, function(v)
    hatchEnabled = v
end)

make_section(ContentFrame, "TARGET RARITY", 19)
make_tier_toggle(ContentFrame, "omniverse",  20)
make_tier_toggle(ContentFrame, "eternal",    21)
make_tier_toggle(ContentFrame, "primordial", 22)
make_tier_toggle(ContentFrame, "godlike",    23)

make_section(ContentFrame, "MOVEMENT", 29)
make_toggle(ContentFrame, "AntiCheat Hop Bypass", true, 30, function(v)
    CFG.ACBypass = v
end)
make_slider(ContentFrame, "Speed", 50, 2000, CFG.StealSpeed, 31, function(v)
    set_speed(v)
end)

local SetFarmBtn = Instance.new("TextButton")
SetFarmBtn.Size             = UDim2.new(1, -20, 0, 30)
SetFarmBtn.BackgroundColor3 = Color3.fromRGB(30, 50, 30)
SetFarmBtn.Text             = "Set Farm Spot (current pos)"
SetFarmBtn.TextColor3       = Color3.fromRGB(160, 240, 160)
SetFarmBtn.TextSize         = 11
SetFarmBtn.Font             = Enum.Font.GothamBold
SetFarmBtn.BorderSizePixel  = 0
SetFarmBtn.LayoutOrder      = 32
SetFarmBtn.Parent           = ContentFrame
Instance.new("UICorner", SetFarmBtn).CornerRadius = UDim.new(0, 6)

SetFarmBtn.MouseButton1Click:Connect(function()
    State.FarmPosition = HRP.CFrame
    SetFarmBtn.Text = "Farm Spot Set!"
    task.wait(1.5)
    SetFarmBtn.Text = "Set Farm Spot (current pos)"
end)

local SetBaseBtn = Instance.new("TextButton")
SetBaseBtn.Size             = UDim2.new(1, -20, 0, 30)
SetBaseBtn.BackgroundColor3 = Color3.fromRGB(50, 25, 80)
SetBaseBtn.Text             = "Set Base Pos (current pos)"
SetBaseBtn.TextColor3       = Color3.fromRGB(220, 180, 255)
SetBaseBtn.TextSize         = 11
SetBaseBtn.Font             = Enum.Font.GothamBold
SetBaseBtn.BorderSizePixel  = 0
SetBaseBtn.LayoutOrder      = 33
SetBaseBtn.Parent           = ContentFrame
Instance.new("UICorner", SetBaseBtn).CornerRadius = UDim.new(0, 6)

SetBaseBtn.MouseButton1Click:Connect(function()
    State.BasePosition = HRP.CFrame
    SetBaseBtn.Text = "Base Set!"
    task.wait(1.5)
    SetBaseBtn.Text = "Set Base Pos (current pos)"
end)

-- ── DRAG ─────────────────────────────────────────────────────────────────────
local dragActive   = false
local dragStartPos = Vector2.new()
local dragFrameCtr = Vector2.new()

local function begin_drag(pos)
    dragActive   = true
    dragStartPos = Vector2.new(pos.X, pos.Y)
    local ap     = MainFrame.AbsolutePosition
    local asz    = MainFrame.AbsoluteSize
    dragFrameCtr = Vector2.new(ap.X + asz.X*0.5, ap.Y + asz.Y*0.5)
end

local function move_drag(pos)
    if not dragActive then return end
    local vp = Workspace.CurrentCamera.ViewportSize
    local hw = MainFrame.AbsoluteSize.X * 0.5
    local hh = MainFrame.AbsoluteSize.Y * 0.5
    local nx = math.clamp(dragFrameCtr.X + (pos.X - dragStartPos.X), hw, vp.X - hw)
    local ny = math.clamp(dragFrameCtr.Y + (pos.Y - dragStartPos.Y), hh, vp.Y - hh)
    MainFrame.Position = UDim2.new(0, nx, 0, ny)
end

TitleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1
    or inp.UserInputType == Enum.UserInputType.Touch then begin_drag(inp.Position) end
end)
TitleBar.InputChanged:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseMovement
    or inp.UserInputType == Enum.UserInputType.Touch then move_drag(inp.Position) end
end)
TitleBar.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1
    or inp.UserInputType == Enum.UserInputType.Touch then dragActive = false end
end)
UserInputService.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1
    or inp.UserInputType == Enum.UserInputType.Touch then dragActive = false end
end)

-- ── MINIMIZE ──────────────────────────────────────────────────────────────────
local minimized = false
MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    ContentFrame.Visible = not minimized
    MainFrame.Size = minimized and UDim2.new(0,FRAME_W,0,42) or UDim2.new(0,FRAME_W,0,FRAME_H)
    MinBtn.Text    = minimized and "+" or "—"
end)

-- ── BOOT ──────────────────────────────────────────────────────────────────────
Hum.WalkSpeed = CFG.StealSpeed
Hum.JumpPower = 0
pcall(function() HRP:SetNetworkOwner(nil) end)

task.spawn(setup_notif_hooks)
task.wait(1)
State.BasePosition = HRP.CFrame
State.FarmPosition = HRP.CFrame

print("[larp] v5 — @Archaes `78")
