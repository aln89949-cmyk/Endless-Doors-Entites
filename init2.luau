--[[
    __      __          _            _       ______       _   _ _            _____                                       __      _____  
    \ \    / /         (_)          ( )     |  ____|     | | (_) |          / ____|                                      \ \    / /__ \ 
     \ \  / /   _ _ __  ___  ___   _|/ ___  | |__   _ __ | |_ _| |_ _   _  | (___  _ __   __ ___      ___ __   ___ _ __   \ \  / /   ) |
      \ \/ / | | | '_ \| \ \/ / | | | / __| |  __| | '_ \| __| | __| | | |  \___ \| '_ \ / _` \ \ /\ / / '_ \ / _ \ '__|   \ \/ /   / / 
       \  /| |_| | | | | |>  <| |_| | \__ \ | |____| | | | |_| | |_| |_| |  ____) | |_) | (_| |\ V  V /| | | |  __/ |       \  /   / /_ 
        \/  \__, |_| |_|_/_/\_\\__,_| |___/ |______|_| |_|\__|_|\__|\__, | |_____/| .__/ \__,_| \_/\_/ |_| |_|\___|_|        \/   |____|
             __/ |                                                   __/ |        | |                                                   
            |___/                                                   |___/         |_|                                                   
]]--

if getgenv().VynixuEntitySpawnerV2 then return getgenv().VynixuEntitySpawnerV2 end

loadstring(game:HttpGet("https://raw.githubusercontent.com/RegularVynixu/Utilities/main/Functions.lua"))()

-- \\ Services // --

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- \\ Variables // --

local ROOT = "https://github.com/RegularVynixu/DOORS-Entity-Spawner-V2/raw/main"

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local RootPart = Character.PrimaryPart or Character:FindFirstChildWhichIsA("BasePart", true)
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

local Remotes = ReplicatedStorage:WaitForChild("RemotesFolder") :: Folder
local GameStats = ReplicatedStorage:WaitForChild("GameStats") :: Folder
local CurrentRooms = workspace:WaitForChild("CurrentRooms") :: Folder

-- \\ NodeGraphs // --

local NodeGraphsModule = require(ReplicatedStorage:WaitForChild("NodeGraphs"))
local Pathfinder = NodeGraphsModule.Pathfinder

-- Кэш графов по комнате
local GraphCache = setmetatable({}, { __mode = "k" })

local function GetRoomGraph(room: Model)
    if GraphCache[room] then
        return GraphCache[room]
    end

    local graphFolder = room:FindFirstChild("NodeGraphs")
    if not graphFolder then return nil end

    local graph = NodeGraphsModule.ExistingNodeGraphs[graphFolder]
    if not graph then
        local ok, res = pcall(NodeGraphsModule.ApplyNodeGraph, graphFolder)
        if not ok then
            warn("[EntitySpawner] ApplyNodeGraph failed for", room.Name, res)
            return nil
        end
        graph = res
    end

    GraphCache[room] = graph
    return graph
end

CurrentRooms.ChildRemoved:Connect(function(room)
    GraphCache[room] = nil
end)

-- Собирает "мега-граф" из всех комнат, сшивая переходы между ними.
-- Возвращает { nodes = {...}, PathfinderInit = true }
local function BuildMegaGraph(rooms: { Model }): any?
    local allNodes = {}
    local roomEnterExit = {} -- room -> { enterNode, exitNode }

    for _, room in next, rooms do
        local graph = GetRoomGraph(room)
        if graph then
            for key, node in next, graph.nodes do
                allNodes[key] = node
            end

            local enterPos = room:FindFirstChild("RoomEntrance") and room.RoomEntrance.Position or nil
            local exitPos  = room:FindFirstChild("RoomExit")     and room.RoomExit.Position     or nil

            roomEnterExit[room] = {
                enterNode = enterPos and Pathfinder:_getClosestNode(graph, enterPos) or nil,
                exitNode  = exitPos  and Pathfinder:_getClosestNode(graph, exitPos)  or nil,
            }
        end
    end

    -- Сшиваем комнаты: exit предыдущей <-> enter следующей
    for i = 1, #rooms - 1 do
        local a = roomEnterExit[rooms[i]]
        local b = roomEnterExit[rooms[i + 1]]
        if a and b and a.exitNode and b.enterNode then
            local exitNode, enterNode = a.exitNode, b.enterNode

            local alreadyLinked = false
            for _, c in next, exitNode.Connections do
                if c == enterNode then alreadyLinked = true break end
            end

            if not alreadyLinked then
                table.insert(exitNode.Connections, enterNode)
                table.insert(enterNode.Connections, exitNode)
                exitNode.ConnectionWeights[enterNode] = 1
                enterNode.ConnectionWeights[exitNode] = 1
            end
        end
    end

    return {
        nodes = allNodes,
        PathfinderInit = true, -- пропускаем _init (нет folder.Dependancy)
    }
end

-- \\ Assets / Modules / Storage // --

local Assets = {
    Repentance = LoadCustomInstance(ROOT.."/Assets/Repentance.rbxm"),
    Earthquake = LoadCustomInstance(ROOT.."/Assets/Earthquake.rbxm")
}
local Modules = {
    Module_Events = require(ReplicatedStorage.ModulesClient.Module_Events :: ModuleScript),
    Main_Game = require(PlayerGui.MainUI.Initiator.Main_Game :: ModuleScript)
}
local Storage = {
    Ambient = {},
    DeathTypes = {
        ["Yellow"] = {"yellow", "curious"},
        ["Blue"] = {"blue", "guiding"}
    },
    CrucifixTypes = {
        ["guiding"] = { Color = Color3.fromRGB(137, 207, 255) },
        ["curious"] = { Color = Color3.fromRGB(255, 227, 137) }
    }
}

local CONST = {
    BASE_ENTITY_SPEED = 65,
    ATTR = {
        ENTITY = {
            Running = false,
            CustomEntity = true,
            Paused = false,
            BeingBanished = false,
            Despawning = false,
            Damage = true,
            LastEnteredRoom = -1
        },
        PLAYER = {
            SpawnProtection = 5
        }
    },
    DEFAULT = {
        CONFIG = {
            Entity = {
                Name = "Template Entity",
                Asset = "https://github.com/RegularVynixu/Utilities/raw/refs/heads/main/Doors/Entity%20Spawner/Assets/Entities/Rush.rbxm",
                HeightOffset = 0
            },
            Movement = {
                Speed = 100,
                Delay = 2,
                Reversed = false
            },
            Damage = {
                Enabled = true,
                Range = 40,
                Amount = 125,
                IgnoreHiding = false
            },
            Rebounding = {
                Enabled = true,
                Type = "Ambush",
                Min = 2,
                Max = 4,
                Delay = 2
            },
            Lights = {
                Flicker = {
                    Enabled = true,
                    Duration = 1
                },
                Shatter = true,
                Repair = false
            },
            Earthquake = {
                Enabled = true
            },
            CameraShake = {
                Enabled = true,
                Values = {1.5, 20, 0.1, 1},
                Range = 100
            },
            Crucifixion = {
                Type = "Guiding",
                Enabled = true,
                Range = 40,
                Resist = false,
                Break = true
            },
            Death = {
                Type = "Guiding",
                Hints = {"Death", "Hints", "Go", "Here"},
                Cause = ""
            }
        },
        DEBUG = {
            OnSpawned = function() end,
            OnStartMoving = function() end,
            OnReachedNode = function() end,
            OnEnterRoom = function() end,
            OnLookAt = function() end,
            OnRebounding = function() end,
            OnDespawning = function() end,
            OnDespawned = function() end,
            OnDamagePlayer = function() end,
            CrucifixionOverwrite = nil
        }
    }
}

local Module = {
    ActiveEntities = {}
}

-- \\ Helpers // --

local function CloneTable(tbl: any): any
    local new = {}
    for key, value in next, tbl do
        if typeof(value) == "table" then
            new[key] = CloneTable(value)
        else
            new[key] = value
        end
    end
    return new
end

function ApplyConfigDefaults(tbl, defaults)
    local new = CloneTable(tbl)
    for key, value in next, defaults do
        if new[key] == nil then
            if typeof(value) == "table" then
                new[key] = CloneTable(value)
            else
                new[key] = value
            end
        elseif typeof(value) == "table" then
            if typeof(new[key]) ~= "table" then
                new[key] = {}
            end
            new[key] = ApplyConfigDefaults(new[key], value)
        end
    end
    return new
end

local function OnCharacterAdded(char: Model)
    LastRespawn = tick()

    Character = char
    Humanoid = char:WaitForChild("Humanoid")
    RootPart = char.PrimaryPart or char:FindFirstChildWhichIsA("BasePart")

    Modules.Main_Game = require(PlayerGui:WaitForChild("MainUI").Initiator.Main_Game :: ModuleScript)
end

local function GetCurrentRoom(latest: boolean): Model?
    if latest then
        return CurrentRooms:GetChildren()[#CurrentRooms:GetChildren()]
    end
    return CurrentRooms:FindFirstChild(LocalPlayer:GetAttribute("CurrentRoom"))
end

local function GetRoomAtPoint(vector3: Vector3): Model?
    local whitelist = {}
    for _, room in next, CurrentRooms:GetChildren() do
        local p = room:FindFirstChild(room.Name)
        if p then
            whitelist[#whitelist + 1] = p
        end
    end

    if #whitelist > 0 then
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = whitelist
        params.CollisionGroup = "BaseCheck"

        local result = workspace:Raycast(vector3, Vector3.new(0, -100, 0), params)
        if result then
            for _, room in next, CurrentRooms:GetChildren() do
                if result.Instance.Parent == room then
                    return room
                end
            end
        end
    end
    return
end

local function FixRoomLights(room: Model)
    local roomEntrance = room:FindFirstChild("RoomEntrance")
    if not roomEntrance then return end

    for _, c in next, Camera:GetChildren() do
        if c.Name == "Piece" then
            c:Destroy()
        end
    end

    Modules.Module_Events.toggle(room, true, Storage.Ambient[room])

    local stuff = {}
    for _, d in next, room:GetDescendants() do
        if d:IsA("Model") and (d.Name == "LightStand" or d.Name == "Chandelier") then
            table.insert(stuff, d)
        end
    end

    local random = Random.new(tick())
    for _, v in next, stuff do
        if v:GetAttribute("Shattered") then
            local r1 = random:NextInteger(-10, 10) / 50
            local r2 = random:NextInteger(5, 20) / 100

            task.delay((roomEntrance.Position - v.PrimaryPart.Position).Magnitude / 150 + r1, function()
                local neon = v:FindFirstChild("Neon", true)
                for _, d in next, v:GetDescendants() do
                    if d:IsA("Light") then
                        TweenService:Create(d, TweenInfo.new(r2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
                            Brightness = d:GetAttribute("OGBrightness")
                        }):Play()
                    elseif d:IsA("Sound") then
                        TweenService:Create(d, TweenInfo.new(r2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
                            Volume = d:GetAttribute("OGVolume")
                        }):Play()
                    end
                end
                if neon then
                    neon.Transparency = 0.9
                    neon.Material = Enum.Material.Neon
                    TweenService:Create(neon, TweenInfo.new(r2, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut), {
                        Transparency = 0.2
                    }):Play()
                    task.wait(r2)
                end
                v:SetAttribute("Shattered", nil)
            end)
        end
    end
end

local function HasEquipped(name: string): boolean
    local tool = Character:FindFirstChildOfClass("Tool")
    if tool and (tool.Name == name or tool:HasTag(name)) then
        return true, tool
    end
    return false
end

local function CrucifixEntity(entity: any)
    local model = entity.Model
    local config = entity.Config

    local resist = config.Crucifixion.Resist

    local entityPivot = model:GetPivot()

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {Character, model}

    local result = workspace:Raycast(entityPivot.Position, Vector3.new(0, -1000, 0), params)
    if not result then return end

    model:SetAttribute("BeingBanished", true)

    local MainGame = require(PlayerGui.MainUI.Initiator.Main_Game :: ModuleScript)
    local CamShaker = MainGame.camShaker
    local TheShake = CamShaker:StartShake(5, 20, 2, Vector3.zero)

    local Repentance = Assets.Repentance:Clone()
    local Crucifix = Repentance.Crucifix
    local Handle = Crucifix.Handle
    local Pentagram = Repentance.Pentagram
    local EntityPart = Repentance.Entity
    local Sound = Handle[resist and "SoundFail" or "Sound"]

    Repentance:PivotTo(CFrame.new(result.Position))
    Crucifix:PivotTo(Character:GetPivot())
    EntityPart.CFrame = entityPivot
    Repentance.Parent = workspace
    Sound:Play()

    local function waitUntil(t: number)
        repeat RunService.RenderStepped:Wait() until Sound.TimePosition >= t
    end

    local function fadeOut()
        for _, v in Pentagram:GetChildren() do
            if v.Name == "BeamFlat" then
                task.delay(v:GetAttribute("Delay") or 0, function()
                    TweenService:Create(
                        v,
                        TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
                        { Brightness = 0 }
                    ):Play()
                end)
            elseif v.Name == "BeamChain" then
                TweenService:Create(
                    v,
                    TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
                    { Brightness = 0 }
                ):Play()
            end
        end
    end

    local Color = Storage.CrucifixTypes[config.Crucifixion.Type:lower()].Color

    for _, v in next, Repentance:QueryDescendants(".GiveMeColor") do
        if v:IsA("Light") or v:IsA("BasePart") then
            v.Color = Color
        elseif v:IsA("ParticleEmitter") or v:IsA("Beam") then
            v.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color),
                ColorSequenceKeypoint.new(1, Color)
            })
        end
    end

    task.spawn(function()
        if not resist then
            while EntityPart.Parent do
                model:PivotTo(EntityPart.CFrame)
                RunService.RenderStepped:Wait()
            end
            model:Destroy()
        end
    end)

    TweenService:Create(
        Pentagram.Circle,
        TweenInfo.new(2, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
        { CFrame = Pentagram.Circle.CFrame - Vector3.new(0, 25, 0) }
    ):Play()

    task.delay(2, Pentagram.Circle.Destroy, Pentagram.Circle)

    Handle.BodyPosition.Position = (Character:GetPivot() * CFrame.new(1, 4, -6)).Position

    TweenService:Create(
        Handle.BodyAngularVelocity,
        TweenInfo.new(4, Enum.EasingStyle.Cubic, Enum.EasingDirection.In),
        { AngularVelocity = Vector3.new(0, 40, 0) }
    ):Play()

    task.delay(3, function()
        for _, shard in next, Handle.Shards:GetChildren() do
            shard.CollisionGroup = "NoPlayer"
            shard.CanCollide = true
            shard.Weld:Destroy()
            shard.AssemblyAngularVelocity = Vector3.zero
        end
    end)

    if not resist then
        TweenService:Create(
            EntityPart,
            TweenInfo.new(3, Enum.EasingStyle.Elastic, Enum.EasingDirection.In),
            { CFrame = EntityPart.CFrame + Vector3.new(0, 2, 0) }
        ):Play()
    end

    task.spawn(function()
        waitUntil(2.625)

        TweenService:Create(
            Pentagram.Base.LightAttach.LightBright,
            TweenInfo.new(1.5, Enum.EasingStyle.Circular, Enum.EasingDirection.InOut),
            { Brightness = 5, Range = 40 }
        ):Play()
        TweenService:Create(
            Handle.Light,
            TweenInfo.new(1.5, Enum.EasingStyle.Circular, Enum.EasingDirection.InOut),
            { Brightness = 11.25, Range = 30 }
        ):Play()

        task.wait(1.5)

        TweenService:Create(Pentagram.Base.LightAttach.LightBright, TweenInfo.new(1.5, Enum.EasingStyle.Circular, Enum.EasingDirection.InOut), {
            Brightness = 0,
            Range = 0
        }):Play()
        TweenService:Create(Handle.Light, TweenInfo.new(1.5, Enum.EasingStyle.Circular, Enum.EasingDirection.InOut), {
            Brightness = 0,
            Range = 0
        }):Play()

        if not resist then
            TweenService:Create(
                Handle.Light,
                TweenInfo.new(1, Enum.EasingStyle.Circular, Enum.EasingDirection.InOut),
                { Brightness = 15, Range = 40 }
            ):Play()

            TheShake:StartFadeOut(3)
            fadeOut()

            TweenService:Create(
                Handle.BodyAngularVelocity,
                TweenInfo.new(3, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
                { AngularVelocity = Vector3.zero }
            ):Play()
        end
    end)

    if not resist then
        waitUntil(2.5)

        TweenService:Create(
            EntityPart,
            TweenInfo.new(3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
            { CFrame = EntityPart.CFrame - Vector3.new(0, 50, 0) }
        ):Play()

        for _, s in next, model:QueryDescendants("Sound") do
            if s:GetAttribute("VolumeIgnore") then continue end

            TweenService:Create(
                s,
                TweenInfo.new(3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
                { Volume = 0 }
            ):Play()
        end

        waitUntil(6.75)
    else
        waitUntil(4)

        TweenService:Create(
            Handle.BodyAngularVelocity,
            TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
            { AngularVelocity = Vector3.zero }
        ):Play()
        TweenService:Create(
            Pentagram.Base.LightAttach.LightBright,
            TweenInfo.new(1.5, Enum.EasingStyle.Circular, Enum.EasingDirection.InOut),
            { Brightness = 0, Range = 0, Color = Color3.fromRGB(255, 116, 130) }
        ):Play()
        TweenService:Create(
            Handle.Light,
            TweenInfo.new(1.5, Enum.EasingStyle.Circular, Enum.EasingDirection.InOut),
            { Brightness = 0, Range = 0, Color = Color3.fromRGB(255, 116, 130) }
        ):Play()

        TheShake:StartFadeOut(3)

        task.spawn(function()
            local color = Instance.new("Color3Value")
            color.Value = Color3.fromRGB(137, 207, 255)

            local tween = TweenService:Create(
                color,
                TweenInfo.new(0.5, Enum.EasingStyle.Sine),
                { Value = Color3.fromRGB(255, 116, 130) }
            )
            tween:Play()

            while tween.PlaybackState == Enum.PlaybackState.Playing do
                for _, d in next, Repentance:GetDescendants() do
                    if d.ClassName == "Beam" then
                        d.Color = ColorSequence.new({
                            ColorSequenceKeypoint.new(0, color.Value),
                            ColorSequenceKeypoint.new(1, color.Value)
                        })
                    elseif d.Name == "Glow" then
                        d.Color = color.Value
                    end
                end
                task.wait()
            end
        end)

        waitUntil(9.625)
    end

    TweenService:Create(
        Handle.Glow,
        TweenInfo.new(1),
        { Size = Handle.Glow.Size * 3, Transparency = 1 }
    ):Play()
    TweenService:Create(
        Pentagram.Base.LightAttach.LightBright,
        TweenInfo.new(1),
        { Brightness = 0, Range = 0 }
    ):Play()
    TweenService:Create(
        Handle.Light,
        TweenInfo.new(1),
        { Brightness = 0, Range = 0 }
    ):Play()

    if not resist then
        Handle.ExplodeParticle:Emit(math.random(20, 30))
        CamShaker:ShakeOnce(7.5, 7.5, 0.25, 1.5)
    else
        model:SetAttribute("BeingBanished", false)
        model:SetAttribute("Paused", false)
        fadeOut()
    end

    task.delay(5, Repentance.Destroy, Repentance)
end

local function IsPlayerProtected(): boolean
    return (tick() - LastRespawn) <= LocalPlayer:GetAttribute("SpawnProtection")
end

local function DamagePlayer(entity: any)
    if Humanoid.Health <= 0 or IsPlayerProtected() then return end

    local config = entity.Config
    local newHealth = math.clamp(Humanoid.Health - config.Damage.Amount, 0, Humanoid.MaxHealth)

    Humanoid.Health = newHealth
    task.spawn(entity.RunCallback, entity, "OnDamagePlayer", newHealth)

    if newHealth == 0 then
        if #config.Death.Hints > 0 then
            PlayerGui.MainUI.Death:GetPropertyChangedSignal("Visible"):Wait()

            local colour;
            for name, values in next, Storage.DeathTypes do
                if table.find(values, config.Death.Type:lower()) then
                    colour = name
                end
            end
            if not colour then
                for _, c in next, PlayerGui.MainUI.Initiator.Main_Game.Health.Music:GetChildren() do
                    if c.Name:lower() == config.Death.Type:lower() then
                        colour = c.Name
                    end
                end
            end
            if not colour then
                colour = "Blue"
            end

            if firesignal then
                firesignal(Remotes.DeathHint.OnClientEvent, config.Death.Hints, colour)
            else
                warn(debug.traceback("function 'firesignal' not supported by exploit, ignoring death hints"))
            end
        end

        local cause = config.Death.Cause
        if typeof(cause) ~= "string" or cause ~= "" then
            cause = config.Entity.Name
        end
        GameStats["Player_".. LocalPlayer.Name].Total.DeathCause.Value = cause
    end
end

-- ============================================================
--                    NODE GRAPH PATHFINDING
-- ============================================================

-- Возвращает позицию входа/выхода комнаты (для Ambush-пути и endpoint'ов)
local function GetRoomEndpoints(room: Model, reversed: boolean): (Vector3?, Vector3?)
    local entrance = room:FindFirstChild("RoomEntrance")
    local exitPart  = room:FindFirstChild("RoomExit")

    local enterPos = entrance and entrance.Position or nil
    local exitPos  = exitPart and exitPart.Position  or nil

    if reversed then
        return exitPos, enterPos
    end
    return enterPos, exitPos
end

-- Ambush: единый путь от входа первой комнаты до выхода последней (или наоборот)
local function GetPathfindNodesAmbush(config: any): { any }
    local rooms = CurrentRooms:GetChildren()
    if #rooms == 0 then return {} end

    -- Порядок комнат (в зависимости от Reversed)
    local orderedRooms = table.clone(rooms)
    if config.Movement.Reversed then
        table.reverse(orderedRooms)
    end

    local megaGraph = BuildMegaGraph(orderedRooms)
    if not megaGraph or not next(megaGraph.nodes) then
        warn("[EntitySpawner] Ambush: пустой граф")
        return {}
    end

    local startPos, _ = GetRoomEndpoints(orderedRooms[1], config.Movement.Reversed)
    local _, endPos   = GetRoomEndpoints(orderedRooms[#orderedRooms], config.Movement.Reversed)

    if not startPos or not endPos then
        warn("[EntitySpawner] Ambush: не найдены RoomEntrance/RoomExit")
        return {}
    end

    local pathData = Pathfinder:_getPath(megaGraph, startPos, endPos)
    if not pathData then
        warn("[EntitySpawner] Ambush: path not found")
        return {}
    end

    return pathData.path
end

-- Blitz: два пути — до игрока и от игрока до конца
local function GetPathfindNodesBlitz(config: any): ({ any }, { any })
    local currentRoomIndex = LocalPlayer:GetAttribute("CurrentRoom")
    local rooms = CurrentRooms:GetChildren()
    if #rooms == 0 then return {}, {} end

    local orderedRooms = table.clone(rooms)
    if config.Movement.Reversed then
        table.reverse(orderedRooms)
    end

    local currentRoom
    for _, room in next, rooms do
        if tonumber(room.Name) == currentRoomIndex then
            currentRoom = room
            break
        end
    end
    if not currentRoom then
        warn("[EntitySpawner] Blitz: текущая комната не найдена")
        return {}, {}
    end

    local megaGraph = BuildMegaGraph(orderedRooms)
    if not megaGraph or not next(megaGraph.nodes) then
        warn("[EntitySpawner] Blitz: пустой граф")
        return {}, {}
    end

    local startPos, _ = GetRoomEndpoints(orderedRooms[1], config.Movement.Reversed)
    local _, endPos   = GetRoomEndpoints(orderedRooms[#orderedRooms], config.Movement.Reversed)
    if not startPos or not endPos then
        warn("[EntitySpawner] Blitz: не найдены endpoints")
        return {}, {}
    end

    -- Точка "встречи" — центр текущей комнаты (или позиция игрока)
    local currentEntrance = currentRoom:FindFirstChild("RoomEntrance")
    local meetPos = currentEntrance and currentEntrance.Position or RootPart.Position

    local pathToCurrent = Pathfinder:_getPath(megaGraph, startPos, meetPos)
    local pathToEnd     = Pathfinder:_getPath(megaGraph, meetPos, endPos)

    return
        (pathToCurrent and pathToCurrent.path) or {},
        (pathToEnd and pathToEnd.path) or {}
end

-- ============================================================
--                    MOVEMENT / SPAWNER
-- ============================================================

local function EntityMoveTo(model: Model, cframe: CFrame, speed: number)
    local reached = false
    local connection; connection = RunService.Stepped:Connect(function(_, step)
        if not model:GetAttribute("Paused") then
            local pivot = model:GetPivot()
            local difference = (cframe.Position - pivot.Position)
            local unit = difference.Unit
            local magnitude = difference.Magnitude

            if magnitude > 0.1 then
                model:PivotTo(pivot + unit * math.min(step * speed, magnitude))
            else
                connection:Disconnect()
                reached = true
            end
        end
    end)
    repeat RunService.Stepped:Wait() until reached
end

-- Универсальная функция прохода по пути (массив nodeData)
local function TraversePath(entity, model, path, config, reverse: boolean?)
    if reverse then
        for i = #path, 1, -1 do
            local node = path[i]
            local cframe = CFrame.new(node.Position + Vector3.new(0, 3 + config.Entity.HeightOffset, 0))
            EntityMoveTo(model, cframe, config.Movement.Speed)
            task.spawn(entity.RunCallback, entity, "OnReachNode", node)
        end
    else
        for _, node in next, path do
            local cframe = CFrame.new(node.Position + Vector3.new(0, 3 + config.Entity.HeightOffset, 0))
            EntityMoveTo(model, cframe, config.Movement.Speed)
            task.spawn(entity.RunCallback, entity, "OnReachNode", node)
        end
    end
end

local function Earthquake()
    Modules.Main_Game.camShaker:ShakeOnce(4, 12, 1, 5)
    Modules.Main_Game.camShaker:ShakeOnce(10, 2, 3, 3)
    Assets.Earthquake.SoundEarthquake:Play()
    local v5 = CollectionService:GetTagged("PartCeiling")
    local v6 = {}
    for _, v7 in v5 do
        local v8 = v7.Size.Magnitude * 0.7
        local v9 = math.clamp(v8, 0, 150)
        for _, v10 in Assets.Earthquake.Particles:GetChildren() do
            local v11 = v10:Clone()
            v11.Parent = v7
            v11:Emit(v9 / 10)
            v11.Enabled = true
            table.insert(v6, v11)
        end
    end
    task.wait(4)
    for _, v12 in v6 do
        v12.Enabled = false
    end
end

-- \\ Setup // --

for name, value in next, CONST.ATTR.PLAYER do
    LocalPlayer:SetAttribute(name, value)
end

LastRespawn = tick() - LocalPlayer:GetAttribute("SpawnProtection")

LocalPlayer.CharacterAdded:Connect(OnCharacterAdded)

-- \\ Main // --

Module.Create = function(self, config: any): any?
    local newConfig = ApplyConfigDefaults(config, CONST.DEFAULT.CONFIG)
    newConfig.Movement.Speed = CONST.BASE_ENTITY_SPEED / 100 * config.Movement.Speed

    local asset = newConfig.Entity.Asset
    local success, entityModel = false, nil

    if typeof(asset) == "Instance" then
        success, entityModel = true, asset
    elseif typeof(asset) == "string" then
        success, entityModel = pcall(function()
            local instance: Instance? = LoadCustomInstance(asset)
            if typeof(instance) == "Instance" then
                if instance.ClassName ~= "Model" then
                    error(string.format(
                        debug.traceback("Entity model Instance invalid, expected Model but got '%s'"),
                        instance.ClassName
                    ))
                    return
                end
            else
                error(debug.traceback("Failed to fetch entity model."))
                return
            end
            return instance
        end)
    end
    if not (success and entityModel) then return end

    local rootPart = entityModel.PrimaryPart or entityModel:FindFirstChildWhichIsA("BasePart", true)
    if not rootPart then return end

    rootPart.Anchored = true
    entityModel.PrimaryPart = rootPart

    local name = config.Entity.Name
    if typeof(name) == "string" and name ~= "" then
        entityModel.Name = name
    end

    for attr, val in next, CONST.ATTR.ENTITY do
        entityModel:SetAttribute(attr, val)
    end

    local c = Instance.new("Configuration")
    c.Name = "RoomsEntered"
    c.Parent = entityModel

    return {
        Model = entityModel,
        Config = newConfig,
        Debug = CloneTable(CONST.DEFAULT.DEBUG),
        SetCallback = function(self, key: string, callback: any)
            assert(typeof(key) == "string" and self.Debug[key], debug.traceback("Callback key is invalid."))
            assert(typeof(callback) == "function", debug.traceback("Callback must be a function."))
            if self.Debug[key] then
                self.Debug[key] = callback
            end
        end,
        RunCallback = function(self, key: string, ...: any?)
            local callback = self.Debug[key]
            if typeof(callback) == "function" then
                local success, result = pcall(callback, ...)
                if not success then
                    error(debug.traceback(
                        string.format(
                            "Error in callback: '%s' for entity: '%s':\n%s",
                            key,
                            self.Config.Entity.Name,
                            result
                        )
                    ))
                end
            end
        end,
        IsAlive = function(self): boolean
            return self.Model and self.Model.Parent
        end,
        Pause = function(self)
            if self:IsAlive() then
                self.Model:SetAttribute("Paused", true)
            end
        end,
        Resume = function(self)
            if self:IsAlive() then
                self.Model:SetAttribute("Paused", false)
            end
        end,
        Run = function(self, copyEntity: boolean)
            Module:Run(self, copyEntity)
        end,
        Despawn = function(self)
            if self:IsAlive() then
                self.Model:Destroy()
                local i = table.find(Module.ActiveEntities, self)
                if i then
                    table.remove(Module.ActiveEntities, i)
                end
                task.spawn(self.RunCallback, self, "OnDespawned")
            end
        end
    }
end

Module.Run = function(self, entity: any, copyEntity: boolean)
    if copyEntity == true then
        self:Run(CloneTable(entity), false)
        return
    end

    if entity.Model:GetAttribute("Running") then return end
    do
        local rebounding = entity.Config.Rebounding
        if
            rebounding.Enabled
            and (
                rebounding.Min <= 0
                or rebounding.Max <= 0
                or rebounding.Min > rebounding.Max
            )
        then
            error(string.format(
                debug.traceback("Invalid rebounding minmax values: %s - %s"),
                rebounding.Min,
                rebounding.Max
            ))
        end
    end

    local model = entity.Model
    local config = entity.Config
    local debug = entity.Debug

    model:SetAttribute("Running", true)
    self.ActiveEntities[#self.ActiveEntities + 1] = entity

    -- Spawn point
    local spawnPoint: BasePart? = nil
    do
        local rooms = CurrentRooms:GetChildren()
        if config.Movement.Reversed then
            spawnPoint = rooms[#rooms]:FindFirstChild("RoomExit")
        else
            spawnPoint = rooms[1]:FindFirstChild("RoomEntrance")
        end
    end
    if not spawnPoint then
        error(string.format(debug.traceback("Failed to find spawn point for entity: '%s'"), config.Entity.Name))
    end

    model:PivotTo(spawnPoint.CFrame + Vector3.new(0, config.Entity.HeightOffset, 0))
    model.Parent = workspace
    task.spawn(entity.RunCallback, entity, "OnSpawned")

    local currentRoom = GetCurrentRoom(false)
    if currentRoom then
        if config.Lights.Flicker.Enabled then
            Modules.Module_Events.flicker(currentRoom, config.Lights.Flicker.Duration)
        end
        if config.Earthquake.Enabled then
            task.spawn(Earthquake)
        end
    end

    task.wait(config.Movement.Delay)

    -- Awareness loop (урон, распятие, камера, комнаты)
    task.spawn(entity.RunCallback, entity, "OnStartMoving")
    task.spawn(function()
        while entity:IsAlive() and task.wait() do
            if model:GetAttribute("Paused") then continue end

            local origin = model:GetPivot().Position
            local charOrigin = RootPart.Position

            local inSight = false
            if (charOrigin - origin).Magnitude <= config.Damage.Range then
                local params = RaycastParams.new()
                params.FilterType = Enum.RaycastFilterType.Exclude
                params.FilterDescendantsInstances = {Character, model, CollectionService:GetTagged("HidingSpot")}

                inSight = workspace:Raycast(origin, charOrigin - origin, params) == nil
            end

            if Humanoid.Health > 0 then
                local _, isVisible = Camera:WorldToViewportPoint(origin)
                if isVisible then
                    task.spawn(entity.RunCallback, entity, "OnLookAt", inSight)
                end
            end

            -- Room detection
            do
                local room = GetRoomAtPoint(origin)
                if room then
                    local index = tonumber(room.Name)
                    if index and index >= 0 and index ~= model:GetAttribute("LastEnteredRoom") then
                        model:SetAttribute("LastEnteredRoom", index)

                        local roomsEntered = model:FindFirstChild("RoomsEntered") :: Folder
                        if roomsEntered then
                            local firstTime = roomsEntered:GetAttribute(room.Name) == nil
                            task.spawn(entity.RunCallback, entity, "OnEnterRoom", room, firstTime)

                            if firstTime then
                                roomsEntered:SetAttribute(room.Name, true)
                            end

                            local latestRoom = GetCurrentRoom(true)
                            if room ~= latestRoom then
                                if config.Lights.Shatter then
                                    Modules.Module_Events.shatter(room)
                                elseif config.Lights.Repair then
                                    FixRoomLights(room)
                                end
                            end
                        end
                    end
                end
            end

            -- Crucifix
            local usedCrucifix = false
            do
                local crucifixion = config.Crucifixion
                if
                    crucifixion.Enabled
                    and crucifixion.Range > 0
                    and (charOrigin - origin).Magnitude <= crucifixion.Range
                    and inSight
                then
                    local hasTool, tool = HasEquipped("Crucifix")
                    if hasTool and tool and not model:GetAttribute("BeingBanished") then
                        if typeof(debug.CrucifixionOverwrite) == "function" then
                            entity:RunCallback("CrucifixionOverwrite")
                        else
                            tool:Destroy()
                            model:SetAttribute("Paused", true)
                            CrucifixEntity(entity)
                        end
                        usedCrucifix = true
                    end
                end
            end

            -- Damage
            if not model:GetAttribute("Paused") and not usedCrucifix then
                local damage = config.Damage
                if
                    damage.Enabled
                    and damage.Range > 0
                    and Humanoid.Health > 0
                    and (not Character:GetAttribute("Hiding") or damage.IgnoreHiding)
                    and model:GetAttribute("Damage")
                    and not model:GetAttribute("BeingBanished")
                    and (charOrigin - origin).Magnitude <= damage.Range
                    and inSight
                then
                    model:SetAttribute("Damage", false)
                    DamagePlayer(entity)
                end
            end

            -- Camera shake
            do
                local camShake = config.CameraShake
                if camShake.Enabled then
                    local mag = (charOrigin - origin).Magnitude
                    if mag <= camShake.Range then
                        local cloned = {}
                        for i, v in next, camShake.Values do
                            cloned[i] = v
                        end

                        cloned[1] = camShake.Values[1] / camShake.Range * (camShake.Range - mag)
                        cloned[2] = camShake.Values[2] / camShake.Range * (camShake.Range - mag)
                        Modules.Main_Game.camShaker:ShakeOnce(table.unpack(cloned))
                    end
                end
            end
        end
    end)

    -- Pathfinding + Rebounding + Despawn
    task.spawn(function()
        local reboundType = config.Rebounding.Type:upper()

        if reboundType == "AMBUSH" then
            local path = GetPathfindNodesAmbush(config)

            -- Forward
            TraversePath(entity, model, path, config, false)

            -- Rebounding
            if config.Rebounding.Enabled and #path > 0 then
                local reboundsCount = math.random(config.Rebounding.Min, config.Rebounding.Max)
                for i = 1, reboundsCount do
                    task.wait(config.Rebounding.Delay)
                    model:SetAttribute("Damage", true)
                    task.spawn(entity.RunCallback, entity, "OnRebounding", true)

                    -- Backward
                    TraversePath(entity, model, path, config, true)

                    task.spawn(entity.RunCallback, entity, "OnRebounding", false)
                    task.wait(config.Rebounding.Delay)
                    model:SetAttribute("Damage", true)
                    task.spawn(entity.RunCallback, entity, "OnRebounding", true)

                    -- Rebuild path (комнаты могли добавиться)
                    path = GetPathfindNodesAmbush(config)

                    -- Forward again
                    TraversePath(entity, model, path, config, false)

                    task.spawn(entity.RunCallback, entity, "OnRebounding", false)

                    if i < reboundsCount then
                        task.wait(config.Rebounding.Delay)
                    end
                end
            end

        elseif reboundType == "BLITZ" then
            local nodesToCurrent, nodesToEnd = GetPathfindNodesBlitz(config)

            TraversePath(entity, model, nodesToCurrent, config, false)

            if config.Rebounding.Enabled and #nodesToCurrent > 1 then
                for _ = 1, math.random(config.Rebounding.Min, config.Rebounding.Max) do
                    model:SetAttribute("Damage", true)
                    task.spawn(entity.RunCallback, entity, "OnRebounding", true)

                    local randomIndex = math.random(2, #nodesToCurrent)

                    -- Backward to randomIndex
                    for i = #nodesToCurrent, randomIndex, -1 do
                        local node = nodesToCurrent[i]
                        local cframe = CFrame.new(node.Position + Vector3.new(0, 3 + config.Entity.HeightOffset, 0))
                        EntityMoveTo(model, cframe, config.Movement.Speed)
                        task.spawn(entity.RunCallback, entity, "OnReachNode", node)
                    end

                    task.wait(config.Rebounding.Delay)
                    model:SetAttribute("Damage", true)
                    task.spawn(entity.RunCallback, entity, "OnRebounding", false)

                    -- Forward back
                    for i = randomIndex, #nodesToCurrent do
                        local node = nodesToCurrent[i]
                        local cframe = CFrame.new(node.Position + Vector3.new(0, 3 + config.Entity.HeightOffset, 0))
                        EntityMoveTo(model, cframe, config.Movement.Speed)
                        task.spawn(entity.RunCallback, entity, "OnReachNode", node)
                    end
                end
            end

            TraversePath(entity, model, nodesToEnd, config, false)
        end

        -- Despawn
        if not model:GetAttribute("Despawning") then
            model:SetAttribute("Despawning", true)
            task.spawn(entity.RunCallback, entity, "OnDespawning")
            EntityMoveTo(model, model:GetPivot() - Vector3.new(0, 300, 0), config.Movement.Speed)
            entity:Despawn()
        end
    end)
end

-- \\ Ambient storage // --

if not getgenv()._internal_vynixu_entity_spawner then
    getgenv()._internal_vynixu_entity_spawner = true

    local function GetAmbient(room: Model): Color3
        return
            room:GetAttribute("AmbientOriginal") :: Color3
            or room:GetAttribute("Ambient") :: Color3
            or Color3.fromRGB(67, 51, 56)
    end

    for _, room in next, CurrentRooms:GetChildren() do
        Storage.Ambient[room] = GetAmbient(room)
    end

    CurrentRooms.ChildAdded:Connect(function(room: Model)
        Storage.Ambient[room] = GetAmbient(room)
    end)
end

Module.Clear = function(self)
    for _, entity in next, self.ActiveEntities do
        entity:Despawn()
    end
end

Module.Unload = function(self)
    self:Clear()
    for i, v in self.Connections do
        v:Disconnect()
        self.Connections[i] = nil
    end
    for i in next, self do
        self[i] = nil
    end
end

getgenv().VynixuEntitySpawnerV2 = Module
return Module