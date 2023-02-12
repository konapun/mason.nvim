local installer = require "mason-core.installer"
local _ = require "mason-core.functional"
local path = require "mason-core.path"
local Result = require "mason-core.result"
local spawn = require "mason-core.spawn"
local Optional = require "mason-core.optional"
local platform = require "mason-core.platform"

local M = {}

---@param package string
local function with_receipt(package)
    return function()
        local ctx = installer.context()
        ctx.receipt:with_primary_source(ctx.receipt.raco(package))
    end
end

---@param package string The luarock package to install.
---@param opts { dev: boolean?, server: string?, bin: string[]? }?
function M.package(package, opts)
    return function()
        return M.install(package, opts).with_receipt()
    end
end

---@async
---@param pkg string: The luarock package to install.
---@param opts { dev: boolean?, server: string?, bin: string[]? }?
function M.install(pkg, opts)
    opts = opts or {}
    local ctx = installer.context()
    ctx:promote_cwd()
    ctx.spawn.luarocks {
        "install",
        "--tree",
        ctx.cwd:get(),
        opts.dev and "--dev" or vim.NIL,
        opts.server and ("--server=%s"):format(opts.server) or vim.NIL,
        pkg,
        ctx.requested_version:or_else(vim.NIL),
    }
    if opts.bin then
        _.each(function(executable)
            ctx:link_bin(executable, create_bin_path(executable))
        end, opts.bin)
    end
    return {
        with_receipt = with_receipt(pkg),
    }
end

function M.get_installed_primary_package_version(receipt, install_dir)
    if receipt.primary_source.type ~= "luarocks" then
        return Result.failure "Receipt does not have a primary source of type luarocks"
    end
    local primary_package = receipt.primary_source.package
    return spawn
        .luarocks({
            "list",
            "--tree",
            install_dir,
            "--porcelain",
        })
        :map_catching(function(result)
            local luarocks = M.parse_installed_rocks(result.stdout)
            return Optional.of_nilable(_.find_first(_.prop_eq("package", primary_package), luarocks))
                :map(_.prop "version")
                :or_else_throw()
        end)
end

---@async
---@param receipt InstallReceipt<InstallReceiptPackageSource>
---@param install_dir string
function M.check_outdated_primary_package(receipt, install_dir)
    local normalized_pkg_name = M.parse_package_mod(receipt.primary_source.package)
    return spawn
        .go({
            "list",
            "-json",
            "-m",
            ("%s@latest"):format(normalized_pkg_name),
            cwd = install_dir,
        })
        :map_catching(function(result)
            ---@type {Path: string, Version: string}
            local output = vim.json.decode(result.stdout)
            return Optional.of_nilable(output.Version)
                :map(function(latest_version)
                    local installed_version = M.get_installed_primary_package_version(receipt, install_dir)
                        :get_or_throw()
                    if installed_version ~= latest_version then
                        return {
                            name = normalized_pkg_name,
                            current_version = assert(installed_version, "missing installed_version"),
                            latest_version = assert(latest_version, "missing latest_version"),
                        }
                    end
                end)
                :or_else_throw "Primary package is not outdated."
        end)
end

return M
