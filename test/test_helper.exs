# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# The CMS's application supervisor owns these; running the extension's suite on its own means
# starting the ones a JSON API request actually touches, and nothing more:
#
#   Repo                 the database, named by the resources (see the test-only `MishkaBlog.Repo`)
#   PubSub               resources broadcast on write through their `pub_sub` blocks
#   SiteState            ETS host index — the tenant plug resolves a request's site through it
#   SettingsState        ETS settings cache, read while rendering and authorizing
#   TranslationsState    ETS cache of the words runtime templates ask t/1 for
#   ViewerState          ETS cache of who a signed-in user is to the site gates
#   RateLimitState       ETS counters signing in is limited by, hit on every sign-in
#   AshAuthentication    token signing and verification for the bearer flow
#   TestEndpoint         the endpoint the requests are made against
#
# Left out deliberately: Oban, the compilers, the asset and page-builder caches and BootHandler. They
# belong to running a site, not to answering an API call, and starting them would make this suite
# depend on machinery it never exercises.
# Oban's tables are not an Ash resource, so `mix ash.codegen` never emits them. Create them before
# anything that enqueues starts — see `MishkaBlog.Test.ObanMigration`.
{:ok, _} = MishkaBlog.Repo.start_link()
Ecto.Migrator.up(MishkaBlog.Repo, 0, MishkaBlog.Test.ObanMigration, log: false)
:ok = Supervisor.stop(MishkaBlog.Repo)

# THE COUNTER THE PARTITION SUPERVISOR PICKS A PARTITION WITH. `ModuleCompilerHandler` reads it
# from `:persistent_term` on every compile, and the CMS's own application puts it there at boot —
# so a suite that compiles components has to put it there itself.
:persistent_term.put(:module_compiler_partition_counter, :atomics.new(1, signed: false))

children = [
  MishkaBlog.Repo,
  {Oban, Application.fetch_env!(:mishka_blog, Oban)},
  {Phoenix.PubSub, name: MishkaCmsCore.PubSub},
  MishkaCmsCore.Runtime.States.SiteState,
  MishkaCmsCore.Runtime.States.SettingsState,
  MishkaCmsCore.Runtime.States.TranslationsState,
  MishkaCmsCore.Runtime.States.ViewerState,
  MishkaCmsCore.Runtime.States.RateLimitState,
  # THE ONE ASSET CACHE THIS SUITE STARTS, the sitemap's store.
  # `MishkaBlog.Plugins.SitemapUrlsTest` reads what this extension adds to a sitemap
  # the way core's build reads it, and the build keeps the sitemap it makes there.
  MishkaCmsCore.Runtime.States.AssetsState,
  # THIS EXTENSION SHIPS COMPONENTS NOW, and a component is only a row until something compiles it.
  # `MishkaBlog.LiveComponentsRenderTest` renders the four out of the database for real — the same
  # lazy compile a visitor's first request triggers — and that needs the gate, the registry that
  # names each compile, and the supervisor those compiles run under. The CMS's own suite starts the
  # same three for the same reason.
  #
  # Everything else the comment at the top of this file leaves out stays out: these three are what
  # rendering a stored component costs, and nothing more.
  MishkaCmsCore.Runtime.Handlers.CompileGate,
  {Registry, keys: :unique, name: MishkaCms.ModuleCompilerHandlerRegistry},
  {PartitionSupervisor,
   child_spec: DynamicSupervisor,
   name: MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandlerPartition,
   partitions: System.schedulers_online()},
  {AshAuthentication.Supervisor, [otp_app: :mishka_blog]},
  MishkaBlog.TestEndpoint
]

{:ok, _} =
  Supervisor.start_link(children, strategy: :one_for_one, name: MishkaBlog.TestSupervisor)

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

# The run starts once the core's plugins and this extension's own are live — the sidebar entry every
# blog admin page reads its permission from among them. See `MishkaBlog.Test.PluginReadiness`.
MishkaBlog.Test.PluginReadiness.await(
  MishkaCmsCore.Application.plugins() ++ MishkaBlog.Application.plugins()
)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(MishkaBlog.Repo, :manual)
