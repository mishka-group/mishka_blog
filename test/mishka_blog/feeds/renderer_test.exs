# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Feeds.RendererTest do
  @moduledoc """
  A feed written in each format parses back to what went in: HTML survives in CDATA whatever it
  holds, a `]]>` included, every text keeps only the characters XML 1.0 allows and only UTF-8, markup in a
  title is escaped, and an Atom entry with no author names the feed.
  """
  use ExUnit.Case, async: true

  import SweetXml

  alias MishkaBlog.Feeds.Renderer

  defp feed(item) do
    %{
      title: "Feed Site",
      description: "Feed Site",
      language: "en",
      link: "https://example.test/blog",
      self_url: "https://example.test/feed",
      updated_at: ~U[2026-11-01 10:00:00Z],
      items: [
        Map.merge(
          %{
            url: "https://example.test/blog/hello",
            title: "Hello",
            summary: "About it",
            content_html: "<p>Body</p>",
            published_at: ~U[2026-11-01 10:00:00Z],
            updated_at: ~U[2026-11-01 10:00:00Z],
            authors: ["Mona"],
            categories: ["Elixir"],
            image_url: nil,
            language: "en"
          },
          item
        )
      ]
    }
  end

  test "keeps HTML in CDATA, a ]]> included, and escapes a title" do
    rss = Renderer.render(:rss, feed(%{title: "A & <b>B</b>", content_html: "<p>a ]]> b</p>"}))

    assert rss =~ "<![CDATA["
    assert xpath(rss, ~x"//item/title/text()"s) == "A & <b>B</b>"
    assert xpath(rss, ~x"//item/content:encoded/text()"s) == "<p>a ]]> b</p>"
  end

  test "takes the characters XML forbids out of every text" do
    item = %{title: "Bad\u0001 title", summary: "x\u0000y", content_html: "<p>a\u000Bb￾c</p>"}
    rss = Renderer.render(:rss, feed(item))

    assert xpath(rss, ~x"//item/title/text()"s) == "Bad title"
    assert xpath(rss, ~x"//item/description/text()"s) == "xy"
    assert xpath(rss, ~x"//item/content:encoded/text()"s) == "<p>abc</p>"

    assert [%{"title" => "Bad title"}] =
             :json |> Renderer.render(feed(item)) |> Jason.decode!() |> Map.fetch!("items")
  end

  test "keeps every character XML allows, beyond the Basic Multilingual Plane included" do
    text = "tab\there\nسلام 😀 \u00A0\u{FFFD}"

    for format <- [:rss, :atom] do
      doc = Renderer.render(format, feed(%{title: text}))
      path = if format == :rss, do: ~x"//item/title/text()"s, else: ~x"//entry/title/text()"s
      assert xpath(doc, path) == text
    end
  end

  test "drops bytes that are not UTF-8 and still writes every format" do
    item = %{title: "a" <> <<0xFF, 0xC3>> <> "b", content_html: <<"<p>x", 0x80, "y</p>">>}

    for format <- Renderer.formats(), do: assert(is_binary(Renderer.render(format, feed(item))))

    rss = Renderer.render(:rss, feed(item))
    assert xpath(rss, ~x"//item/title/text()"s) == "ab"
    assert xpath(rss, ~x"//item/content:encoded/text()"s) == "<p>xy</p>"
  end

  test "an Atom entry with no author names the feed, and its content is html" do
    atom = Renderer.render(:atom, feed(%{authors: []}))

    assert xpath(
             atom,
             ~x"//*[local-name()='entry']/*[local-name()='author']/*[local-name()='name']/text()"s
           ) == "Feed Site"

    assert xpath(atom, ~x"//*[local-name()='entry']/*[local-name()='content']/@type"s) == "html"

    assert xpath(atom, ~x"//*[local-name()='entry']/*[local-name()='category']/@term"s) ==
             "Elixir"
  end
end
