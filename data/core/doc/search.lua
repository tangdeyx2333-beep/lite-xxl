local search = {}

local default_opt = {}

local function largefile_search_trace(doc, fmt, ...)
  if not doc or not doc.is_large_file then
    return
  end
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then text = tostring(fmt) end
  local fp = io.open(USERDIR .. PATHSEP .. "largefile-search.log", "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    fp:close()
  end
end


local function pattern_lower(str)
  if str:sub(1, 1) == "%" then
    return str
  end
  return str:lower()
end


local function init_args(doc, line, col, text, opt)
  opt = opt or default_opt
  line, col = doc:sanitize_position(line, col)

  if opt.no_case and not opt.regex then
    text = text:lower()
  end

  return doc, line, col, text, opt
end

local function get_search_bounds(doc, line, opt)
  local line_count = doc:line_count()
  local start_line = 1
  local end_line = line_count
  if opt.limit_start_line then
    start_line = math.max(1, math.min(line_count, opt.limit_start_line))
  end
  if opt.limit_end_line then
    end_line = math.max(start_line, math.min(line_count, opt.limit_end_line))
  end
  if line < start_line then
    line = start_line
  elseif line > end_line then
    line = end_line
  end
  return line, start_line, end_line, line_count
end

-- This function is needed to uniform the behavior of
-- `regex:cmatch` and `string.find`.
local function regex_func(text, re, index, _)
  local s, e = re:cmatch(text, index)
  return s, e and e - 1
end

local function rfind(func, text, pattern, index, plain)
  local s, e = func(text, pattern, 1, plain)
  local last_s, last_e
  if index < 0 then index = #text - index + 1 end
  while e and e <= index do
    last_s, last_e = s, e
    s, e = func(text, pattern, s + 1, plain)
  end
  return last_s, last_e
end


function search.find(doc, line, col, text, opt)
  doc, line, col, text, opt = init_args(doc, line, col, text, opt)
  local plain = not opt.pattern
  local pattern = text
  local search_func = string.find
  local cached_start, cached_end = nil, nil
  local scanned_lines = 0
  if doc.is_large_file and doc.get_cached_window_range then
    cached_start, cached_end = doc:get_cached_window_range()
  end
  if opt.regex then
    pattern = regex.compile(text, opt.no_case and "i" or "")
    search_func = regex_func
  end
  local scoped_start_line, scoped_end_line, line_count
  line, scoped_start_line, scoped_end_line, line_count = get_search_bounds(doc, line, opt)
  local start, finish, step = line, scoped_end_line, 1
  if opt.reverse then
    start, finish, step = line, scoped_start_line, -1
  end
  for line = start, finish, step do
    scanned_lines = scanned_lines + 1
    local line_text = doc:get_line(line)
    if opt.no_case and not opt.regex then
      line_text = line_text:lower()
    end
    local s, e
    if opt.reverse then
      s, e = rfind(search_func, line_text, pattern, col - 1, plain)
    else
      s, e = search_func(line_text, pattern, col, plain)
    end
    if s then
      local line2 = line
      -- If we've matched the newline too,
      -- return until the initial character of the next line.
      if e >= doc:get_line_length(line) then
        line2 = line + 1
        e = 0
      end
      -- Avoid returning matches that go beyond the last line.
      -- This is needed to avoid selecting the "last" newline.
      if line2 <= line_count then
        largefile_search_trace(
          doc,
          "search.hit file=%s scanned=%d match=%d:%d-%d:%d cached=%s-%s",
          tostring(doc.abs_filename or doc.filename),
          scanned_lines,
          line,
          s,
          line2,
          e + 1,
          tostring(cached_start),
          tostring(cached_end)
        )
        return line, s, line2, e + 1
      end
    end
    col = opt.reverse and -1 or 1
  end

  if opt.wrap then
    largefile_search_trace(
      doc,
      "search.wrap file=%s scanned=%d restart_reverse=%s",
      tostring(doc.abs_filename or doc.filename),
      scanned_lines,
      tostring(opt.reverse)
    )
    opt = {
      no_case = opt.no_case,
      regex = opt.regex,
      reverse = opt.reverse,
      limit_start_line = opt.limit_start_line,
      limit_end_line = opt.limit_end_line,
    }
    if opt.reverse then
      return search.find(doc, scoped_end_line, doc:get_line_length(scoped_end_line), text, opt)
    else
      return search.find(doc, scoped_start_line, 1, text, opt)
    end
  end

end


return search
