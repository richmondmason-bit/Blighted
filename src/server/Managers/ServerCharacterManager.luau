local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerSprintManager = require(ServerScriptService.Managers.PlayerManager.PlayerSprintManager)
local Utils = require(ReplicatedStorage.Modules.Utils)
local PlayerManager = require(script.Parent.PlayerManager)
local Network = require(ReplicatedStorage.Modules.Network)
local Sounds = require(ReplicatedStorage.Modules.Sounds)
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local CharModuleCache = require(ServerScriptService.System.CharModuleCache)

local Rand = Random.new()

local ServerCharacterManager = {}

local PlayersRemainingFolder = ReplicatedStorage.RoundInfo.PlayersRemaining

function ServerCharacterManager:Init()
end

--- Resolves the spawn CFrame for a given role from the current map's SpawnPoints.
--- Returns nil if no valid spawn point is found.
function ServerCharacterManager._ResolveSpawnCFrame(charType, cf)
    if cf then
        return cf
    end

    if not charType then
        return nil
    end

    local Map = workspace:FindFirstChild("Map")
    if not Map then
        warn("[ServerCharacterManager] No Map in workspace!")
        return nil
    end

    Map = Map:FindFirstChild("Map") or Map

    local SpawnPoints = Map:FindFirstChild("SpawnPoints")
    if not SpawnPoints then
        warn("[ServerCharacterManager._PositionCharacter()] Spawn points aren't set for this map!")
        return nil
    end

    local Layouts = SpawnPoints:GetChildren()
    if #Layouts <= 0 then
        warn("[ServerCharacterManager._PositionCharacter()] The map's spawn point folder is empty!")
        return nil
    end

    local Layout = Layouts[#Layouts > 1 and Rand:NextInteger(1, #Layouts) or 1]
    local RoleFolder = Layout:FindFirstChild(charType.."s")
    if not RoleFolder then
        warn("[ServerCharacterManager._PositionCharacter()] No spawn points for role \"" .. charType .. "\" in layout \"" .. Layout.Name .. "\"!")
        return nil
    end

    local Points = RoleFolder:GetChildren()
    if #Points <= 0 then
        warn("[ServerCharacterManager._PositionCharacter()] Spawn Points folder for \"" .. charType .. "\" is empty!")
        return nil
    end

    local ChosenSpawnPoint = Points[Rand:NextInteger(1, #Points)]
    if ChosenSpawnPoint:IsA("BasePart") then
        return ChosenSpawnPoint.CFrame
    elseif ChosenSpawnPoint:IsA("Model") then
        return ChosenSpawnPoint:GetPivot()
    else
        warn("[ServerCharacterManager._PositionCharacter()] Spawn point is not a BasePart or Model!")
        return nil
    end
end

function ServerCharacterManager._PositionCharacter(Char, charType, cf)
    local SpawnCFrame = ServerCharacterManager._ResolveSpawnCFrame(charType, cf)
    if SpawnCFrame then
        Char:PivotTo(SpawnCFrame)
    end
end

--- Sets up a player's character specified by its name, its type, and a possible skin.
--- Can also take a `CFrame` parameter to pivot the character there.
function ServerCharacterManager.SetupCharacter(player: Player, charName: string, charType: "Survivor" | "Killer", skinName: string?, cf: CFrame?)
    if not charName or not charType then
        return PlayerManager._RespawnPlayer(player)
    end

    local rigOverride = nil
    do
        local charModule = Utils.Instance.GetCharacterModule(charType, charName, skinName)
        if charModule then
            local ok, mod = pcall(require, charModule)
            if ok and type(mod) == "table" and mod.Config and typeof(mod.Config.Rig) == "Instance" then
                rigOverride = mod.Config.Rig
            end
        end
    end
    -- Resolve the spawn CFrame BEFORE the character is parented/replicated to clients.
    -- This ensures clients receive the character already at the correct position.
    local spawnCF = ServerCharacterManager._ResolveSpawnCFrame(charType, cf)
    local Char = PlayerManager._RespawnPlayer(player, charName, charType, skinName, rigOverride, spawnCF)

    if charType == "Survivor" then
	    local Remaining = Instance.new("ObjectValue") --only for survivors since there's only ever going to be 1 killer (i'm lazy to make the possibility to have multiple and it'd be too broken lol)
	    Remaining.Name = player.UserId
	    Remaining.Value = player
	    Remaining.Parent = PlayersRemainingFolder
    end

    ServerCharacterManager._InitCharacter(player, Char, Utils.Instance.GetCharacterModule(charType, charName, skinName))

    return Char, spawnCF
end

--- Inits a character's abilities and sets its properties accordingly as specified in its `GameplayConfig`.
function ServerCharacterManager._InitCharacter(player, Char, charModule)
    local module = Utils.Type.CopyTable(require(charModule))
    module.Owner = player

    -- Store in the shared cache so CommonFunctions/Hitbox can look it up without
    -- requiring the client-side CharacterAbilities script (sandboxed on noob rigs).
    CharModuleCache.Set(Char, module)

    --Abilities
    -- CharacterAbilities now lives in PlayerScripts (client-side, unsandboxed).
    -- The client reads CharacterModule from CharModuleCache via a network signal instead.
    local charAbilitiesResult = nil

    local Humanoid = Char:FindFirstChildWhichIsA("Humanoid")
    Humanoid.MaxHealth = module.GameplayConfig.Health
    Humanoid.Health = module.GameplayConfig.Health
    Humanoid.JumpPower = 0
    Humanoid.JumpHeight = 0

    task.defer(function()
        if not PlayerSprintManager.ManagedPlayers[player] then
            local Timeout = 0
            repeat
                task.wait()
                Timeout = Timeout + 1
            until PlayerSprintManager.ManagedPlayers[player] or Timeout >= 50
            if Timeout >= 50 then
                return
            end
        end

        PlayerSprintManager.ManagedPlayers[player].SprintMultiplier = module.GameplayConfig.SprintSpeedMultiplier
    end)

    Utils.Misc.PreloadAssets(module.Config)

    for name, value in module.GameplayConfig.StaminaProperties do
        local Property = Char.PlayerAttributes:FindFirstChild(name)
        if not Property then
            continue
        end

        Property.Value = value
    end

    for _, Ability in module.GameplayConfig.Abilities do
        Ability:Init(module, player)
        if charAbilitiesResult then
            charAbilitiesResult.Abilities[Ability] = Ability
        end
    end

    task.defer(function()
        -- loading all execution animations
        task.defer(function()
            for rootName, _ in module.Config.AnimationIDs do
                if not rootName:lower():find("execution") then
                    continue
                end

                module.GameplayConfig.Cache.Animations[rootName] = {}

                for name, anims in module.Config.AnimationIDs[rootName] do
                    module.GameplayConfig.Cache.Animations[rootName][name] = {}
                    for animName, anim in anims do
                        if animName:lower() ~= "killer" then
                            continue
                        end

                        module.GameplayConfig.Cache.Animations[rootName][name][animName] = Utils.Character.LoadAnimationFromID(Char, anim)
                    end
                end
            end
        end)

        if not module.Config.Voicelines then
            return
        end

        local Primary = Utils.Character.GetRootPart(Char)
        if not Primary then
            return
        end

        local VoicelineJanitor = Janitor.new()
        VoicelineJanitor:LinkToInstance(Char)

        if module.Config.Voicelines.Stunned then
            Char.Effects.ChildAdded:Connect(function(newChild)
                if newChild.Name == "Stunned" then
                    Sounds.PlayVoiceline(Char, module.Config.Voicelines.Stunned)
                end
            end)
        end

        task.defer(function()
            if not module.Config.Voicelines.Idle then
                return
            end

            task.wait(math.random(10, 25))
            while player.Character and Char and player.Character == Char and Primary do
                if module.Config.Voicelines.Idle then
                    Sounds.PlayVoiceline(Char, module.Config.Voicelines.Idle, {
                        Priority = 0,
                    })
                end
                task.wait(math.random(10, 25))
            end
        end)

        if not module.Config.Voicelines.LMS then
            return
        end

        VoicelineJanitor:Add(Network:SetConnection("LMSVoiceline", "BINDABLE_EVENT", function(LastMan)
            local Voiceline =
                module.Config.Voicelines.LMS[LastMan:GetAttribute("CharacterSkinName") and LastMan:GetAttribute("CharacterSkinName")..LastMan:GetAttribute("CharacterName") or LastMan:GetAttribute("CharacterName")]
                or module.Config.Voicelines.LMS["Default"]
                or module.Config.Voicelines.LMS

            Sounds.PlayVoiceline(Char, Voiceline, {
                Priority = 999,
            })
        end))
    end)

    if module.OnInit then
        module:OnInit(Char)
    end
end

return ServerCharacterManager
