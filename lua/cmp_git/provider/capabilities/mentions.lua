local command = require("cmp_git.command")
local format = require("cmp_git.format")
local issues = require("cmp_git.provider.capabilities.issues")

local M = {}

---The most users that the REST APIs give on one page.
local MAX_PAGE_SIZE = 100

---A fetch of the pages of mentions. The requests that wait for it share it.
---@class cmp_git.Provider.MentionFetch
---@field items table[] The raw users of the pages so far.
---@field subscribers cmp_git.Provider.MentionSubscriber[]
---@field active? cmp_git.SystemJob
---@field cancelled boolean
---@field done boolean

---A request that waits for the pages of a fetch. Each request formats the users with its own config.
---@class cmp_git.Provider.MentionSubscriber
---@field callback fun(list: cmp_git.CompletionList)
---@field config table
---@field trigger_char string

---@param subscribers cmp_git.Provider.MentionSubscriber[]
---@param items table[] The raw users.
---@param incomplete boolean
local function notify(subscribers, items, incomplete)
    -- A copy, because a callback can cancel its request
    for _, subscriber in ipairs(vim.list_extend({}, subscribers)) do
        subscriber.callback({
            items = format.items(subscriber.config, subscriber.trigger_char, items),
            isIncomplete = incomplete,
        })
    end
end

---Add a request to a fetch of the entry. The fetch stops when all its requests are cancelled.
---@param entry cmp_git.CacheEntry
---@param fetch cmp_git.Provider.MentionFetch
---@param args cmp_git.Provider.CapabilityArgs
local function subscribe(entry, fetch, args)
    local subscriber = { callback = args.callback, config = args.config, trigger_char = args.trigger_char }
    table.insert(fetch.subscribers, subscriber)

    return {
        command = "mentions",
        cancel = function()
            for i, other in ipairs(fetch.subscribers) do
                if other == subscriber then
                    table.remove(fetch.subscribers, i)
                    break
                end
            end
            if #fetch.subscribers > 0 or fetch.cancelled or fetch.done then
                return
            end

            -- Otherwise the entry keeps the fetch, and later requests wait for pages that never come
            fetch.cancelled = true
            if entry.fetch == fetch then
                entry.fetch = nil
            end
            if fetch.active and fetch.active.cancel then
                fetch.active:cancel()
            end
        end,
    }
end

---Get the pages of users into `fetch.items`.
---@param args cmp_git.Provider.RefreshArgs
---@param fetch cmp_git.Provider.MentionFetch
---@param on_page fun() Runs after each page before the last.
---@param on_done fun(success: boolean) Runs once after the last page or a failure, unless the fetch is cancelled.
local function start_fetch(args, fetch, on_page, on_done)
    local runner = args.runner or command
    local limit = args.config.limit
    -- A constant page size, so that page N starts after the users of the pages before it
    local page_size = math.min(limit, MAX_PAGE_SIZE)

    ---@param success boolean
    local function finish(success)
        fetch.done = true
        fetch.active = nil
        on_done(success)
    end

    if limit < 1 then
        finish(true)
        return
    end

    ---@param build_request fun(git_info: cmp_git.GitInfo, trigger_char: string, config: table, opts: table): table?
    ---@param page integer
    ---@param context any
    ---@param on_last fun(success: boolean) Runs after the last page or a failure.
    ---@param request? table The request of `page`, when the caller already built it.
    local function fetch_page(build_request, page, context, on_last, request)
        request = request
            or build_request(args.git_info, args.trigger_char, args.config, {
                context = context,
                page = page,
                page_size = page_size,
            })
        ---@cast request -nil

        local job = runner.build_fallback_list(request.commands, function(list, success)
            if fetch.cancelled then
                return
            end
            if not success then
                on_last(false)
                return
            end

            local items = vim.list_extend(vim.list_extend({}, fetch.items), issues.raw_items(list.items))
            local has_more
            if build_request == args.adapter.mentions_request and args.adapter.mentions_has_more then
                has_more = args.adapter.mentions_has_more(list, items, args.config, context)
            else
                -- A page that is not full is the last one. Asking for the next page would wait for an empty one.
                has_more = #list.items >= page_size
            end
            if #items >= limit then
                has_more = false
                for i = #items, limit + 1, -1 do
                    items[i] = nil
                end
            end
            fetch.items = items

            if not has_more then
                on_last(true)
                return
            end

            on_page()
            fetch_page(build_request, page + 1, context, on_last)
        end, request.handle_item, request.handle_parsed)

        if not job then
            on_last(false)
            return
        end
        fetch.active = job
        job:start()
    end

    ---Get the users, then the extra mentions of the adapter, such as the teams of a GitHub organization.
    local function fetch_mentions(context)
        fetch_page(args.adapter.mentions_request, 1, context, function(success)
            local build_extra = args.adapter.mentions_extra_request
            local extra = success
                and #fetch.items < limit
                and build_extra
                and build_extra(args.git_info, args.trigger_char, args.config, {
                    context = context,
                    page = 1,
                    page_size = page_size,
                })
            if not extra then
                finish(success)
                return
            end

            on_page()
            -- The extra mentions are optional: a failure, for example for a repository of a user and not of an
            -- organization, keeps the users and still caches them
            fetch_page(build_extra, 1, context, function()
                finish(true)
            end, extra)
        end)
    end

    local preflight = args.adapter.mentions_preflight_request
        and args.adapter.mentions_preflight_request(args.git_info, args.trigger_char, args.config)
    if not preflight then
        fetch_mentions(nil)
        return
    end

    local job = runner.build_fallback(preflight.commands, function(result, success)
        if fetch.cancelled then
            return
        end

        -- `handle_result` also gets a failed preflight, and chooses the users to ask for
        local context = nil
        if preflight.handle_result then
            context = preflight.handle_result(result, success)
        end
        fetch_mentions(context)
    end)

    if not job then
        fetch_mentions(nil)
        return
    end
    fetch.active = job
    job:start()
end

---@return cmp_git.Provider.MentionFetch
local function new_fetch()
    return { items = {}, subscribers = {}, cancelled = false, done = false }
end

---Give the mentions of the remote. The callback gets a list with `isIncomplete = true` for each page before the last,
---then exactly one list with `isIncomplete = false`, unless the request is cancelled. A request during a fetch joins
---it.
---@param args cmp_git.Provider.CapabilityArgs
---@return { command: string, cancel: fun() }? controller nil when the callback already has its final list.
function M.complete(args)
    if issues.from_cache(args) then
        return nil
    end

    local entry = args.cache
    local fetch = entry.fetch
    if fetch then
        if #fetch.items > 0 then
            args.callback({ items = format.items(args.config, args.trigger_char, fetch.items), isIncomplete = true })
        end
        return subscribe(entry, fetch, args)
    end

    fetch = new_fetch()
    entry.fetch = fetch
    local controller = subscribe(entry, fetch, args)
    start_fetch(args, fetch, function()
        notify(fetch.subscribers, fetch.items, true)
    end, function(success)
        if entry.fetch == fetch then
            entry.fetch = nil
        end
        -- A failure is not cached, so that the next request tries again. The pages before it are still shown.
        if success then
            entry:set(fetch.items)
        end
        local subscribers = fetch.subscribers
        fetch.subscribers = {}
        notify(subscribers, fetch.items, false)
    end)
    return controller
end

---Get all pages for the cache only.
---@param args cmp_git.Provider.RefreshArgs
---@param done fun(items: table[]?) Gets the raw users, or nil when a page fails.
function M.refresh(args, done)
    local fetch = new_fetch()
    start_fetch(args, fetch, function() end, function(success)
        done(success and fetch.items or nil)
    end)
end

return M
