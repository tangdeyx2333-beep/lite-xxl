local config = require "core.config"

local Backend = {}
Backend.__index = Backend

function Backend.available()
  return true
end

function Backend.new(doc)
  return setmetatable({
    doc = doc,
    chunk_line_count = math.max(1, config.large_file_window_chunk_lines or 256),
    visible_window = nil,
    visible_window_margin = 0,
    visible_window_epoch = 0,
    pending_visible_window = nil,
  }, Backend)
end

function Backend:get_loading_state()
  return {
    visible_window = self.visible_window,
    visible_window_epoch = self.visible_window_epoch,
    chunk_line_count = self.chunk_line_count,
  }
end

function Backend:is_view_ready(start_line, end_line)
  if not self.visible_window then
    return false
  end
  return start_line >= self.visible_window.start_line
    and end_line <= self.visible_window.end_line
end

function Backend:request_visible_window(start_line, end_line, margin)
  margin = margin or 0
  self.visible_window_margin = margin
  self.pending_visible_window = {
    start_line = math.floor((math.max(1, start_line - margin) - 1) / self.chunk_line_count) * self.chunk_line_count + 1,
    end_line = math.min(
      self.doc:line_count(),
      math.ceil((math.max(start_line, end_line) + margin) / self.chunk_line_count) * self.chunk_line_count
    ),
    requested_start_line = start_line,
    requested_end_line = end_line,
    margin = margin,
    epoch = self.visible_window_epoch + 1,
    chunk_line_count = self.chunk_line_count,
  }
end

function Backend:poll_ready_window(budget_hint)
  if not self.pending_visible_window then
    return nil
  end
  self.visible_window_epoch = self.pending_visible_window.epoch
  self.visible_window = self.pending_visible_window
  self.pending_visible_window = nil
  return self.visible_window
end

function Backend:cancel_noncritical_work()
  self.pending_visible_window = nil
  return true
end

function Backend:shutdown()
  self.pending_visible_window = nil
  self.visible_window = nil
  return true
end

return Backend
