# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.CommentGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.Comment`.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Comment

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :content,
                 :status,
                 :sender_data,
                 :is_pinned,
                 :site_id,
                 :guest_name,
                 :guest_email,
                 :guest_website
               ]) ==
                 Comment.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "content is plain text, every tag stripped; status enum accept" do
        assert {:ok,
                %{
                  content: content,
                  status: :approved,
                  is_pinned: true
                }} =
                 Comment.__guarded_change__(%{
                   content: "<p>hello <b>world</b></p><script>alert(1)</script>",
                   status: :approved,
                   is_pinned: true
                 })

        assert content =~ "hello world"
        refute content =~ "<"
      end

      test "status outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = Comment.__guarded_change__(%{status: :bogus})
      end

      test "a guest's name is plain text, the email lowercased, the website trimmed" do
        assert {:ok,
                %{
                  guest_name: "Ada",
                  guest_email: "ada@example.com",
                  guest_website: "https://ada.example.com"
                }} =
                 Comment.__guarded_change__(%{
                   guest_name: " <b>Ada</b> ",
                   guest_email: " ADA@Example.com ",
                   guest_website: " https://ada.example.com "
                 })
      end

      test "a guest's name and email lose their tags and keep an ampersand as typed" do
        assert {:ok, %{guest_name: "Tom x & Jerry", guest_email: "a&b@example.com"}} =
                 Comment.__guarded_change__(%{
                   guest_name: "Tom <b>x</b> & Jerry",
                   guest_email: " <b>A&B@Example.com</b> "
                 })
      end

      test "empty content → not_empty error" do
        assert {:error, errs} = Comment.__guarded_change__(%{content: ""})
        assert Enum.any?(errs, &match?(%{field: :content, action: :not_empty}, &1))
      end
    end
  end
end
