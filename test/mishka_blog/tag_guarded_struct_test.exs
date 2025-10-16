defmodule MishkaBlog.Test.TagGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.Tag`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Tag

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :name,
                 :slug,
                 :description,
                 :language,
                 :language_group_id
               ]) == Tag.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "name + slug trim; language trim+downcase" do
        assert {:ok,
                %{
                  name: "Phoenix",
                  slug: "phoenix",
                  language: "en"
                }} =
                 Tag.__guarded_change__(%{
                   name: "  Phoenix  ",
                   slug: "  phoenix  ",
                   language: "  EN  "
                 })
      end

      test "language over max_len=10 → both max_len + language_code fire" do
        assert {:error, errs} = Tag.__guarded_change__(%{language: "english-language"})

        assert Enum.any?(errs, &match?(%{field: :language, action: :max_len}, &1))
        assert Enum.any?(errs, &match?(%{field: :language, action: :language_code}, &1))
      end

      test "language: BCP-47 shapes accepted (with downcasing)" do
        for {input, expected} <- [
              {"en", "en"},
              {"FA", "fa"},
              {"  EN-US  ", "en-us"},
              {"Zh-Hant", "zh-hant"},
              {"pt-BR", "pt-br"}
            ] do
          assert {:ok, %{language: ^expected}} = Tag.__guarded_change__(%{language: input})
        end
      end

      test "language: non-BCP-47 shapes rejected" do
        for bad <- ["english", "e", "123", "fr_FR"] do
          assert {:error, errs} = Tag.__guarded_change__(%{language: bad})

          assert Enum.any?(errs, &match?(%{field: :language, action: :language_code}, &1)),
                 "expected :language_code rejection for #{inspect(bad)}, got #{inspect(errs)}"
        end
      end
    end
  end
end
