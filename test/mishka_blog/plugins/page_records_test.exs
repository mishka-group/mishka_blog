# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PageRecordsTest do
  @moduledoc """
  `MishkaBlog.Plugins.PageRecords`: the samples a page of posts, categories or tags is previewed
  with are in the languages the site publishes in, so none opens a page the site does not serve.

  `async: false`: the settings cache is process-global.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Plugins.PageRecords
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  setup do
    site = create_site!(active: true)
    {:ok, _} = Settings.put("site.languages", ["en", "fr"], site_id: site.id)
    on_exit(fn -> SettingsState.delete(site.id, "site.languages") end)
    {:ok, site: site}
  end

  defp sample_languages(site, kind) do
    site.id
    |> PageRecords.types()
    |> Enum.find(&(&1.id == kind))
    |> Map.fetch!(:samples)
    |> Enum.map(& &1.params["lang"])
    |> Enum.sort()
  end

  test "posts, categories and tags are sampled in the site's languages alone", %{site: site} do
    for language <- ["en", "fr", "fa", "ru"] do
      create_blog_post!(site_id: site.id, status: :published, language: language)
      create_collection!(site_id: site.id, status: :active, language: language)
      create_blog_tag!(site_id: site.id, language: language)
    end

    for kind <- ["blog:post", "blog:category", "blog:tag"] do
      assert sample_languages(site, kind) == ["en", "fr"], kind
    end
  end
end
