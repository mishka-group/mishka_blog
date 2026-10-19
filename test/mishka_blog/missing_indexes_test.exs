# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.MissingIndexesTest do
  @moduledoc """
  The columns a blog page reads a table by from the other side. A join table's primary key leads
  with its post (or team), so listing the posts of a tag, a collection or a blogger, and counting
  them (`post_count`, `published_post_count`), needs an index that leads with the other column; a
  record's version table is read by the record it versions (`version_count`, `sorted_versions`).
  """
  use MishkaBlog.DataCase, async: false

  @leading_columns """
  SELECT a.attname
  FROM pg_index i
  JOIN pg_class t ON t.oid = i.indrelid
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = i.indkey[0]
  WHERE t.relname = $1 AND i.indpred IS NULL
  """

  @join_tables [
    {"mishka_blog_post_tags", "tag_id"},
    {"mishka_blog_post_collections", "collection_id"},
    {"mishka_blog_post_bloggers", "blogger_id"},
    {"mishka_blog_team_members", "blogger_id"}
  ]

  @version_tables ~w(
    mishka_blog_post_versions
    mishka_blog_tag_versions
    mishka_blog_collection_versions
    mishka_blog_blogger_versions
    mishka_blog_team_versions
    mishka_blog_auto_posting_versions
  )

  for {table, column} <- @join_tables do
    test "#{table} has an index that leads with #{column}" do
      assert unquote(column) in leading_columns(unquote(table))
    end
  end

  for table <- @version_tables do
    test "#{table} has an index that leads with version_source_id, whichever site the record is of" do
      assert "version_source_id" in leading_columns(unquote(table))
    end
  end

  defp leading_columns(table) do
    %{rows: rows} = Repo.query!(@leading_columns, [table])
    List.flatten(rows)
  end
end
