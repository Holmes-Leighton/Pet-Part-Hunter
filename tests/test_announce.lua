--!strict
local Test = require("./harness")
local Announce = require("../src/Shared/Announce")
local Config = require("../src/Shared/Config")

Test.case("rich text markup characters are escaped", function()
	Test.eq(Announce.escape('<b>"hi" & \'bye\'</b>'), "&lt;b&gt;&quot;hi&quot; &amp; &apos;bye&apos;&lt;/b&gt;")
	Test.eq(Announce.escape("plain"), "plain")
end)

Test.case("a hostile player name cannot inject markup into the chat line", function()
	local line = Announce.chatLine('<font size="999">BOO</font>', "the Mythic Area Pass", false)
	Test.truthy(not string.find(line, "BOO</font>", 1, true), "raw tags must not survive")
	Test.truthy(string.find(line, "&lt;font", 1, true) ~= nil, "escaped instead")
	Test.truthy(string.find(line, "the Mythic Area Pass", 1, true) ~= nil)
end)

Test.case("names are trimmed, stripped of control characters, and never empty", function()
	Test.eq(Announce.cleanName("Bob"), "Bob")
	Test.eq(Announce.cleanName("a\nb\tc"), "abc")
	Test.eq(#Announce.cleanName(string.rep("x", 100)), 24)
	Test.eq(Announce.cleanName(""), "Someone")
	Test.eq(Announce.cleanName("\n\n"), "Someone")
end)

Test.case("others see 'X just bought Y!', the buyer sees 'You bought Y!'", function()
	Test.eq(Announce.plain("Ana", "a Coin Pack", false), "Ana just bought a Coin Pack!")
	Test.eq(Announce.plain("Ana", "a Coin Pack", true), "You bought a Coin Pack!")
	Test.truthy(string.find(Announce.chatLine("Ana", "a Coin Pack", true), "<b>You</b> bought", 1, true) ~= nil)
	Test.truthy(string.find(Announce.chatLine("Ana", "a Coin Pack", false), "<b>Ana</b> just bought", 1, true) ~= nil)
end)

Test.case("every pass has a display name, and announcements are rate limited by config", function()
	for key in Config.Passes do
		Test.truthy((Config.PassNames :: any)[key] ~= nil, key .. " needs a PassNames entry")
	end
	Test.truthy(Config.Announce.PerSecond > 0 and Config.Announce.Burst >= 1)
	Test.truthy(Config.Announce.MaxToasts >= 1)
end)

Test.done()
