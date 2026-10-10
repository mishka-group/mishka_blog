defmodule MishkaBlog.Test.PlainTextFieldsTest do
  @moduledoc """
  The blog's plain-text fields — a post's title and subtitle, a category's, a tag's, a team's and an
  auto-posting's name and description, a blogger's name, a comment — store what was typed, without its markup
  and with nothing escaped (`MishkaCmsCore.PlainText`). Escaping is the page's and the head's job.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.BlogPost
  alias MishkaCmsCore.PlainText

  @moduletag :integration

  @post "admin:dashboard:blog:post"

  @typed ~s(Tom & Jerry's <b>"cat"</b>)
  @kept ~s(Tom & Jerry's "cat")

  # Read off the resources rather than listed, so a field declared tomorrow is covered too.
  defp guarded_fields do
    for resource <- Ash.Domain.Info.resources(MishkaBlog),
        function_exported?(resource, :__guarded_fields__, 0),
        field <- resource.__guarded_fields__(),
        do: {resource, field}
  end

  defp plain_text_fields do
    for {resource, %{name: name, validator: {PlainText, :field}}} <- guarded_fields(),
        do: {resource, name}
  end

  describe "every plain-text field" do
    test "is one the blog shows as text" do
      assert MapSet.new(plain_text_fields()) ==
               MapSet.new([
                 {MishkaBlog.AutoPosting, :description},
                 {MishkaBlog.AutoPosting, :name},
                 {MishkaBlog.AutoPosting, :plugin},
                 {MishkaBlog.BlogPost, :subtitle},
                 {MishkaBlog.BlogPost, :title},
                 {MishkaBlog.Blogger, :display_name},
                 {MishkaBlog.Collection, :description},
                 {MishkaBlog.Comment, :content},
                 {MishkaBlog.Collection, :name},
                 {MishkaBlog.Tag, :description},
                 {MishkaBlog.Tag, :name},
                 {MishkaBlog.Team, :description},
                 {MishkaBlog.Team, :name}
               ])
    end

    test "keeps what was typed without its markup, and keeping it again changes nothing" do
      for {resource, field} <- plain_text_fields() do
        label = "#{inspect(resource)}.#{field}"

        assert {:ok, %{^field => @kept}} = resource.__guarded_change__(%{field => @typed}), label
        assert {:ok, %{^field => @kept}} = resource.__guarded_change__(%{field => @kept}), label

        assert {:ok, %{^field => "alert(1)Hi"}} =
                 resource.__guarded_change__(%{field => "<script>alert(1)</script>Hi"}),
               label
      end
    end

    # `strip_tags` escapes the text it leaves, so a field sanitized with it stores `&amp;`.
    test "no field is stripped of its tags the escaping way" do
      escaping =
        for {resource, %{name: name, __derive_ops__: %{sanitize: ops}}} <- guarded_fields(),
            :strip_tags in List.wrap(ops),
            do: {resource, name}

      assert escaping == []
    end
  end

  describe "a post written through its actions" do
    setup do
      site = create_site!()
      %{site: site, editor: create_user_with_permissions!([@post], site_id: site.id)}
    end

    defp create!(ctx, attrs) do
      unique = System.unique_integer([:positive])

      BlogPost
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{slug: "post-#{unique}", content: "<p>Body</p>", status: :draft, language: "en"},
          attrs
        ),
        actor: ctx.editor,
        tenant: ctx.site.id
      )
      |> Ash.create!()
    end

    defp update!(post, ctx, attrs) do
      post
      |> Ash.Changeset.for_update(:update, attrs, actor: ctx.editor, tenant: ctx.site.id)
      |> Ash.update!()
    end

    test "stores its title and subtitle as typed, and saving them again changes nothing", ctx do
      post = create!(ctx, %{title: @typed, subtitle: "<i>Why</i> & how"})

      assert post.title == @kept
      assert post.subtitle == "Why & how"

      saved = update!(post, ctx, %{title: post.title, subtitle: post.subtitle})
      assert {saved.title, saved.subtitle} == {@kept, "Why & how"}

      again = update!(saved, ctx, %{title: saved.title, subtitle: saved.subtitle})
      assert {again.title, again.subtitle} == {@kept, "Why & how"}
    end

    test "never stores a script", ctx do
      post = create!(ctx, %{title: "<script>alert(1)</script>Hi", subtitle: "<<script>script>x"})

      refute post.title =~ "<script"
      refute post.subtitle =~ "<script"
      assert post.title == "alert(1)Hi"

      updated = update!(post, ctx, %{title: "<img src=x onerror=alert(1)>Hi"})
      assert updated.title == "Hi"
    end
  end
end
