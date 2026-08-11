--!strict
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local TimeManager = RunService:IsServer() and require(ServerScriptService.Managers.TimeManager) or nil
local CommonFunctions = RunService:IsServer() and require(ServerScriptService.System.CommonFunctions) or nil
local Types = require(script.Parent.Types)
local Network = require(ReplicatedStorage.Modules.Network)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Sounds = require(ReplicatedStorage.Modules.Sounds)

local HitboxFolder = workspace.TempObjectFolders.Hitboxes

local Hitbox = {
	DefaultConfig = {
		Size = Vector3.new(4, 7, 4),
		CFrameOffset = CFrame.new(),
		Damage = 20,
		Time = 0.2,
		Knockback = 0,
		HitMultiple = false,
		PredictVelocity = true,
		ExecuteOnKill = false,
		IsProjectile = false,
		FriendlyFire = false,
		Reason = "Slash Attack",
		Shape = Enum.PartType.Block,
		EffectsToApply = {},
		Connections = {},
		-- Optional: CFrame | () -> CFrame
		-- Optional: ExecutionAnimation = "Execution"
	},
}

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

local function runCallback(connList: {[string]: any}?, id: string, ...)
	if connList and connList[id] then
		connList[id](...)
	end
end

local function isSameTeam(attackerChar: Model, targetChar: Model): boolean
	local attackerRole = attackerChar:FindFirstChild("Role")
	local targetRole = targetChar:FindFirstChild("Role")
	if not (attackerRole and targetRole) then
		return false
	end
	return attackerRole.Value == targetRole.Value
end

local function canHitTarget(
	humanoid: Humanoid,
	targetChar: Model,
	attackerChar: Model,
	config: Types.HitboxSettings,
	alreadyHit: {Humanoid}
): boolean
	if humanoid.Health <= 0 then
		return false
	end
	if table.find(alreadyHit, humanoid) then
		return false
	end
	if targetChar:GetAttribute("Invincible") or targetChar:GetAttribute("Executing") then
		return false
	end

	local friendlyFireEnabled = workspace:GetAttribute("FriendlyFire") or config.FriendlyFire
	if not friendlyFireEnabled and isSameTeam(attackerChar, targetChar) then
		return false
	end

	return true
end

local function passesWallCheck(
	root: BasePart,
	collidedPart: BasePart,
	hitboxSizeZ: number,
	rayParams: RaycastParams
): boolean
	local directions = {
		root.CFrame.LookVector,
		CFrame.lookAt(root.Position, collidedPart.Position).LookVector,
	}

	local blockedCount = 0
	for _, dir in directions do
		local result = workspace:Raycast(root.Position, dir * hitboxSizeZ, rayParams)
		local inst = result and result.Instance
		if inst
			and not inst.Parent:FindFirstChildWhichIsA("Humanoid")
			and inst.Transparency ~= 1
			and not inst:GetAttribute("Hitbox")
		then
			blockedCount += 1
		end
	end

	-- Both rays hit something map-related → treat as blocked
	return blockedCount < 2
end

local function getResistance(targetChar: Model): number
	local effects = targetChar:FindFirstChild("Effects")
	if not effects then
		return 0
	end
	local resistance = effects:FindFirstChild("Resistance")
	return resistance and resistance.Value or 0
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function Hitbox.New(sourcePlayer: Player, config: Types.HitboxSettings): Types.HitboxDetails
	-- Client stub (never runs real logic)
	if not RunService:IsServer() then
		return {
			HumanoidsHit = {},
			Creator = sourcePlayer,
			Damage = 0,
			TimePast = 0,
			Cancelled = true,
			Connections = {},
			Cancel = function() end,
		}
	end

	local char = sourcePlayer and sourcePlayer.Character
	local root = char and char.PrimaryPart
	if not root then
		warn(
			`ReplicatedStorage/Classes/Hitbox: Notice – Hitbox creation halted, no PrimaryPart on '{sourcePlayer.Name}'.`
		)
		return {
			HumanoidsHit = {},
			Creator = sourcePlayer,
			Damage = 0,
			TimePast = 0,
			Cancelled = true,
			Connections = {},
			Cancel = function() end,
		}
	end

	Utils.Type.DeepTableWrite(config, Hitbox.DefaultConfig)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {char}
	overlapParams.CollisionGroup = "Attackable"

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {char}

	local effects = char:FindFirstChild("Effects") :: Folder?

	local props: Types.HitboxDetails = {
		HumanoidsHit = {},
		Creator = sourcePlayer,
		Damage = config.Damage,
		TimePast = 0,
		Cancelled = false,
		IsProjectile = config.IsProjectile,
		Connections = {},
		Cancel = function(self: Types.HitboxDetails)
			if self.Cancelled then
				return
			end
			self.Cancelled = true
			for _, conn in self.Connections do
				conn:Disconnect()
			end
			table.clear(self.Connections)
		end,
	}

	-- Auto-cancel conditions
	if effects then
		table.insert(props.Connections, effects.ChildAdded:Connect(function(child)
			if child.Name == "Stunned" then
				props:Cancel()
			end
		end))
	end

	table.insert(props.Connections, char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			props:Cancel()
		end
	end))
	table.insert(props.Connections, char.Destroying:Connect(function()
		props:Cancel()
	end))
	table.insert(props.Connections, root.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			props:Cancel()
		end
	end))
	table.insert(props.Connections, root.Destroying:Connect(function()
		props:Cancel()
	end))

	----------------------------------------------------------------------
	-- Main hitbox loop
	----------------------------------------------------------------------
	task.defer(function()
		if effects and effects:FindFirstChild("Stunned") then
			return
		end

		-- Create a reusable template part (cloned each tick so Debris can still manage visibility)
		local template = Instance.new("Part")
		template.Name = sourcePlayer.Name .. "Hitbox"
		template.Transparency = 1
		template.CanCollide = false
		template.CanQuery = false
		template.CanTouch = false
		template.CastShadow = false
		template.Anchored = true
		template.Size = config.Size
		template.Shape = config.Shape

		while not props.Cancelled and props.TimePast < config.Time do
			if not config.HitMultiple and #props.HumanoidsHit > 0 then
				break
			end

			local checkPart = template:Clone()
			checkPart.Size = config.Size
			checkPart.Shape = config.Shape

			-- Resolve CFrame
			local baseCF: CFrame
			if config.CFrame then
				baseCF = typeof(config.CFrame) == "function" and config.CFrame() or config.CFrame
			else
				baseCF = root.CFrame
			end
			checkPart.CFrame = baseCF * config.CFrameOffset
			checkPart.Parent = HitboxFolder

			-- Ping / velocity prediction (non-projectiles only)
			if config.PredictVelocity and not config.IsProjectile then
				local ping = math.clamp(sourcePlayer:GetNetworkPing(), 0, 3)
				local divider = 6.5 - ping
				local offset = checkPart.CFrame:VectorToObjectSpace(root.AssemblyLinearVelocity) / divider
				checkPart.CFrame *= CFrame.new(offset)
			end

			Debris:AddItem(checkPart, 0.75)

			-- Collect overlapping parts
			local parts = workspace:GetPartsInPart(checkPart, overlapParams)

			-- Priority sort (higher HitboxPriority first)
			table.sort(parts, function(a, b)
				local pa = a.Parent:GetAttribute("HitboxPriority") or 1
				local pb = b.Parent:GetAttribute("HitboxPriority") or 1
				return pa > pb
			end)

			local hitThisTick: {Humanoid} = {}

			for _, part in parts do
				local humanoid = part.Parent and part.Parent:FindFirstChildWhichIsA("Humanoid")
				if not humanoid then
					continue
				end

				local targetChar = humanoid.Parent :: Model
				if not canHitTarget(humanoid, targetChar, char, config, props.HumanoidsHit) then
					continue
				end

				-- Wall check only when using the attacker’s own CFrame
				if not config.CFrame then
					if not passesWallCheck(root, part, checkPart.Size.Z, rayParams) then
						continue
					end
				end

				table.insert(props.HumanoidsHit, humanoid)
				table.insert(hitThisTick, humanoid)

				if not config.HitMultiple then
					break
				end
			end

			-- Visual feedback colour
			checkPart.Color = #hitThisTick > 0 and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 0, 0)

			-- Process each valid hit
			for index, humanoid in hitThisTick do
				local isFirst = index == 1
				runCallback(config.Connections, "PreHit", config, humanoid, isFirst)

				local targetChar = humanoid.Parent :: Model
				local hRoot = Utils.Character.GetRootPart(targetChar)
				if not hRoot then
					continue
				end

				local resistance = getResistance(targetChar)
				local damage = config.Damage * (1 - resistance / 5)

				local function applyDamage()
					CommonFunctions.DamagePlayer({
						SourcePlayer = sourcePlayer,
						TargetHumanoid = humanoid,
						Damage = damage,
						Reason = config.Reason,
						KnockbackDirection = checkPart.CFrame.LookVector,
						KnockbackMagnitude = config.Knockback,
					})
				end

				-- Character-specific OnHit hook
				if targetChar:GetAttribute("CharacterName") ~= nil then
					local ok, characterModule = pcall(function()
						return require(targetChar.PlayerAbilities.CharacterAbilities).CharacterModule
					end)
					if ok and characterModule and characterModule.OnHit then
						if characterModule:OnHit(props, damage) == "Ignored" then
							continue
						end
					end
				end

				runCallback(config.Connections, "Hit", config, humanoid, isFirst)

				-- Last-hitter tracking
				local killerValue = targetChar:FindFirstChild("Killer")
				if killerValue and killerValue:IsA("ObjectValue") then
					killerValue.Value = sourcePlayer
				end

				targetChar:SetAttribute("TimesHit", (targetChar:GetAttribute("TimesHit") or 0) + 1)

				local willKill = humanoid.Health > 0 and humanoid.Health - damage <= 0
				local shouldExecute = willKill
					and char.Role.Value == "Killer"
					and config.ExecuteOnKill
					and not targetChar:GetAttribute("ExecutionsDisabled")

				if shouldExecute then
					-- Execution path (non-blocking for the rest of the hitbox)
					task.defer(function()
						local module = require(Utils.Instance.GetCharacterModule(
							char.Role.Value,
							char:GetAttribute("CharacterName"),
							char:GetAttribute("CharacterSkinName")
						))

						local killedSurvivor = {
							Name = targetChar:GetAttribute("CharacterName"),
							Skin = targetChar:GetAttribute("CharacterSkinName"),
						}

						-- Kill voiceline
						if module.Config.Voicelines and module.Config.Voicelines.Kill then
							local voiceline = (killedSurvivor.Skin and module.Config.Voicelines.Kill[killedSurvivor.Skin .. killedSurvivor.Name])
								or module.Config.Voicelines.Kill[killedSurvivor.Name]
								or module.Config.Voicelines.Kill["Default"]
							if voiceline then
								Sounds.PlayVoiceline(char, voiceline)
							end
						end

						local execKey = config.ExecutionAnimation or "Execution"
						local executionAnims = module.Config.AnimationIDs and module.Config.AnimationIDs[execKey]
						if not executionAnims then
							applyDamage()
							return
						end

						-- Mark both parties as executing
						char:SetAttribute("Executing", true)
						char:SetAttribute("Invincible", true)
						targetChar:SetAttribute("Executing", true)

						-- Rewards / stats (same as a normal kill while in chase)
						task.spawn(function()
							local targetPlayer = Players:GetPlayerFromCharacter(targetChar)
							if not targetPlayer then
								return
							end
							Network:FireClientConnection(sourcePlayer, "KilledPlayer", "REMOTE_EVENT", targetPlayer)
							Network:FireConnection("KilledPlayer", sourcePlayer, targetPlayer)
							CommonFunctions.UpdatePlayerStat(sourcePlayer, "KillerStats.Kills", 1)
							CommonFunctions.GrantRewardToPlayer(sourcePlayer, {
								Money = 20,
								EXP = 60,
								Reason = "killing a Survivor",
							})
							TimeManager.SetTime(TimeManager.CurrentTime + 35)
						end)

						local executionAnim = (killedSurvivor.Skin and executionAnims[killedSurvivor.Skin .. killedSurvivor.Name])
							or executionAnims[killedSurvivor.Name]
							or executionAnims["Default"]

						if not executionAnim then
							applyDamage()
							return
						end

						local runtimeModule = require(char.PlayerAbilities.CharacterAbilities).CharacterModule
						local killerExecCache = runtimeModule.GameplayConfig.Cache.Animations[execKey]
						local killerAnim = ((killedSurvivor.Skin and killerExecCache[killedSurvivor.Skin .. killedSurvivor.Name])
							or killerExecCache[killedSurvivor.Name]
							or killerExecCache["Default"]).Killer

						local survivorAnim = Utils.Character.LoadAnimationFromID(targetChar, executionAnim.Survivor)

						local exSound
						if module.Config.Sounds and module.Config.Sounds.Execute then
							exSound = (killedSurvivor.Skin and module.Config.Sounds.Execute[killedSurvivor.Skin .. killedSurvivor.Name])
								or module.Config.Sounds.Execute[killedSurvivor.Name]
								or module.Config.Sounds.Execute["Default"]
						end

						-- Cleanup effects & lock positions
						if targetChar:FindFirstChild("Effects") then
							targetChar.Effects:ClearAllChildren()
						end
						root.Anchored = true
						hRoot.Anchored = true

						char:PivotTo(CFrame.new(root.Position, Vector3.new(hRoot.Position.X, root.Position.Y, hRoot.Position.Z)))
						targetChar:PivotTo(
							root.CFrame
								* (module.Config.ExecutionSurvivorCFrameOffset or CFrame.new(0, 0, -3))
								* CFrame.fromEulerAnglesXYZ(0, math.rad(180), 0)
						)

						task.delay(killerAnim.Length, function()
							if char then
								char:SetAttribute("Invincible", false)
								char:SetAttribute("Executing", false)
							end
							if root then
								root.Anchored = false
							end
							if hRoot then
								hRoot.Anchored = false
							end
							if humanoid then
								humanoid.Health = 0
							end
						end)

						killerAnim:Play(0)
						survivorAnim:Play(0)
						if exSound then
							Sounds.PlaySound(exSound, { Parent = root })
						end

						if runtimeModule.OnExecution then
							runtimeModule:OnExecution(targetChar, execKey)
						end
					end)
				else
					-- Normal damage path
					applyDamage()
				end

				-- Status effects
				if config.EffectsToApply then
					for _, effect in config.EffectsToApply do
						CommonFunctions.ApplyEffect({
							TargetHumanoid = humanoid,
							EffectSettings = {
								Name = effect.Name,
								Level = effect.Level,
								Duration = effect.Duration,
								Subfolder = effect.Subfolder,
							},
							OverwriteExistingEffect = effect.OverwriteExisting,
						})
					end
				end

				runCallback(config.Connections, "PostHit", config, humanoid, isFirst)
			end

			props.TimePast += task.wait(1 / 40)
		end

		runCallback(config.Connections, "Ended")
	end)

	return props
end

function Hitbox._RunCallback(connList: {[string]: any}?, id: string, ...)
	runCallback(connList, id, ...)
end

return Hitbox