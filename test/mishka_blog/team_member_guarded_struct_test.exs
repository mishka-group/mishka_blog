defmodule MishkaBlog.Test.TeamMemberGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.TeamMember`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.TeamMember

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:role]) == TeamMember.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "role trim + downcase; nil passes" do
        assert {:ok, %{role: "editor"}} = TeamMember.__guarded_change__(%{role: "  Editor  "})
        assert {:ok, %{role: nil}} = TeamMember.__guarded_change__(%{role: nil})
      end

      test "role over max_len=100 rejected" do
        long = String.duplicate("x", 101)

        assert {:error,
                [
                  %{
                    field: :role,
                    action: :max_len,
                    message: "The maximum number of characters in the role field is 100" <> _
                  }
                ]} = TeamMember.__guarded_change__(%{role: long})
      end
    end
  end
end
