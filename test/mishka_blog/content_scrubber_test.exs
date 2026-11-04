# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.ContentScrubberTest do
  @moduledoc """
  What a post's content keeps and what it still removes, through the real `BlogPost` pipeline.
  """

  use MishkaBlog.DataCase, async: false
  @moduletag :unit

  alias MishkaBlog.BlogPost

  defp clean(html) do
    assert {:ok, %{content: content}} =
             BlogPost.__guarded_change__(%{
               title: "T",
               content: html,
               status: :draft,
               language: "en"
             })

    content
  end

  defp find(tokens, tag) when is_list(tokens), do: Enum.flat_map(tokens, &find(&1, tag))
  defp find({tag, _attrs, _children} = node, tag), do: [node | find_in(node, tag)]
  defp find({_other, _attrs, _children} = node, tag), do: find_in(node, tag)
  defp find(_text, _tag), do: []

  defp find_in({_, _, children}, tag), do: find(children, tag)

  defp attrs_of(html, tag) do
    html |> HtmlSanitizeEx.Parser.parse() |> find(tag) |> Enum.flat_map(&elem(&1, 1)) |> Map.new()
  end

  describe "figure and figcaption" do
    test "are kept with their class, and the caption stays inside the figure" do
      out =
        clean(
          ~s|<figure class="gallery"><img src="/a.jpg" alt="A"><figcaption>Caption</figcaption></figure>|
        )

      assert {"figure", _, children} = HtmlSanitizeEx.Parser.parse(out)
      assert [{"figcaption", _, ["Caption"]}] = find(children, "figcaption")
      assert attrs_of(out, "figure")["class"] == "gallery"
    end

    test "drop event handlers and unknown attributes like a div does" do
      out =
        clean(
          ~s|<figure onclick="x()" onmouseover="x()" style="x" data-x="1"><figcaption onclick="x()">c</figcaption></figure>|
        )

      refute out =~ "onclick"
      refute out =~ "onmouseover"
      assert out =~ "<figcaption>c</figcaption>"
    end
  end

  describe "srcset and sizes" do
    test "are kept on img and source when every candidate is http, https or relative" do
      srcset = "/a.jpg 1x, https://cdn.example.com/b.jpg 2x, //cdn.example.com/c.jpg 3x"

      out =
        clean(~s|<img src="/a.jpg" srcset="#{srcset}" sizes="(max-width: 600px) 100vw, 50vw">|)

      attrs = attrs_of(out, "img")
      assert attrs["srcset"] == srcset
      assert attrs["sizes"] == "(max-width: 600px) 100vw, 50vw"

      out =
        clean(~s|<source srcset="/a.webp 480w, /b.webp 800w" sizes="100vw" type="image/webp">|)

      assert attrs_of(out, "source")["srcset"] == "/a.webp 480w, /b.webp 800w"
      assert attrs_of(out, "source")["sizes"] == "100vw"
    end

    test "are dropped when any candidate uses javascript:, data: or an entity-hidden scheme" do
      for bad <- [
            "javascript:alert(1) 1x",
            "/a.jpg 1x, javascript:alert(1) 2x",
            "data:image/svg+xml;base64,PHN2Zz4= 1x",
            "/a.jpg 1x, data:text/html;base64,AAAA 2x",
            "&#106;avascript:alert(1) 1x",
            "/a.jpg 1x, &#106;avascript:alert(1) 2x",
            "JaVaScRiPt:alert(1) 1x",
            "/a.jpg 1x onerror=alert(1)",
            "/a.jpg bogus"
          ] do
        out = clean(~s|<p>x</p><img src="/a.jpg" srcset="#{bad}"><source srcset="#{bad}">|)
        refute out =~ "srcset", "kept srcset #{inspect(bad)}: #{out}"
        refute out =~ "javascript:"
        assert out =~ ~s|src="/a.jpg"|
      end
    end

    test "sizes with markup characters is dropped" do
      out = clean(~s|<img src="/a.jpg" sizes="100vw&quot; onerror=&quot;x">|)
      refute out =~ "sizes"
      refute out =~ "onerror"
    end
  end

  describe "iframe allowfullscreen and allow" do
    test "a YouTube style embed keeps fullscreen and its safe permissions" do
      out =
        clean(
          ~s|<iframe src="https://www.youtube.com/embed/x" allowfullscreen allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen"></iframe>|
        )

      attrs = attrs_of(out, "iframe")
      assert Map.has_key?(attrs, "allowfullscreen")
      assert attrs["src"] == "https://www.youtube.com/embed/x"

      assert attrs["allow"] |> String.split("; ") |> Enum.sort() ==
               Enum.sort(MishkaBlog.ContentScrubber.allowed_permissions())
    end

    test "allow filters unknown tokens and origin lists" do
      out =
        clean(
          ~s|<iframe src="https://v.example.com/e" allow="camera; microphone *; geolocation; autoplay; fullscreen https://evil.example; payment"></iframe>|
        )

      assert attrs_of(out, "iframe")["allow"] == "autoplay"
    end

    test "allow with only unknown tokens is dropped" do
      out = clean(~s|<iframe src="https://v.example.com/e" allow="camera; microphone"></iframe>|)
      refute out =~ "allow"
      assert out =~ "<iframe"
    end

    test "iframes html5 refuses stay refused" do
      out =
        clean(
          ~s|<iframe src="javascript:alert(1)" allowfullscreen></iframe><iframe srcdoc="<script>alert(1)</script>" src="data:text/html;base64,AAAA"></iframe><iframe src="https://v.example.com/e" onload="x()" allowfullscreen="x"></iframe>|
        )

      refute out =~ "javascript:"
      refute out =~ "srcdoc"
      refute out =~ "data:"
      refute out =~ "onload"
      refute out =~ "<script"
    end
  end

  describe "style, object, embed and applet" do
    test "style and object are dropped with everything inside them" do
      out =
        clean(
          ~s|<p>keep</p><!-- hidden --><style>body { background: url(https://evil.example/x.png) }</style>| <>
            ~s|<object data="https://evil.example/x.swf" type="application/x-shockwave-flash" class="c">| <>
            ~s|<param name="movie" value="https://evil.example/x.swf">fallback</object>|
        )

      refute out =~ "<style"
      refute out =~ "<object"
      refute out =~ "<param"
      refute out =~ "background"
      refute out =~ "fallback"
      refute out =~ "evil.example"
      refute out =~ "hidden"
      assert out =~ "<p>keep</p>"
    end

    test "embed and applet stay removed" do
      out =
        clean(
          ~s|<p>keep</p><embed src="https://evil.example/x.swf" type="application/x-shockwave-flash">| <>
            ~s|<applet code="Evil.class" archive="https://evil.example/x.jar"></applet>|
        )

      refute out =~ "<embed"
      refute out =~ "<applet"
      refute out =~ "evil.example"
      assert out =~ "<p>keep</p>"
    end

    test "figures, srcset and iframe embeds next to them are kept" do
      out =
        clean(
          ~s|<style>p { color: red }</style><figure class="g"><img src="/a.jpg" srcset="/a.jpg 1x, /b.jpg 2x">| <>
            ~s|<figcaption>c</figcaption></figure><object data="/x.swf"></object>| <>
            ~s|<iframe src="https://www.youtube.com/embed/x" allowfullscreen allow="autoplay"></iframe>|
        )

      assert attrs_of(out, "figure")["class"] == "g"
      assert out =~ "<figcaption>c</figcaption>"
      assert attrs_of(out, "img")["srcset"] == "/a.jpg 1x, /b.jpg 2x"
      assert attrs_of(out, "iframe")["allow"] == "autoplay"
      assert Map.has_key?(attrs_of(out, "iframe"), "allowfullscreen")
      refute out =~ "<style"
      refute out =~ "<object"
    end
  end

  describe "everything else follows html5" do
    test "scripts, on* attributes and dangerous URLs are removed everywhere" do
      html = """
      <script>alert(1)</script>
      <a href="javascript:alert(1)" onclick="x()">a</a>
      <img src="javascript:alert(1)" onerror="x()" onload="x()">
      <p onmouseover="x()">p</p><div onclick="x()">d</div><video onplay="x()" src="data:video/mp4;base64,AA"></video>
      <svg onload="x()"></svg>
      """

      out = clean(html)
      refute out =~ ~r/\bon[a-z]+\s*=/i
      refute out =~ "<script"
      refute out =~ "javascript:"
      refute out =~ "data:"
      refute out =~ "<svg"
    end

    test "the scrubber output equals html5 for content without the three additions" do
      html =
        ~s|<h2>Title</h2><p class="x">Hi <b>there</b> <a href="https://a.example" title="t">l</a></p><ul><li>1</li></ul><img src="/a.jpg" alt="a" width="10">|

      assert MishkaBlog.ContentScrubber.sanitize(html) == HtmlSanitizeEx.html5(html)
    end

    test "other ops are left for the next sanitizer" do
      assert MishkaBlog.ContentScrubber.sanitize("x", :trim) == nil
    end
  end
end
