local a = require("plenary.async")
local Collection = require("neogit.lib.collection")

local function update_file(file, mode, name)
  local mt, diff, has_diff
  if file then
    mt = getmetatable(file)
    has_diff = file.has_diff

    if rawget(file, "diff") then
      diff = file.diff
    end
  end

  return setmetatable({ mode = mode, name = name, has_diff = has_diff, diff = diff }, mt or {})
end

local function update_status(state)
  local git = require("neogit.lib.git")
  -- git-status outputs files relative to the cwd.
  --
  -- Save the working directory to allow resolution to absolute paths since the
  -- cwd may change after the status is refreshed and used, especially if using
  -- rooter plugins with lsp integration
  local cwd = vim.fn.getcwd()
  local result = git.cli.status.porcelain(2).branch.call():trim()

  local head = {}
  local upstream = { unmerged = { items = {} }, unpulled = { items = {} }, ref = nil }

  local untracked_files, unstaged_files, staged_files = {}, {}, {}
  local old_files_hash = {
    staged_files = Collection.new(state.staged.items or {}):key_by("name"),
    unstaged_files = Collection.new(state.unstaged.items or {}):key_by("name"),
    untracked_files = Collection.new(state.untracked.items or {}):key_by("name"),
  }

  local match_kind = "(.) (.+)"
  local match_u = "(..) (....) (%d+) (%d+) (%d+) (%d+) (%w+) (%w+) (%w+) (.+)"
  local match_1 = "(.)(.) (....) (%d+) (%d+) (%d+) (%w+) (%w+) (.+)"
  local match_2 = "(.)(.) (....) (%d+) (%d+) (%d+) (%w+) (%w+) (%a%d+) ([^\t]+)\t?(.+)"

  for _, l in ipairs(result.stdout) do
    local header, value = l:match("# ([%w%.]+) (.+)")
    if header then
      if header == "branch.head" then
        head.branch = value
      elseif header == "branch.oid" then
        head.oid = value
        head.abbrev = git.rev_parse.abbreviate_commit(value)
      elseif header == "branch.upstream" then
        upstream.ref = value

        local commit = git.log.list({ value, "--max-count=1" })[1]
        upstream.abbrev = git.rev_parse.abbreviate_commit(commit.oid)

        local remote, branch = unpack(vim.split(value, "/"))
        upstream.remote = remote
        upstream.branch = branch
      end
    else
      local kind, rest = l:match(match_kind)

      -- kinds:
      -- u = Unmerged
      -- 1 = Ordinary Entries
      -- 2 = Renamed/Copied Entries
      -- ? = Untracked
      -- ! = Ignored

      if kind == "u" then
        local mode, _, _, _, _, _, _, _, _, name = rest:match(match_u)

        table.insert(untracked_files, { mode = mode, name = name })
      elseif kind == "?" then
        table.insert(untracked_files, update_file(old_files_hash.untracked_files[rest], nil, rest))
      elseif kind == "1" then
        local mode_staged, mode_unstaged, _, _, _, _, _, _, name = rest:match(match_1)

        if mode_staged ~= "." then
          table.insert(staged_files, update_file(old_files_hash.staged_files[name], mode_staged, name))
        end

        if mode_unstaged ~= "." then
          table.insert(unstaged_files, update_file(old_files_hash.unstaged_files[name], mode_unstaged, name))
        end
      elseif kind == "2" then
        local mode_staged, mode_unstaged, _, _, _, _, _, _, _, name, orig_name = rest:match(match_2)

        local entry = { name = name }

        if mode_staged ~= "." then
          entry.mode = mode_staged
          table.insert(staged_files, entry)
        end

        if mode_unstaged ~= "." then
          entry.mode = mode_unstaged
          table.insert(unstaged_files, entry)
        end

        if orig_name ~= nil then
          entry.original_name = orig_name
        end
      end
    end
  end

  -- These are a bit hacky - because we can _partially_ refresh repo state (for now),
  -- some things need to be carried over here.
  if not state.head.branch or head.branch == state.head.branch then
    head.commit_message = state.head.commit_message
  end

  if not upstream.ref or upstream.ref == state.upstream.ref then
    upstream.commit_message = state.upstream.commit_message
  end

  if #state.upstream.unmerged.items > 0 then
    upstream.unmerged = state.upstream.unmerged
  end

  if #state.upstream.unpulled.items > 0 then
    upstream.unpulled = state.upstream.unpulled
  end

  state.cwd = cwd
  state.head = head
  state.upstream = upstream
  state.untracked.items = untracked_files
  state.unstaged.items = unstaged_files
  state.staged.items = staged_files
end

local function update_branch_information(state)
  local git = require("neogit.lib.git")

  local tasks = {}

  if state.head.oid ~= "(initial)" then
    table.insert(tasks, function()
      local result = git.cli.log.max_count(1).pretty("%B").call():trim()
      state.head.commit_message = result.stdout[1]
    end)

    if state.upstream.ref then
      table.insert(tasks, function()
        local commit = git.log.list({ state.upstream.ref, "--max-count=1" })[1]
        -- May be done earlier by `update_status`, but this function can be called separately
        if commit then
          state.upstream.commit_message = commit.message
          state.upstream.abbrev = git.rev_parse.abbreviate_commit(commit.oid)
        end
      end)
    end

    local pushRemote = require("neogit.lib.git").branch.pushRemote_ref()
    if pushRemote and not git.branch.is_detached() then
      table.insert(tasks, function()
        local commit = git.log.list({ pushRemote, "--max-count=1" })[1]
        if commit then
          state.pushRemote.commit_message = commit.message
          state.pushRemote.abbrev = git.rev_parse.abbreviate_commit(commit.oid)
        end
      end)
    end
  end

  if #tasks > 0 then
    a.util.join(tasks)
  end
end

local git = { cli = require("neogit.lib.git.cli") }
local status = {
  stage = function(...)
    git.cli.add.files(...).call()
  end,
  stage_modified = function()
    git.cli.add.update.call()
  end,
  stage_all = function()
    git.cli.add.all.call()
  end,
  unstage = function(...)
    git.cli.reset.files(...).call()
  end,
  unstage_all = function()
    git.cli.reset.call()
  end,
  is_dirty = function()
    local repo = require("neogit.lib.git.repository")
    return #repo.staged.items > 0 or #repo.unstaged.items > 0
  end,
  anything_staged = function()
    return #require("neogit.lib.git.repository").staged.items > 0
  end,
  anything_unstaged = function()
    return #require("neogit.lib.git.repository").unstaged.items > 0
  end,
}

status.register = function(meta)
  meta.update_status = update_status
  meta.update_branch_information = update_branch_information
end

return status
