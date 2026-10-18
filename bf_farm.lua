-- language: Luau, file: bf_farm.lua
-- target: Blox Fruits (PlaceId 2753915549), Delta / Arceus X / Codex (Android)
-- requires: executor with HTTP (request/http_request/syn.request) + TeleportToPlaceInstance

local Players           = game:GetService("Players")
local VirtualUser       = game:GetService("VirtualUser")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")
local HttpService       = game:GetService("HttpService")

local LP = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 20)
if not Remotes then warn("[BF] Remotes missing — wrong game or not loaded"); return end
local CommF = Remotes:FindFirstChild("CommF_")
if not CommF then warn("[BF] CommF_ missing — verify current build"); return end

-- ═══ CONFIG ═══════════════════════════════════════════════════
local Config = {
    Enabled       = false,
    MoveSpeed     = 220,
    AttackDelay   = 0.18,
    PlayerRadius  = 100,
    AutoHop       = true,
    AutoGacha     = true,
    GachaInterval = 7200,
    AutoQuest     = true,
    QuestIndex    = 1,
    HeightOffset  = 8,    -- (5) 8–10 studs — melee hitbox misses ground at 15
    AttackWindow  = 3.0,
    HopMinLevel   = 11,   -- (7) skip AutoHop until past starter zone
}

-- ═══ QUEST TABLE ══════════════════════════════════════════════
-- (6) CommF_:InvokeServer("StartQuest", <QuestID>, <Tier>)
--   QuestID is the quest-giver's internal name — NOT the mob's display name.
--   VERIFY against the live quest list before the first run:
--   open the in-game quest menu, hover each quest, note the internal label
--   shown in the executor's remote log. Same list, same order — patch only
--   the `QuestID` strings below if any 404 silently.
local Quests = {
    {Mob="Bandit",           QuestID="BanditQuest1",   Tier=1, Level=1},
    {Mob="Brutal Bandit",    QuestID="BanditQuest1",   Tier=2, Level=10},
    {Mob="Monkey",           QuestID="JungleQuest",    Tier=1, Level=20},
    {Mob="Serpent",          QuestID="JungleQuest",    Tier=2, Level=30},
    {Mob="Mob Leader",       QuestID="BuggyQuest1",    Tier=1, Level=40},
    {Mob="Pirate",           QuestID="BuggyQuest1",    Tier=2, Level=50},
    {Mob="Chef",             QuestID="BruteQuest",     Tier=1, Level=60},
    {Mob="Galley Pirate",    QuestID="BruteQuest",     Tier=2, Level=75},
    {Mob="Galley Captain",   QuestID="GalleyQuest",    Tier=1, Level=90},
    {Mob="Fishman",          QuestID="GalleyQuest",    Tier=2, Level=110},
    {Mob="Fishman Captain",  QuestID="FishmanQuest",   Tier=1, Level=125},
    {Mob="The Fishman Lord", QuestID="FishmanQuest",   Tier=2, Level=150},
    {Mob="Snow Bandit",      QuestID="FountainQuest",  Tier=1, Level=175},
    {Mob="Snowman",          QuestID="FountainQuest",  Tier=2, Level=200},
    {Mob="Snow Trooper",     QuestID="SnowQuest",      Tier=1, Level=225},
    {Mob="Snow Assassin",    QuestID="SnowQuest",      Tier=2, Level=250},
    {Mob="Snow Leader",      QuestID="WysperQuest",    Tier=1, Level=275},
    {Mob="Yeti",             QuestID="WysperQuest",    Tier=2, Level=300},
    {Mob="Wysper",           QuestID="ThunderQuest",   Tier=1, Level=325},
    {Mob="Thunder God",      QuestID="ThunderQuest",   Tier=2, Level=350},
    -- Sea 2 / Sea 3 — append here once Third Sea is unlocked
}

-- ═══ STATE ════════════════════════════════════════════════════
local lastGacha = 0
local ui
local hoverBV  = nil
local hoverChar = nil

-- ═══ ANTI-AFK ═════════════════════════════════════════════════
LP.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

-- ═══ HELPERS ══════════════════════════════════════════════════
local function getLevel()
    local ls = LP:FindFirstChild("leaderstats")
    if ls then
        local lv = ls:FindFirstChild("Level") or ls:FindFirstChild("Lvl")
        if lv then return lv.Value end
    end
    return 0
end

local function getHRP()
    local c = LP.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart")
end

local function getHum()
    local c = LP.Character
    if not c then return nil end
    return c:FindFirstChildOfClass("Humanoid")
end

-- (1) FIX: capture startPos once, lerp against the captured point
local function tweenTo(target, speed)
    local hrp = getHRP()
    if not hrp then return end
    local startPos = hrp.Position
    local dist = (startPos - target).Magnitude
    if dist < 4 then
        hrp.CFrame = CFrame.new(target)
        return
    end
    local duration = dist / speed
    local t0 = os.clock()
    while os.clock() - t0 < duration do
        if not hrp.Parent then return end
        local alpha = math.min((os.clock() - t0) / duration, 1)
        hrp.CFrame = CFrame.new(startPos:Lerp(target, alpha))
        RunService.RenderStepped:Wait()
    end
    hrp.CFrame = CFrame.new(target)
end

-- (2) FIX: anti-gravity hover, tied to the char that owns the BV
local function startHover()
    local hrp = getHRP()
    if not hrp or hoverBV then return end
    local hum = getHum()
    if hum then
        hum.PlatformStand = true
        hum.AutoRotate    = false
    end
    local bv = Instance.new("BodyVelocity")
    bv.Velocity = Vector3.zero
    bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
    bv.P        = 1250
    bv.Parent   = hrp
    hoverBV     = bv
    hoverChar   = LP.Character
end

local function stopHover()
    if hoverBV then
        pcall(function() hoverBV:Destroy() end)
        hoverBV = nil
    end
    local c = hoverChar or LP.Character
    if c then
        local hum = c:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function()
                hum.PlatformStand = false
                hum.AutoRotate    = true
            end)
        end
    end
    hoverChar = nil
end

-- (3) FIX: prefer Workspace.Enemies folder; fallback to direct children
local function findMob(name)
    local enemies = Workspace:FindFirstChild("Enemies")
    local container = enemies or Workspace
    local fallback
    for _, v in ipairs(container:GetChildren()) do
        if v.Name == name then
            local hum = v:FindFirstChildOfClass("Humanoid")
            local hrp = v:FindFirstChild("HumanoidRootPart")
            if hum and hrp and hum.Health > 0 then
                local giver = v:FindFirstChildOfClass("ProximityPrompt")
                           or v:FindFirstChildOfClass("ClickDetector")
                if not giver then return v end
                fallback = fallback or v
            end
        end
    end
    return fallback
end

-- (4) FIX: if no Tool active in Character, pull first Tool from Backpack
local function ensureEquipped()
    local c = LP.Character
    if not c then return nil end
    local active = c:FindFirstChildOfClass("Tool")
    if active then return active end
    local bp = LP:FindFirstChild("Backpack")
    if not bp then return nil end
    local hum = c:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    for _, t in ipairs(bp:GetChildren()) do
        if t:IsA("Tool") then
            pcall(function() hum:EquipTool(t) end)
            if c:FindFirstChild(t.Name) then return t end
        end
    end
    return nil
end

local function startQuest(questID, tier)
    pcall(function() CommF:InvokeServer("StartQuest", questID, tier) end)
end

local function buyFruit()
    pcall(function() CommF:InvokeServer("Cousin", "Buy") end)
end

local function playerNearby(radius)
    local hrp = getHRP()
    if not hrp then return false end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local o = p.Character:FindFirstChild("HumanoidRootPart")
            if o and (o.Position - hrp.Position).Magnitude < radius then
                return true
            end
        end
    end
    return false
end

local function serverHop()
    local req = (syn and syn.request) or (http and http.request) or http_request or request
    if not req then return false end
    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100",
        game.PlaceId)
    local ok, res = pcall(req, {Url = url, Method = "GET"})
    if not ok or not res or not res.Body then return false end
    local decoded = HttpService:JSONDecode(res.Body)
    for _, s in ipairs(decoded.data or {}) do
        if s.id ~= game.JobId and s.playing and s.playing >= 1 and s.playing <= 8 then
            pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LP) end)
            return true
        end
    end
    return false
end

local function attack()
    local tool = ensureEquipped()
    if tool then
        pcall(function() tool:Activate() end)
    end
end

-- ═══ GUI ══════════════════════════════════════════════════════
local function makeGui()
    local g = Instance.new("ScreenGui")
    g.Name = "BF_Farm_Hub"
    g.ResetOnSpawn = false
    g.Parent = LP:WaitForChild("PlayerGui")

    local f = Instance.new("Frame")
    f.Size = UDim2.new(0, 220, 0, 110)
    f.Position = UDim2.new(0, 10, 0, 10)
    f.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    f.BorderSizePixel = 0
    f.Parent = f.Parent or g
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = f

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 30)
    title.BackgroundTransparency = 1
    title.Text = "BF Farm — IDLE"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.Parent = f

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -20, 0, 40)
    btn.Position = UDim2.new(0, 10, 0, 40)
    btn.BackgroundColor3 = Color3.fromRGB(40, 160, 80)
    btn.Text = "START"
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 14
    btn.Parent = f
    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(0, 6)
    bc.Parent = btn

    local st = Instance.new("TextLabel")
    st.Size = UDim2.new(1, -20, 0, 20)
    st.Position = UDim2.new(0, 10, 0, 85)
    st.BackgroundTransparency = 1
    st.Text = "lvl ? — q ?/?"
    st.TextColor3 = Color3.fromRGB(180, 180, 180)
    st.Font = Enum.Font.Gotham
    st.TextSize = 12
    st.Parent = f

    return {gui = g, title = title, toggle = btn, status = st}
end

ui = makeGui()
ui.toggle.MouseButton1Click:Connect(function()
    Config.Enabled = not Config.Enabled
    if Config.Enabled then
        ui.toggle.Text = "STOP"
        ui.toggle.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
        ui.title.Text = "BF Farm — RUNNING"
    else
        stopHover()
        ui.toggle.Text = "START"
        ui.toggle.BackgroundColor3 = Color3.fromRGB(40, 160, 80)
        ui.title.Text = "BF Farm — IDLE"
    end
end)

-- ═══ MAIN LOOP ════════════════════════════════════════════════
task.spawn(function()
    while true do
        if Config.Enabled then
            local hrp = getHRP()
            local hum = getHum()
            if not hrp or not hum or hum.Health <= 0 then
                stopHover()
                task.wait(1)
            else
                local lvl = getLevel()

                -- (7) AutoHop gated by level — no server-hopping in the starter zone
                if Config.AutoHop
                    and lvl >= Config.HopMinLevel
                    and playerNearby(Config.PlayerRadius) then
                    stopHover()
                    ui.status.Text = "player nearby — hopping"
                    serverHop()
                    task.wait(6)
                else
                    if Config.AutoQuest then
                        while Config.QuestIndex < #Quests
                            and lvl >= Quests[Config.QuestIndex + 1].Level do
                            Config.QuestIndex = Config.QuestIndex + 1
                        end
                        local q = Quests[Config.QuestIndex]
                        if q then
                            startQuest(q.QuestID, q.Tier)
                            local mob = findMob(q.Mob)
                            if mob and mob:FindFirstChild("HumanoidRootPart") then
                                local mp = mob.HumanoidRootPart.Position
                                       + Vector3.new(0, Config.HeightOffset, 0)
                                stopHover()
                                tweenTo(mp, Config.MoveSpeed)
                                startHover()
                                local t0 = os.clock()
                                while os.clock() - t0 < Config.AttackWindow
                                    and Config.Enabled do
                                    local mHum = mob:FindFirstChildOfClass("Humanoid")
                                    if not mob.Parent
                                        or (mHum and mHum.Health <= 0) then break end
                                    attack()
                                    task.wait(Config.AttackDelay)
                                end
                                stopHover()
                            else
                                task.wait(0.5)
                            end
                        end
                    end

                    if Config.AutoGacha
                        and os.time() - lastGacha > Config.GachaInterval then
                        buyFruit()
                        lastGacha = os.time()
                    end

                    ui.status.Text = string.format("lvl %d — q %d/%d",
                        lvl, Config.QuestIndex, #Quests)
                end
            end
        else
            stopHover()
        end
        task.wait(0.1)
    end
end)

-- ═══ CLEANUP ON RESPAWN ══════════════════════════════════════
LP.CharacterAdded:Connect(function()
    stopHover()
end)

print("[BF] hub v2 loaded — press START")
