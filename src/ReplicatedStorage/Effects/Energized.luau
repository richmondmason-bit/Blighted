--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Classes.Types)
local Effect = require(ReplicatedStorage.Classes.Effect)

local PlayerSpeedManager = RunService:IsServer()
	and require(ServerScriptService.Managers.PlayerManager.PlayerSpeedManager)
	or nil

local PlayerSprintManager = RunService:IsServer()
	and require(ServerScriptService.Managers.PlayerManager.PlayerSprintManager)
	or nil

return Effect.New({
	Name = "Speed",
	Description = "Slight speed boost with more stamina drain",

	ApplyEffect = function(_own: Types.Effect, level: number, char: Model)
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end

		if RunService:IsServer() then
			-- Speed multiplier
			PlayerSpeedManager.AddSpeedFactor(player, "SpeedEffect", 1 + 0.26 * level)

			-- Stamina drain multiplier (higher level = faster drain)
			-- Example: level 1 → 1.1× drain, level 2 → 1.2×, etc.
			PlayerSprintManager.AddStaminaDrain(player, "SpeedEffect", 1 + 0.1 * level)
			return
		end

		-- Client-only visual / FOV feedback
		local fovManager = require(player.Character.PlayerAttributeScripts.FOVManager)
		fovManager:AddFOVFactor("SpeedEffect", math.clamp(1 + 0.07 * level, 1, 1.5))
	end,

	RemoveEffect = function(_own: Types.Effect, char: Model)
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end

		if RunService:IsServer() then
			PlayerSpeedManager.RemoveSpeedFactor(player, "SpeedEffect")
			PlayerSprintManager.RemoveStaminaDrain(player, "SpeedEffect")
			return
		end

		local fovManager = require(player.Character.PlayerAttributeScripts.FOVManager)
		fovManager:RemoveFOVFactor("SpeedEffect")
	end,
})
