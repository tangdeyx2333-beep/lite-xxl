require "core.strict"
require "core.regex"
local common = require "core.common"
local config = require "core.config"
local style = require "colors.default"
local command
local keymap
local dirwatch
local ime
local RootView
local StatusView
local TitleView
local CommandView
local NagView
local DocView
local Doc
local LargeFileDoc
local WlPtDoc
local Project
local SessionRestore

local core = {}

local function load_session()
  local ok, t = pcall(dofile, USERDIR .. PATHSEP .. "session.lua")
  return ok and t or {}
end


local function save_session()
  local fp = io.open(USERDIR .. PATHSEP .. "session.lua", "w")
  if fp then
    fp:write("return {recents=", common.serialize(core.recent_projects),
      ", window=", common.serialize(table.pack(system.get_window_size(core.window))),
      ", window_mode=", common.serialize(system.get_window_mode(core.window)),
      ", previous_find=", common.serialize(core.previous_find),
      ", previous_replace=", common.serialize(core.previous_replace),
      "}\n")
    fp:close()
  end
end


local unsaved_instances_dirname = "unsaved_instances"
local unsaved_snapshot_prefix = "instance_"
local unsaved_snapshot_ext = ".lua"

local function get_unsaved_instances_dir()
  return USERDIR .. PATHSEP .. unsaved_instances_dirname
end

local function normalize_runtime_path(path)
  if type(path) ~= "string" or path == "" then return nil end
  local normalized = common.normalize_volume(path) or path
  normalized = normalized:gsub("[/\\]+", PATHSEP)
  normalized = normalized:gsub(PATHSEP .. "+$", "")
  return normalized
end

local function is_path_in_dir(path, dir)
  path = normalize_runtime_path(path)
  dir = normalize_runtime_path(dir)
  if not path or not dir then return false end
  return path == dir or path:sub(1, #dir + 1) == dir .. PATHSEP
end

local function is_ephemeral_project_dir(path)
  return is_path_in_dir(path, USERDIR .. PATHSEP .. "drag_temp")
    or is_path_in_dir(path, get_unsaved_instances_dir())
end

local function sanitize_recent_projects(recents)
  local sanitized = {}
  for _, path in ipairs(recents or {}) do
    local normalized = normalize_runtime_path(path)
    if normalized and not is_ephemeral_project_dir(normalized) then
      sanitized[#sanitized + 1] = normalized
    end
  end
  return sanitized
end

local function log_filetree_debug(fmt, ...)
  local ok, message = pcall(string.format, fmt, ...)
  local line = ok and message or ("format-error: " .. tostring(fmt))
  local logfile = USERDIR and (USERDIR .. PATHSEP .. "filetree-debug.log")
  if logfile then
    local fp = io.open(logfile, "ab")
    if fp then
      fp:write(os.date("[%Y-%m-%d %H:%M:%S] "), line, "\n")
      fp:close()
    end
  end
end

local function log_quit_debug(fmt, ...)
  local ok, message = pcall(string.format, fmt, ...)
  local line = ok and message or ("format-error: " .. tostring(fmt))
  local logfile = USERDIR and (USERDIR .. PATHSEP .. "largefile-debug.log")
  if logfile then
    local fp = io.open(logfile, "ab")
    if fp then
      fp:write(os.date("[%Y-%m-%d %H:%M:%S] "), line, "\n")
      fp:close()
    end
  end
end

local function log_window_restore_debug(fmt, ...)
  local ok, message = pcall(string.format, fmt, ...)
  local line = ok and message or ("format-error: " .. tostring(fmt))
  local logfile = USERDIR and (USERDIR .. PATHSEP .. "window-restore-debug.log")
  if logfile then
    local fp = io.open(logfile, "ab")
    if fp then
      fp:write(os.date("[%Y-%m-%d %H:%M:%S] "), line, "\n")
      fp:close()
    end
  end
end

local function log_startup_debug(fmt, ...)
  local ok, message = pcall(string.format, fmt, ...)
  local line = ok and message or ("format-error: " .. tostring(fmt))
  local logfile = USERDIR and (USERDIR .. PATHSEP .. "startup-window-debug.log")
  if logfile then
    local fp = io.open(logfile, "ab")
    if fp then
      fp:write(os.date("[%Y-%m-%d %H:%M:%S] "), line, "\n")
      fp:close()
    end
  end
end

local function get_session_window_rect(session_window)
  if type(session_window) ~= "table" then
    return nil
  end
  local w = tonumber(session_window[1])
  local h = tonumber(session_window[2])
  local x = tonumber(session_window[3])
  local y = tonumber(session_window[4])
  if not (w and h and x and y) then
    return nil
  end
  if w <= 0 or h <= 0 then
    return nil
  end
  return { w = w, h = h, x = x, y = y }
end

local function rect_intersects_display(rect, display)
  local left = math.max(rect.x, display.x)
  local top = math.max(rect.y, display.y)
  local right = math.min(rect.x + rect.w, display.x + display.w)
  local bottom = math.min(rect.y + rect.h, display.y + display.h)
  return right > left and bottom > top
end

local function should_restore_session_window(session_window)
  local rect = get_session_window_rect(session_window)
  if not rect then
    return false, "invalid-session-window"
  end
  if not system.get_display_bounds then
    return true, "display-bounds-unavailable"
  end
  local ok, displays = pcall(system.get_display_bounds)
  if not ok or type(displays) ~= "table" or #displays == 0 then
    return true, "display-bounds-unavailable"
  end
  for _, display in ipairs(displays) do
    if type(display) == "table" and rect_intersects_display(rect, display) then
      return true, string.format(
        "matched-display id=%s bounds=%s,%s,%s,%s",
        tostring(display.id),
        tostring(display.x),
        tostring(display.y),
        tostring(display.w),
        tostring(display.h)
      )
    end
  end
  return false, "outside-all-displays"
end

local function list_unsaved_snapshot_files()
  local files = {}
  local dir = get_unsaved_instances_dir()
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:find(unsaved_snapshot_prefix, 1, true) == 1
      and filename:sub(-#unsaved_snapshot_ext) == unsaved_snapshot_ext then
      files[#files + 1] = filename
    end
  end
  table.sort(files)
  return files
end

local function get_ws_storage_dir()
  return USERDIR .. PATHSEP .. "storage" .. PATHSEP .. "ws"
end

local function write_instance_storage(key, value)
  local dir = get_ws_storage_dir()
  common.mkdirp(dir)
  local fp = io.open(dir .. PATHSEP .. key, "w")
  if not fp then return false end
  fp:write("return ", common.serialize(value), "\n")
  fp:close()
  return true
end

local function read_instance_storage(key)
  if type(key) ~= "string" or key == "" then return nil end
  local ok, value = pcall(dofile, get_ws_storage_dir() .. PATHSEP .. key)
  if ok and type(value) == "table" then
    return value
  end
end

local function remove_instance_storage(key)
  if type(key) ~= "string" or key == "" then return end
  os.remove(get_ws_storage_dir() .. PATHSEP .. key)
end

local PENDING_TREEVIEW_STATE_KEY = "pending_treeview_state"

local function write_pending_treeview_state(width, visible)
  width = tonumber(width)
  if not width or width <= 0 then
    remove_instance_storage(PENDING_TREEVIEW_STATE_KEY)
    return false
  end
  return write_instance_storage(PENDING_TREEVIEW_STATE_KEY, {
    size = width,
    visible = visible ~= false
  })
end

local function consume_pending_treeview_state()
  local state = read_instance_storage(PENDING_TREEVIEW_STATE_KEY)
  if state then
    remove_instance_storage(PENDING_TREEVIEW_STATE_KEY)
  end
  if type(state) ~= "table" then return nil end
  local width = tonumber(state.size)
  if not width or width <= 0 then return nil end
  return {
    size = width,
    visible = state.visible ~= false
  }
end

local function is_blank_unsaved_content(name, content)
  local normalized_name = type(name) == "string" and name or ""
  local normalized_content = type(content) == "string" and content or ""
  local compact = normalized_content:gsub("[\r\n]", "")
  return compact == "" and (normalized_name == "" or normalized_name == "unsaved")
end

local function should_snapshot_wlpt_by_path(doc)
  return doc
    and doc.abs_filename
    and doc.is_wlpt_mode
    and doc:is_wlpt_mode()
end

local function save_unsaved_instance_snapshot()
  local docs = {}
  local views = core.root_view and core.root_view.root_node:get_children() or {}
  local snapshot_name = string.format(
    "%s%013d_%06x%s",
    unsaved_snapshot_prefix,
    math.floor(system.get_time() * 1000),
    math.random(0, 0xffffff),
    unsaved_snapshot_ext
  )
  local snapshot_id = snapshot_name:sub(1, -#unsaved_snapshot_ext - 1)

  for i, view in ipairs(views) do
    local doc = view and view.doc
    if doc then
      local item = {
        selection = { doc:get_selection(true) },
        scroll = view.scroll and {
          x = view.scroll.to and view.scroll.to.x or view.scroll.x or 0,
          y = view.scroll.to and view.scroll.to.y or view.scroll.y or 0,
        } or { x = 0, y = 0 },
        active = (core.active_view == view)
      }
      local name = doc.filename or doc:get_name()
      local content
      log_quit_debug(
        "snapshot.inspect index=%d name=%s abs=%s dirty=%s is_large=%s active=%s sel=%s scroll=%s,%s view=%s",
        i,
        tostring(name),
        tostring(doc.abs_filename),
        tostring(doc:is_dirty()),
        tostring(doc.is_large_file),
        tostring(item.active),
        tostring(item.selection and item.selection[1]),
        tostring(item.scroll and item.scroll.x),
        tostring(item.scroll and item.scroll.y),
        tostring(view)
      )
      if doc.abs_filename and (not doc:is_dirty() or should_snapshot_wlpt_by_path(doc)) then
        item.type = "path"
        item.abs_filename = doc.abs_filename
        log_quit_debug(
          "snapshot.store index=%d type=path name=%s abs=%s dirty=%s wlpt=%s",
          i,
          tostring(name),
          tostring(doc.abs_filename),
          tostring(doc:is_dirty()),
          tostring(should_snapshot_wlpt_by_path(doc))
        )
      else
        content = doc:get_all_text()
        log_quit_debug(
          "snapshot.content index=%d name=%s len=%d preview=%q",
          i,
          tostring(name),
          #(content or ""),
          tostring(content or ""):gsub("\n", "\\n"):sub(1, 80)
        )
        if not doc.abs_filename and is_blank_unsaved_content(name, content) then
          item = nil
          log_quit_debug(
            "snapshot.skip_blank index=%d name=%s",
            i,
            tostring(name)
          )
        else
        local storage_key = string.format("%s_doc_%03d", snapshot_id, i)
          if write_instance_storage(storage_key, {
            content = content,
            name = name,
            selection = item.selection,
          }) then
            item.type = "temp_storage"
            item.storage_key = storage_key
            log_quit_debug(
              "snapshot.store index=%d type=temp_storage key=%s name=%s len=%d",
              i,
              tostring(storage_key),
              tostring(name),
              #(content or "")
            )
          else
            item.type = "content"
            item.content = content
            item.name = name
            log_quit_debug(
              "snapshot.store index=%d type=content name=%s len=%d",
              i,
              tostring(name),
              #(content or "")
            )
          end
        end
      end
      if item then
        docs[#docs + 1] = item
      end
    end
  end

  if #docs == 0 then return end

  local dir = get_unsaved_instances_dir()
  common.mkdirp(dir)

  local fp = io.open(dir .. PATHSEP .. snapshot_name, "w")
  if not fp then return end

  fp:write("return ", common.serialize({
    created_at = os.time(),
    project_dir = core.root_project() and core.root_project().path or nil,
    restore_treeview_from_file_open = core.restore_treeview_from_file_open == true,
    docs = docs
  }), "\n")
  fp:close()
end

local function load_unsaved_instance_snapshot(snapshot_path)
  local ok, snapshot = pcall(dofile, snapshot_path)
  if ok and type(snapshot) == "table" then
    return snapshot
  end
end

local function restore_unsaved_instance_snapshot_file(snapshot_path)
  local snapshot = load_unsaved_instance_snapshot(snapshot_path)
  local restore_active_view
  local restore_treeview_from_file_open = snapshot and snapshot.restore_treeview_from_file_open == true
  core.restore_treeview_from_file_open = restore_treeview_from_file_open

  if snapshot and type(snapshot.docs) == "table" then
    for _, item in ipairs(snapshot.docs) do
      if item.type == "path" and type(item.abs_filename) == "string" and item.abs_filename ~= "" then
        log_quit_debug(
          "snapshot.restore.item type=path abs=%s selection=%s active=%s scroll=%s,%s",
          tostring(item.abs_filename),
          tostring(item.selection and item.selection[1]),
          tostring(item.active),
          tostring(item.scroll and item.scroll.x),
          tostring(item.scroll and item.scroll.y)
        )
        local doc = core.open_doc(item.abs_filename)
        local view = core.root_view:open_doc(doc, true)
        if item.selection and #item.selection >= 4 then
          doc:set_selection(table.unpack(item.selection, 1, 4))
          if view and item.scroll then
            view.scroll.x, view.scroll.to.x = item.scroll.x or 0, item.scroll.x or 0
            view.scroll.y, view.scroll.to.y = item.scroll.y or 0, item.scroll.y or 0
          elseif view and view.scroll_to_line then
            view:scroll_to_line(item.selection[1], true, true)
          end
        end
        if item.active and view then
          restore_active_view = view
        end
      elseif item.type == "content" and type(item.content) == "string" then
        if not is_blank_unsaved_content(item.name, item.content) then
          log_quit_debug(
            "snapshot.restore.item type=content name=%s len=%d active=%s scroll=%s,%s preview=%q",
            tostring(item.name),
            #(item.content or ""),
            tostring(item.active),
            tostring(item.scroll and item.scroll.x),
            tostring(item.scroll and item.scroll.y),
            tostring(item.content or ""):gsub("\n", "\\n"):sub(1, 80)
          )
          local doc = core.open_doc()
          doc:remove(1, 1, 1, 2)
          if item.content ~= "" then
            doc:insert(1, 1, item.content)
          end
          if item.name and item.name ~= "" and item.name ~= "unsaved" then
            doc.filename = item.name
          end
          if item.selection and #item.selection >= 4 then
            doc:set_selection(table.unpack(item.selection, 1, 4))
          end
          local view = core.root_view:open_doc(doc, true)
          if item.selection and #item.selection >= 4 and view and item.scroll then
            view.scroll.x, view.scroll.to.x = item.scroll.x or 0, item.scroll.x or 0
            view.scroll.y, view.scroll.to.y = item.scroll.y or 0, item.scroll.y or 0
          elseif item.selection and #item.selection >= 4 and view and view.scroll_to_line then
            view:scroll_to_line(item.selection[1], true, true)
          end
          if item.active and view then
            restore_active_view = view
          end
        end
      elseif item.type == "temp_storage" and type(item.storage_key) == "string" then
        local stored = read_instance_storage(item.storage_key)
        if stored and type(stored.content) == "string" and not is_blank_unsaved_content(stored.name, stored.content) then
          log_quit_debug(
            "snapshot.restore.item type=temp_storage key=%s name=%s len=%d active=%s scroll=%s,%s preview=%q",
            tostring(item.storage_key),
            tostring(stored.name),
            #(stored.content or ""),
            tostring(item.active),
            tostring(item.scroll and item.scroll.x),
            tostring(item.scroll and item.scroll.y),
            tostring(stored.content or ""):gsub("\n", "\\n"):sub(1, 80)
          )
          local doc = core.open_doc()
          doc:remove(1, 1, 1, 2)
          if stored.content ~= "" then
            doc:insert(1, 1, stored.content)
          end
          if stored.name and stored.name ~= "" and stored.name ~= "unsaved" then
            doc.filename = stored.name
          end
          local selection = stored.selection or item.selection
          if selection and #selection >= 4 then
            doc:set_selection(table.unpack(selection, 1, 4))
          end
          local view = core.root_view:open_doc(doc, true)
          if selection and #selection >= 4 and view and item.scroll then
            view.scroll.x, view.scroll.to.x = item.scroll.x or 0, item.scroll.x or 0
            view.scroll.y, view.scroll.to.y = item.scroll.y or 0, item.scroll.y or 0
          elseif selection and #selection >= 4 and view and view.scroll_to_line then
            view:scroll_to_line(selection[1], true, true)
          end
          if item.active and view then
            restore_active_view = view
          end
        end
        remove_instance_storage(item.storage_key)
      end
    end
  end

  if restore_active_view then
    local node = core.root_view and core.root_view.root_node and core.root_view.root_node:get_node_for_view(restore_active_view)
    if node and node.set_active_view then
      node:set_active_view(restore_active_view)
    else
      core.set_active_view(restore_active_view)
    end
  end

  os.remove(snapshot_path)
  return restore_treeview_from_file_open
end

local function restore_unsaved_instance_snapshots(target_snapshot_path)
  local dir = get_unsaved_instances_dir()
  local restore_treeview_from_file_open = false

  if type(target_snapshot_path) == "string" and target_snapshot_path ~= "" then
    return restore_unsaved_instance_snapshot_file(target_snapshot_path) == true
  end

  local snapshot_files = list_unsaved_snapshot_files()
  if #snapshot_files == 0 then return false end

  local first_snapshot_path = dir .. PATHSEP .. snapshot_files[1]
  restore_treeview_from_file_open = restore_unsaved_instance_snapshot_file(first_snapshot_path) == true

  for i = 2, #snapshot_files do
    local snapshot_path = dir .. PATHSEP .. snapshot_files[i]
    local snapshot = load_unsaved_instance_snapshot(snapshot_path)
    local project_dir = snapshot and snapshot.project_dir or (core.root_project() and core.root_project().path) or "."
    system.exec(string.format("%q --project-dir %q --restore-snapshot %q", EXEFILE, project_dir, snapshot_path))
  end
  return restore_treeview_from_file_open
end


local function update_recents_project(action, dir_path_abs)
  local dirname = common.normalize_volume(dir_path_abs)
  if not dirname or is_ephemeral_project_dir(dirname) then return end
  local recents = core.recent_projects
  local n = #recents
  for i = 1, n do
    if dirname == recents[i] then
      table.remove(recents, i)
      break
    end
  end
  if action == "add" then
    table.insert(recents, 1, dirname)
  end
end


function core.add_project(project)
  project = type(project) == "string" and Project(common.normalize_volume(project)) or project
  table.insert(core.projects, project)
  update_recents_project("add", project.path)
  core.redraw = true
  return project
end


function core.remove_project(project, force)
  for i = (force and 1 or 2), #core.projects do
    if project == core.projects[i] or project == core.projects[i].path then
      local project = core.projects[i]
      table.remove(core.projects, i)
      return project
    end
  end
  return false
end

function core.set_pending_treeview_state(width, visible)
  return write_pending_treeview_state(width, visible)
end

function core.set_restore_treeview_from_file_open(enabled, source)
  core.restore_treeview_from_file_open = enabled == true
  return core.restore_treeview_from_file_open
end


function core.set_project(project)
  while #core.projects > 0 do core.remove_project(core.projects[#core.projects], true) end
  local project = core.add_project(project)
  return project
end


function core.open_project(project)
  local project = core.set_project(project)
  core.root_view:close_all_docviews()
  update_recents_project("add", project.path)
  command.perform("core:restart")
end


local function strip_trailing_slash(filename)
  if filename:match("[^:]["..PATHSEP.."]$") then
    return filename:sub(1, -2)
  end
  return filename
end

-- create a directory using mkdir but may need to create the parent
-- directories as well.
local function create_user_directory()
  local success, err = common.mkdirp(USERDIR)
  if not success then
    error("cannot create directory \"" .. USERDIR .. "\": " .. err)
  end
  for _, modname in ipairs {'plugins', 'colors', 'fonts'} do
    local subdirname = USERDIR .. PATHSEP .. modname
    if not system.mkdir(subdirname) then
      error("cannot create directory: \"" .. subdirname .. "\"")
    end
  end
end


local function write_user_init_file(init_filename)
  local init_file = io.open(init_filename, "w")
  if not init_file then error("cannot create file: \"" .. init_filename .. "\"") end
  init_file:write([[
-- put user settings here
-- this module will be loaded after everything else when the application starts
-- it will be automatically reloaded when saved

local core = require "core"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"

------------------------------ Themes ----------------------------------------

-- light theme:
-- core.reload_module("colors.summer")

--------------------------- Key bindings -------------------------------------

-- key binding:
-- keymap.add { ["ctrl+escape"] = "core:quit" }

-- pass 'true' for second parameter to overwrite an existing binding
-- keymap.add({ ["ctrl+pageup"] = "root:switch-to-previous-tab" }, true)
-- keymap.add({ ["ctrl+pagedown"] = "root:switch-to-next-tab" }, true)

------------------------------- Fonts ----------------------------------------

-- customize fonts:
-- Uncomment and modify the lines below to customize fonts
-- The second parameter is the font size (multiplied by SCALE for DPI scaling)

-- User interface font (menus, status bar, etc.)
-- style.font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 14 * SCALE)

-- Code font (editor)
-- style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14 * SCALE)

-- Big font (welcome screen)
-- style.big_font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 24 * SCALE)

-- Icon font
-- style.icon_font = renderer.font.load(DATADIR .. "/fonts/MaterialIcons-Regular.otf", 16 * SCALE)

-- Toolbar icon font
-- style.icon_big_font = renderer.font.load(DATADIR .. "/fonts/MaterialIcons-Regular.otf", 24 * SCALE)

-- DATADIR is the location of the installed Lite XL Lua code, default color
-- schemes and fonts.
-- USERDIR is the location of the Lite XL configuration directory.
--
-- font names used by lite:
-- style.font          : user interface
-- style.big_font      : big text in welcome screen
-- style.icon_font     : icons
-- style.icon_big_font : toolbar icons
-- style.code_font     : code
--
-- the function to load the font accept a 3rd optional argument like:
--
-- {antialiasing="grayscale", hinting="full", bold=true, italic=true, underline=true, smoothing=true, strikethrough=true}
--
-- possible values are:
-- antialiasing: grayscale, subpixel
-- hinting: none, slight, full
-- bold: true, false
-- italic: true, false
-- underline: true, false
-- smoothing: true, false
-- strikethrough: true, false

------------------------------ Plugins ----------------------------------------

-- disable plugin loading setting config entries:

-- disable plugin detectindent, otherwise it is enabled by default:
-- config.plugins.detectindent = false

---------------------------- Miscellaneous -------------------------------------

-- modify list of files to ignore when indexing the project:
-- config.ignore_files = {
--   -- folders
--   "^%.svn/",        "^%.git/",   "^%.hg/",        "^CVS/", "^%.Trash/", "^%.Trash%-.*/",
--   "^node_modules/", "^%.cache/", "^__pycache__/",
--   -- files
--   "%.pyc$",         "%.pyo$",       "%.exe$",        "%.dll$",   "%.obj$", "%.o$",
--   "%.a$",           "%.lib$",       "%.so$",         "%.dylib$", "%.ncb$", "%.sdf$",
--   "%.suo$",         "%.pdb$",       "%.idb$",        "%.class$", "%.psd$", "%.db$",
--   "^desktop%.ini$", "^%.DS_Store$", "^%.directory$",
-- }

]])
  init_file:close()
end


config.plugins.treeview.visible = false
config.plugins.treeview.size = 0

function core.write_init_project_module(init_filename)
  local init_file = io.open(init_filename, "w")
  if not init_file then error("cannot create file: \"" .. init_filename .. "\"") end
  init_file:write([[
-- Put project's module settings here.
-- This module will be loaded when opening a project, after the user module
-- configuration.
-- It will be automatically reloaded when saved.

local config = require "core.config"

-- you can add some patterns to ignore files within the project
-- config.ignore_files = {"^%.", <some-patterns>}

-- Patterns are normally applied to the file's or directory's name, without
-- its path. See below about how to apply filters on a path.
--
-- Here some examples:
--
-- "^%." matches any file of directory whose basename begins with a dot.
--
-- When there is an '/' or a '/$' at the end, the pattern will only match
-- directories. When using such a pattern a final '/' will be added to the name
-- of any directory entry before checking if it matches.
--
-- "^%.git/" matches any directory named ".git" anywhere in the project.
--
-- If a "/" appears anywhere in the pattern (except when it appears at the end or
-- is immediately followed by a '$'), then the pattern will be applied to the full
-- path of the file or directory. An initial "/" will be prepended to the file's
-- or directory's path to indicate the project's root.
--
-- "^/node_modules/" will match a directory named "node_modules" at the project's root.
-- "^/build.*/" will match any top level directory whose name begins with "build".
-- "^/subprojects/.+/" will match any directory inside a top-level folder named "subprojects".

-- You may activate some plugins on a per-project basis to override the user's settings.
-- config.plugins.trimwitespace = true
]]):close()
end


function core.ensure_user_directory()
  return core.try(function()
    if not system.get_file_info(USERDIR) then
      create_user_directory()
    end
    local init_filename = USERDIR .. PATHSEP .. "init.lua"
    if not system.get_file_info(init_filename) then
      write_user_init_file(init_filename)
    end
  end)
end


function core.configure_borderless_window()
  system.set_window_bordered(core.window, not config.borderless)
  core.title_view:configure_hit_test(config.borderless)
  core.title_view.visible = config.borderless
end


function core.init()
  core.log_items = {}
  core.log_quiet("Lite XL version %s - mod-version %s", VERSION, MOD_VERSION_STRING)

  command = require "core.command"
  keymap = require "core.keymap"
  dirwatch = require "core.dirwatch"
  ime = require "core.ime"
  RootView = require "core.rootview"
  StatusView = require "core.statusview"
  TitleView = require "core.titleview"
  CommandView = require "core.commandview"
  NagView = require "core.nagview"
  Project = require "core.project"
  DocView = require "core.docview"
  Doc = require "core.doc"
  LargeFileDoc = require "core.doc.largefile"
  WlPtDoc = require "core.doc.wlpt"

  if PATHSEP == '\\' then
    USERDIR = common.normalize_volume(USERDIR)
    DATADIR = common.normalize_volume(DATADIR)
    EXEDIR  = common.normalize_volume(EXEDIR)
  end

  local session = load_session()
  log_window_restore_debug(
    "session.loaded window_mode=%s window=%s recent0=%s",
    tostring(session.window_mode),
    tostring(common.serialize(session.window)),
    tostring(session.recents and session.recents[1])
  )
  core.recent_projects = sanitize_recent_projects(session.recents or {})
  core.previous_find = {}
  core.previous_replace = {}

  local project_dir = core.recent_projects[1] or "."
  local project_dir_explicit = false
  local files = {}
  local restore_snapshot_arg
  if not RESTARTED then
    local skip_next_arg = false
    for i = 2, #ARGS do
      if skip_next_arg then
        skip_next_arg = false
      elseif ARGS[i] == "--restore-snapshot" then
        restore_snapshot_arg = ARGS[i + 1]
        skip_next_arg = true
      elseif ARGS[i] == "--project-dir" then
        project_dir = ARGS[i + 1]
        project_dir_explicit = true
        skip_next_arg = true
      else
        local arg_filename = strip_trailing_slash(ARGS[i])
        local info = system.get_file_info(arg_filename) or {}
        if info.type == "dir" then
          project_dir = arg_filename
          project_dir_explicit = true
        else
          -- on macOS we can get an argument like "-psn_0_52353" that we just ignore.
          if not ARGS[i]:match("^-psn") then
            local file_abs = common.is_absolute_path(arg_filename) and arg_filename or (system.absolute_path(".") .. PATHSEP .. common.normalize_path(arg_filename))
            if file_abs then
              table.insert(files, file_abs)
              if not project_dir_explicit then
                project_dir = file_abs:match("^(.+)[/\\].+$")
              end
            end
          end
        end
      end
    end
  end
  -- Ensure that we have a user directory.
  core.ensure_user_directory()

  core.frame_start = 0
  core.clip_rect_stack = {{ 0,0,0,0 }}
  core.docs = {}
  core.projects = {}
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  core.window_mode = "normal"
  core.threads = setmetatable({}, { __mode = "k" })
  core.thread_metrics = {
    created = 0,
    resumed = 0,
    completed = 0,
    cancelled = 0,
    resume_time = 0,
    max_resume_time = 0,
  }
  core.scheduler_epoch = 0
  core.blink_start = system.get_time()
  core.blink_timer = core.blink_start
  core.active_file_dialogs = {}
  core.redraw = true
  core.visited_files = {}
  core.restart_request = false
  core.quit_request = false
  core.restore_treeview_from_file_open = #files > 0

  -- We load core views before plugins that may need them.
  ---@type core.rootview
  core.root_view = RootView()
  ---@type core.commandview
  core.command_view = CommandView()
  ---@type core.statusview
  core.status_view = StatusView()
  ---@type core.nagview
  core.nag_view = NagView()
  ---@type core.titleview
  core.title_view = TitleView()

  -- Some plugins (eg: console) require the nodes to be initialized to defaults
  local cur_node = core.root_view.root_node
  cur_node.is_primary_node = true

  -- 预先加载 ToolbarView，以便在布局中使用
  local ToolbarView = require "plugins.toolbarview"
  core.toolbar_view = ToolbarView()

  -- 将标题栏和工具栏放在最上方（工具栏在标题栏下方）
  -- 1. 先添加 title_view，它会在最上方
  cur_node:split("up", core.title_view, {y = true})
  -- 2. 然后在 title_view 下方添加 toolbar_view
  cur_node = cur_node.b  -- 移到 title_view 的节点
  cur_node:split("up", core.toolbar_view, {y = true})
  -- 3. 然后在 toolbar_view 下方添加 nag_view
  cur_node = cur_node.b  -- 移到 toolbar_view 的节点
  cur_node:split("up", core.nag_view, {y = true})
  cur_node = cur_node.b
  -- 添加 Toolbar 到主界面顶部
  cur_node = cur_node:split("down", core.command_view, {y = true})
  cur_node = cur_node:split("down", core.status_view, {y = true})

  -- Load default commands first so plugins can override them
  command.add_defaults()
  command.add(nil, {
    ["toolbar:toggle"] = function()
      if core.toolbar_view then
        core.toolbar_view:toggle_visible()
      end
    end,
  })

  local project_dir_abs = system.absolute_path(project_dir)
  -- We prevent set_project below to effectively add and scan the directory because the
  -- project module and its ignore files is not yet loaded.
  if project_dir_abs and pcall(core.set_project, project_dir_abs) then
    if project_dir_explicit then
      update_recents_project("add", project_dir_abs)
    end
  else
    if not project_dir_explicit then
      update_recents_project("remove", project_dir)
    end
    project_dir_abs = system.absolute_path(".")
    local status, err = pcall(core.set_project, project_dir_abs)
  end
  log_filetree_debug(
    "core.init before load_plugins root=%s config_visible=%s config_size=%s restarted=%s",
    tostring(core.root_project() and core.root_project().path),
    tostring(config.plugins.treeview and config.plugins.treeview.visible),
    tostring(config.plugins.treeview and config.plugins.treeview.size),
    tostring(RESTARTED)
  )

  -- Load core and user plugins giving preference to user ones with same name.
  log_startup_debug(
    "startup.load_plugins.begin root=%s restarted=%s project_dir_abs=%s",
    tostring(core.root_project() and core.root_project().path),
    tostring(RESTARTED),
    tostring(project_dir_abs)
  )
  local plugins_success, plugins_refuse_list = core.load_plugins()
  log_startup_debug(
    "startup.load_plugins.done root=%s success=%s user_refused=%d data_refused=%d active_view=%s",
    tostring(core.root_project() and core.root_project().path),
    tostring(plugins_success),
    #(plugins_refuse_list and plugins_refuse_list.userdir and plugins_refuse_list.userdir.plugins or {}),
    #(plugins_refuse_list and plugins_refuse_list.datadir and plugins_refuse_list.datadir.plugins or {}),
    core.describe_view and core.describe_view(core.active_view) or tostring(core.active_view)
  )

  log_startup_debug(
    "startup.window.begin root=%s existing_window=%s",
    tostring(core.root_project() and core.root_project().path),
    tostring(core.window)
  )
  if not core.window then
    log_startup_debug("startup.window.restore_try root=%s", tostring(core.root_project() and core.root_project().path))
    core.window = renwindow._restore()
    log_startup_debug(
      "startup.window.restore_result root=%s window=%s",
      tostring(core.root_project() and core.root_project().path),
      tostring(core.window)
    )
  end
  if not core.window then
    log_startup_debug("startup.window.create_try root=%s", tostring(core.root_project() and core.root_project().path))
    core.window = renwindow.create("")
    log_startup_debug(
      "startup.window.create_result root=%s window=%s",
      tostring(core.root_project() and core.root_project().path),
      tostring(core.window)
    )
  end
  log_startup_debug(
    "startup.window.done root=%s window=%s",
    tostring(core.root_project() and core.root_project().path),
    tostring(core.window)
  )
  do
    local w, h, x, y = system.get_window_size(core.window)
    log_window_restore_debug(
      "window.created size=%s,%s pos=%s,%s mode=%s",
      tostring(w),
      tostring(h),
      tostring(x),
      tostring(y),
      tostring(system.get_window_mode(core.window))
    )
  end
  log_startup_debug(
    "startup.window.restore.begin root=%s session_mode=%s session_window=%s",
    tostring(core.root_project() and core.root_project().path),
    tostring(session.window_mode),
    tostring(common.serialize(session.window))
  )
  if session.window_mode == "normal" then
    local should_restore, reason = should_restore_session_window(session.window)
    if should_restore then
      log_window_restore_debug(
        "window.restore.apply mode=normal target=%s reason=%s",
        tostring(common.serialize(session.window)),
        tostring(reason)
      )
      system.set_window_size(core.window, table.unpack(session.window))
      local w, h, x, y = system.get_window_size(core.window)
      log_window_restore_debug(
        "window.restore.after_apply size=%s,%s pos=%s,%s mode=%s",
        tostring(w),
        tostring(h),
        tostring(x),
        tostring(y),
        tostring(system.get_window_mode(core.window))
      )
    else
      local w, h, x, y = system.get_window_size(core.window)
      log_window_restore_debug(
        "window.restore.skip mode=normal target=%s reason=%s fallback_size=%s,%s fallback_pos=%s,%s",
        tostring(common.serialize(session.window)),
        tostring(reason),
        tostring(w),
        tostring(h),
        tostring(x),
        tostring(y)
      )
    end
  elseif session.window_mode == "maximized" then
    log_window_restore_debug("window.restore.apply mode=maximized")
    system.set_window_mode(core.window, "maximized")
    local w, h, x, y = system.get_window_size(core.window)
    log_window_restore_debug(
      "window.restore.after_apply size=%s,%s pos=%s,%s mode=%s",
      tostring(w),
      tostring(h),
      tostring(x),
      tostring(y),
      tostring(system.get_window_mode(core.window))
    )
  else
    log_window_restore_debug(
      "window.restore.skip mode=%s reason=no-session-window-mode-match",
      tostring(session.window_mode)
    )
  end
  log_startup_debug(
    "startup.window.restore.done root=%s mode=%s",
    tostring(core.root_project() and core.root_project().path),
    tostring(system.get_window_mode(core.window))
  )


  do
    local pdir, pname = project_dir_abs:match("(.*)[/\\\\](.*)")
    core.log_quiet("Opening project %q from directory %s", pname, pdir)
  end

  for _, filename in ipairs(files) do
    core.root_view:open_doc(core.open_doc(filename))
  end

  log_startup_debug(
    "startup.restore_snapshots.begin root=%s arg=%s docs_before=%d",
    tostring(core.root_project() and core.root_project().path),
    tostring(restore_snapshot_arg),
    #(core.docs or {})
  )
  local restored_from_file_open = restore_unsaved_instance_snapshots(restore_snapshot_arg)
  log_startup_debug(
    "startup.restore_snapshots.done root=%s docs_after=%d active_view=%s restored_from_file_open=%s",
    tostring(core.root_project() and core.root_project().path),
    #(core.docs or {}),
    core.describe_view and core.describe_view(core.active_view) or tostring(core.active_view),
    tostring(restored_from_file_open)
  )
  core.restore_treeview_from_file_open = restored_from_file_open
  if restored_from_file_open and #(core.docs or {}) > 0 and core.ensure_treeview_visible then
    local restore_treeview_size = tonumber(config.plugins.treeview.open_project_size)
      or tonumber(config.plugins.treeview.open_file_size)
    core.ensure_treeview_visible(restore_treeview_size)
  end

  if not plugins_success then
    -- defer LogView to after everything is initialized,
    -- so that EmptyView won't be added after LogView.
    core.add_thread(function()
      command.perform("core:open-log")
    end, nil, core.thread_options {
      label = "defer-open-log",
      kind = "ui-deferred",
      priority = "U3",
    })
  end

  log_startup_debug("startup.configure_borderless.begin root=%s", tostring(core.root_project() and core.root_project().path))
  core.configure_borderless_window()
  log_startup_debug("startup.configure_borderless.done root=%s", tostring(core.root_project() and core.root_project().path))

  if #plugins_refuse_list.userdir.plugins > 0 or #plugins_refuse_list.datadir.plugins > 0 then
    local opt = {
      { text = "Exit", default_no = true },
      { text = "Continue", default_yes = true }
    }
    local msg = {}
    for _, entry in pairs(plugins_refuse_list) do
      if #entry.plugins > 0 then
        local msg_list = {}
        for _, p in pairs(entry.plugins) do
          table.insert(msg_list, string.format("%s[%s]", p.file, p.version_string))
        end
        msg[#msg + 1] = string.format("Plugins from directory \"%s\":\n%s", common.home_encode(entry.dir), table.concat(msg_list, "\n"))
      end
    end
    core.nag_view:show(
      "Refused Plugins",
      string.format(
        "Some plugins are not loaded due to version mismatch. Expected version %s.\n\n%s.\n\n" ..
        "Please download a recent version from https://github.com/lite-xl/lite-xl-plugins.",
        MOD_VERSION_STRING, table.concat(msg, ".\n\n")),
      opt, function(item)
        if item.text == "Exit" then os.exit(1) end
      end)
  end
end


function core.confirm_close_docs(docs, close_fn, ...)
  local dirty_count = 0
  local dirty_name
  local total_docs = #(docs or core.docs or {})
  for _, doc in ipairs(docs or core.docs) do
    if doc:is_dirty() then
      dirty_count = dirty_count + 1
      dirty_name = doc:get_name()
    end
  end
  log_quit_debug(
    "quit.confirm_close_docs total_docs=%d dirty_count=%d dirty_name=%s",
    total_docs,
    dirty_count,
    tostring(dirty_name)
  )
  if dirty_count > 0 then
    for _, doc in ipairs(docs or core.docs) do
      if doc:is_dirty() then
        -- 中文说明：全局退出确认会直接进入强制关闭流程，这里标记用户已经选择丢弃未保存修改。
        doc._close_without_saving_requested = true
      end
    end
    local text
    if dirty_count == 1 then
      text = string.format("\"%s\" has unsaved changes. Quit anyway?", dirty_name)
    else
      text = string.format("%d docs have unsaved changes. Quit anyway?", dirty_count)
    end
    local args = {...}
    close_fn(table.unpack(args))
  else
    close_fn(...)
  end
end

local temp_uid = math.floor(system.get_time() * 1000) % 0xffffffff
local temp_file_prefix = string.format(".lite_temp_%08x", tonumber(temp_uid))
local temp_file_counter = 0

function core.delete_temp_files(dir)
  dir = type(dir) == "string" and common.normalize_path(dir) or USERDIR
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:find(temp_file_prefix, 1, true) == 1 then
      os.remove(dir .. PATHSEP .. filename)
    end
  end
end

function core.temp_filename(ext, dir)
  dir = type(dir) == "string" and common.normalize_path(dir) or USERDIR
  temp_file_counter = temp_file_counter + 1
  return dir .. PATHSEP .. temp_file_prefix
      .. string.format("%06x", temp_file_counter) .. (ext or "")
end


function core.exit(quit_fn, force)
  log_quit_debug(
    "quit.exit.begin force=%s docs=%d projects=%d active_view=%s",
    tostring(force),
    #(core.docs or {}),
    #(core.projects or {}),
    core.describe_view and core.describe_view(core.active_view) or tostring(core.active_view)
  )
  if force then
    log_quit_debug("quit.exit.force save_unsaved_instance_snapshot.begin")
    save_unsaved_instance_snapshot()
    log_quit_debug("quit.exit.force save_unsaved_instance_snapshot.done")
    log_quit_debug("quit.exit.force delete_temp_files.begin")
    core.delete_temp_files()
    log_quit_debug("quit.exit.force delete_temp_files.done")
    while #core.projects > 0 do core.remove_project(core.projects[#core.projects], true) end
    log_quit_debug("quit.exit.force remove_projects.done remaining=%d", #core.projects)
    log_quit_debug("quit.exit.force save_session.begin")
    save_session()
    log_quit_debug("quit.exit.force save_session.done")
    log_quit_debug("quit.exit.force quit_fn.begin")
    quit_fn()
    log_quit_debug(
      "quit.exit.force quit_fn.done restart_request=%s quit_request=%s",
      tostring(core.restart_request),
      tostring(core.quit_request)
    )
  else
    log_quit_debug("quit.exit.normal save_session.begin")
    save_session()
    log_quit_debug("quit.exit.normal save_session.done")

    log_quit_debug("quit.exit.normal confirm_close_docs.begin")
    core.confirm_close_docs(core.docs, core.exit, quit_fn, true)
    log_quit_debug("quit.exit.normal confirm_close_docs.dispatched")
  end
end


function core.quit(force)
  log_quit_debug("quit.request force=%s", tostring(force))
  core.exit(function() core.quit_request = true end, force)
end


function core.restart()
  core.exit(function()
    core.restart_request = true
    core.window:_persist()
  end)
end


local function require_lua_plugin(plugin)
  return require("plugins." .. plugin.name)
end


local function load_lua_plugin_if_exists(plugin)
  return system.get_file_info(plugin.file) and dofile(plugin.file)
end


function core.parse_plugin_details(path, file, mod_version_regex, priority_regex)
  local f = io.open(file, "r")
  if not f then return false end
  local priority = false
  local version_match = false
  local major, minor, patch

  for line in f:lines() do
    if not version_match then
      local status, _major, _minor, _patch = pcall(mod_version_regex.match, mod_version_regex, line)
      if status and _major then
        _major = tonumber(_major) or 0
        _minor = tonumber(_minor) or 0
        _patch = tonumber(_patch) or 0
        major, minor, patch = _major, _minor, _patch

        version_match = major == MOD_VERSION_MAJOR
        if version_match then
          version_match = minor <= MOD_VERSION_MINOR
        end
        if version_match then
          version_match = patch <= MOD_VERSION_PATCH
        end
      end
    end

    if not priority then
      local status, _priority = pcall(priority_regex.match, priority_regex, line)
      if status and _priority then priority = tonumber(_priority) end
    end

    if version_match then
      break
    end
  end
  f:close()
  local version = major and {major, minor, patch} or {}
  return {
    name = common.basename(path),
    file = file,
    version_match = version_match,
    version = version,
    priority = priority or 100,
    version_string = major and table.concat(version, ".") or "unknown"
  }
end


local mod_version_regex =
  regex.compile([[--.*mod-version:(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:$|\s)]])
local priority_regex = regex.compile([[\-\-.*priority\s*:\s*(\-?[\d\.]+)]])
function core.get_plugin_details(path)
  local info = system.get_file_info(path)
  local file = path
  if info ~= nil and info.type == "dir" then
    file = path .. PATHSEP .. "init.lua"
    info = system.get_file_info(file)
  end
  local details = info and core.parse_plugin_details(path:gsub("%.lua$", ""), file, mod_version_regex, priority_regex)
  if details then details.load = require_lua_plugin end
  return details
end


core.plugin_list = {}
-- Can be called from within plugins; don't insert things lower than your own priority.
function core.add_plugins(plugins)
  for i,v in ipairs(plugins) do table.insert(core.plugin_list, v) end

  -- sort by priority or name for plugins that have same priority
  table.sort(core.plugin_list, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.name < b.name
  end)
end


function core.load_plugins()
  local no_errors = true
  local pending_treeview_state = consume_pending_treeview_state()
  local refused_list = {
    userdir = {dir = USERDIR, plugins = {}},
    datadir = {dir = DATADIR, plugins = {}},
  }
  local files, ordered = {}, {
    { priority = -2, load = load_lua_plugin_if_exists, version_match = true, file = USERDIR .. PATHSEP .. "init.lua", name = "User Module" },
    { priority = -1, load = load_lua_plugin_if_exists, version_match = true, file = core.root_project().path .. PATHSEP .. ".lite_project.lua", name = "Project Module" }
  }
  for _, root_dir in ipairs {DATADIR, USERDIR} do
    local plugin_dir = root_dir .. PATHSEP .. "plugins"
    for _, filename in ipairs(system.list_dir(plugin_dir) or {}) do
      if not files[filename] then
        local details = core.get_plugin_details(plugin_dir .. PATHSEP .. filename)
        if details then table.insert(ordered, details) end
      end
      -- user plugins will always replace system plugins
      files[filename] = plugin_dir
    end
  end
  core.add_plugins(ordered)

  local load_start = system.get_time()
  for i = 1, #core.plugin_list do
    local plugin = core.plugin_list[i]
    if pending_treeview_state and plugin.name == "treeview" then
      config.plugins.treeview = config.plugins.treeview or {}
      config.plugins.treeview.visible = pending_treeview_state.visible
      config.plugins.treeview.size = pending_treeview_state.size
      log_filetree_debug(
        "core.load_plugins apply pending treeview root=%s visible=%s size=%s",
        tostring(core.root_project() and core.root_project().path),
        tostring(config.plugins.treeview.visible),
        tostring(config.plugins.treeview.size)
      )
      pending_treeview_state = nil
    end
    if plugin.name == "User Module" or plugin.name == "Project Module" or plugin.name == "treeview" then
      log_filetree_debug(
        "core.load_plugins before plugin=%s root=%s config_visible=%s config_size=%s",
        tostring(plugin.name),
        tostring(core.root_project() and core.root_project().path),
        tostring(config.plugins.treeview and config.plugins.treeview.visible),
        tostring(config.plugins.treeview and config.plugins.treeview.size)
      )
    end
    if not config.skip_plugins_version and not plugin.version_match then
      core.log_quiet(
        "Version mismatch for plugin %q[%s] from %s",
        plugin.name,
        plugin.version_string,
        common.dirname(plugin.file)
      )
      local rlist = plugin.file:find(USERDIR, 1, true) == 1
        and 'userdir' or 'datadir'
      table.insert(refused_list[rlist].plugins, plugin)
    elseif config.plugins[plugin.name] ~= false then
      local start = system.get_time()
      local ok, loaded_plugin = core.try(plugin.load, plugin)
      if plugin.name == "User Module" or plugin.name == "Project Module" or plugin.name == "treeview" then
        log_filetree_debug(
          "core.load_plugins after plugin=%s ok=%s root=%s config_visible=%s config_size=%s",
          tostring(plugin.name),
          tostring(ok),
          tostring(core.root_project() and core.root_project().path),
          tostring(config.plugins.treeview and config.plugins.treeview.visible),
          tostring(config.plugins.treeview and config.plugins.treeview.size)
        )
      end
      if ok then
        local plugin_version = ""
        if plugin.version_string and  plugin.version_string ~= MOD_VERSION_STRING then
          plugin_version = "["..plugin.version_string.."]"
        end
        core.log_quiet(
          "Loaded plugin %q%s from %s in %.1fms",
          plugin.name,
          plugin_version,
          common.dirname(plugin.file),
          (system.get_time() - start) * 1000
        )
        if config.plugins[plugin.name].onload then
          core.try(config.plugins[plugin.name].onload, loaded_plugin)
        end
      else
        no_errors = false
      end
    end
  end
  core.log_quiet(
    "Loaded all plugins in %.1fms",
    (system.get_time() - load_start) * 1000
  )
  return no_errors, refused_list
end


function core.reload_module(name)
  local old = package.loaded[name]
  package.loaded[name] = nil
  local new = require(name)
  if type(old) == "table" then
    for k, v in pairs(new) do old[k] = v end
    package.loaded[name] = old
  end
end


function core.set_visited(filename)
  for i = 1, #core.visited_files do
    if core.visited_files[i] == filename then
      table.remove(core.visited_files, i)
      break
    end
  end
  table.insert(core.visited_files, 1, filename)
end


function core.set_active_view(view)
  assert(view, "Tried to set active view to nil")
  -- Reset the IME even if the focus didn't change
  ime.stop()
  if view ~= core.active_view then
    if core.window then system.text_input(core.window, view:supports_text_input()) end
    if core.active_view and core.active_view.force_focus then
      core.next_active_view = view
      return
    end
    core.next_active_view = nil
    if view.doc and view.doc.filename then
      core.set_visited(view.doc.filename)
    end
    core.last_active_view = core.active_view
    core.active_view = view
    core.scheduler_epoch = core.scheduler_epoch + 1
    core.scheduler_debug(
      "active-view epoch=%s from=%s to=%s",
      tostring(core.scheduler_epoch),
      core.describe_view(core.last_active_view),
      core.describe_view(core.active_view)
    )
  end
  -- Pre-position the IME window so the candidate box appears at the
  -- caret location as soon as typing starts.
  if view.update_ime_location then
    view:update_ime_location(true)
  end
end


function core.show_title_bar(show)
  core.title_view.visible = show
end


local thread_counter = 0
function core.thread_options(meta)
  meta = meta or {}
  meta.__thread_meta = true
  return meta
end

function core.describe_view(view)
  if not view then return "nil" end
  if view.doc and view.doc.get_name then
    return string.format("%s[%s]", tostring(view), tostring(view.doc:get_name()))
  end
  return tostring(view)
end

local function normalize_thread_meta(key, weak_ref, meta)
  meta = meta or {}
  meta.key = key
  meta.label = meta.label or (type(weak_ref) == "string" and weak_ref) or tostring(weak_ref or key)
  meta.kind = meta.kind or "generic"
  meta.priority = meta.priority or "U3"
  meta.owner_view = meta.owner_view == nil and core.active_view or meta.owner_view
  meta.owner_doc = meta.owner_doc or (meta.owner_view and meta.owner_view.doc) or nil
  meta.created_at = system.get_time()
  meta.created_epoch = core.scheduler_epoch
  return meta
end

function core.add_thread(f, weak_ref, ...)
  local key = weak_ref
  if not key then
    thread_counter = thread_counter + 1
    key = thread_counter
  end
  assert(core.threads[key] == nil, "Duplicate thread reference")
  local args = {...}
  local meta
  if type(args[1]) == "table" and args[1].__thread_meta then
    meta = args[1]
    table.remove(args, 1)
  end
  local fn = function() return core.try(f, table.unpack(args)) end
  meta = normalize_thread_meta(key, weak_ref, meta)
  core.threads[key] = { cr = coroutine.create(fn), wake = 0, meta = meta }
  core.thread_metrics.created = core.thread_metrics.created + 1
  core.scheduler_debug(
    "thread-create key=%s label=%s kind=%s priority=%s owner=%s epoch=%s",
    tostring(key),
    tostring(meta.label),
    tostring(meta.kind),
    tostring(meta.priority),
    core.describe_view(meta.owner_view),
    tostring(meta.created_epoch)
  )
  return key
end

function core.cancel_thread(key, reason)
  local thread = core.threads[key]
  if not thread then return false end
  core.threads[key] = nil
  core.thread_metrics.cancelled = core.thread_metrics.cancelled + 1
  core.scheduler_debug(
    "thread-cancel key=%s label=%s reason=%s",
    tostring(key),
    tostring(thread.meta and thread.meta.label),
    tostring(reason or "unspecified")
  )
  return true
end

local function is_thread_frozen(thread)
  local meta = thread.meta
  if not config.inactive_freeze_policy or not meta then
    return false
  end
  if meta.priority == "U0" or meta.priority == "U1" then
    return false
  end
  if not meta.owner_doc then
    return false
  end
  local active_doc = core.active_view and core.active_view.doc
  if not active_doc then
    return false
  end
  return meta.owner_doc ~= active_doc
end


function core.push_clip_rect(x, y, w, h)
  local x2, y2, w2, h2 = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  local r, b, r2, b2 = x+w, y+h, x2+w2, y2+h2
  x, y = math.max(x, x2), math.max(y, y2)
  b, r = math.min(b, b2), math.min(r, r2)
  w, h = r-x, b-y
  table.insert(core.clip_rect_stack, { x, y, w, h })
  renderer.set_clip_rect(x, y, w, h)
end


function core.pop_clip_rect()
  table.remove(core.clip_rect_stack)
  local x, y, w, h = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  renderer.set_clip_rect(x, y, w, h)
end

function core.root_project() return core.projects[1] end
function core.project_for_path(path)
  for i, project in ipairs(core.projects) do
    if project.path:find(path, 1, true) then return project end
  end
  return nil
end
-- Legacy interface; do not use. Use a specific project instead. When in doubt, use root_project.
function core.normalize_to_project_dir(path) core.deprecation_log("core.normalize_to_project_dir") return core.root_project():normalize_path(path) end
function core.project_absolute_path(path) core.deprecation_log("core.project_absolute_path") return core.root_project() and core.root_project():absolute_path(path) or system.absolute_path(path) end

function core.open_doc(filename)
  local new_file = true
  local abs_filename
  local file_info
  if filename then
    -- normalize filename and set absolute filename then
    -- try to find existing doc for filename
    filename = core.root_project():normalize_path(filename)
    abs_filename = core.root_project():absolute_path(filename)
    file_info = system.get_file_info(abs_filename)
    new_file = not file_info
    log_filetree_debug(
      "core.open_doc request filename=%s abs=%s exists=%s type=%s size=%s",
      tostring(filename),
      tostring(abs_filename),
      tostring(file_info ~= nil),
      tostring(file_info and file_info.type),
      tostring(file_info and file_info.size)
    )
    for _, doc in ipairs(core.docs) do
      if doc.abs_filename and abs_filename == doc.abs_filename then
        log_filetree_debug(
          "core.open_doc reuse abs=%s new_file=%s",
          tostring(abs_filename),
          tostring(new_file)
        )
        return doc
      end
    end
  end
  -- no existing doc for filename; create new
  local wlpt_threshold_bytes = (config.wlpt_file_size_limit or 1) * 1024 * 1024
  local is_wlpt = file_info and file_info.size > wlpt_threshold_bytes
  local is_large = is_wlpt or (file_info and file_info.size > config.large_file_size_limit * 1e6)
  local doc_class = is_wlpt and WlPtDoc or (is_large and LargeFileDoc or Doc)
  local doc = doc_class(filename, abs_filename, new_file, is_large)
  log_filetree_debug(
    "core.open_doc created filename=%s abs=%s new_file=%s is_large=%s is_wlpt=%s doc=%s",
    tostring(filename),
    tostring(abs_filename),
    tostring(new_file),
    tostring(is_large),
    tostring(is_wlpt),
    tostring(doc)
  )
  if filename and not new_file and (is_large or is_wlpt) then
    doc:start_loading(abs_filename, file_info)
  end
  table.insert(core.docs, doc)
  core.log_quiet(filename and "Opened doc \"%s\"" or "Opened new doc", filename)
  return doc
end


function core.get_views_referencing_doc(doc)
  local res = {}
  local views = core.root_view.root_node:get_children()
  for _, view in ipairs(views) do
    if view.doc == doc then table.insert(res, view) end
  end
  return res
end


function core.custom_log(level, show, backtrace, fmt, ...)
  local text = string.format(fmt, ...)
  if show then
    local s = style.log[level]
    if core.status_view then
      core.status_view:show_message(s.icon, s.color, text)
    end
  end

  local info = debug.getinfo(2, "Sl")
  local at = string.format("%s:%d", info.short_src, info.currentline)
  local item = {
    level = level,
    text = text,
    time = os.time(),
    at = at,
    info = backtrace and debug.traceback("", 2):gsub("\t", "")
  }
  table.insert(core.log_items, item)
  if #core.log_items > config.max_log_items then
    table.remove(core.log_items, 1)
  end
  return item
end


function core.log(...)
  return core.custom_log("INFO", true, false, ...)
end


function core.log_quiet(...)
  return core.custom_log("INFO", false, false, ...)
end

function core.async_debug(fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then
    text = tostring(fmt)
  end
  local fp = io.open(USERDIR .. PATHSEP .. "async-fileload.log", "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    fp:close()
  end
end

function core.scheduler_debug(fmt, ...)
  if not config.scheduler_log then return end
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then
    text = tostring(fmt)
  end
  local fp = io.open(USERDIR .. PATHSEP .. "scheduler.log", "a")
  if fp then
    fp:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    fp:close()
  end
end

function core.warn(...)
  return core.custom_log("WARN", true, true, ...)
end

function core.error(...)
  return core.custom_log("ERROR", true, true, ...)
end


function core.get_log(i)
  if i == nil then
    local r = {}
    for _, item in ipairs(core.log_items) do
      table.insert(r, core.get_log(item))
    end
    return table.concat(r, "\n")
  end
  local item = type(i) == "number" and core.log_items[i] or i
  local text = string.format("%s [%s] %s at %s", os.date(nil, item.time), item.level, item.text, item.at)
  if item.info then
    text = string.format("%s\n%s\n", text, item.info)
  end
  return text
end


function core.try(fn, ...)
  local err
  local ok, res = xpcall(fn, function(msg)
    local item = core.error("%s", msg)
    item.info = debug.traceback("", 2):gsub("\t", "")
    err = msg
  end, ...)
  if ok then
    return true, res
  end
  return false, err
end

function core.on_event(type, ...)
  local did_keymap = false
  if type == "textinput" then
    core.root_view:on_text_input(...)
  elseif type == "textediting" then
    ime.on_text_editing(...)
  elseif type == "keypressed" then
    -- In some cases during IME composition input is still sent to us
    -- so we just ignore it.
    if ime.editing then return false end
    did_keymap = keymap.on_key_pressed(...)
  elseif type == "keyreleased" then
    keymap.on_key_released(...)
  elseif type == "mousemoved" then
    core.root_view:on_mouse_moved(...)
  elseif type == "mousepressed" then
    if not core.root_view:on_mouse_pressed(...) then
      did_keymap = keymap.on_mouse_pressed(...)
    end
  elseif type == "mousereleased" then
    core.root_view:on_mouse_released(...)
  elseif type == "mouseleft" then
    core.root_view:on_mouse_left()
  elseif type == "mousewheel" then
    if not core.root_view:on_mouse_wheel(...) then
      did_keymap = keymap.on_mouse_wheel(...)
    end
  elseif type == "touchpressed" then
    core.root_view:on_touch_pressed(...)
  elseif type == "touchreleased" then
    core.root_view:on_touch_released(...)
  elseif type == "touchmoved" then
    core.root_view:on_touch_moved(...)
  elseif type == "resized" then
    core.window_mode = system.get_window_mode(core.window)
  elseif type == "minimized" or type == "maximized" or type == "restored" then
    core.window_mode = type == "restored" and "normal" or type
  elseif type == "filedropped" then
    core.root_view:on_file_dropped(...)
  elseif type == "dialogfinished" then
    local id, status, result = ...
    local callback = core.active_file_dialogs[id]
    if not callback then
      core.error("Invalid dialog id %d", id)
    else
      core.active_file_dialogs[id] = nil
      callback(status, result)
    end
  elseif type == "focuslost" then
    core.root_view:on_focus_lost(...)
  elseif type == "quit" then
    log_quit_debug("quit.event received")
    core.quit()
  end
  return did_keymap
end


local function get_title_filename(view)
  local doc_filename = view.get_filename and view:get_filename() or view:get_name()
  if doc_filename ~= "---" then return doc_filename end
  return ""
end


function core.compose_window_title(title)
  return (title == "" or title == nil) and "lite-xxl" or title .. " - lite-xxl"
end


function core.step()
  -- handle events
  local did_keymap = false

  for type, a,b,c,d in system.poll_event do
    if type == "textinput" and did_keymap then
      did_keymap = false
    elseif type == "mousemoved" then
      core.try(core.on_event, type, a, b, c, d)
    elseif type == "enteringforeground" then
      -- to break our frame refresh in two if we get entering/entered at the same time.
      -- required to avoid flashing and refresh issues on mobile
      core.redraw = true
      break
    else
      local _, res = core.try(core.on_event, type, a, b, c, d)
      did_keymap = res or did_keymap
    end
    core.redraw = true
  end

  local width, height = core.window:get_size()

  -- update
  core.root_view.size.x, core.root_view.size.y = width, height
  core.root_view:update()
  if not core.redraw then return false end
  core.redraw = false

  -- close unreferenced docs
  for i = #core.docs, 1, -1 do
    local doc = core.docs[i]
    if #core.get_views_referencing_doc(doc) == 0 then
      log_quit_debug(
        "quit.doc_close.begin index=%d is_large=%s dirty=%s loading=%s filename=%s abs=%s",
        i,
        tostring(doc.is_large_file),
        tostring(doc:is_dirty()),
        tostring(doc.loading),
        tostring(doc.filename),
        tostring(doc.abs_filename)
      )
      table.remove(core.docs, i)
      doc:on_close()
      log_quit_debug(
        "quit.doc_close.done index=%d filename=%s remaining_docs=%d",
        i,
        tostring(doc.filename or doc.abs_filename),
        #core.docs
      )
    end
  end

  -- update window title
  local current_title = get_title_filename(core.active_view)
  if current_title ~= nil and current_title ~= core.window_title then
    system.set_window_title(core.window, core.compose_window_title(current_title))
    core.window_title = current_title
  end

  -- draw
  renderer.begin_frame(core.window)
  core.clip_rect_stack[1] = { 0, 0, width, height }
  renderer.set_clip_rect(table.unpack(core.clip_rect_stack[1]))
  core.root_view:draw()
  renderer.end_frame()
  return true
end


local run_threads = coroutine.wrap(function()
  while true do
    local max_time = 1 / config.fps - 0.004
    local minimal_time_to_wake = math.huge

    local threads = {}
    -- We modify core.threads while iterating, both by removing dead threads,
    -- and by potentially adding more threads while we yielded early,
    -- so we need to extract the threads list and iterate over that instead.
    for k, thread in pairs(core.threads) do
      threads[k] = thread
    end

    for k, thread in pairs(threads) do
      -- Run thread if it wasn't deleted externally and it's time to resume it
      if core.threads[k] and is_thread_frozen(thread) then
        if not thread.frozen_logged then
          thread.frozen_logged = true
          core.scheduler_debug(
            "thread-frozen key=%s label=%s kind=%s active=%s owner_doc=%s",
            tostring(k),
            tostring(thread.meta and thread.meta.label),
            tostring(thread.meta and thread.meta.kind),
            core.describe_view(core.active_view),
            tostring(thread.meta and thread.meta.owner_doc and thread.meta.owner_doc:get_name())
          )
        end
        minimal_time_to_wake = math.min(minimal_time_to_wake, 1 / config.fps)
      elseif core.threads[k] and thread.wake < system.get_time() then
        if thread.frozen_logged then
          thread.frozen_logged = false
          core.scheduler_debug(
            "thread-thawed key=%s label=%s active=%s",
            tostring(k),
            tostring(thread.meta and thread.meta.label),
            core.describe_view(core.active_view)
          )
        end
        local resumed_at = system.get_time()
        local _, wait = assert(coroutine.resume(thread.cr))
        local elapsed = system.get_time() - resumed_at
        local meta = thread.meta or {}
        core.thread_metrics.resumed = core.thread_metrics.resumed + 1
        core.thread_metrics.resume_time = core.thread_metrics.resume_time + elapsed
        core.thread_metrics.max_resume_time = math.max(core.thread_metrics.max_resume_time, elapsed)
        if elapsed >= config.scheduler_slow_resume_threshold then
          core.scheduler_debug(
            "thread-slow-resume key=%s label=%s kind=%s priority=%s elapsed_ms=%.3f owner=%s",
            tostring(k),
            tostring(meta.label),
            tostring(meta.kind),
            tostring(meta.priority),
            elapsed * 1000,
            core.describe_view(meta.owner_view)
          )
        end
        if coroutine.status(thread.cr) == "dead" then
          core.thread_metrics.completed = core.thread_metrics.completed + 1
          core.scheduler_debug(
            "thread-complete key=%s label=%s elapsed_ms=%.3f",
            tostring(k),
            tostring(meta.label),
            elapsed * 1000
          )
          core.threads[k] = nil
        else
          wait = wait or (1/30)
          thread.wake = system.get_time() + wait
          minimal_time_to_wake = math.min(minimal_time_to_wake, wait)
        end
      else
        if core.threads[k] and thread.frozen_logged and not is_thread_frozen(thread) then
          thread.frozen_logged = false
          core.scheduler_debug(
            "thread-thawed key=%s label=%s active=%s",
            tostring(k),
            tostring(thread.meta and thread.meta.label),
            core.describe_view(core.active_view)
          )
        end
        minimal_time_to_wake =  math.min(minimal_time_to_wake, thread.wake - system.get_time())
      end

      -- stop running threads if we're about to hit the end of frame
      if system.get_time() - core.frame_start > max_time then
        coroutine.yield(0, false)
      end
    end

    coroutine.yield(minimal_time_to_wake, true)
  end
end)


function core.run()
  local next_step
  local last_frame_time
  local run_threads_full = 0
  while true do
    core.frame_start = system.get_time()
    local time_to_wake, threads_done = run_threads()
    if threads_done then
      run_threads_full = run_threads_full + 1
    end
    local did_redraw = false
    local did_step = false
    local force_draw = core.redraw and last_frame_time and core.frame_start - last_frame_time > (1 / config.fps)
    if force_draw or not next_step or system.get_time() >= next_step then
      if core.step() then
        did_redraw = true
        last_frame_time = core.frame_start
      end
      next_step = nil
      did_step = true
    end
    if core.restart_request or core.quit_request then break end

    if not did_redraw then
      if system.window_has_focus(core.window) or not did_step or run_threads_full < 2 then
        local now = system.get_time()
        if not next_step then -- compute the time until the next blink
          local t = now - core.blink_start
          local h = config.blink_period / 2
          local dt = math.ceil(t / h) * h - t
          local cursor_time_to_wake = dt + 1 / config.fps
          next_step = now + cursor_time_to_wake
        end
        if system.wait_event(math.min(next_step - now, time_to_wake)) then
          next_step = nil -- if we've recevied an event, perform a step
        end
      else
        system.wait_event()
        next_step = nil -- perform a step when we're not in focus if get we an event
      end
    else -- if we redrew, then make sure we only draw at most FPS/sec
      run_threads_full = 0
      local now = system.get_time()
      local elapsed = now - core.frame_start
      local next_frame = math.max(0, 1 / config.fps - elapsed)
      next_step = next_step or (now + next_frame)
      system.sleep(math.min(next_frame, time_to_wake))
    end
  end
  log_quit_debug(
    "quit.run.break restart_request=%s quit_request=%s remaining_docs=%d threads=%s",
    tostring(core.restart_request),
    tostring(core.quit_request),
    #(core.docs or {}),
    tostring(core.threads and next(core.threads) ~= nil)
  )
end


function core.blink_reset()
  core.blink_start = system.get_time()
end


local last_file_dialog_tag = 0
local function open_dialog(type, window, callback, options)
  local types = {
    ["openfile"] = system.open_file_dialog,
    ["opendirectory"] = system.open_directory_dialog,
    ["savefile"] = system.save_file_dialog,
  }

  local dialog_fn = types[type]
  assert(dialog_fn, "Invalid dialog type")

  last_file_dialog_tag = last_file_dialog_tag + 1
  core.active_file_dialogs[last_file_dialog_tag] = callback
  dialog_fn(window, last_file_dialog_tag, options)
end

---Open the system file picker.
---
---Returns immediately.
---The callback will be called with the result.
---
---@param window renwindow
---@param callback fun(status: "accept"|"cancel"|"error"|"unknown", result: string[]|string|nil)
---@param options? system.dialogoptions.openfile
function core.open_file_dialog(window, callback, options)
  return open_dialog("openfile", window, callback, options)
end

---Open the system directory picker.
---
---Returns immediately.
---The callback will be called with the result.
---
---@param window renwindow
---@param callback fun(status: "accept"|"cancel"|"error"|"unknown", result: string[]|string|nil)
---@param options? system.dialogoptions.opendirectory
function core.open_directory_dialog(window, callback, options)
  return open_dialog("opendirectory", window, callback, options)
end

---Open the system save file picker.
---
---Returns immediately.
---The callback will be called with the result.
---
---@param window renwindow
---@param callback fun(status: "accept"|"cancel"|"error"|"unknown", result: string[]|string|nil)
---@param options? system.dialogoptions.savefile
function core.save_file_dialog(window, callback, options)
  return open_dialog("savefile", window, callback, options)
end


function core.request_cursor(value)
  core.cursor_change_req = value
end


function core.on_error(err)
  -- write error to file
  local fp = io.open(USERDIR .. PATHSEP .. "error.txt", "wb")
  fp:write("Error: " .. tostring(err) .. "\n")
  fp:write(debug.traceback("", 4) .. "\n")
  fp:close()
  -- save copy of all unsaved documents
  for _, doc in ipairs(core.docs) do
    if doc:is_dirty() and doc.filename then
      doc:save(doc.filename .. "~")
    end
  end
end


local alerted_deprecations = {}
---Show deprecation notice once per `kind`.
---
---@param kind string
function core.deprecation_log(kind)
  if alerted_deprecations[kind] then return end
  alerted_deprecations[kind] = true
  core.warn("Used deprecated functionality [%s]. Check if your plugins are up to date.", kind)
end


return core
