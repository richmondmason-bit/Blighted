local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Utils = require(ReplicatedStorage.Modules.Utils)

return {
    Init = function(_)
        Utils.Character.ObserveCharacter(Players.LocalPlayer, function(Char)
            local Server = Char:FindFirstChild("Server")

            local AnimationManager = Char:FindFirstChild("AnimationManager")
            local animOk, animResult = pcall(require, AnimationManager)
            if not animOk then
                return
            end
            animResult:Init()

            for _, Module in Char:GetDescendants() do
            	if not Module:IsA("ModuleScript") or Module == AnimationManager or Module:IsDescendantOf(Server) then
            		continue
            	end

            	debug.setmemorycategory(Module.Name)
            	local ok, Scr = pcall(require, Module)
            	if ok and type(Scr) == "table" and Scr["Init"] and type(Scr["Init"]) == "function" then
            		Scr:Init()
            	end
            end

            debug.setmemorycategory("Default")
        end)
    end,
}