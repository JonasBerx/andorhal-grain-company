-- GuildSyncNoticeBoard: the board's own template and atlas check (spec noticeboard/two-column.md). Same shape as
-- GuildSync's Kit.lua, but over this module's M.Compat.call, never GuildSync's internals. A client without a template
-- or an atlas gets a fallback template, a plain frame, a file or a colour instead, never an error.
-- The only board file that sets an atlas.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local Look = {}
ns.Look = Look

local function call(dotted, ...) return M.Compat.call(dotted, ...) end
local function hasMethod(obj, name) return type(obj) == "table" and type(obj[name]) == "function" end

-- True when the client has this frame template.
function Look.HasTemplate(name)
  if type(name) ~= "string" then return false end
  return type(call("C_XMLUtil.GetTemplateInfo", name)) == "table"
end

-- The atlas when the client has it, else the fallback: { r, g, b, a } (a colour), a file, or nil (the texture hides).
-- True only when the atlas was set.
function Look.Atlas(tex, name, fallback)
  if type(tex) ~= "table" then return false end
  if hasMethod(tex, "SetAtlas") and type(name) == "string"
    and type(call("C_Texture.GetAtlasInfo", name)) == "table" and pcall(tex.SetAtlas, tex, name) then
    tex:Show()
    return true
  end
  if type(fallback) == "table" then
    if hasMethod(tex, "SetColorTexture") then
      pcall(tex.SetColorTexture, tex, fallback[1], fallback[2], fallback[3], fallback[4])
      tex:Show()
    end
  elseif fallback ~= nil and hasMethod(tex, "SetTexture") and pcall(tex.SetTexture, tex, fallback) then
    tex:SetTexCoord(0, 1, 0, 1)
    tex:Show()
  elseif hasMethod(tex, "Hide") then
    tex:Hide()
  end
  return false
end

-- A frame on the template when the client knows it, else on the fallback template, else plain. -> frame, used|nil
function Look.Frame(kind, parent, template, fallbackTemplate)
  for _, t in ipairs({ template, fallbackTemplate }) do
    if Look.HasTemplate(t) then
      local good, f = pcall(CreateFrame, kind, nil, parent, t)
      if good and f then return f, t end
    end
  end
  return CreateFrame(kind, nil, parent), nil
end

-- The board's one rule for a push button (Page, PageBoard, PageWhen, PageCreate, PageDetail, Status): the template
-- when the client has it, else a plain Button with its own dark backing and font string, so SetText still shows a label.
function Look.Button(parent, label, onClick)
  local b, used = Look.Frame("Button", parent, "UIPanelButtonTemplate")
  if not used then
    if hasMethod(b, "CreateTexture") then
      local bg = b:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints(b)
      if hasMethod(bg, "SetColorTexture") then bg:SetColorTexture(0.15, 0.15, 0.15, 0.9) end
    end
    if hasMethod(b, "CreateFontString") and hasMethod(b, "SetFontString") then
      local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      fs:SetPoint("CENTER", b, "CENTER", 0, 0)
      b:SetFontString(fs)
      -- f11: a disabled button reads dimmed
      if hasMethod(b, "SetNormalFontObject") then b:SetNormalFontObject("GameFontNormalSmall") end
      if hasMethod(b, "SetDisabledFontObject") then b:SetDisabledFontObject("GameFontDisableSmall") end
    end
  end
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

-- ---------- t55 seams over the hub kit (ns.M.Kit, needs 4; plan d698-d700, d703) ----------

-- Each answer kind's kit tone (d698); a kind not listed draws grey.
local PILL_TONE = { coming = "green", tentative = "gold", notcoming = "red", unanswered = "grey", standby = "grey",
  grey = "grey", gold = "gold", green = "green", red = "red" }

-- M.Kit.Pill; pill.text is the FontString. No board fallback (d693): the kit draws its own.
function Look.Pill(parent) return M.Kit.Pill(parent) end

-- The pill's text in kind's tone; nil or "" hides the pill, a text shows it (Kit.SetPill never hides).
function Look.SetPill(pill, text, kind)
  if type(pill) ~= "table" then return end
  if text == nil or text == "" then
    pill:Hide()
    return
  end
  M.Kit.SetPill(pill, text, PILL_TONE[kind] or "grey")
  pill:Show()
end

-- M.Kit.Dropdown, else the board's own WowStyle1 dropdown when the client has the template, else nil (the caller
-- keeps its steppers). Callers wrap every radio's setSelected body in ns.M.Safe and never set a radio menu's text (d699).
function Look.Dropdown(parent, width, generate)
  local dd = M.Kit.Dropdown(parent, width, generate)
  if dd then return dd end
  -- checked first: a client without the template may lack the DropdownButton frame type too
  if not Look.HasTemplate("WowStyle1DropdownTemplate") then return nil end
  local good, own = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if not good or not own then return nil end
  own:SetSize(width, 22)
  own:SetupMenu(generate)
  return own
end

-- M.Kit.InputBox, else Look.Frame's InputBoxInstructionsTemplate / InputBoxTemplate chain at width x 20; either way
-- no autofocus and maxBytes as the cap, as 0.1 caps its boxes (d700; Kit.InputBox sets no limits).
function Look.Input(parent, width, maxBytes)
  local box = M.Kit.InputBox(parent, width, width)
  if not box then
    box = Look.Frame("EditBox", parent, "InputBoxInstructionsTemplate", "InputBoxTemplate")
    box:SetSize(width, 20)
  end
  box:SetAutoFocus(false)
  box:SetMaxBytes(maxBytes)
  return box
end

-- A vertical black shade on tex: alpha fromA at the bottom, toA at the top (for VERTICAL the first colour is the
-- bottom). Without CreateColor or SetGradient, or when SetGradient throws: a flat black at fromA. -> true when the
-- gradient was set.
function Look.Gradient(tex, fromA, toA)
  if type(tex) ~= "table" then return false end
  if hasMethod(tex, "SetGradient") then
    local bottom = call("CreateColor", 0, 0, 0, fromA)
    local top = call("CreateColor", 0, 0, 0, toA)
    -- a white base for the gradient's colours to tint (a texture with nothing set draws nothing)
    if bottom and top and pcall(tex.SetTexture, tex, "Interface\\Buttons\\WHITE8X8")
      and pcall(tex.SetGradient, tex, "VERTICAL", bottom, top) then
      tex:Show()
      return true
    end
  end
  if hasMethod(tex, "SetColorTexture") then pcall(tex.SetColorTexture, tex, 0, 0, 0, fromA) end
  return false
end
