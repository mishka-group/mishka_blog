# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.TeamFollowerGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.TeamFollower`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.TeamFollower

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:followed_at, :notification_enabled]) ==
                 TeamFollower.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "notification_enabled boolean accept/reject" do
        assert {:ok, %{notification_enabled: true}} =
                 TeamFollower.__guarded_change__(%{notification_enabled: true})

        assert {:error, errs} = TeamFollower.__guarded_change__(%{notification_enabled: "yes"})
        assert Enum.any?(errs, &match?(%{field: :notification_enabled, action: :boolean}, &1))
      end
    end
  end
end
