# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.AgentOperations do
  @moduledoc """
  The blog's operations an agent receipt can be kept for, on the core's `agent:operations` event
  (`MishkaCmsCore.Agent.Operation`). Run one with `MishkaCmsCore.Agent.Receipts.run/3`:

      post
      |> Ash.Changeset.for_update(:publish, %{}, actor: admin, tenant: site.id)
      |> MishkaCmsCore.Agent.Receipts.run("blog:blog_post:publish", source: :agent)

  Each operation is one action and its master twin. Its receipt is read by whoever holds the posts
  area (`admin:dashboard:blog:post`, `admin:api:blog:post`) on that site, and is `:verified` when
  the action committed and a separate read of the row finds what the action is for.

  ## Posts

  | Operation | Read back from the table | Also checked |
  |---|---|---|
  | `blog:blog_post:create` | the title, slug, status and language the action returned | broadcast, sitemap job |
  | `blog:blog_post:update` | the title, slug, status and language the action returned | broadcast, sitemap job |
  | `blog:blog_post:publish` | `published`, with a publication time | broadcast, sitemap job and build, share-card job and look, the site's feeds dropped, a LiveView that saw it |
  | `blog:blog_post:unpublish` | `draft`, with no publication time and no schedule | broadcast, sitemap job |
  | `blog:blog_post:schedule` | `scheduled`, with a time | broadcast (the master twin only publishes one), sitemap job, and that the host's crontab runs the job that publishes it at its time (below) |
  | `blog:blog_post:destroy` | archived | broadcast, sitemap job |
  | `blog:blog_post:unarchive` | not archived | broadcast, sitemap job |
  | `blog:blog_post:permanent_destroy` | gone | broadcast, sitemap job |
  | `blog:blog_post:restore_version` | the title, slug and status the action returned | broadcast, sitemap job |

  A scheduled post is published at its time by `MishkaBlog.Workers.PublishScheduledWorker`, which
  the host runs on its Oban crontab. That publish comes later than the receipt, so
  `:published_when_due` checks only that the worker is on the crontab of the running Oban: when it is
  not (`:not_on_crontab`), nothing will publish the post and the receipt is `:partial`.

  ## Categories and tags

  `blog:collection:*` and `blog:tag:*` for `create`, `update`, `destroy`, `unarchive` and
  `permanent_destroy`: the row read back (the name and slug the action returned, archived, not
  archived, gone) and the broadcast.

  Reads, views, ratings, bookmarks, comments and followers are not operations here: they are many,
  cheap to repeat and would push the writes that matter out of the bounded store.
  """
  use MishkaCmsCore.Agent.Operation

  alias MishkaBlog.{BlogPost, Collection, Feeds, ShareCards, Tag}
  alias MishkaBlog.Workers.PublishScheduledWorker
  alias MishkaCmsCore.Agent.Operation
  alias MishkaCmsCore.Agent.Stages.{JobDone, JobEnqueued}
  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Runtime.States.AssetsState
  alias MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker

  @visibility ["admin:dashboard:blog:post", "admin:api:blog:post"]
  @required [:action_committed, :db_read_back]

  @written [:dispatched, :validated, :action_committed]

  @post_stages %{
    create: [
      {:db_read_back,
       expect: [title: :claimed, slug: :claimed, status: :claimed, language: :claimed]}
    ],
    update: [
      {:db_read_back,
       expect: [title: :claimed, slug: :claimed, status: :claimed, language: :claimed]}
    ],
    publish: [{:db_read_back, expect: [status: :published, published_at: :present]}],
    unpublish: [
      {:db_read_back,
       expect: [status: :draft, published_at: :absent, scheduled_publish_at: :absent]}
    ],
    schedule: [{:db_read_back, expect: [status: :scheduled, scheduled_publish_at: :present]}],
    destroy: [{:db_read_back, expect: [status: :archived, archived_at: :present]}],
    unarchive: [{:db_read_back, expect: [archived_at: :absent]}],
    permanent_destroy: [{:db_read_back, gone: true}],
    restore_version: [
      {:db_read_back, expect: [title: :claimed, slug: :claimed, status: :claimed]}
    ]
  }

  @listed_stages %{
    create: [{:db_read_back, expect: [name: :claimed, slug: :claimed]}],
    update: [{:db_read_back, expect: [name: :claimed, slug: :claimed]}],
    destroy: [{:db_read_back, expect: [archived_at: :present]}],
    unarchive: [{:db_read_back, expect: [archived_at: :absent]}],
    permanent_destroy: [{:db_read_back, gone: true}]
  }

  @operations Enum.map(@post_stages, fn {action, read_back} ->
                extra =
                  case action do
                    :publish ->
                      [
                        JobDone.sitemap(),
                        {:job_enqueued, :share_card_job,
                         worker: ShareCardRefreshWorker,
                         args: &__MODULE__.share_card_args/1,
                         skip_when: &__MODULE__.no_share_card/1},
                        {:job_done, :share_card_looked,
                         worker: ShareCardRefreshWorker, skip_when: &__MODULE__.no_share_card/1},
                        {:side_effect, :feeds_dropped, check: &__MODULE__.feeds_dropped/1},
                        :ui_observed
                      ]

                    :schedule ->
                      [
                        {:side_effect, :published_when_due,
                         check: &__MODULE__.published_when_due/1}
                      ]

                    _other ->
                      []
                  end

                Operation.new!(%{
                  name: "blog:blog_post:#{action}",
                  resource: BlogPost,
                  action: action,
                  master_action: :"master_#{action}",
                  visibility: @visibility,
                  stages:
                    @written ++
                      read_back ++ [:broadcast_published, JobEnqueued.sitemap()] ++ extra,
                  required:
                    if(action == :schedule,
                      do: @required ++ [:published_when_due],
                      else: @required
                    )
                })
              end) ++
                for(
                  {resource, segment} <- [{Collection, "collection"}, {Tag, "tag"}],
                  {action, read_back} <- @listed_stages,
                  do:
                    Operation.new!(%{
                      name: "blog:#{segment}:#{action}",
                      resource: resource,
                      action: action,
                      master_action: :"master_#{action}",
                      visibility: @visibility,
                      stages: @written ++ read_back ++ [:broadcast_published],
                      required: @required
                    })
                )

  @impl MishkaCmsCore.Agent.Operation
  def operations, do: @operations

  @doc false
  # The share-card look a published post's save queues (`MishkaBlog.Plugins.PostShareCard`).
  def share_card_args(%{site_id: site_id, result: {:ok, post}}),
    do: %{"site_id" => site_id, "target" => ShareCard.encode(ShareCards.target(post))}

  @doc false
  def no_share_card(%{site_id: site_id, result: {:ok, post}}) when is_binary(site_id) do
    if ShareCards.target(post), do: nil, else: :not_applicable
  end

  def no_share_card(_ctx), do: :not_applicable

  @doc false
  # The site's feeds are dropped on every write (`MishkaBlog.Resources.Notifiers.FeedRefresh`), so
  # right after it none is kept. One kept again means a request rebuilt it since, or it was never
  # dropped: which one cannot be told, so it is unverified rather than failed.
  def feeds_dropped(%{site_id: site_id}) when is_binary(site_id) do
    case Enum.count(AssetsState.types(site_id), &String.starts_with?(&1, Feeds.prefix())) do
      0 -> {:ok, %{cached_feeds: 0}}
      kept -> {:unverified, :rebuilt_or_kept, %{cached_feeds: kept}}
    end
  end

  def feeds_dropped(_ctx), do: {:skip, :not_applicable}

  @doc false
  def published_when_due(_ctx) do
    if Enum.any?(Oban.config().plugins, &on_crontab?/1),
      do: {:ok, %{worker: PublishScheduledWorker}},
      else: {:unverified, :not_on_crontab}
  end

  defp on_crontab?({Oban.Plugins.Cron, opts}),
    do: Enum.any?(Keyword.get(opts, :crontab, []), &(elem(&1, 1) == PublishScheduledWorker))

  defp on_crontab?(_plugin), do: false
end
