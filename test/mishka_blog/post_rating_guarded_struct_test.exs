# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PostRatingGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.PostRating`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostRating

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:rating]) == PostRating.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "rating in [1..5] accepted; 0 + 99 rejected" do
        assert {:ok, %{rating: 1}} = PostRating.__guarded_change__(%{rating: 1})
        assert {:ok, %{rating: 5}} = PostRating.__guarded_change__(%{rating: 5})

        assert {:error,
                [
                  %{
                    field: :rating,
                    action: :min_len,
                    message: "The minimum number the rating field is 1" <> _
                  }
                ]} = PostRating.__guarded_change__(%{rating: 0})

        assert {:error,
                [
                  %{
                    field: :rating,
                    action: :max_len,
                    message: "The maximum number the rating field is 5" <> _
                  }
                ]} = PostRating.__guarded_change__(%{rating: 99})
      end
    end
  end
end
