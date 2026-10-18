# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PaperTrailMixinTest do
  @moduledoc """
  Each version resource of the blog is built by `MishkaBlog.Resources.Mixins.PaperTrailMixin` with
  its own table: the same actions, the same policies, global rather than per site.
  """
  use ExUnit.Case, async: true

  @versions [
    {MishkaBlog.AutoPosting.Version, "mishka_blog_auto_posting_versions"},
    {MishkaBlog.BlogPost.Version, "mishka_blog_post_versions"},
    {MishkaBlog.Blogger.Version, "mishka_blog_blogger_versions"},
    {MishkaBlog.Collection.Version, "mishka_blog_collection_versions"},
    {MishkaBlog.Tag.Version, "mishka_blog_tag_versions"},
    {MishkaBlog.Team.Version, "mishka_blog_team_versions"}
  ]

  for {version, table} <- @versions do
    describe inspect(version) do
      test "is stored in #{table}" do
        assert AshPostgres.DataLayer.Info.table(unquote(version)) == unquote(table)
      end

      test "is global and reads every site's versions through its own actions" do
        assert Ash.Resource.Info.multitenancy_global?(unquote(version))

        for name <- [:get_any, :read_any, :sorted_versions] do
          assert %{type: :read} = Ash.Resource.Info.action(unquote(version), name)
          assert Ash.Resource.Info.action(unquote(version), name).multitenancy == :bypass
        end
      end

      test "sorts its versions newest first" do
        assert [%{field: :version_inserted_at, order: :desc}] =
                 unquote(version)
                 |> Ash.Query.for_read(:sorted_versions, %{}, authorize?: false)
                 |> Map.fetch!(:sort)
                 |> Enum.map(fn {field, order} -> %{field: field, order: order} end)
      end

      test "keeps its versions to an admin of the record's site" do
        policies = Ash.Policy.Info.policies(unquote(version))

        assert length(policies) == 2
      end
    end
  end
end
