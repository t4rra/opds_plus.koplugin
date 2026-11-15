-- Live progress dialog for downloads: current book, MB so far, books left in the batch.
-- With no known total size the byte count is shown as text, not a bar.
-- Tapping cancels when used as a trap widget (Trapper installs dismiss_callback itself).
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local DownloadProgressDialog = InputContainer:extend{
	modal = true,
	dismissable = true,
	title = nil,
	align = "center",
	vertical_align = "center",
}

local function statusText(bytes, index, total)
	local mb = string.format("%.1f", math.max(bytes or 0, 0) / 1048576)
	local size = T(_("%1 MB"), mb)
	if index and total and total > 1 then
		return T(_("%1 · book %2 of %3 · %4 left"), size, index, total, total - index)
	end
	return size
end

function DownloadProgressDialog:init()
	self.dimen = Screen:getSize()

	if self.dismissable then
		if Device:hasKeys() then
			self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
		end
		if Device:isTouchDevice() then
			self.ges_events.TapClose = {
				GestureRange:new{
					ges = "tap",
					range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
				}
			}
		end
	end

	local width = Screen:getWidth() - Screen:scaleBySize(80)
	self.title_widget = TextWidget:new {
		text = self.title or _("Downloading…"),
		face = Font:getFace("ffont"),
		bold = true,
		max_width = width,
	}
	self.subtitle_widget = TextWidget:new {
		text = "",
		face = Font:getFace("smallffont"),
		max_width = width,
	}

	self[1] = FrameContainer:new {
		radius = Size.radius.window,
		bordersize = Size.border.window,
		padding = Size.padding.large,
		background = Blitbuffer.COLOR_WHITE,
		VerticalGroup:new {
			self.title_widget,
			self.subtitle_widget,
		},
	}
end

-- redraw at most once per second, only the window itself
function DownloadProgressDialog:repaint()
	local now = os.time()
	if now == self.last_refresh then return end
	self.last_refresh = now
	UIManager:setDirty(self, function() return "fast", self[1].dimen end)
	UIManager:forceRePaint()
end

-- show a different book; the byte counter restarts from zero
function DownloadProgressDialog:setBook(title, index, total)
	if self.book == title and self.index == index and self.total == total then return end
	self.book, self.index, self.total = title, index, total
	self.title_widget:setText(title or _("Downloading…"))
	self:reportBytes(0)
end

function DownloadProgressDialog:reportBytes(bytes)
	self.subtitle_widget:setText(statusText(bytes, self.index, self.total))
	self:repaint()
end

-- without a dismiss_callback (plain display) there is nothing to cancel; swallow the tap
function DownloadProgressDialog:onDismiss()
	if self.dismiss_callback then self.dismiss_callback() end
	return true
end

DownloadProgressDialog.onTapClose = DownloadProgressDialog.onDismiss
DownloadProgressDialog.onAnyKeyPressed = DownloadProgressDialog.onDismiss

return DownloadProgressDialog
