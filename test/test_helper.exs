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

children = [
  MishkaBlog.Repo,
  {Oban, Application.fetch_env!(:mishka_blog, Oban)},
  {Phoenix.PubSub, name: MishkaCmsCore.PubSub},
  MishkaCmsCore.Runtime.States.SiteState,
  MishkaCmsCore.Runtime.States.SettingsState,
  MishkaCmsCore.Runtime.States.TranslationsState,
  MishkaCmsCore.Runtime.States.ViewerState,
  MishkaCmsCore.Runtime.States.RateLimitState,
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

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(MishkaBlog.Repo, :manual)
