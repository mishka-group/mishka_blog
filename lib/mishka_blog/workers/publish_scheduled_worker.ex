# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Workers.PublishScheduledWorker do
  @moduledoc """
  Publishes every scheduled post whose time has come (Oban Cron). One bulk `:master_publish` over
  `:due_scheduled` across all sites, run as the system (`authorize?: false`), streaming so a large
  backlog publishes in constant memory. Each post gets its scheduled time as `published_at` and
  loses its schedule (`MishkaBlog.Resources.Changes.PublishLifecycle`), and the publish notifies as
  any master publish does: the broadcast, the sitemap, the share card and the feeds follow.

  A post already published is no longer `:scheduled`, so a second run publishes nothing.

  The host runs it on its crontab, once a minute:

      config :my_app, Oban,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [{"* * * * *", MishkaBlog.Workers.PublishScheduledWorker}]}
        ]
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias MishkaBlog.BlogPost

  @impl Oban.Worker
  def perform(_job) do
    BlogPost
    |> Ash.Query.for_read(:due_scheduled, %{}, authorize?: false)
    |> Ash.bulk_update(:master_publish, %{},
      authorize?: false,
      strategy: [:stream],
      notify?: true,
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end
end
