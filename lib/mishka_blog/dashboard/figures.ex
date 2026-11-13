# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Figures do
  @moduledoc """
  The arithmetic `MishkaBlog.Dashboard.Overview` and `MishkaBlog.Dashboard.Analytics` share: where a
  day starts and what an engagement rate is.
  """

  @doc "The first instant of `date`, in UTC."
  @spec beginning_of_day(Date.t()) :: DateTime.t()
  def beginning_of_day(date), do: DateTime.new!(date, ~T[00:00:00])

  @doc """
  The share of `views` that led to an interaction, as a whole percent: `interactions` over `views`,
  never above `100`, and `0` when there are no views. A comment needs a reader, so a period with
  more comments than counted views (views counted since the counter came, comments from before) is
  every reader engaged, not more than all of them.
  """
  @spec rate(non_neg_integer(), non_neg_integer()) :: 0..100
  def rate(_interactions, 0), do: 0
  def rate(interactions, views), do: min(round(interactions * 100 / views), 100)
end
