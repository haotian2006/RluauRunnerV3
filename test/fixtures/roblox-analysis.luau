--!strict
local part = Instance.new("Part")
part.Size = Vector3.new(1, 2, 3)
part.Anchored = true
game:GetService("RunService").Heartbeat:Connect(function(dt: number)
    print(dt, CFrame.new(), Enum.Material.Plastic)
end)
part.Size = "wrong"
part.FakeProperty = true
