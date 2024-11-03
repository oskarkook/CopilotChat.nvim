---@class CopilotChat.Chat
---@field bufnr number
---@field winnr number
---@field separator string
---@field spinner CopilotChat.Spinner
---@field valid fun(self: CopilotChat.Chat)
---@field visible fun(self: CopilotChat.Chat)
---@field active fun(self: CopilotChat.Chat)
---@field append fun(self: CopilotChat.Chat, str: string)
---@field last fun(self: CopilotChat.Chat)
---@field clear fun(self: CopilotChat.Chat)
---@field open fun(self: CopilotChat.Chat, config: CopilotChat.config)
---@field close fun(self: CopilotChat.Chat, bufnr: number?)
---@field focus fun(self: CopilotChat.Chat)
---@field follow fun(self: CopilotChat.Chat)
---@field finish fun(self: CopilotChat.Chat, msg: string?)
---@field delete fun(self: CopilotChat.Chat)

local Overlay = require('CopilotChat.overlay')
local Spinner = require('CopilotChat.spinner')
local utils = require('CopilotChat.utils')
local is_stable = utils.is_stable
local class = utils.class

function CopilotChatFoldExpr(lnum, separator)
  local to_match = separator .. '$'
  if string.match(vim.fn.getline(lnum), to_match) then
    return '1'
  elseif string.match(vim.fn.getline(lnum + 1), to_match) then
    return '0'
  end
  return '='
end

local Chat = class(function(self, help, auto_insert, on_buf_create)
  self.header_ns = vim.api.nvim_create_namespace('copilot-chat-headers')
  self.help = help
  self.auto_insert = auto_insert
  self.on_buf_create = on_buf_create
  self.bufnr = nil
  self.winnr = nil
  self.spinner = nil
  self.separator = nil
  self.layout = nil

  self.buf_create = function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, 'copilot-chat')
    vim.bo[bufnr].filetype = 'copilot-chat'
    vim.bo[bufnr].syntax = 'markdown'
    vim.bo[bufnr].textwidth = 0
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    if ok and parser then
      vim.treesitter.start(bufnr, 'markdown')
    end

    if not self.spinner then
      self.spinner = Spinner(bufnr)
    else
      self.spinner.bufnr = bufnr
    end

    return bufnr
  end
end, Overlay)

function Chat:visible()
  return self.winnr
    and vim.api.nvim_win_is_valid(self.winnr)
    and vim.api.nvim_win_get_buf(self.winnr) == self.bufnr
end

function Chat:render()
  if not self:visible() then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.bufnr, self.header_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  for l, line in ipairs(lines) do
    if line:match(self.separator .. '$') then
      local sep = vim.fn.strwidth(line) - vim.fn.strwidth(self.separator)
      -- separator line
      vim.api.nvim_buf_set_extmark(self.bufnr, self.header_ns, l - 1, sep, {
        virt_text_win_col = sep,
        virt_text = { { string.rep(self.separator, vim.go.columns), 'CopilotChatSeparator' } },
        priority = 100,
        strict = false,
      })
      -- header hl group
      vim.api.nvim_buf_set_extmark(self.bufnr, self.header_ns, l - 1, 0, {
        end_col = sep + 1,
        hl_group = 'CopilotChatHeader',
        priority = 100,
        strict = false,
      })
    end
  end
end

function Chat:render_history(history, config)
  -- <copied from old append function>
  self:validate()

  if self:active() then
    utils.return_to_normal_mode()
  end

  if self.spinner then
    self.spinner:start()
  end
  -- </copied from old append function>

  local lines = {}

  local question_prefix = config.question_header .. config.separator .. '\n\n'
  local answer_prefix = config.answer_header .. config.separator .. '\n\n'
  local error_prefix = config.error_header .. config.separator .. '\n\n'

  for _, entry in ipairs(history) do
    local prefix

    if entry.role == 'assistant' then
      prefix = entry.state == 'error' and error_prefix or answer_prefix
    else
      prefix = question_prefix
    end

    vim.list_extend(lines, vim.split(prefix .. entry.content .. '\n', '\n'))
  end

  local last_entry = history[#history]
  if last_entry == nil or (last_entry.role == 'assistant' and last_entry.state == 'done') then
    vim.list_extend(lines, vim.split(question_prefix, '\n'))
  elseif last_entry.role == 'user' then
    vim.list_extend(lines, vim.split(answer_prefix, '\n'))
  end

  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

  -- <copied from old append function>
  self:render()

  if config and config.auto_follow_cursor then
    self:follow()
  end
  -- </copied from old append function>
end

function Chat:active()
  return vim.api.nvim_get_current_win() == self.winnr
end

function Chat:open(config)
  self:validate()

  local window = config.window
  local layout = window.layout
  local width = window.width > 1 and window.width or math.floor(vim.o.columns * window.width)
  local height = window.height > 1 and window.height or math.floor(vim.o.lines * window.height)

  if self.layout ~= layout then
    self:close()
  end

  if self:visible() then
    return
  end

  if layout == 'float' then
    local win_opts = {
      style = 'minimal',
      width = width,
      height = height,
      zindex = window.zindex,
      relative = window.relative,
      border = window.border,
      title = window.title,
      row = window.row or math.floor((vim.o.lines - height) / 2),
      col = window.col or math.floor((vim.o.columns - width) / 2),
    }
    if not is_stable() then
      win_opts.footer = window.footer
    end
    self.winnr = vim.api.nvim_open_win(self.bufnr, false, win_opts)
  elseif layout == 'vertical' then
    local orig = vim.api.nvim_get_current_win()
    local cmd = 'vsplit'
    if width ~= 0 then
      cmd = width .. cmd
    end
    vim.cmd(cmd)
    self.winnr = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winnr, self.bufnr)
    vim.api.nvim_set_current_win(orig)
  elseif layout == 'horizontal' then
    local orig = vim.api.nvim_get_current_win()
    local cmd = 'split'
    if height ~= 0 then
      cmd = height .. cmd
    end
    vim.cmd(cmd)
    self.winnr = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winnr, self.bufnr)
    vim.api.nvim_set_current_win(orig)
  elseif layout == 'replace' then
    self.winnr = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winnr, self.bufnr)
  end

  self.layout = layout
  self.separator = config.separator

  vim.wo[self.winnr].wrap = true
  vim.wo[self.winnr].linebreak = true
  vim.wo[self.winnr].cursorline = true
  vim.wo[self.winnr].conceallevel = 2
  vim.wo[self.winnr].foldlevel = 99
  if config.show_folds then
    vim.wo[self.winnr].foldcolumn = '1'
    vim.wo[self.winnr].foldmethod = 'expr'
    vim.wo[self.winnr].foldexpr = "v:lua.CopilotChatFoldExpr(v:lnum, '" .. config.separator .. "')"
  else
    vim.wo[self.winnr].foldcolumn = '0'
  end
  self:render()
end

function Chat:close(bufnr)
  if self.spinner then
    self.spinner:finish()
  end

  if self:visible() then
    if self:active() then
      utils.return_to_normal_mode()
    end

    if self.layout == 'replace' then
      self:restore(self.winnr, bufnr)
    else
      vim.api.nvim_win_close(self.winnr, true)
    end

    self.winnr = nil
  end
end

function Chat:focus()
  if self:visible() then
    vim.api.nvim_set_current_win(self.winnr)
    if self.auto_insert and self:active() then
      vim.cmd('startinsert')
    end
  end
end

function Chat:follow()
  if not self:visible() then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  if line_count == 0 then
    return
  end

  vim.api.nvim_win_set_cursor(self.winnr, { line_count, 0 })
end

function Chat:finish(msg)
  if not self.spinner then
    return
  end

  self.spinner:finish()

  if msg and msg ~= '' then
    if self.help and self.help ~= '' then
      msg = msg .. '\n' .. self.help
    end
  else
    msg = self.help
  end

  self:show_help(msg, -2)
  if self.auto_insert and self:active() then
    vim.cmd('startinsert')
  end
end

return Chat
