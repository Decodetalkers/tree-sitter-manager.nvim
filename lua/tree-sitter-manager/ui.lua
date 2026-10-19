local config = require("tree-sitter-manager.config")
local util = require("tree-sitter-manager.util")
local installer = require("tree-sitter-manager.installer")
local backport = require("tree-sitter-manager.backport")
local ns = vim.api.nvim_create_namespace("tree-sitter-manager.spinner")

local title_asci = " Tree-sitter Parser Manager "
local title_nerd = " 🌳 Tree-sitter Parser Manager "
local title

local status_asci = { "OK", "!!", "..", "  " }
local status_nerd = { "✅", "⚠️", "❌", "  " }
---@type fun(id:integer) -> string
local get_status_icon
local icon_col

local footer = " [i] Install  [x] Remove  [u] Update  [r] Refresh  [f] Filter  [q] Close "

local filter_type = {
    --            ok    warn  miss  installing
    util.getter({ true, true, true, true }), --    all
    util.getter({ true, true, false, true }), --   installed
    util.getter({ false, true, false, true }), --  warning
    util.getter({ false, false, true, false }), -- missing
}
---@type integer
local filter_idx

local frames = { "⣾ ", "⣽ ", "⣻ ", "⢿ ", "⡿ ", "⣟ ", "⣯ ", "⣷ " }
local frame_idx

---@class UiStatus
---@field buf integer|nil
---@field win integer|nil
---@field langs string[]
---@field formatter string
---@field spinner uv.uv_timer_t|nil
---@field content_width integer
local UiStatus =  {
    buf = nil,
    win = nil,
    langs = {},
    formatter = "",
    spinner = nil,
    content_width = 0
};

local M = {}

function M.setup()
    title = config.cfg.nerdfont and title_nerd or title_asci
    get_status_icon = util.getter(config.cfg.nerdfont and status_nerd or status_asci)
    local langwidth = vim.iter(config.languages):map(string.len):fold(0, math.max)
    UiStatus.formatter = "   %-" .. langwidth .. "s  %s%s"
    icon_col = 3 + langwidth + 2
end

---@param lang string
local function get_status(lang)
    if installer.installing[lang] then
        return 4 -- installing
    elseif util.not_installed(lang) then
        return 3 -- missing
    elseif vim.list_contains(config.cfg.assume_installed, lang) then
        return 1 -- ok
    elseif vim.iter(util.get_requires(lang)):all(util.is_installed) then
        return 1 -- ok
    else
        return 2 -- warning
    end
end

local function get_meta_suffix(lang)
    local info = util.get_repo_info(lang)
    local parts = {}
    if info and info.revision then
        local rev = #info.revision == 40 and string.sub(info.revision, 1, 7) or info.revision
        table.insert(parts, string.format("%-7s", rev))
    end
    local reqs = util.get_requires(lang)
    if #reqs > 0 then
        vim.list_extend(parts, { "requires:", unpack(reqs) })
    end
    return #parts > 0 and "  " .. table.concat(parts, " ") or ""
end

local function get_langs_filtered()
    return vim.iter(config.languages)
        :filter(function(lang)
            return filter_type[filter_idx](get_status(lang))
        end)
        :totable()
end

local function cycle_filter()
    local new_langs
    for idx = 1, 4 do
        filter_idx = (filter_idx % 4) + 1
        new_langs = get_langs_filtered()
        if #new_langs > 0 and not vim.deep_equal(UiStatus.langs, new_langs) then
            break
        end
    end
    UiStatus.langs = new_langs
    M.render()
end

local function render_spinner()
    if not UiStatus.buf or not vim.api.nvim_buf_is_valid(UiStatus.buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(UiStatus.buf, ns, 0, -1)
    for row, lang in ipairs(UiStatus.langs) do
        if installer.installing[lang] then
            vim.api.nvim_buf_set_extmark(UiStatus.buf, ns, row - 1, icon_col, {
                virt_text = { { frames[frame_idx], "Special" } },
                virt_text_pos = "overlay",
            })
        end
    end
end

local act = vim.defaulttable(function(action)
    return function()
        local r, _ = unpack(vim.api.nvim_win_get_cursor(UiStatus.win))
        local lang = UiStatus.langs[r]
        if lang then
            installer[action](lang, M.render)
            M.render(true)
        end
    end
end)

---@param out? boolean | Status
---@return boolean
function M.render(out)
    if not UiStatus.buf or not vim.api.nvim_buf_is_valid(UiStatus.buf) then
        return false
    elseif out then -- update langs on callback
        table.sort(vim.list.unique(vim.list_extend(UiStatus.langs, get_langs_filtered())))
    end

    local status = vim.iter(UiStatus.langs):map(get_status):map(get_status_icon)
    local meta = vim.iter(UiStatus.langs):map(get_meta_suffix)
    local lines = vim.iter(UiStatus.langs)
        :map(function(lang)
            return UiStatus.formatter:format(lang, status:next(), meta:next())
        end)
        :totable()

    vim.bo[UiStatus.buf].modifiable = true
    vim.api.nvim_buf_set_lines(UiStatus.buf, 0, -1, false, lines)
    vim.bo[UiStatus.buf].modifiable = false
    render_spinner()

    UiStatus.content_width = vim.iter(lines):map(string.len):fold(0, math.max)
    return true
end

local function close()
    UiStatus.spinner:stop()
    vim.api.nvim_win_close(UiStatus.win, true)
end

---@return number|nil
---@return number|nil
---@return number
---@return number
local function get_dims()
    local w = math.max(config.cfg.min_width, #footer + 4, UiStatus.content_width + 3)
    local h = math.max(config.cfg.min_height, vim.o.lines - 15)
    local r = math.floor((vim.o.lines - h) / 2 - 1)
    local c = math.floor((vim.o.columns - w) / 2 - 1)

    return w, h, r, c
end

local function resize()
    if not UiStatus.win or not vim.api.nvim_win_is_valid(UiStatus.win) then
        return
    end

    local w, h, r, c = get_dims()
    vim.api.nvim_win_set_config(UiStatus.win, {
        relative = "editor",
        width = w,
        height = h,
        row = r,
        col = c,
    })
end

function M.open()
    UiStatus.langs = config.languages
    filter_idx = 1
    frame_idx = 1

    if not UiStatus.buf or not vim.api.nvim_buf_is_valid(UiStatus.buf) then
        UiStatus.buf = vim.api.nvim_create_buf(false, true)
        local opts = { buf = UiStatus.buf, noremap = true, silent = true }
        vim.keymap.set("n", "q", close, opts)
        vim.keymap.set("n", "<Esc>", close, opts)
        vim.keymap.set("n", "r", M.open, opts)
        vim.keymap.set("n", "i", act.install, opts)
        vim.keymap.set("n", "x", act.remove, opts)
        vim.keymap.set("n", "u", act.update, opts)
        vim.keymap.set("n", "f", cycle_filter, opts)

        vim.api.nvim_create_autocmd("VimResized", {
            group = vim.api.nvim_create_augroup("tree-sitter-manager.ui", {}),
            callback = resize,
        })
    end

    M.render()

    if not UiStatus.win or not vim.api.nvim_win_is_valid(UiStatus.win) then
        local w, h, r, c = get_dims()
        UiStatus.win = vim.api.nvim_open_win(UiStatus.buf, true, {
            relative = "editor",
            width = w,
            height = h,
            style = "minimal",
            border = config.cfg.border,
            row = r,
            col = c,
            title = title,
            title_pos = "center",
            footer = footer,
            footer_pos = "center",
        })
    end

    if not UiStatus.spinner then
        UiStatus.spinner = vim.uv.new_timer()
    end

    UiStatus.spinner:start(
        0,
        80,
        vim.schedule_wrap(function()
            frame_idx = (frame_idx % #frames) + 1
            render_spinner()
        end)
    )
end

-- Backward compatibility
backport.open = M.open
function backport._act(action)
    act[action]()
end

return M
