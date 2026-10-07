defmodule MishkaBlog.Test.BlogPostGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaBlog.BlogPost`.

  Pins the title/slug/content sanitize behavior and the `:status` enum
  in both happy and error paths.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.BlogPost

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :title,
                 :subtitle,
                 :slug,
                 :content,
                 :excerpt,
                 :featured_image_url,
                 :status,
                 :published_at,
                 :scheduled_publish_at,
                 :schema,
                 :seo_tags,
                 :permissions,
                 :featured,
                 :language,
                 :language_group_id
               ]) == BlogPost.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "title strip_tags+trim; content keeps safe HTML, drops scripts; status enum accept" do
        assert {:ok,
                %{
                  title: title,
                  content: content,
                  status: :draft,
                  language: "fa"
                }} =
                 BlogPost.__guarded_change__(%{
                   title: "  <b>Hello</b> World  ",
                   content: "<p>Hello, <b>reader</b>!</p><script>alert(1)</script>",
                   status: :draft,
                   language: "  FA  "
                 })

        assert title == "Hello World"
        refute title =~ "<b>"

        assert content =~ "<p>Hello, <b>reader</b>!</p>"
        refute content =~ "<script"
      end

      # A post is rich content: code highlighted by class, headings a table of contents links to,
      # notes and figures. What the reader's browser would run is still taken out.
      test "content keeps classes, ids and rich blocks, and still drops what would run" do
        html = """
        <h2 id="install">Install</h2>
        <pre class="highlight"><code class="language-elixir"><span class="ss">:ok</span></code></pre>
        <aside class="post-note"><strong>Note:</strong> read this.</aside>
        <a href="javascript:alert(1)" onclick="alert(1)">bad</a>
        <img src="/media/x.png" onerror="alert(1)" alt="x">
        <script>alert(1)</script>
        """

        assert {:ok, %{content: content}} =
                 BlogPost.__guarded_change__(%{
                   title: "t",
                   content: html,
                   status: :draft,
                   language: "en"
                 })

        assert content =~ ~s(<h2 id="install">)
        assert content =~ ~s(<pre class="highlight"><code class="language-elixir">)
        assert content =~ ~s(<span class="ss">:ok</span>)
        assert content =~ ~s(<aside class="post-note">)
        refute content =~ "<script"
        refute content =~ "onclick"
        refute content =~ "onerror"
        refute content =~ "javascript:"
      end

      test "subtitle is plain text of at most 300 characters" do
        assert {:ok, %{subtitle: "A line, bold"}} =
                 BlogPost.__guarded_change__(%{
                   title: "t",
                   subtitle: "  A line, <b>bold</b>  ",
                   content: "<p>x</p>",
                   status: :draft,
                   language: "en"
                 })

        assert {:error, _too_long} =
                 BlogPost.__guarded_change__(%{
                   title: "t",
                   subtitle: String.duplicate("a", 301),
                   content: "<p>x</p>",
                   status: :draft,
                   language: "en"
                 })
      end

      test "status outside enum rejected with explicit message" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = BlogPost.__guarded_change__(%{status: :bogus})
      end

      test "title over max_len=500 rejected" do
        long = String.duplicate("x", 501)

        assert {:error,
                [
                  %{
                    field: :title,
                    action: :max_len,
                    message: "The maximum number of characters in the title field is 500" <> _
                  }
                ]} = BlogPost.__guarded_change__(%{title: long})
      end

      test "permissions: trim + downcase + reject empties + uniq" do
        assert {:ok, %{permissions: ["members:read", "members:write"]}} =
                 BlogPost.__guarded_change__(%{
                   permissions: ["  MEMBERS:READ  ", "Members:Read", "", "MEMBERS:WRITE"]
                 })
      end

      test "permissions: non-list is rejected" do
        assert {:error,
                [
                  %{
                    field: :permissions,
                    action: :list,
                    message: _
                  }
                ]} = BlogPost.__guarded_change__(%{permissions: "not a list"})
      end
    end
  end
end
