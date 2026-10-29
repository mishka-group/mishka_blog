# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dashboard.Figures do
  @moduledoc """
  The arithmetic `MishkaBlog.Dashboard.Overview` and `MishkaBlog.Dashboard.Analytics` share: where a
  day starts and how an engagement rate is rounded.
  """

  @doc "The first instant of `date`, in UTC."
  @spec beginning_of_day(Date.t()) :: DateTime.t()
  def beginning_of_day(date), do: DateTime.new!(date, ~T[00:00:00])

  @doc "`interactions` as a whole percent of `views`, `0` when there are no views."
  @spec rate(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def rate(_interactions, 0), do: 0
  def rate(interactions, views), do: round(interactions * 100 / views)
end
