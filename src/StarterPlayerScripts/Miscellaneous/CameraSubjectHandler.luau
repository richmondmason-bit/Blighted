local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

return {
	Init = function(_)
		local function onCharacterAdded(char: Model)
			local humanoid = char:FindFirstChildWhichIsA("Humanoid")
			if not humanoid then
				humanoid = char:WaitForChild("Humanoid", 10)
			end
			if humanoid then
				workspace.CurrentCamera.CameraSubject = humanoid
			end
		end

		LocalPlayer.CharacterAdded:Connect(onCharacterAdded)
		if LocalPlayer.Character then
			onCharacterAdded(LocalPlayer.Character)
		end
	end,
}
