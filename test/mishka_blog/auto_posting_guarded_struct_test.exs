# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.AutoPostingGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.AutoPosting`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.AutoPosting

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:name, :plugin, :description, :is_active, :config]) ==
                 AutoPosting.__guarded_field_name_set__()
      end

      test "GuardedStruct.AshResource.Change is registered" do
        assert AutoPosting
               |> Ash.Resource.Info.changes()
               |> Enum.any?(fn c -> c.change == {GuardedStruct.AshResource.Change, []} end)
      end
    end

    describe "direct __guarded_change__/1" do
      test "name + plugin trimmed; description sanitized; is_active boolean" do
        assert {:ok,
                %{
                  name: "Twitter Crossposter",
                  plugin: "twitter",
                  description: "Posts to X on publish.",
                  is_active: true,
                  config: %{api_key: "abc"}
                }} =
                 AutoPosting.__guarded_change__(%{
                   name: "  Twitter Crossposter  ",
                   plugin: "  twitter  ",
                   description: "  Posts to X on publish.  ",
                   is_active: true,
                   config: %{api_key: "abc"}
                 })
      end

      test "name empty → min_len + not_empty errors" do
        assert {:error, errs} = AutoPosting.__guarded_change__(%{name: ""})
        assert Enum.any?(errs, &match?(%{field: :name, action: :min_len}, &1))
        assert Enum.any?(errs, &match?(%{field: :name, action: :not_empty}, &1))
      end

      test "is_active rejects non-boolean" do
        assert {:error, errs} = AutoPosting.__guarded_change__(%{is_active: "yes"})
        assert Enum.any?(errs, &match?(%{field: :is_active, action: :boolean}, &1))
      end
    end
  end
end
