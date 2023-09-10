local InstallContext = require "mason-core.installer.context"
local Result = require "mason-core.result"
local a = require "mason-core.async"
local fs = require "mason-core.fs"
local installer = require "mason-core.installer"
local match = require "luassert.match"
local path = require "mason-core.path"
local spy = require "luassert.spy"
local stub = require "luassert.stub"

local function timestamp()
    local seconds, microseconds = vim.loop.gettimeofday()
    return (seconds * 1000) + math.floor(microseconds / 1000)
end

describe("installer", function()
    before_each(function()
        package.loaded["dummy_package"] = nil
    end)

    it(
        "should call installer",
        async_test(function()
            spy.on(fs.async, "mkdirp")
            spy.on(fs.async, "rename")

            local handle = InstallHandleGenerator "dummy"
            spy.on(handle.package.spec.source, "install")
            local result = installer.execute(handle, {})

            assert.is_nil(result:err_or_nil())
            assert.spy(handle.package.spec.source.install).was_called(1)
            assert
                .spy(handle.package.spec.source.install)
                .was_called_with(match.instanceof(InstallContext), match.is_table())
            assert.spy(fs.async.mkdirp).was_called_with(path.package_build_prefix "dummy")
            assert.spy(fs.async.rename).was_called_with(path.package_build_prefix "dummy", path.package_prefix "dummy")
        end)
    )

    it(
        "should return failure if installer errors",
        async_test(function()
            spy.on(fs.async, "rmrf")
            spy.on(fs.async, "rename")
            local installer_fn = spy.new(function()
                error("something went wrong. don't try again.", 0)
            end)
            local handler = InstallHandleGenerator "dummy"
            stub(handler.package.spec.source, "install", installer_fn)
            local result = installer.execute(handler, {})
            assert.spy(installer_fn).was_called(1)
            assert.is_true(result:is_failure())
            assert.equals("something went wrong. don't try again.", result:err_or_nil())
            assert.spy(fs.async.rmrf).was_called_with(path.package_build_prefix "dummy")
            assert.spy(fs.async.rename).was_not_called()
        end)
    )

    it(
        "should write receipt",
        async_test(function()
            spy.on(fs.async, "write_file")
            local handle = InstallHandleGenerator "dummy"
            stub(handle.package.spec.source, "install", function(ctx)
                ctx.fs:write_file("target", "")
                ctx.fs:write_file("file.jar", "")
                ctx.fs:write_file("opt-cmd", "")
            end)
            handle.package.spec.bin = {
                ["executable"] = "target",
            }
            handle.package.spec.share = {
                ["package/file.jar"] = "file.jar",
            }
            handle.package.spec.opt = {
                ["package/bin/opt-cmd"] = "opt-cmd",
            }
            installer.execute(handle, {})
            handle.package.spec.bin = {}
            handle.package.spec.share = {}
            handle.package.spec.opt = {}
            assert.spy(fs.async.write_file).was_called_with(
                ("%s/mason-receipt.json"):format(handle.package:get_install_path()),
                match.capture(function(arg)
                    ---@type InstallReceipt
                    local receipt = vim.json.decode(arg)
                    assert.is_true(match.tbl_containing {
                        name = "dummy",
                        primary_source = match.same {
                            type = handle.package.spec.schema,
                            id = handle.package.spec.source.id,
                        },
                        secondary_sources = match.same {},
                        schema_version = "1.1",
                        metrics = match.is_table(),
                        links = match.same {
                            bin = { executable = "target" },
                            share = { ["package/file.jar"] = "file.jar" },
                            opt = { ["package/bin/opt-cmd"] = "opt-cmd" },
                        },
                    }(receipt))
                end)
            )
        end)
    )

    it(
        "should run async functions concurrently",
        async_test(function()
            spy.on(fs.async, "write_file")
            local capture = spy.new()
            local start = timestamp()
            local handle = InstallHandleGenerator "dummy"
            stub(handle.package.spec.source, "install", function(ctx)
                capture(installer.run_concurrently {
                    function()
                        a.sleep(100)
                        return installer.context()
                    end,
                    function()
                        a.sleep(100)
                        return "two"
                    end,
                    function()
                        a.sleep(100)
                        return "three"
                    end,
                })
            end)
            installer.execute(handle, {})
            local stop = timestamp()
            local grace_ms = 25
            assert.is_true((stop - start) >= (100 - grace_ms))
            assert.spy(capture).was_called_with(match.instanceof(InstallContext), "two", "three")
        end)
    )

    it(
        "should write log files if debug is true",
        async_test(function()
            spy.on(fs.async, "write_file")
            local handle = InstallHandleGenerator "dummy"
            stub(handle.package.spec.source, "install", function(ctx)
                ctx.stdio_sink.stdout "Hello stdout!\n"
                ctx.stdio_sink.stderr "Hello "
                ctx.stdio_sink.stderr "stderr!"
            end)
            installer.execute(handle, { debug = true })
            assert
                .spy(fs.async.write_file)
                .was_called_with(path.package_prefix "dummy/mason-debug.log", "Hello stdout!\nHello stderr!")
        end)
    )

    it(
        "should raise spawn errors in strict mode",
        async_test(function()
            local handle = InstallHandleGenerator "dummy"
            stub(handle.package.spec.source, "install", function(ctx)
                ctx.spawn.bash { "-c", "exit 42" }
            end)
            local result = installer.execute(handle, { debug = true })
            assert.same(
                Result.failure {
                    exit_code = 42,
                    signal = 0,
                },
                result
            )
            assert.equals("spawn: bash failed with exit code 42 and signal 0. ", tostring(result:err_or_nil()))
        end)
    )

    it(
        "should lock package",
        async_test(function()
            local handle = InstallHandleGenerator "dummy"
            local callback = spy.new()
            stub(handle.package.spec.source, "install", function()
                a.sleep(3000)
            end)

            a.run(function()
                return installer.execute(handle, { debug = true })
            end, callback)

            assert.wait_for(function()
                assert.is_true(fs.sync.file_exists(path.package_lock "dummy"))
            end)
            handle:terminate()
            assert.wait_for(function()
                assert.spy(callback).was_called(1)
            end)
            assert.is_false(fs.sync.file_exists(path.package_lock "dummy"))
        end)
    )

    it(
        "should not run installer if package lock exists",
        async_test(function()
            local handle = InstallHandleGenerator "dummy"
            local install = spy.new()
            stub(handle.package.spec.source, "install", install)

            fs.sync.write_file(path.package_lock "dummy", "dummypid")
            local result = installer.execute(handle, { debug = true })
            assert.is_true(fs.sync.file_exists(path.package_lock "dummy"))
            fs.sync.unlink(path.package_lock "dummy")

            assert.spy(install).was_not_called()
            assert.equals(
                "Lockfile exists, installation is already running in another process (pid: dummypid). Run with :MasonInstall --force to bypass.",
                result:err_or_nil()
            )
        end)
    )
end)
