# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.BloggerFollowerGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.BloggerFollower`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.BloggerFollower

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:followed_at, :notification_enabled]) ==
                 BloggerFollower.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "notification_enabled boolean accepted; non-boolean rejected" do
        assert {:ok, %{notification_enabled: true}} =
                 BloggerFollower.__guarded_change__(%{notification_enabled: true})

        assert {:ok, %{notification_enabled: false}} =
                 BloggerFollower.__guarded_change__(%{notification_enabled: false})

        assert {:error, errs} = BloggerFollower.__guarded_change__(%{notification_enabled: "yes"})
        assert Enum.any?(errs, &match?(%{field: :notification_enabled, action: :boolean}, &1))
      end

      test "followed_at struct passes through (Ash handles ISO parsing)" do
        now = DateTime.utc_now()

        assert {:ok, %{followed_at: ^now}} =
                 BloggerFollower.__guarded_change__(%{followed_at: now})
      end
    end
  end
end
