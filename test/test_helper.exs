# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# The CMS's application supervisor owns the runtime around the core; running the extension's suite on
# its own means starting it here, and the core ships the harness that does: `MishkaCmsCore.Test.Boot`
# creates Oban's tables (they are not an Ash resource, so `mix ash.codegen` never emits them), then
# starts the repo, Oban, the core's caches and runtime compiler, AshAuthentication and the endpoint,
# the way a host starts them. The core's own application has already started `MishkaCmsCore.PubSub`,
# the partition counter the compiler picks a partition with, and `mishka_installer`'s registry.
#
# THE RUN STARTS ONCE THE CORE'S PLUGINS AND THIS EXTENSION'S OWN ARE LIVE — the sidebar entry every
# blog admin page reads its permission from among them. Without the wait the first tests of a run find
# no `MishkaBlogWeb.SidebarMenu` on `"sidebar:menus"`, so every blog admin page declares no permission
# and refuses its admin.
#
# A TEST PLUGIN THAT OUTLIVED ITS RUN is swept first: `mishka_installer` keeps registrations in Mnesia,
# on disk, so a suite killed part-way leaves one of `MishkaBlog.Test.Plugins` registered and every
# later run boots with it live.
:ok =
  MishkaCmsCore.Test.Boot.start!(
    otp_app: :mishka_blog,
    repo: MishkaBlog.Repo,
    endpoint: MishkaBlog.TestEndpoint,
    plugins: MishkaCmsCore.Application.plugins() ++ MishkaBlog.Application.plugins(),
    sweep: ["Elixir.MishkaBlog.Test.Plugins."]
  )

# `render_async/1` WAITS THIS LONG, and 100ms is not a number anybody here chose. LiveView's
# default is `Application.fetch_env!(:ex_unit, :assert_receive_timeout)`, and every `render_async`
# in these suites is waiting on a real database load — the editor's `start_async` record fetch,
# most of them. On a machine running another suite beside this one that load takes longer than
# 100ms, and the test fails with "expected async processes to finish within 100ms" from a line that
# was asserting something else entirely.
#
# Raising it here rather than at 156 call sites: it is the knob LiveView itself reads, it covers
# every future `render_async` without anyone remembering, and it costs nothing on a passing run —
# a longer timeout only delays FAILURES, never successes.
ExUnit.configure(assert_receive_timeout: 1_000)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(MishkaBlog.Repo, :manual)
