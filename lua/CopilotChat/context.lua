local log = require('plenary.log')

local M = {}

-- https://github.com/Aider-AI/aider/tree/0022c1a67e2b1bef61ccac61fb6fdea8a834e4b9/aider/queries
local queries = {
  ruby = vim.treesitter.query.parse("ruby", [[
    (module
      name: (constant) @name.definition.module) @definition.module

    (
      [
        (class
          name: (constant) @name.definition.class) @definition.class
        (singleton_class
          value: (constant) @name.definition.class) @definition.class
      ]
    )

    (
      [
        (method
          name: (_) @name.definition.method) @definition.method
        (singleton_method
          name: (_) @name.definition.method) @definition.method
      ]
    )
  ]]),
}

local function spatial_distance_cosine(a, b)
  local dot_product = 0
  local magnitude_a = 0
  local magnitude_b = 0
  for i = 1, #a do
    dot_product = dot_product + a[i] * b[i]
    magnitude_a = magnitude_a + a[i] * a[i]
    magnitude_b = magnitude_b + b[i] * b[i]
  end
  magnitude_a = math.sqrt(magnitude_a)
  magnitude_b = math.sqrt(magnitude_b)
  return dot_product / (magnitude_a * magnitude_b)
end

local function data_ranked_by_relatedness(query, data, top_n)
  local scores = {}
  for i, item in pairs(data) do
    scores[i] = { index = i, score = spatial_distance_cosine(item.embedding, query.embedding) }
  end
  table.sort(scores, function(a, b)
    return a.score > b.score
  end)
  local result = {}
  for i = 1, math.min(top_n, #scores) do
    local srt = scores[i]
    table.insert(result, vim.tbl_extend('keep', data[srt.index], { score = srt.score }))
  end
  return result
end

--- Build an outline for a buffer
--- Follows the example of https://github.com/Aider-AI/aider/blob/0022c1a67e2b1bef61ccac61fb6fdea8a834e4b9/tests/fixtures/sample-code-base-repo-map.txt
---@param bufnr number
---@return CopilotChat.copilot.embed?
function M.build_outline(bufnr)
  local lang = vim.treesitter.language.get_lang(ft)
  local ok, parser = false, nil
  if lang then
    ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  end
  if not ok or not parser then
    local ft = vim.bo[bufnr].filetype
    ft = string.gsub(ft, 'react', '')
    ok, parser = pcall(vim.treesitter.get_parser, bufnr, ft)
    if not ok or not parser then
      return
    end
  end

  local root = parser:parse()[1]:root()
  local query = queries[lang]

  if query == nil then
    return
  end

  local sourcemap = {}
  local previous_start_row = -1

  for id, node, metadata in query:iter_captures(root, bufnr, 0, -1) do
    local name = query.captures[id]
    if name == "definition.module" or name == "definition.class" or name == "definition.method" then
      local start_row, _, end_row, _ = node:range()
      local line_text = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]

      if previous_start_row + 1 ~= start_row then
        -- TODO: This isn't perfect, as it doesn't take whitespace into account
        table.insert(sourcemap, "⋮...")
      end

      line_text = "│" .. line_text
      table.insert(sourcemap, line_text)

      previous_start_row = start_row
    end
  end

  if #sourcemap == 0 then
    return
  end

  if previous_start_row ~= vim.api.nvim_buf_line_count(bufnr) - 1 then
    table.insert(sourcemap, "⋮...")
  end

  return table.concat(sourcemap, '\n')
end

---@class CopilotChat.context.find_for_query.opts
---@field context string?
---@field prompt string
---@field selection string?
---@field filename string
---@field filetype string
---@field bufnr number
---@field on_done function
---@field on_error function?

--- Find items for a query
---@param copilot CopilotChat.Copilot
---@param opts CopilotChat.context.find_for_query.opts
function M.find_for_query(copilot, opts)
  local context = opts.context
  local prompt = opts.prompt
  local selection = opts.selection
  local filename = opts.filename
  local filetype = opts.filetype
  local active_bufnr = opts.bufnr
  local on_done = opts.on_done
  local on_error = opts.on_error

  local context_files = {}
  local function add_context(bufnr)
    local content = nil

    if bufnr == active_bufnr then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      content = table.concat(lines, '\n')
    else
      content = M.build_outline(bufnr)
    end

    if not content then
      return
    end

    table.insert(context_files, {
      content = content,
      filename = vim.api.nvim_buf_get_name(bufnr),
      filetype = vim.api.nvim_buf_get_option(bufnr, 'filetype'),
    })
  end

  if context == 'buffers' then
    context_files = vim.tbl_map(
      add_context,
      vim.tbl_filter(function(b)
        return vim.api.nvim_buf_is_loaded(b) and vim.fn.buflisted(b) == 1
      end, vim.api.nvim_list_bufs())
    )
  elseif context == 'buffer' then
    add_context(active_bufnr)
  end

  if #context_files == 0 then
    on_done({})
    return
  end

  copilot:embed(context_files, {
    on_error = on_error,
    on_done = function(out)
      out = vim.tbl_filter(function(item)
        return item ~= nil
      end, out)
      if #out == 0 then
        on_done({})
        return
      end

      log.debug(string.format('Got %s embeddings', #out))
      copilot:embed({
        {
          prompt = prompt,
          content = selection,
          filename = filename,
          filetype = filetype,
        },
      }, {
        on_error = on_error,
        on_done = function(query_out)
          local query = query_out[1]
          if not query then
            on_done({})
            return
          end
          log.debug('Prompt:', query.prompt)
          log.debug('Content:', query.content)
          local data = data_ranked_by_relatedness(query, out, 20)
          log.debug('Ranked data:', #data)
          for i, item in ipairs(data) do
            log.debug(string.format('%s: %s - %s', i, item.score, item.filename))
          end
          on_done(data)
        end,
      })
    end,
  })
end

return M
