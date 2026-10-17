defmodule MishkaBlog.Resources.Changes.RestoreVersionTest do
  use ExUnit.Case, async: true

  alias MishkaBlog.Resources.Changes.RestoreVersion

  describe "known_changes/2" do
    test "keeps the entries that name a field, keyed by its atom" do
      changes = %{"name" => "Elixir", "slug" => "elixir", "site_id" => "x"}

      assert RestoreVersion.known_changes(changes, [:name, :slug]) ==
               %{name: "Elixir", slug: "elixir"}
    end

    test "reads atom keys and the version's JSON the same way" do
      assert RestoreVersion.known_changes(%{name: "Elixir"}, [:name]) == %{name: "Elixir"}
      assert RestoreVersion.known_changes(~s({"name":"Elixir"}), [:name]) == %{name: "Elixir"}
    end

    test "a key that names no field is left out and never becomes an atom" do
      key = "never_an_atom_#{System.unique_integer([:positive])}"

      assert RestoreVersion.known_changes(%{key => 1, "name" => "x"}, [:name]) == %{name: "x"}
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "nothing to read is an empty map" do
      assert RestoreVersion.known_changes(nil, [:name]) == %{}
      assert RestoreVersion.known_changes(%{}, [:name]) == %{}
    end

    test "JSON that does not parse, or is not an object, is an empty map" do
      assert RestoreVersion.known_changes("not json {", [:name]) == %{}
      assert RestoreVersion.known_changes(~s({"name":), [:name]) == %{}
      assert RestoreVersion.known_changes(~s(["name"]), [:name]) == %{}
      assert RestoreVersion.known_changes(~s("name"), [:name]) == %{}
      assert RestoreVersion.known_changes("", [:name]) == %{}
    end
  end

  describe "cast_field/3" do
    test "a string value is read through the attribute's type" do
      assert RestoreVersion.cast_field(%{status: "inactive"}, MishkaBlog.Team, :status) ==
               %{status: :inactive}
    end

    test "a value the type refuses is dropped and never becomes an atom" do
      value = "never_a_status_#{System.unique_integer([:positive])}"

      assert RestoreVersion.cast_field(%{status: value, name: "x"}, MishkaBlog.Team, :status) ==
               %{name: "x"}

      assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
    end

    test "an absent or non-string value is left as it is" do
      assert RestoreVersion.cast_field(%{name: "x"}, MishkaBlog.Team, :status) == %{name: "x"}

      assert RestoreVersion.cast_field(%{status: :active}, MishkaBlog.Team, :status) ==
               %{status: :active}
    end
  end
end
