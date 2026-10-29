# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Templates.CardRecord do
  @moduledoc """
  What the blog's card templates (`MishkaBlogWeb.Templates.PostCard` and its siblings) read off a
  record in the same way: an aggregate, a status badge and the name of the site a row belongs to.
  Each card keeps its own table of badges and its own markup; only the reading is shared.
  """

  @doc "One aggregate off the record, or 0 when it arrived unloaded."
  @spec count(map(), atom()) :: non_neg_integer()
  def count(record, key) do
    case Map.get(record, key) do
      value when is_integer(value) and value >= 0 -> value
      _unloaded -> 0
    end
  end

  @doc """
  The entry of `statuses` for the record's `status`, or the one named `default` when the record
  has none of them — the attribute's own default.
  """
  @spec status_badge(map(), %{optional(atom()) => map()}, atom()) :: map()
  def status_badge(%{status: status}, statuses, _default) when is_map_key(statuses, status),
    do: statuses[status]

  def status_badge(_record, statuses, default), do: Map.fetch!(statuses, default)

  # A tenant admin only ever sees their own site, so naming it on every row is noise; a master is
  # reading across sites and needs to know which one each row belongs to.
  @doc "The record's site name for a master reading across sites, `nil` for anyone else."
  @spec site_name(map(), map()) :: String.t() | nil
  def site_name(%{site: %{name: name}}, %{master_user?: true}) when is_binary(name), do: name
  def site_name(_record, _state), do: nil
end
