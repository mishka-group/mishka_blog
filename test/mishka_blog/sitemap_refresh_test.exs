# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.SitemapRefreshTest do
  @moduledoc """
  A write of a blog post, category, tag, blogger or team schedules its site's sitemap job, tenant and
  master alike: the five list `MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh`. What the
  job builds is pinned in core, and what the blog adds to it in `MishkaBlog.Plugins.SitemapUrlsTest`.

  `MishkaCmsCore.Runtime.Compilers.SitemapCompiler.schedule/1` enqueues nothing under the
  `:env_test?` flag, so setup switches it off once every row a test writes exists. `async: false` —
  the flag and `SiteState` are process-global.
  """
  use MishkaBlog.DataCase, async: false
  use Oban.Testing, repo: MishkaBlog.Repo

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  setup do
    site = open_site!()
    other = open_site!()

    rows = %{
      site: site,
      other: other,
      draft: create_blog_post!(site_id: site.id, status: :draft),
      published: create_blog_post!(site_id: site.id, status: :published),
      other_post: create_blog_post!(site_id: other.id, status: :published),
      collection: create_collection!(site_id: site.id),
      tag: create_blog_tag!(site_id: site.id),
      blogger: create_blogger!(site_id: site.id),
      team: create_team!(site_id: site.id)
    }

    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

    {:ok, rows}
  end

  # A NAME AND HOST OF ITS OWN. Its create caches it in `SiteState`, which a job is only enqueued for
  # and which outlives the rollback — and the generator's names start over in every test, so the
  # second test's site would be refused there for the first one's host.
  defp open_site! do
    name = "sitemaptown#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)
    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp sitemap_jobs(site) do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(fn job ->
      get_in(job.args, ["data", "type"]) == "sitemap" and
        get_in(job.args, ["data", "site_id"]) == site.id
    end)
  end

  defp update!(record, action, params, opts) do
    record
    |> Ash.Changeset.for_update(action, params, [authorize?: false] ++ opts)
    |> Ash.update!()
  end

  defp archive!(record, site) do
    record
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
    |> Ash.destroy!()
  end

  describe "a blog post" do
    test "published by its site gives one sitemap job, for that site", %{site: site, draft: draft} do
      update!(draft, :publish, %{}, tenant: site.id)

      assert [job] = sitemap_jobs(site)
      assert job.queue == "sitemaps"
      assert job.args["data"]["site_name"] == site.name
    end

    test "published by a master, with no tenant, gives the job for the post's own site", %{
      site: site,
      draft: draft
    } do
      update!(draft, :master_publish, %{}, [])

      assert [_job] = sitemap_jobs(site)
    end

    test "updated gives the job", %{site: site, published: published} do
      update!(published, :update, %{title: "Updated title"}, tenant: site.id)

      assert [_job] = sitemap_jobs(site)
    end

    test "unpublished gives the job", %{site: site, published: published} do
      update!(published, :unpublish, %{}, tenant: site.id)

      assert [_job] = sitemap_jobs(site)
    end

    test "archived gives the job", %{site: site, published: published} do
      archive!(published, site)

      assert [_job] = sitemap_jobs(site)
    end

    test "updated twenty times in a row is one job", %{site: site, published: published} do
      Enum.reduce(1..20, published, fn n, post ->
        update!(post, :update, %{title: "Title #{n}"}, tenant: site.id)
      end)

      assert [_job] = sitemap_jobs(site)
    end

    test "on another site schedules that site's job only", %{
      site: site,
      other: other,
      other_post: other_post
    } do
      update!(other_post, :update, %{title: "Updated title"}, tenant: other.id)

      assert [_job] = sitemap_jobs(other)
      assert sitemap_jobs(site) == []
    end
  end

  describe "a category, a tag, a blogger and a team" do
    test "a category updated gives its site's job", %{site: site, collection: collection} do
      update!(collection, :update, %{name: "Renamed category"}, tenant: site.id)

      assert [_job] = sitemap_jobs(site)
    end

    test "a tag updated or archived gives its site's job", %{site: site, tag: tag} do
      tag
      |> update!(:update, %{name: "Renamed tag"}, tenant: site.id)
      |> archive!(site)

      assert [_job] = sitemap_jobs(site)
    end

    test "a blogger created, updated or archived gives its site's job", %{
      site: site,
      other: other,
      blogger: blogger
    } do
      create_blogger!(site_id: site.id)
      assert [_job] = sitemap_jobs(site)

      blogger
      |> update!(:update, %{display_name: "Renamed blogger"}, tenant: site.id)
      |> archive!(site)

      assert [_job] = sitemap_jobs(site)
      assert sitemap_jobs(other) == []
    end

    test "a team created, updated or archived gives its site's job", %{
      site: site,
      other: other,
      team: team
    } do
      create_team!(site_id: site.id, status: :active)
      assert [_job] = sitemap_jobs(site)

      team
      |> update!(:update, %{name: "Renamed team"}, tenant: site.id)
      |> archive!(site)

      assert [_job] = sitemap_jobs(site)
      assert sitemap_jobs(other) == []
    end
  end
end
