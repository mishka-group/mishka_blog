# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.TeamGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.Team`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Team

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :name,
                 :slug,
                 :description,
                 :avatar_url,
                 :cover_image_url,
                 :status
               ]) == Team.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "name + slug trim, status enum accept" do
        assert {:ok,
                %{
                  name: "Core Team",
                  slug: "core-team",
                  status: :active
                }} =
                 Team.__guarded_change__(%{
                   name: "  Core Team  ",
                   slug: "  core-team  ",
                   status: :active
                 })
      end

      test "status outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = Team.__guarded_change__(%{status: :archived})
      end

      test "name empty → min_len + not_empty fire" do
        assert {:error, errs} = Team.__guarded_change__(%{name: ""})
        assert Enum.any?(errs, &match?(%{field: :name, action: :min_len}, &1))
        assert Enum.any?(errs, &match?(%{field: :name, action: :not_empty}, &1))
      end
    end
  end
end
