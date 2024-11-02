local M = {}

function M.load(tokenizer, on_done)
  on_done()
end

function M.available()
  return false
end

function M.encode(prompt)
  return nil
end

function M.count(prompt)
  return 0
end

return M
