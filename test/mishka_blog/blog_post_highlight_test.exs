defmodule MishkaBlog.Test.BlogPostHighlightTest do
  @moduledoc """
  A post's code blocks are highlighted with Makeup when the post is written, and stored that way —
  `MishkaBlog.Resources.Changes.HighlightCode`.

  The shape is the one posts imported from the old site already hold:
  `pre.highlight > code.language-x > span.<token>`. Every write here goes through the action an
  admin's form or the JSON:API calls, as an admin holding the post area.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.BlogPost

  @moduletag :integration

  @post "admin:dashboard:blog:post"

  @escapes %{"&" => "&amp;", "<" => "&lt;", ">" => "&gt;"}

  # A lexer that fails on whatever it is handed. A test registers it under a language of its own.
  defmodule FailingLexer do
    def lex(_source, _options), do: raise(ArgumentError, "this lexer fails on purpose")
  end

  setup do
    site = create_site!()

    # Makeup's registry is application env, and a test that registers a lexer must not leave it
    # registered for the next.
    registry = Application.get_all_env(:makeup)

    on_exit(fn ->
      Enum.each(registry, fn {key, value} -> Application.put_env(:makeup, key, value) end)
    end)

    %{site: site, editor: create_user_with_permissions!([@post], site_id: site.id)}
  end

  defp create!(site, actor, content) do
    BlogPost
    |> Ash.Changeset.for_create(:create, post_attrs(content), actor: actor, tenant: site.id)
    |> Ash.create!()
  end

  defp update!(post, actor, attrs) do
    post
    |> Ash.Changeset.for_update(:update, attrs, actor: actor, tenant: post.site_id)
    |> Ash.update!()
  end

  defp post_attrs(content) do
    unique = System.unique_integer([:positive])

    %{
      title: "Code #{unique}",
      slug: "code-#{unique}",
      content: content,
      status: :draft,
      language: "en"
    }
  end

  defp block(language, code), do: ~s(<pre><code class="language-#{language}">#{code}</code></pre>)

  defp query(content, selector),
    do: content |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(content, selector), do: content |> query(selector) |> Enum.count()

  defp code_text(content, language),
    do: content |> query("pre > code.language-#{language}") |> LazyHTML.text()

  describe "a plain block of a known language" do
    test "is stored highlighted, in the shape the imported posts hold", ctx do
      post = create!(ctx.site, ctx.editor, block("elixir", "def hello, do: :world"))

      assert count(post.content, "pre.highlight > code.language-elixir > span.kd") == 1
      assert count(post.content, "pre.highlight > code.language-elixir > span.nf") == 1
      assert code_text(post.content, "elixir") == "def hello, do: :world"
    end

    test "HEEx and Erlang too", ctx do
      heex = ~S(&lt;.link navigate={~p"/"}&gt;Home&lt;/.link&gt;)
      erlang = "f(X) -&gt; X + 1."

      post = create!(ctx.site, ctx.editor, block("heex", heex) <> block("erlang", erlang))

      assert count(post.content, "pre.highlight > code.language-heex > span.nf") == 2
      assert code_text(post.content, "heex") == ~S(<.link navigate={~p"/"}>Home</.link>)

      assert count(post.content, "pre.highlight > code.language-erlang > span.nf") == 1
      assert code_text(post.content, "erlang") == "f(X) -> X + 1."
    end

    test "JavaScript, TypeScript and CSS too", ctx do
      js = "const total = items.map((item) =&gt; item.price);"
      ts = "let name: string = &quot;Mishka&quot;;"
      css = ".card &gt; a:hover { color: #c2a9ff; margin: 0 4px; }"

      post =
        create!(
          ctx.site,
          ctx.editor,
          block("js", js) <> block("typescript", ts) <> block("css", css)
        )

      assert count(post.content, "pre.highlight > code.language-js > span.kd") == 1
      assert count(post.content, "pre.highlight > code.language-js > span.nf") == 1
      assert code_text(post.content, "js") == "const total = items.map((item) => item.price);"

      assert count(post.content, "pre.highlight > code.language-typescript > span.s") == 1
      assert code_text(post.content, "typescript") == ~s(let name: string = "Mishka";)

      assert count(post.content, "pre.highlight > code.language-css > span.nc") == 1
      assert count(post.content, "pre.highlight > code.language-css > span.mi") == 1

      assert code_text(post.content, "css") ==
               ".card > a:hover { color: #c2a9ff; margin: 0 4px; }"
    end

    test "and under the names a lexer is known by, and its file extensions", ctx do
      samples = [
        {"ex", "def a, do: 1"},
        {"exs", "def a, do: 1"},
        {"iex", "def a, do: 1"},
        {"Elixir", "def a, do: 1"},
        {"eex", "&lt;%= @name %&gt;"},
        {"erl", "f(X) -&gt; X."},
        {"javascript", "let a = 1;"},
        {"ts", "let a = 1;"}
      ]

      post =
        create!(
          ctx.site,
          ctx.editor,
          Enum.map_join(samples, fn {lang, code} -> block(lang, code) end)
        )

      for {language, _code} <- samples do
        assert count(post.content, "pre.highlight > code.language-#{language} > span") > 1,
               "language-#{language} was left plain"
      end
    end

    test "keeps the classes the pre already had", ctx do
      content = ~s(<pre class="wide"><code class="language-elixir">:ok</code></pre>)

      post = create!(ctx.site, ctx.editor, content)

      assert post.content =~ ~s(<pre class="wide highlight">)
    end
  end

  describe "left as written" do
    test "a block that is already highlighted", ctx do
      content =
        ~s(<pre class="highlight"><code class="language-elixir"><span class="nc">Foo</span>) <>
          ~s(<span class="o">.</span><span class="ss">:bar</span></code></pre>)

      assert create!(ctx.site, ctx.editor, content).content == content
    end

    test "a block with no language, or one no lexer answers to", ctx do
      content =
        "<pre><code>echo hi</code></pre>" <>
          block("bash", "echo hi") <> block("shell", "ls") <> block("", "x = 1")

      assert create!(ctx.site, ctx.editor, content).content == content
    end

    test "inline code, whatever its class says", ctx do
      content = ~s(<p>Run <code class="language-elixir">mix test</code> first.</p>)

      assert create!(ctx.site, ctx.editor, content).content == content
    end

    test "a pre holding more than its one code", ctx do
      content =
        ~s(<pre><code class="language-elixir">def a, do: 1</code><code>b</code></pre>)

      assert create!(ctx.site, ctx.editor, content).content == content
    end
  end

  describe "the code stays text" do
    test "markup written as text in a block is text after it is highlighted", ctx do
      code = ~s|html = "&lt;script&gt;alert(1)&lt;/script&gt;" &amp;&amp; :ok|

      post = create!(ctx.site, ctx.editor, block("elixir", code))

      assert count(post.content, "pre.highlight > code.language-elixir > span.s") == 1
      assert count(post.content, "script") == 0
      refute post.content =~ "<script"
      assert code_text(post.content, "elixir") == ~s|html = "<script>alert(1)</script>" && :ok|
    end

    test "a block showing a code block shows it as text, and holds no block of its own", ctx do
      shown =
        "&lt;pre&gt;&lt;code class=&quot;language-elixir&quot;&gt;IO.puts(1)&lt;/code&gt;&lt;/pre&gt;"

      post = create!(ctx.site, ctx.editor, block("html", shown))

      assert count(post.content, "pre.highlight > code.language-html > span.nt") > 1
      assert count(post.content, "pre") == 1
      assert count(post.content, "code") == 1

      assert code_text(post.content, "html") ==
               ~s|<pre><code class="language-elixir">IO.puts(1)</code></pre>|
    end

    test "a tag written into a block is gone before anything is highlighted", ctx do
      post = create!(ctx.site, ctx.editor, block("elixir", "IO.puts(1)<script>alert(1)</script>"))

      assert count(post.content, "pre.highlight > code.language-elixir > span") > 1
      refute post.content =~ "<script"
    end

    # THE SANITIZER RUNS AGAIN on every later save and every render, and drops a text node that is
    # only whitespace: a line's trailing space beside a newline would join two lines into one.
    test "and keeps every space, tab and newline through the sanitizing that follows", ctx do
      code = "def a do \n\t:ok\t\n  \n  b = 1 \t c\nend"

      post = create!(ctx.site, ctx.editor, block("elixir", code))

      assert code_text(post.content, "elixir") == code
      assert HtmlSanitizeEx.html5(post.content) == post.content
    end
  end

  describe "an update" do
    test "highlights the code it was handed in place of the old", ctx do
      post = create!(ctx.site, ctx.editor, block("elixir", "def old, do: 1"))

      updated = update!(post, ctx.editor, %{content: block("elixir", "def new, do: 2")})

      assert count(updated.content, "pre.highlight > code.language-elixir > span.nf") == 1
      assert code_text(updated.content, "elixir") == "def new, do: 2"
    end

    # THE ADMIN EDITS THE STORED HTML, highlighted blocks and all, and saves it back.
    test "of a highlighted post leaves its blocks as they are and highlights only a new one",
         ctx do
      post = create!(ctx.site, ctx.editor, block("elixir", "def kept, do: 1"))

      same = update!(post, ctx.editor, %{title: "Renamed", content: post.content})
      assert same.content == post.content

      grown = update!(post, ctx.editor, %{content: post.content <> block("erlang", "ok.")})

      assert String.starts_with?(grown.content, post.content)
      assert count(grown.content, "pre.highlight > code.language-erlang > span") > 1
    end

    test "and a master's create and update highlight the same way", ctx do
      master = create_user_with_permissions!([@post])

      post =
        BlogPost
        |> Ash.Changeset.for_create(
          :master_create,
          Map.put(post_attrs(block("elixir", "def a, do: 1")), :site_id, ctx.site.id),
          actor: master
        )
        |> Ash.create!()

      assert count(post.content, "pre.highlight > code.language-elixir > span.kd") == 1

      # A master edits a post read the way the admin reads it, across every site.
      updated =
        BlogPost
        |> Ash.get!(post.id, action: :master_get, actor: master)
        |> Ash.Changeset.for_update(
          :master_update,
          %{content: block("heex", "&lt;p&gt;{@x}&lt;/p&gt;")},
          actor: master
        )
        |> Ash.update!()

      assert count(updated.content, "pre.highlight > code.language-heex > span") > 1
    end

    # A version written while its language had no lexer holds the block plain, as every post did
    # before this change.
    test "restoring a version highlights the block it held plain", ctx do
      post = create!(ctx.site, ctx.editor, block("later", "def a, do: 1"))
      assert post.content == block("later", "def a, do: 1")

      updated = update!(post, ctx.editor, %{content: "<p>Rewritten</p>"})
      Makeup.Registry.register_lexer_with_name("later", {Makeup.Lexers.ElixirLexer, []})

      restored =
        updated
        |> Ash.Changeset.for_update(
          :restore_version,
          %{version_id: first_version(BlogPost.Version, post.id, tenant: ctx.site.id).id},
          actor: ctx.editor,
          tenant: ctx.site.id
        )
        |> Ash.update!()

      assert count(restored.content, "pre.highlight > code.language-later > span.kd") == 1
    end
  end

  describe "a lexer that fails" do
    @tag :capture_log
    test "leaves its block plain, and the post and its other blocks are still written", ctx do
      Makeup.Registry.register_lexer_with_name("failing", {FailingLexer, []})

      post =
        create!(
          ctx.site,
          ctx.editor,
          block("failing", "anything") <> block("elixir", "def a, do: 1")
        )

      assert post.content =~ block("failing", "anything")
      assert count(post.content, "pre.highlight > code.language-elixir > span.kd") == 1
    end
  end

  test "a post of 150 KB in 35 blocks has every block highlighted", ctx do
    code =
      ~S"""
      defmodule Shop.Cart do
        @moduledoc "A cart & its items: <total> in cents."
        def add(%{items: items} = cart, item) when is_map(item), do: %{cart | items: [item | items]}
        def total(%{items: items}), do: Enum.reduce(items, 0, &(&1.price + &2))
      end
      """
      |> String.duplicate(15)
      |> String.replace(Map.keys(@escapes), &Map.fetch!(@escapes, &1))

    content =
      Enum.map_join(1..35, fn index ->
        "<h2>Step #{index}</h2><p>#{String.duplicate("Words about it. ", 20)}</p>" <>
          block("elixir", code)
      end)

    assert byte_size(content) > 150_000

    post = create!(ctx.site, ctx.editor, content)

    assert count(post.content, "pre.highlight > code.language-elixir") == 35
    assert count(post.content, "pre:not(.highlight)") == 0
  end
end
