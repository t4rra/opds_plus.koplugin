-- Live progress dialog for downloads
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen
local UIUtils = require("ui.utils")
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
		return T(_("%1 · book %2 of %3"), size, index, total)
	end
	return size
end

local function titleText(title)
	return title or _("Downloading…")
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
	self.text_max_width = width
	local big_face = Font:getFace("ffont")
	local small_face = Font:getFace("smallffont")
	self.small_face = small_face
	self.big_face = big_face
	-- Fixed-width lines
	-- TextBoxWidget does not clip, so truncate by hand
	self.stats_widget = TextBoxWidget:new {
		text = statusText(0, nil, nil),
		face = big_face,
		bold = true,
		width = width,
		alignment = "center",
	}
	self.title_widget = TextBoxWidget:new {
		text = UIUtils.truncateText(titleText(self.title), small_face, width),
		face = small_face,
		alignment = "center",
		width = width,
	}

	self[1] = FrameContainer:new {
		radius = Size.radius.window,
		bordersize = Size.border.window,
		padding = Size.padding.large,
		background = Blitbuffer.COLOR_WHITE,
		VerticalGroup:new {
			align = "center",
			self.stats_widget,
			self.title_widget,
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

-- nothing repaints what is underneath when this window closes; force it or the frame border lingers on e-ink
function DownloadProgressDialog:onCloseWidget()
	UIManager:setDirty(nil, "ui")
end

-- show a different book; the byte counter restarts from zero
function DownloadProgressDialog:setBook(title, index, total)
	if self.book == title and self.index == index and self.total == total then return end
	self.book, self.index, self.total = title, index, total
	self.title_widget:setText(UIUtils.truncateText(titleText(title), self.small_face, self.text_max_width))
	self:reportBytes(0)
end

function DownloadProgressDialog:reportBytes(bytes)
	self.stats_widget:setText(UIUtils.truncateText(statusText(bytes, self.index, self.total), self.big_face, self.text_max_width))
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
