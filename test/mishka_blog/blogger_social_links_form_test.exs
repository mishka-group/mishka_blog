# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.BloggerSocialLinksFormTest do
  @moduledoc """
  A blogger's social links are a list of `platform` / `url` pairs, and the form says so.

  The column has said so all along — `{:array, :map}` constrained to those two keys, both
  `allow_nil?: false` — while the form asked for the whole list as JSON. Adding one link meant
  typing `[{"platform": "github", "url": "https://github.com/user"}]` by hand, and a misspelt key
  was accepted by the textarea and refused by Ash afterwards, if it was noticed at all.
  """
  use ExUnit.Case, async: true

  alias MishkaGervaz.Form.Types.Field.KeyList
  alias MishkaGervaz.Resource.Info.Form, as: FormInfo

  defp field, do: FormInfo.field(MishkaBlog.Blogger, :social_links)

  test "the field declares the two keys the column constrains" do
    assert field().type == :key_list
    assert Enum.map(KeyList.keys(field()), & &1.name) == [:platform, :url]
  end

  # The declaration and the column have to agree, and the column is the one that refuses a write —
  # so this reads the constraint rather than repeating it.
  test "and the column constrains exactly those two" do
    %{constraints: constraints} =
      MishkaBlog.Blogger
      |> Ash.Resource.Info.attributes()
      |> Enum.find(&(&1.name == :social_links))

    declared =
      constraints
      |> Keyword.fetch!(:items)
      |> Keyword.fetch!(:fields)
      |> Keyword.keys()

    assert declared == Enum.map(KeyList.keys(field()), & &1.name)
  end

  test "a posted list is taken as rows, blanks dropped" do
    posted = %{
      "_empty" => "1",
      "0" => %{"platform" => "github", "url" => "https://github.com/user"},
      "1" => %{"platform" => "  ", "url" => ""}
    }

    assert KeyList.parse_params(posted, field()) == [
             %{"platform" => "github", "url" => "https://github.com/user"}
           ]
  end

  test "and clearing the last one empties the column rather than leaving it alone" do
    assert KeyList.parse_params(%{"_empty" => "1"}, field()) == []
  end

  # What the form writes has to be what the column accepts, which is the whole point of the
  # conversion: the textarea could produce a shape Ash would then refuse, and often did.
  test "what the form produces casts against the column" do
    rows =
      KeyList.parse_params(
        %{"0" => %{"platform" => "github", "url" => "https://github.com/user"}},
        field()
      )

    %{type: type, constraints: constraints} =
      MishkaBlog.Blogger
      |> Ash.Resource.Info.attributes()
      |> Enum.find(&(&1.name == :social_links))

    assert {:ok, cast} = Ash.Type.cast_input(type, rows, constraints)

    assert {:ok, [%{platform: "github", url: "https://github.com/user"}]} =
             Ash.Type.apply_constraints(type, cast, constraints)
  end

  # And a row the author half-filled is refused by the column rather than stored, because both keys
  # are `allow_nil?: false` — which is the answer the JSON box gave far later, if at all.
  test "while a half-filled row is refused" do
    rows = KeyList.parse_params(%{"0" => %{"platform" => "github", "url" => ""}}, field())

    %{type: type, constraints: constraints} =
      MishkaBlog.Blogger
      |> Ash.Resource.Info.attributes()
      |> Enum.find(&(&1.name == :social_links))

    assert rows == [%{"platform" => "github"}]

    assert {:ok, cast} = Ash.Type.cast_input(type, rows, constraints)

    assert {:error, [[index: 0, message: "field must be present", field: :url]]} =
             Ash.Type.apply_constraints(type, cast, constraints)
  end
end
