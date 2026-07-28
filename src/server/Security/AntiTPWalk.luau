local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local CommonFunctions = require(ServerScriptService.System.CommonFunctions)
local Utils = require(ReplicatedStorage.Modules.Utils)

-- How many studs/second over the allowed speed before it counts as a violation.
-- Roblox network replication adds jitter so we give a generous buffer.
local SPEED_TOLERANCE = 20

-- How many seconds of continuous violations before action is taken.
-- A single laggy frame should not be enough to trigger.
local VIOLATION_WINDOW = 1.5

-- Whether to kick (true) or just kill the humanoid (false).
local KICK_ON_DETECT = false

local AntiTPWalk = {
    PlayerThreads = {},
}

function AntiTPWalk:Init()
    Utils.Player.ObservePlayers(function(Player: Player)
        Utils.Character.ObserveCharacter(Player, function(_Character: Model)
            AntiTPWalk._SetupCharacter(Player)
        end)
        Player.CharacterRemoving:Connect(function()
            if AntiTPWalk.PlayerThreads[Player.UserId] then
                AntiTPWalk.PlayerThreads[Player.UserId]:Disconnect()
                AntiTPWalk.PlayerThreads[Player.UserId] = nil
            end
        end)
    end)

    Players.PlayerRemoving:Connect(function(Player: Player)
        if AntiTPWalk.PlayerThreads[Player.UserId] then
            AntiTPWalk.PlayerThreads[Player.UserId]:Disconnect()
            AntiTPWalk.PlayerThreads[Player.UserId] = nil
        end
    end)
end

function AntiTPWalk._SetupCharacter(Player: Player)
    local Character = Player.Character
    if not Character then return end

    local Humanoid = Character:FindFirstChildWhichIsA("Humanoid")
    local HRP = Utils.Character.GetRootPart(Player)
    if not Humanoid or not HRP then return end

    local LastPos = HRP.Position
    local ViolationAccum = 0

    AntiTPWalk.PlayerThreads[Player.UserId] = RunService.PostSimulation:Connect(function(deltaTime)
        if not Character.Parent or Humanoid.Health <= 0 then
            return
        end

        -- Skip frames where the server intentionally moved the character.
        if Character:GetAttribute("ServerTeleport") then
            LastPos = HRP.Position
            ViolationAccum = 0
            return
        end

        -- Skip while the character is in the air (jumping/falling/ragdoll).
        -- Velocity.Y != 0 means they're not grounded; we only care about horizontal
        -- walk-speed cheats.
        if math.abs(HRP.AssemblyLinearVelocity.Y) > 1 then
            LastPos = HRP.Position
            ViolationAccum = 0
            return
        end

        -- Skip if an effect like Ragdoll or Stunned is active.
        local effects = Character:FindFirstChild("Effects")
        if effects and (effects:FindFirstChild("Ragdoll") or effects:FindFirstChild("Stunned")) then
            LastPos = HRP.Position
            ViolationAccum = 0
            return
        end

        local moved = (HRP.Position - LastPos) * Vector3.new(1, 0, 1) -- horizontal only
        local speedThisFrame = moved.Magnitude / deltaTime
        local allowedSpeed = Humanoid.WalkSpeed + SPEED_TOLERANCE

        if speedThisFrame > allowedSpeed then
            ViolationAccum = ViolationAccum + deltaTime
            if ViolationAccum >= VIOLATION_WINDOW then
                ViolationAccum = 0
                if KICK_ON_DETECT then
                    CommonFunctions.KickPlayer(Player, CommonFunctions.KickIDs.SpeedHacking)
                else
                    Utils.Misc.Print("Killing " .. Player.Name .. ": speed hack detected (" .. math.floor(speedThisFrame) .. " studs/s, allowed " .. math.floor(allowedSpeed) .. ")")
                    Humanoid.Health = 0
                end
            end
        else
            -- Decay the accumulator when the player is behaving normally.
            ViolationAccum = math.max(0, ViolationAccum - deltaTime)
        end

        LastPos = HRP.Position
    end)
end

return AntiTPWalk
