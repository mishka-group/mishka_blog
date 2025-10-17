defmodule MishkaBlog.Test.CommentVoteGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.CommentVote`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.CommentVote

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:vote_type]) ==
                 CommentVote.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "vote_type enum accepted both ways" do
        assert {:ok, %{vote_type: :up}} = CommentVote.__guarded_change__(%{vote_type: :up})
        assert {:ok, %{vote_type: :down}} = CommentVote.__guarded_change__(%{vote_type: :down})
      end

      test "vote_type outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :vote_type,
                    action: :enum,
                    message: "Your sent data form vote_type field is not in the allowed list"
                  }
                ]} = CommentVote.__guarded_change__(%{vote_type: :sideways})
      end
    end
  end
end
