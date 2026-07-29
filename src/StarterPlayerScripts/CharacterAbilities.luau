local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Janitor = require(ReplicatedStorage.Packages.Janitor)

local CharacterAbilities = {
    CharacterModule = {},
    Abilities = {},
    Animations = {},
}

function CharacterAbilities:Init()
    local janitorInstance = Janitor.new()
    janitorInstance:LinkToInstance(Players.LocalPlayer.Character)
    janitorInstance:Add(function()
        table.clear(CharacterAbilities.Abilities)
        table.clear(CharacterAbilities.Animations)
        CharacterAbilities.CharacterModule = {}
    end, true)
end

return CharacterAbilities
