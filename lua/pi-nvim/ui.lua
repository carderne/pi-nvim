local M = {}

--- Capture visual selection info before it's lost.
--- @return table|nil
function M.capture_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] == 0 and end_pos[2] == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = vim.fn.visualmode() })
  if not ok or not lines or #lines == 0 then
    return nil
  end

  local text = table.concat(lines, "\n")
  if text == "" then return nil end

  return {
    text = text,
    file = vim.fn.expand("%:."),
    start_line = start_pos[2],
    end_line = end_pos[2],
    ft = vim.bo.filetype,
  }
end

--- Open the Pi send dialog as two floating windows.
--- @param opts { selection: table|nil }|nil
function M.open(opts)
  opts = opts or {}
  local pi = require("pi-nvim")
  local selection = opts.selection
  local file = vim.fn.expand("%:p")
  local rel_file = vim.fn.expand("%:.")
  local ft = vim.bo.filetype
  local send_buffer = false
  local source_buf = vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)

  -- Build info lines
  local file_info = "File: " .. (rel_file ~= "" and rel_file or "(no file)")
  local context_info
  if selection then
    local n = select(2, selection.text:gsub("\n", "")) + 1
    context_info = string.format("Selection: %d lines (%d-%d)", n, selection.start_line, selection.end_line)
  else
    context_info = "Send buffer: [ ] (Tab to toggle)"
  end

  -- Layout
  local width = math.min(72, math.floor(vim.o.columns * 0.5))
  local info_height = 2
  local input_height = 3
  local gap = 0 -- no gap between bubbles
  local total_height = info_height + 2 + gap + input_height + 2 -- +2 each for borders
  local top_row = math.floor((vim.o.lines - total_height) / 2)
  local col = math.floor((vim.o.columns - width - 2) / 2)

  -- Accent highlights
  local accent_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local accent_fg = accent_hl.fg
  vim.api.nvim_set_hl(0, "PiNvimBorder", { fg = accent_fg, bg = normal_hl.bg })
  vim.api.nvim_set_hl(0, "PiNvimTitle", { fg = accent_fg, bg = normal_hl.bg })


  -- Top bubble: info
  local info_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[info_buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, {
    " " .. file_info,
    " " .. context_info,
  })
  vim.bo[info_buf].modifiable = false

  local info_win = vim.api.nvim_open_win(info_buf, false, {
    relative = "editor",
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " pi ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
    focusable = false,
  })
  vim.wo[info_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"
  vim.wo[info_win].cursorline = false

  -- Bottom bubble: prompt input
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = "nofile"
  vim.bo[input_buf].filetype = "pi-nvim-prompt"
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

  local input_row = top_row + info_height + 2 + gap -- +2 for info border
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = input_height,
    row = input_row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " prompt ",
    title_pos = "center",
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[input_win].winhl = "NormalFloat:Normal,FloatBorder:PiNvimBorder,FloatTitle:PiNvimTitle"

  -- Highlight the visual selection in the source buffer while the dialog is open
  local sel_ns = nil
  if selection and vim.api.nvim_buf_is_valid(source_buf) then
    sel_ns = vim.api.nvim_create_namespace("pi_nvim_selection")
    for lnum = selection.start_line, selection.end_line do
      vim.api.nvim_buf_add_highlight(source_buf, sel_ns, "Visual", lnum - 1, 0, -1)
    end
  end

  -- Start in insert mode
  vim.cmd("noautocmd startinsert!")

  local closed = false

  local function close()
    if closed then return end
    closed = true
    vim.cmd("noautocmd stopinsert")
    -- Remove selection highlight from source buffer
    if sel_ns and vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_clear_namespace(source_buf, sel_ns, 0, -1)
    end
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, info_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, info_buf, { force = true })
  end

  local function update_context()
    if selection then return end
    local marker = send_buffer and "[x]" or "[ ]"
    local line = " Send buffer: " .. marker .. " (Tab to toggle)"
    vim.bo[info_buf].modifiable = true
    vim.api.nvim_buf_set_lines(info_buf, 1, 2, false, { line })
    vim.bo[info_buf].modifiable = false
  end

  local function send()
    local prompt_text = vim.fn.trim(vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or "")
    close()

    local message
    if selection then
      local header = string.format("%s lines %d-%d", selection.file, selection.start_line, selection.end_line)
      if prompt_text == "" then
        message = string.format("Look at this code from %s:\n\n```%s\n%s\n```", header, selection.ft, selection.text)
      else
        message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", prompt_text, header, selection.ft, selection.text)
      end
    elseif send_buffer and rel_file ~= "" then
      local content = table.concat(buf_lines, "\n")
      if prompt_text == "" then
        message = string.format("Look at this file %s:\n\n```%s\n%s\n```", rel_file, ft, content)
      else
        message = string.format("%s\n\nFile: %s\n```%s\n%s\n```", prompt_text, rel_file, ft, content)
      end
    elseif file ~= "" then
      if prompt_text == "" then
        message = string.format("Look at this file: %s", file)
      else
        message = string.format("File: %s\n\n%s", file, prompt_text)
      end
    else
      if prompt_text == "" then
        vim.notify("Nothing to send", vim.log.levels.WARN)
        return
      end
      message = prompt_text
    end

    pi.prompt(message)
  end

  local kopts = { buffer = input_buf, noremap = true, silent = true }

  vim.keymap.set("i", "<CR>", send, kopts)
  vim.keymap.set("n", "<CR>", send, kopts)
  vim.keymap.set({ "i", "n" }, "<Esc>", close, kopts)
  vim.keymap.set({ "i", "n" }, "<C-c>", close, kopts)
  vim.keymap.set({ "i", "n" }, "<Tab>", function()
    if not selection then
      send_buffer = not send_buffer
      update_context()
    end
  end, kopts)

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = input_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
