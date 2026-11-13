# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.PostViewDaily do
  @moduledoc """
  How many times a post was read on one day, and by how many readers: one row per site, post and
  day. Nothing about a reader is stored, no IP, no account and no session.

  A view is never written on its own. `MishkaBlog.Views` counts them in memory and writes what it
  counted every minute with one bulk `:record`, an upsert that adds the batch's numbers to the row
  already there (`views = views + n`).

  `unique_readers` is approximate where the site runs on several nodes: each node tells its readers
  apart on its own, so a reader served by two nodes on one day is counted twice.

  `:purge_expired` deletes the rows older than the `blog.views.retention_days` setting (730 days by
  default). AshOban runs it every day at 03:17 on the `:maintenance` queue, through the host's
  `AshOban.config/2`.
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  @retention_days 730

  postgres do
    table "mishka_blog_post_views_daily"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :post, on_delete: :delete
      reference :site, on_delete: :delete
    end

    custom_indexes do
      index [:day]
      index [:post_id]
    end
  end

  oban do
    scheduled_actions do
      schedule :purge_expired, "17 3 * * *" do
        action :purge_expired
        queue(:maintenance)
        worker_module_name(MishkaBlog.Workers.PurgeExpiredViewsWorker)
      end
    end
  end

  actions do
    read :read do
      primary? true
    end

    read :master_read do
      description "Reads every site's daily views (master users only)"
      multitenancy :bypass
    end

    create :record do
      description "Adds a batch of counted views to a day's row, creating it when there is none"
      accept [:site_id, :post_id, :day, :views, :unique_readers]
      upsert? true
      upsert_identity :one_per_day
      upsert_fields []

      change atomic_update(:views, expr(views + upsert_conflict(:views)))

      change atomic_update(
               :unique_readers,
               expr(unique_readers + upsert_conflict(:unique_readers))
             )
    end

    action :purge_expired do
      description "Deletes the daily views older than the blog.views.retention_days setting"

      run fn _input, _context ->
        cutoff = Date.add(Date.utc_today(), -retention_days())

        __MODULE__
        |> Ash.Query.filter(day < ^cutoff)
        |> Ash.bulk_destroy(:destroy, %{},
          authorize?: false,
          strategy: [:atomic, :stream],
          return_errors?: true
        )
        |> case do
          %Ash.BulkResult{status: :success} -> :ok
          %Ash.BulkResult{errors: errors} -> {:error, errors}
        end
      end
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # A master reads every site's views; a site user only its own site's.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  multitenancy do
    strategy :attribute
    attribute :site_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :day, :date do
      allow_nil? false
      public? true
    end

    attribute :views, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :unique_readers, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
    end

    belongs_to :post, MishkaBlog.BlogPost do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :one_per_day, [:site_id, :post_id, :day]
  end

  @doc "How many days of daily views are kept: the `blog.views.retention_days` setting."
  @spec retention_days() :: pos_integer()
  def retention_days do
    case MishkaCmsCore.Settings.get("blog.views.retention_days", @retention_days) do
      days when is_integer(days) and days > 0 -> days
      _unset -> @retention_days
    end
  end
end
