local format = require("cmp_git.format")

local M = {}

---An issue from `gh issue list --json` or the REST API.
---@class cmp_git.GitHub.Issue
---@field number integer
---@field title string
---@field body string
---@field updatedAt string
---@field updated_at? string The name of `updatedAt` in the REST API.
---@field state string

---A pull request from `gh pr list --json` or the REST API.
---@class cmp_git.GitHub.PullRequest: cmp_git.GitHub.Issue

---A user from the collaborators or contributors API.
---@class cmp_git.GitHub.Mention
---@field login string

---A team of the organization that owns the repository, from the teams API. It has no `login`.
---Reference: https://docs.github.com/en/rest/teams/teams#list-teams
---@class cmp_git.GitHub.Team
---@field name string
---@field slug string The handle of the team in `@org/slug`.
---@field organization string
---@field description string

---A user from the users API.
---Reference: https://docs.github.com/en/rest/users/users#get-a-user
---@class cmp_git.GitHub.User
---@field login string
---@field name string|vim.NIL|nil
---@field company string|vim.NIL|nil
---@field email string|vim.NIL|nil
---@field bio string|vim.NIL|nil
---@field location string|vim.NIL|nil

local function github_url(git_host, path)
    if git_host == "github.com" then
        return string.format("https://api.github.com/%s", path)
    end

    return string.format("https://%s/api/v3/%s", git_host, path)
end

local function env()
    return {
        -- `vim.env` is nil for an unset variable. `vim.fn.getenv` gives `vim.NIL`, which the command passes as the
        -- string "vim.NIL".
        GITHUB_API_TOKEN = vim.env.GITHUB_API_TOKEN,
        CLICOLOR = 0,
    }
end

---@param curl_url string
---@param opts? { error_body?: boolean } `error_body` gives the body of an HTTP error with exit code 0.
---@return cmp_git.CommandSpec
local function curl_command(curl_url, opts)
    local args = { "-s", "-S" }
    if not (opts and opts.error_body) then
        -- Without it, curl exits with 0 on an HTTP error, and the error object looks like an empty list
        table.insert(args, "--fail")
    end
    vim.list_extend(args, {
        "-L",
        "-H",
        "Accept: application/vnd.github.v3+json",
    })
    local stdin = nil

    local token = vim.env.GITHUB_API_TOKEN
    if token and token ~= "" then
        -- `-H @-` reads the header from stdin, so that the token is not in the process list
        vim.list_extend(args, { "-H", "@-" })
        stdin = string.format("Authorization: token %s\n", token)
    end

    table.insert(args, curl_url)
    return { exec = "curl", args = args, stdin = stdin }
end

---@param item cmp_git.GitHub.Issue
local function normalize_issue(item)
    -- JSON null is `vim.NIL`, which the formats would show as the text "vim.NIL"
    if item.title == nil or item.title == vim.NIL then
        item.title = ""
    end
    if item.body ~= vim.NIL then
        item.body = string.gsub(item.body or "", "\r", "")
    else
        item.body = ""
    end

    if not item.updatedAt then
        item.updatedAt = item.updated_at
    end
end

function M.issues_request(git_info, trigger_char, config)
    local gh_args = {
        "issue",
        "list",
        "--repo",
        string.format("%s/%s/%s", git_info.host, git_info.owner, git_info.repo),
        "--limit",
        config.limit,
        "--state",
        config.state,
        "--json",
        table.concat(config.fields, ","),
    }
    local curl_path = string.format(
        "repos/%s/%s/issues?state=%s&per_page=%d&page=%d",
        git_info.owner,
        git_info.repo,
        config.state,
        config.limit,
        1
    )

    if config.filter == "mentioned" then
        gh_args = vim.list_extend(gh_args, { "--mention", "@me" })
        curl_path = string.format("%s&mentioned=@me", curl_path)
    elseif config.filter == "assigned" then
        gh_args = vim.list_extend(gh_args, { "--assignee", "@me" })
        curl_path = string.format("%s&assignee=@me", curl_path)
    elseif config.filter == "created" then
        gh_args = vim.list_extend(gh_args, { "--author", "@me" })
        curl_path = string.format("%s&creator=@me", curl_path)
    end

    return {
        commands = {
            { exec = "gh", args = gh_args, env = env() },
            curl_command(github_url(git_info.host, curl_path)),
        },
        handle_item = function(issue)
            normalize_issue(issue)
            return format.item(config, trigger_char, issue)
        end,
        -- The REST API also returns pull requests, with a `pull_request` field. `gh issue list` does not.
        handle_parsed = function(parsed)
            if not vim.islist(parsed) then
                return nil
            end

            local result = {}
            for _, issue in ipairs(parsed) do
                if issue.pull_request == nil or issue.pull_request == vim.NIL then
                    table.insert(result, issue)
                end
            end
            return result
        end,
    }
end

function M.change_requests_request(git_info, trigger_char, config)
    return {
        commands = {
            {
                exec = "gh",
                args = {
                    "pr",
                    "list",
                    "--repo",
                    string.format("%s/%s/%s", git_info.host, git_info.owner, git_info.repo),
                    "--limit",
                    config.limit,
                    "--state",
                    config.state,
                    "--json",
                    table.concat(config.fields, ","),
                },
                env = env(),
            },
            curl_command(
                github_url(
                    git_info.host,
                    string.format(
                        "repos/%s/%s/pulls?state=%s&per_page=%d&page=%d",
                        git_info.owner,
                        git_info.repo,
                        config.state,
                        config.limit,
                        1
                    )
                )
            ),
        },
        handle_item = function(pr)
            normalize_issue(pr)
            return format.item(config, trigger_char, pr)
        end,
    }
end

function M.mentions_preflight_request(git_info)
    return {
        commands = {
            {
                exec = "gh",
                args = {
                    "api",
                    string.format("repos/%s/%s/collaborators/testing/permission", git_info.owner, git_info.repo),
                    "--hostname",
                    git_info.host,
                },
                env = env(),
            },
            -- `handle_result` reads the status of an HTTP error from the body
            curl_command(
                github_url(
                    git_info.host,
                    string.format("repos/%s/%s/collaborators/testing/permission", git_info.owner, git_info.repo)
                ),
                { error_body = true }
            ),
        },
        handle_result = function(result)
            local ok, parsed = pcall(vim.json.decode, result)
            local member_type = "contributors"
            if ok and type(parsed) == "table" then
                member_type = (parsed.status ~= "403" and parsed.status ~= "401") and "collaborators" or "contributors"
            end
            return { member_type = member_type }
        end,
    }
end

function M.mentions_request(git_info, trigger_char, config, opts)
    local member_type = opts.context and opts.context.member_type or "contributors"
    return {
        commands = {
            {
                exec = "gh",
                args = {
                    "api",
                    string.format(
                        "repos/%s/%s/%s?per_page=%d&page=%d",
                        git_info.owner,
                        git_info.repo,
                        member_type,
                        opts.page_size,
                        opts.page
                    ),
                    "--hostname",
                    git_info.host,
                },
                env = env(),
            },
            curl_command(
                github_url(
                    git_info.host,
                    string.format(
                        "repos/%s/%s/%s?per_page=%d&page=%d",
                        git_info.owner,
                        git_info.repo,
                        member_type,
                        opts.page_size,
                        opts.page
                    )
                )
            ),
        },
        handle_item = function(mention)
            return format.item(config, trigger_char, mention)
        end,
        handle_parsed = function(parsed)
            if type(parsed) == "table" and parsed["mentionableUsers"] then
                return parsed["mentionableUsers"]
            end
            return parsed
        end,
    }
end

---The teams of the organization after its users. Only a collaborator can list them, so they follow the collaborators
---and not the contributors.
function M.mentions_extra_request(git_info, trigger_char, config, opts)
    local member_type = opts.context and opts.context.member_type
    if not config.fetch_teams or member_type ~= "collaborators" then
        return nil
    end

    local path = string.format("orgs/%s/teams?per_page=%d&page=%d", git_info.owner, opts.page_size, opts.page)
    return {
        commands = {
            { exec = "gh", args = { "api", path, "--hostname", git_info.host }, env = env() },
            curl_command(github_url(git_info.host, path)),
        },
        handle_item = function(team)
            ---@type cmp_git.GitHub.Team
            local item = {
                name = team.name,
                slug = team.slug,
                organization = git_info.owner,
                -- JSON null is `vim.NIL`, which the format would show as the text "vim.NIL"
                description = type(team.description) == "string" and team.description or "",
            }
            return format.item(config, trigger_char, item)
        end,
    }
end

---@param git_info cmp_git.GitInfo
---@param login string
function M.user_request(git_info, login)
    local path = string.format("users/%s", login)
    return {
        commands = {
            { exec = "gh", args = { "api", path, "--hostname", git_info.host }, env = env() },
            curl_command(github_url(git_info.host, path)),
        },
    }
end

return M
