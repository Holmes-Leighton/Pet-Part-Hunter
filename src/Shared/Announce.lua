--!strict
-- Wording for purchase announcements (spec section 7): the chat line and the notification text. Pure functions so the
-- text is tested; the server decides when to announce and the client shows it. Player names reach other players'
-- screens inside rich text, so they are escaped here: a name can never inject markup into the chat.

local Announce = {}

-- Escapes the characters rich text treats as markup.
function Announce.escape(text: string): string
	local out = string.gsub(text, "&", "&amp;")
	out = string.gsub(out, "<", "&lt;")
	out = string.gsub(out, ">", "&gt;")
	out = string.gsub(out, '"', "&quot;")
	out = string.gsub(out, "'", "&apos;")
	return out
end

-- Strips control characters and caps the length, so a long or odd name cannot flood the chat or the toast.
function Announce.cleanName(name: string): string
	local cleaned = string.gsub(name, "[%c]", "")
	if #cleaned > 24 then
		cleaned = string.sub(cleaned, 1, 24)
	end
	if cleaned == "" then
		return "Someone"
	end
	return cleaned
end

-- The chat line, in rich text. `what` is our own item name (never player text).
function Announce.chatLine(name: string, what: string, isSelf: boolean): string
	local who = if isSelf then "You" else Announce.escape(Announce.cleanName(name))
	local verb = if isSelf then "bought" else "just bought"
	return string.format('<font color="#FFD34D"><b>[SHOP]</b></font> <b>%s</b> %s <font color="#7CFF8A"><b>%s</b></font>!', who, verb, Announce.escape(what))
end

-- The plain-text version, for the legacy chat and the notification.
function Announce.plain(name: string, what: string, isSelf: boolean): string
	local who = if isSelf then "You" else Announce.cleanName(name)
	return string.format("%s %s %s!", who, if isSelf then "bought" else "just bought", what)
end

return Announce
